import DiskKit
import Foundation
import Observation
import os

/// What the menu shows for a disk image with auto-eject armed.
public enum ImageEjectStatus: Equatable, Sendable {
    /// Will be ejected at this time if it is not in use then.
    case scheduled(Date)
    /// Was in use at its deadline; waits for the blocking apps to quit.
    case waitingWhileInUse
}

/// Ejects disk images (DMG, ISO…) automatically after a timeout.
/// Design: docs/design/0002-disk-image-auto-eject.md.
///
/// Power: one sleeping task for the earliest deadline (with timer tolerance),
/// rescheduled only when disks or settings change. When an image is busy at its
/// deadline we wait for the blocking processes to exit (`DispatchSource` process
/// sources), with a 5-minute fallback re-check — never polling.
@MainActor
@Observable
public final class ImageAutoEjectScheduler {
    /// Status per device ID, for the menu.
    public private(set) var statuses: [String: ImageEjectStatus] = [:]

    /// Called after an image was ejected automatically.
    @ObservationIgnored public var onAutoEjected: ((Device) -> Void)?

    struct Entry: Equatable {
        /// When the countdown started: attach time, or when the image last became idle.
        var countdownStart: Date
        /// Set while the image was busy at its deadline.
        var recheckAt: Date?
        var wasBusy = false
    }

    @ObservationIgnored private(set) var entries: [String: Entry] = [:]
    @ObservationIgnored private let store: DiskStore
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let clock: any Clock<Duration>
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var wakeTask: Task<Void, Never>?
    @ObservationIgnored private var exitSources: [DispatchSourceProcess] = []
    @ObservationIgnored private var isEvaluating = false
    @ObservationIgnored private let log = Logger(subsystem: "app.umounter", category: "image-auto-eject")

    static let busyRecheckInterval: TimeInterval = 5 * 60

    public init(
        store: DiskStore, settings: AppSettings,
        clock: any Clock<Duration> = ContinuousClock(), now: @escaping () -> Date = Date.init
    ) {
        self.store = store
        self.settings = settings
        self.clock = clock
        self.now = now
    }

    /// Starts following disk and settings changes.
    public func start() { observe() }

    private var timeout: TimeInterval { TimeInterval(max(settings.autoEjectMinutes, 1) * 60) }

    /// Devices auto-eject applies to under the current settings.
    func eligibleDevices() -> [Device] {
        guard settings.autoEjectImages else { return [] }
        let exceptions = Set(settings.imageExceptions.map(\.id))
        let neverEject = Set(settings.neverEject.map(\.id))
        return store.devices.filter { device in
            guard device.category == .diskImage, let url = device.diskImageURL else { return false }
            if exceptions.contains(url.path) { return false }
            if !device.ruleIDs.isDisjoint(with: neverEject) { return false }
            // Remounting an encrypted image needs its password: never automatic.
            if device.volumes.contains(where: \.isEncrypted) { return false }
            if settings.autoEjectReadOnlyOnly && device.volumes.contains(where: \.isWritable) { return false }
            return true
        }
    }

    private func observe() {
        withObservationTracking {
            _ = store.devices
            _ = settings.autoEjectImages
            _ = settings.autoEjectMinutes
            _ = settings.autoEjectMode
            _ = settings.autoEjectReadOnlyOnly
            _ = settings.imageExceptions
            _ = settings.neverEject
        } onChange: { [weak self] in
            Task { @MainActor in self?.observe() }
        }
        syncEntries()
    }

    /// Adds entries for new eligible images, drops entries for the rest, re-arms the timer.
    func syncEntries() {
        let eligible = eligibleDevices()
        let ids = Set(eligible.map(\.id))
        entries = entries.filter { ids.contains($0.key) }
        for device in eligible where entries[device.id] == nil {
            entries[device.id] = Entry(countdownStart: device.attachedAt ?? now())
        }
        log.debug("tracking \(self.entries.count) image(s) of \(self.store.devices.count) device(s); enabled=\(self.settings.autoEjectImages)")
        publishAndReschedule()
    }

    func deadline(of entry: Entry) -> Date {
        let due = entry.countdownStart.addingTimeInterval(timeout)
        return max(due, entry.recheckAt ?? .distantPast)
    }

    /// Handles every entry whose deadline has passed.
    public func evaluate() async {
        guard !isEvaluating else { return }
        isEvaluating = true
        defer { isEvaluating = false }
        cancelExitWatchers()

        let current = now()
        for (id, entry) in entries.sorted(by: { $0.key < $1.key }) where deadline(of: entry) <= current {
            guard let device = store.devices.first(where: { $0.id == id }) else {
                entries[id] = nil // gone; dropping it also prevents a zero-delay re-arm
                continue
            }

            let blockers = await store.blockers(of: device)
            if hasMountedNestedImage(device) || !blockers.isEmpty {
                log.info("\(id, privacy: .public) busy at deadline (\(blockers.count) blocker(s))")
                entries[id]?.wasBusy = true
                entries[id]?.recheckAt = current.addingTimeInterval(Self.busyRecheckInterval)
                watchForExit(of: blockers.map(\.pid))
                continue
            }

            // "When no longer in use": the countdown restarts once the image goes idle.
            if entry.wasBusy && settings.autoEjectMode == .whenIdle {
                entries[id] = Entry(countdownStart: current)
                continue
            }

            entries[id] = nil
            if await store.eject(device, mode: .eject) == nil {
                log.info("auto-ejected \(id, privacy: .public)")
                onAutoEjected?(device)
            } else if store.devices.contains(where: { $0.id == id }) {
                entries[id] = Entry(countdownStart: entry.countdownStart, recheckAt: current.addingTimeInterval(Self.busyRecheckInterval), wasBusy: true)
            }
        }
        publishAndReschedule()
    }

    /// An image whose backing file lives on this device must be ejected first.
    private func hasMountedNestedImage(_ device: Device) -> Bool {
        let mountPoints = device.volumes.compactMap { $0.volumePath?.path }
        return store.devices.contains { other in
            guard other.id != device.id, let path = other.diskImageURL?.path else { return false }
            return mountPoints.contains { path.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") }
        }
    }

    // MARK: - Waking up

    private func publishAndReschedule() {
        statuses = entries.mapValues { $0.wasBusy ? .waitingWhileInUse : .scheduled(deadline(of: $0)) }

        wakeTask?.cancel()
        guard let next = entries.values.map(deadline(of:)).min() else { return }
        let delay = max(next.timeIntervalSince(now()), 0)
        wakeTask = Task { [weak self, clock] in
            // Generous tolerance lets the kernel coalesce this wakeup with others.
            try? await clock.sleep(for: .seconds(delay), tolerance: .seconds(min(30, delay / 10)))
            guard !Task.isCancelled else { return }
            await self?.evaluate()
        }
    }

    private func watchForExit(of pids: [pid_t]) {
        for pid in Set(pids) {
            let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated { self?.blockerExited() }
            }
            source.resume()
            exitSources.append(source)
        }
    }

    private func blockerExited() {
        let current = now()
        for id in entries.keys where entries[id]?.wasBusy == true {
            entries[id]?.recheckAt = current
        }
        Task { await evaluate() }
    }

    private func cancelExitWatchers() {
        exitSources.forEach { $0.cancel() }
        exitSources.removeAll()
    }
}
