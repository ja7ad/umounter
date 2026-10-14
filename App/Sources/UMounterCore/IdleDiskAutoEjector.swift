import DiskKit
import Foundation
import Observation
import os

/// Ejects (or parks) physical disks — SD cards, USB drives, HDDs — after they have
/// been idle for a while: no reads or writes and no process using them.
///
/// Activity comes from the disk driver's I/O counters (`IOActivity`). There is no
/// event for "a read happened", so this samples — but only while the feature is on
/// and an eligible disk is mounted, at an interval of timeout/6 (5–30 s) with a
/// generous timer tolerance. With no eligible disk there is no timer at all.
@MainActor
@Observable
public final class IdleDiskAutoEjector {
    /// When each tracked device was last seen active (for the menu).
    public private(set) var lastActivity: [String: Date] = [:]

    /// Called after a device was ejected/parked for being idle.
    @ObservationIgnored public var onIdleEjected: ((Device, EjectMode) -> Void)?

    struct Entry: Equatable {
        var counters: IOCounters?
        var lastActivity: Date
    }

    @ObservationIgnored private(set) var entries: [String: Entry] = [:]
    @ObservationIgnored private let store: DiskStore
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let power: SystemPowerState
    @ObservationIgnored private let clock: any Clock<Duration>
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var samplingTask: Task<Void, Never>?
    @ObservationIgnored private var isTicking = false
    @ObservationIgnored private let log = Logger(subsystem: "app.umounter", category: "idle-eject")

    public init(
        store: DiskStore, settings: AppSettings, power: SystemPowerState = SystemPowerState(),
        clock: any Clock<Duration> = ContinuousClock(), now: @escaping () -> Date = Date.init
    ) {
        self.store = store
        self.settings = settings
        self.power = power
        self.clock = clock
        self.now = now
    }

    public func start() { observe() }

    var timeout: TimeInterval { TimeInterval(max(settings.idleEjectSeconds, 10)) }

    /// Samples often enough to notice idleness within ~1/6 of the timeout.
    var sampleInterval: TimeInterval { min(max(timeout / 6, 5), 30) }

    /// True while sampling is paused for Low Power Mode.
    public var isPausedForLowPower: Bool {
        settings.reduceActivityInLowPowerMode && power.isLowPowerMode
    }

    func eligibleDevices() -> [Device] {
        // The only feature that samples: paused in Low Power Mode unless the user allows it.
        guard settings.idleEjectEnabled, !isPausedForLowPower else { return [] }
        let neverEject = Set(settings.neverEject.map(\.id))
        return store.devices.filter { device in
            guard !device.isNetwork, device.category != .diskImage, device.category != .optical else { return false }
            guard settings.idleEjectCategories.contains(device.category) else { return false }
            if device.volumes.contains(where: \.isInternal) { return false }
            return device.ruleIDs.isDisjoint(with: neverEject)
        }
    }

    private func observe() {
        withObservationTracking {
            _ = store.devices
            _ = settings.idleEjectEnabled
            _ = settings.idleEjectSeconds
            _ = settings.idleEjectCategories
            _ = settings.neverEject
            _ = settings.reduceActivityInLowPowerMode
            _ = power.isLowPowerMode
        } onChange: { [weak self] in
            Task { @MainActor in self?.observe() }
        }
        syncEntries()
    }

    /// Tracks newly eligible devices from "now" (a fresh mount counts as activity).
    func syncEntries() {
        let eligible = eligibleDevices()
        let ids = Set(eligible.map(\.id))
        entries = entries.filter { ids.contains($0.key) }
        for device in eligible where entries[device.id] == nil {
            entries[device.id] = Entry(counters: store.ioCounters(of: device), lastActivity: now())
        }
        lastActivity = entries.mapValues(\.lastActivity)
        updateSampling()
    }

    /// One sample: updates activity from I/O counters, ejects devices idle past the timeout.
    public func tick() async {
        guard !isTicking else { return }
        isTicking = true
        defer { isTicking = false }

        let current = now()
        for (id, entry) in entries.sorted(by: { $0.key < $1.key }) {
            guard let device = store.devices.first(where: { $0.id == id }) else {
                entries[id] = nil
                continue
            }
            let counters = store.ioCounters(of: device)
            if counters != entry.counters {
                entries[id] = Entry(counters: counters, lastActivity: current)
                continue
            }
            guard current.timeIntervalSince(entry.lastActivity) >= timeout else { continue }

            // Quiet on the bus, but an open file (e.g. a shell sitting in it) is still use.
            if !(await store.blockers(of: device)).isEmpty {
                entries[id]?.lastActivity = current
                continue
            }
            let mode = settings.ejectMode
            entries[id] = nil
            if await store.eject(device, mode: mode) == nil {
                log.info("idle for \(Int(self.timeout)) s: \(mode == .park ? "parked" : "ejected", privacy: .public) \(id, privacy: .public)")
                onIdleEjected?(device, mode)
            } else if store.devices.contains(where: { $0.id == id }) {
                // Eject failed (in use after all): start over.
                entries[id] = Entry(counters: store.ioCounters(of: device), lastActivity: current)
            }
        }
        lastActivity = entries.mapValues(\.lastActivity)
    }

    private func updateSampling() {
        guard !entries.isEmpty else {
            samplingTask?.cancel()
            samplingTask = nil
            return
        }
        guard samplingTask == nil else { return }
        samplingTask = Task { [weak self, clock] in
            while !Task.isCancelled {
                guard let interval = self?.sampleInterval else { return }
                try? await clock.sleep(for: .seconds(interval), tolerance: .seconds(interval / 2))
                guard !Task.isCancelled else { return }
                await self?.tick()
            }
        }
    }
}
