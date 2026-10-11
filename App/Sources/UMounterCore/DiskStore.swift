import DiskKit
import Foundation
import Observation
import os

/// Why an operation on one device failed, ready to show to the user.
public struct OperationFailure: Identifiable, Sendable {
    public let id = UUID()
    /// The device that failed, so the UI can retry it.
    public var deviceID: String?
    public var deviceName: String
    public var message: String
    /// Processes holding files open on the device (filled for "in use" errors).
    public var blockers: [Blocker]
}

/// An operation in flight on one device, for progress UI.
public struct DiskOperation: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case eject, unmount, mount
    }

    public var kind: Kind
    public var deviceName: String
    /// "USB drive", "SD card", "disk image"… (see `Device.kindDescription`).
    public var deviceKind: String

    public init(kind: Kind, deviceName: String, deviceKind: String) {
        self.kind = kind
        self.deviceName = deviceName
        self.deviceKind = deviceKind
    }

    /// Progress text such as `Ejecting “JAVAD” (USB drive)…`, or nil when no
    /// operation the user wants to see is running.
    public static func progressMessage(for operations: [DiskOperation], showEjecting: Bool, showMounting: Bool) -> String? {
        let visible = operations.filter { $0.kind == .mount ? showMounting : showEjecting }
            .sorted { $0.deviceName.localizedStandardCompare($1.deviceName) == .orderedAscending }
        guard let first = visible.first else { return nil }
        let verb = switch first.kind {
        case .eject: "Ejecting"
        case .unmount: "Unmounting"
        case .mount: "Mounting"
        }
        if visible.count == 1 { return "\(verb) “\(first.deviceName)” (\(first.deviceKind))…" }
        return "\(verb) \(visible.count) disks: " + visible.map(\.deviceName).joined(separator: ", ") + "…"
    }
}

/// The menu bar icon's state, ordered by priority.
public enum StatusIconState: Equatable, Sendable {
    /// An eject, park or mount is running.
    case working
    /// `count` devices are mounted (what "Eject All" would act on).
    case mounted(count: Int)
    /// Everything UMounter touched is unmounted but still attached: safe to unplug.
    case safeToUnplug
    /// No external disks.
    case empty
}

/// Observable disk state for the UI. Refreshes only when DiskArbitration reports a
/// change (debounced), never on a timer.
@MainActor
@Observable
public final class DiskStore {
    public private(set) var disks: [DiskInfo] = []
    /// Every ejectable device (the "Eject ▸" menu).
    public private(set) var devices: [Device] = []
    /// External volumes that can be mounted.
    public private(set) var mountableVolumes: [DiskInfo] = []
    /// Devices UMounter unmounted (parked) that are still attached and can be remounted.
    public private(set) var parkedDeviceIDs: Set<String> = []
    /// Operations in flight, by device ID (drives the progress HUD).
    public private(set) var activeOperations: [String: DiskOperation] = [:]

    /// Devices with an operation in flight.
    public var busyDeviceIDs: Set<String> { Set(activeOperations.keys) }

    /// Which devices "Eject All" and automatic ejection act on.
    public var filter: EjectFilter = .all {
        didSet { if filter != oldValue { apply(disks) } }
    }
    /// Volumes (rule IDs) that "Remount" leaves unmounted.
    public var neverRemount: Set<String> = []

    /// Devices "Eject All" would act on; the menu bar badge counts these.
    public var ejectAllDevices: [Device] { devices.filter(filter.includes) }

    public var canRemount: Bool { !parkedDeviceIDs.isEmpty }

    /// What the menu bar icon should say at a glance.
    public var statusIconState: StatusIconState {
        if !busyDeviceIDs.isEmpty { return .working }
        if !devices.isEmpty { return .mounted(count: ejectAllDevices.count) }
        if canRemount { return .safeToUnplug }
        return .empty
    }

    @ObservationIgnored private let service: any DiskService
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private let log = Logger(subsystem: "app.umounter", category: "store")

    public init(service: any DiskService) {
        self.service = service
    }

    /// Loads the first snapshot and starts listening for disk events.
    public func start() {
        guard eventTask == nil else { return }
        let events = service.events
        eventTask = Task { [weak self] in
            for await _ in events { self?.scheduleRefresh() }
        }
        scheduleRefresh(after: .zero)
    }

    public func stop() {
        eventTask?.cancel()
        refreshTask?.cancel()
        eventTask = nil
    }

    /// Rebuilds the snapshot off the main thread.
    public func refresh() async {
        let service = self.service
        let snapshot = await Task.detached(priority: .utility) { service.disks() }.value
        apply(snapshot)
    }

    // MARK: - Operations

    /// Ejects (or parks) every device in `ejectAllDevices`, independent devices in parallel.
    @discardableResult
    public func ejectAll(mode: EjectMode) async -> [OperationFailure] {
        await withTaskGroup(of: OperationFailure?.self) { group in
            for device in ejectAllDevices {
                group.addTask { await self.eject(device, mode: mode) }
            }
            var failures: [OperationFailure] = []
            for await failure in group { if let failure { failures.append(failure) } }
            return failures
        }
    }

    @discardableResult
    public func eject(_ device: Device, mode: EjectMode) async -> OperationFailure? {
        guard activeOperations[device.id] == nil else { return nil }
        activeOperations[device.id] = DiskOperation(
            kind: mode == .park ? .unmount : .eject, deviceName: device.name, deviceKind: device.kindDescription
        )
        defer { activeOperations[device.id] = nil }

        do {
            try await service.ejectSafely(device.target, mode: mode)
            log.info("\(mode == .park ? "parked" : "ejected", privacy: .public) \(device.id, privacy: .public)")
            if mode == .park && !device.isNetwork { parkedDeviceIDs.insert(device.id) }
            await refresh()
            return nil
        } catch {
            log.error("eject \(device.id, privacy: .public) failed: \(error, privacy: .public)")
            await refresh()
            return await failure(for: device, error: error)
        }
    }

    @discardableResult
    public func mount(_ volume: DiskInfo) async -> OperationFailure? {
        let id = volume.id
        activeOperations[id] = DiskOperation(
            kind: .mount, deviceName: volume.volumeName ?? id, deviceKind: Device.kindDescription(for: volume)
        )
        defer { activeOperations[id] = nil }
        do {
            try await service.mount(DiskTarget(volume), whole: false, readOnly: false)
            await refresh()
            return nil
        } catch {
            await refresh()
            return OperationFailure(deviceID: nil, deviceName: volume.volumeName ?? volume.id, message: "\(error)", blockers: [])
        }
    }

    /// Remounts every device UMounter parked that is still attached.
    @discardableResult
    public func remountParked() async -> [OperationFailure] {
        var failures: [OperationFailure] = []
        for id in parkedDeviceIDs.sorted() {
            let volumeIDs = Set(mountableVolumes.filter { $0.physicalRootBSDName == id }.compactMap(\.ruleID))
            if !volumeIDs.isEmpty && volumeIDs.isSubset(of: neverRemount) { continue }
            let names = mountableVolumes.filter { $0.physicalRootBSDName == id }.compactMap(\.volumeName)
            activeOperations[id] = DiskOperation(
                kind: .mount, deviceName: names.isEmpty ? id : names.joined(separator: ", "),
                deviceKind: disks.first { $0.bsdName == id }.map(Device.kindDescription(for:)) ?? "disk"
            )
            defer { activeOperations[id] = nil }
            do {
                try await service.mountVolumes(onDevice: id, readOnly: false)
                parkedDeviceIDs.remove(id)
            } catch {
                let name = disks.first { $0.bsdName == id }?.mediaName ?? id
                failures.append(OperationFailure(deviceID: id, deviceName: name, message: "\(error)", blockers: []))
            }
        }
        await refresh()
        return failures
    }

    // MARK: - Internals

    private func scheduleRefresh(after delay: Duration = .milliseconds(50)) {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            if delay > .zero {
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled else { return }
            }
            await self?.refresh()
        }
    }

    func apply(_ snapshot: [DiskInfo]) {
        disks = snapshot
        devices = DiskCatalog.devices(from: snapshot, alsoEject: filter.alsoEject)
        mountableVolumes = DiskCatalog.mountableVolumes(from: snapshot)
        // Forget parked devices that were unplugged or got mounted by someone else.
        let stillParked = Set(mountableVolumes.compactMap(\.physicalRootBSDName))
        parkedDeviceIDs.formIntersection(stillParked)
    }

    /// Processes holding files on any of the device's volumes (scanned off the main thread).
    public func blockers(of device: Device, includeFiles: Bool = false) async -> [Blocker] {
        let service = self.service
        let paths = device.volumes.compactMap(\.volumePath)
        return await Task.detached(priority: .utility) {
            var byPID: [pid_t: Blocker] = [:]
            for blocker in paths.flatMap({ service.blockers(onVolume: $0, includeFiles: includeFiles) }) {
                if var existing = byPID[blocker.pid] {
                    existing.openFiles += blocker.openFiles
                    byPID[blocker.pid] = existing
                } else {
                    byPID[blocker.pid] = blocker
                }
            }
            return byPID.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }.value
    }

    /// I/O counters of the device's physical disk (nil for network volumes).
    public func ioCounters(of device: Device) -> IOCounters? {
        device.isNetwork ? nil : service.ioCounters(bsdName: device.id)
    }

    private func failure(for device: Device, error: Error) async -> OperationFailure {
        var blockers: [Blocker] = []
        if let diskError = error as? DiskError, diskError.code == .busy {
            blockers = await self.blockers(of: device, includeFiles: true)
        }
        return OperationFailure(deviceID: device.id, deviceName: device.name, message: "\(error)", blockers: blockers)
    }
}
