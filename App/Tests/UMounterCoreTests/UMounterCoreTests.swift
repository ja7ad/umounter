import DiskKit
import Foundation
import Testing
@testable import UMounterCore

// MARK: - Fixtures

private func volume(_ bsd: String, root: String, name: String, mounted: Bool = true, isInternal: Bool = false) -> DiskInfo {
    DiskInfo(
        bsdName: bsd, kind: .volume, volumeName: name,
        volumePath: mounted ? URL(filePath: "/Volumes/\(name)") : nil,
        volumeKind: "apfs", isInternal: isInternal, deviceProtocol: "USB", physicalRootBSDName: root
    )
}

private func whole(_ bsd: String, kind: DiskInfo.Kind = .physicalWhole, root: String? = nil) -> DiskInfo {
    DiskInfo(bsdName: bsd, kind: kind, isWhole: true, deviceProtocol: "USB", deviceModel: "T7", physicalRootBSDName: root ?? bsd)
}

private let share = DiskInfo(
    bsdName: nil, kind: .network, volumeName: "share", volumePath: URL(filePath: "/Volumes/share"),
    volumeKind: "smbfs", isNetwork: true
)

/// In-memory DiskService: park clears mount paths, eject removes the device.
private final class FakeDiskService: DiskService, @unchecked Sendable {
    private let lock = NSLock()
    private var state: [DiskInfo]
    private let original: [DiskInfo]
    var busyRoots: Set<String> = []
    /// Makes `ejectSafely` slow, to exercise deadlines.
    var ejectDelay: Duration?
    let events: AsyncStream<DiskEvent> = AsyncStream { _ in }

    init(_ disks: [DiskInfo]) {
        state = disks
        original = disks
    }

    func disks() -> [DiskInfo] { lock.withLock { state } }

    func ejectSafely(_ target: DiskTarget, mode: EjectMode) async throws {
        if let ejectDelay { try await Task.sleep(for: ejectDelay) }
        try lock.withLock {
            switch target {
            case .volume(let url):
                state.removeAll { $0.volumePath == url }
            case .bsdName(let root):
                if busyRoots.contains(root) { throw DiskError(code: .busy, operation: "unmount \(root)") }
                if mode == .eject {
                    state.removeAll { $0.physicalRootBSDName == root }
                } else {
                    for i in state.indices where state[i].physicalRootBSDName == root { state[i].volumePath = nil }
                }
            }
        }
    }

    func mount(_ target: DiskTarget, whole: Bool, readOnly: Bool) async throws {
        guard case .bsdName(let bsd) = target else { return }
        lock.withLock {
            if let i = state.firstIndex(where: { $0.bsdName == bsd }) {
                state[i].volumePath = original.first { $0.bsdName == bsd }?.volumePath
            }
        }
    }

    func mountVolumes(onDevice bsdName: String, readOnly: Bool) async throws {
        lock.withLock {
            for i in state.indices where state[i].physicalRootBSDName == bsdName {
                state[i].volumePath = original.first { $0.bsdName == state[i].bsdName }?.volumePath
            }
        }
    }

    /// nil: every volume reports a blocker (for busy-error tests). Otherwise only these.
    var volumesInUse: Set<URL>?

    var counters: [String: IOCounters] = [:]

    func ioCounters(bsdName: String) -> IOCounters? { lock.withLock { counters[bsdName] } }

    func blockers(onVolume volume: URL, includeFiles: Bool) -> [Blocker] {
        let inUse = lock.withLock { volumesInUse.map { $0.contains(volume) } ?? true }
        return inUse ? [Blocker(pid: 999_999, name: "Preview", executablePath: nil, uid: getuid(), openFiles: [])] : []
    }
}

// MARK: - Catalog

@Suite struct DiskCatalogTests {
    @Test func groupsVolumesByPhysicalDevice() {
        let disks = [
            whole("disk4"), whole("disk5", kind: .containerWhole, root: "disk4"),
            volume("disk5s1", root: "disk4", name: "Photos"),
            volume("disk5s2", root: "disk4", name: "Archive"),
            whole("disk6"), volume("disk6s1", root: "disk6", name: "Card"),
            volume("disk3s5", root: "disk0", name: "Data", isInternal: true),
            share,
        ]
        let devices = DiskCatalog.devices(from: disks)
        #expect(devices.map(\.id) == ["disk4", "disk6", "/Volumes/share"])
        #expect(devices[0].name == "Archive, Photos")
        #expect(devices[0].model == "T7")
        #expect(devices[2].isNetwork)
        #expect(devices[2].target == .volume(URL(filePath: "/Volumes/share")))
    }

    @Test func mountableVolumesAreExternalAndUnmounted() {
        let disks = [
            volume("disk5s1", root: "disk4", name: "Photos", mounted: false),
            volume("disk6s1", root: "disk6", name: "Card"),
            volume("disk3s3", root: "disk0", name: "Recovery", mounted: false, isInternal: true),
        ]
        #expect(DiskCatalog.mountableVolumes(from: disks).map(\.bsdName) == ["disk5s1"])
    }
}

// MARK: - Store

@MainActor
@Suite struct DiskStoreTests {
    private let disks = [
        whole("disk4"), volume("disk4s1", root: "disk4", name: "Photos"),
        whole("disk6"), volume("disk6s1", root: "disk6", name: "Card"),
    ]

    @Test func parkAllThenRemount() async {
        let store = DiskStore(service: FakeDiskService(disks))
        await store.refresh()
        #expect(store.devices.count == 2)

        #expect(store.statusIconState == .mounted(count: 2))
        let failures = await store.ejectAll(mode: .park)
        #expect(failures.isEmpty)
        #expect(store.statusIconState == .safeToUnplug)
        #expect(store.devices.isEmpty)
        #expect(store.parkedDeviceIDs == ["disk4", "disk6"])
        #expect(store.mountableVolumes.count == 2)

        #expect(await store.remountParked().isEmpty)
        #expect(store.devices.count == 2)
        #expect(!store.canRemount)
    }

    @Test func ejectRemovesDeviceAndIsNotRemountable() async throws {
        let store = DiskStore(service: FakeDiskService(disks))
        await store.refresh()
        await store.eject(try #require(store.devices.first { $0.id == "disk4" }), mode: .eject)
        #expect(store.devices.map(\.id) == ["disk6"])
        #expect(!store.canRemount)
        await store.eject(try #require(store.devices.first), mode: .eject)
        #expect(store.statusIconState == .empty)
    }

    @Test func busyDeviceReportsBlockers() async {
        let service = FakeDiskService(disks)
        service.busyRoots = ["disk4"]
        let store = DiskStore(service: service)
        await store.refresh()

        let failures = await store.ejectAll(mode: .eject)
        #expect(failures.count == 1)
        #expect(failures.first?.deviceName == "Photos")
        #expect(failures.first?.blockers.map(\.name) == ["Preview"])
        #expect(failures.first?.blockers.first?.pid == 999_999)
        #expect(store.devices.map(\.id) == ["disk4"])
        #expect(store.busyDeviceIDs.isEmpty)
    }

    @Test func parkedDeviceIsForgottenWhenUnplugged() async throws {
        let service = FakeDiskService(disks)
        let store = DiskStore(service: service)
        await store.refresh()
        await store.eject(try #require(store.devices.first { $0.id == "disk4" }), mode: .park)
        #expect(store.parkedDeviceIDs == ["disk4"])

        try? await service.ejectSafely(.bsdName("disk4"), mode: .eject) // simulate unplug
        await store.refresh()
        #expect(store.parkedDeviceIDs.isEmpty)
    }
}

// MARK: - Filters, settings, automation

/// A clock whose sleeps return immediately.
private struct ImmediateClock: Clock {
    struct Instant: InstantProtocol {
        var offset: Duration
        func advanced(by duration: Duration) -> Instant { Instant(offset: offset + duration) }
        func duration(to other: Instant) -> Duration { other.offset - offset }
        static func < (lhs: Instant, rhs: Instant) -> Bool { lhs.offset < rhs.offset }
    }
    var now: Instant { Instant(offset: .zero) }
    var minimumResolution: Duration { .zero }
    func sleep(until deadline: Instant, tolerance: Duration?) async throws { await Task.yield() }
}

private func isolatedDefaults() -> UserDefaults {
    let name = "umounter.tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
}

@MainActor
@Suite struct FilterAndAutomationTests {
    private var image: DiskInfo {
        var disk = volume("disk8s1", root: "disk8", name: "Installer")
        disk.diskImageURL = URL(filePath: "/Users/me/Downloads/App.dmg")
        return disk
    }

    private var disks: [DiskInfo] {
        [whole("disk4"), volume("disk4s1", root: "disk4", name: "Photos"), whole("disk8", kind: .diskImage), image]
    }

    @Test func categoryAndRuleFilters() async {
        let store = DiskStore(service: FakeDiskService(disks))
        await store.refresh()
        #expect(store.devices.map(\.category) == [.diskImage, .hardDisk])

        store.filter = EjectFilter(categories: [.hardDisk], alsoEject: [], neverEject: [])
        #expect(store.ejectAllDevices.map(\.id) == ["disk4"])
        #expect(store.statusIconState == .mounted(count: 1))

        store.filter = EjectFilter(categories: [.hardDisk], alsoEject: ["Installer"], neverEject: ["Photos"])
        #expect(store.ejectAllDevices.map(\.id) == ["disk8"])

        await store.ejectAll(mode: .eject)
        #expect(store.devices.map(\.id) == ["disk4"], "never-eject disk stays mounted")
    }

    @Test func alsoEjectIncludesInternalVolume() {
        let internalVolume = volume("disk3s7", root: "disk0", name: "Scratch", isInternal: true)
        #expect(DiskCatalog.devices(from: [internalVolume]).isEmpty)
        #expect(DiskCatalog.devices(from: [internalVolume], alsoEject: ["Scratch"]).map(\.id) == ["disk0"])
    }

    @Test func settingsPersist() {
        let defaults = isolatedDefaults()
        let settings = AppSettings(defaults: defaults)
        #expect(settings.ejectBeforeSleep && settings.unmountInsteadOfEject && !settings.categories.contains(.sdCard))

        settings.ejectAfterDisplayOff = true
        settings.categories.insert(.sdCard)
        settings.neverEject = [DiskRule(id: "UUID-1", name: "Backup")]
        settings.hotkeys[.ejectAll] = KeyCombo(keyCode: 14, modifiers: 1 << 20)
        settings.remountDelaySeconds = 30
        #expect(settings.menuBarIconStyle == .eject)
        settings.menuBarIconStyle = .drive

        let reloaded = AppSettings(defaults: defaults)
        #expect(reloaded.ejectAfterDisplayOff)
        #expect(reloaded.categories.contains(.sdCard))
        #expect(reloaded.neverEject.map(\.name) == ["Backup"])
        #expect(reloaded.hotkeys[.ejectAll] == KeyCombo(keyCode: 14, modifiers: 1 << 20))
        #expect(reloaded.remountDelaySeconds == 30)
        #expect(reloaded.menuBarIconStyle == .drive)
        #expect(reloaded.ejectFilter.neverEject == ["UUID-1"])
    }

    @Test func sleepParksAndUserReturnRemounts() async {
        let store = DiskStore(service: FakeDiskService(disks))
        let settings = AppSettings(defaults: isolatedDefaults())
        settings.remountDelaySeconds = 0
        let automation = AutomationController(store: store, settings: settings)

        #expect(await automation.systemWillSleep().isEmpty)
        #expect(store.devices.isEmpty)
        #expect(automation.parkedForSleep)

        automation.userDidReturn()
        await automation.waitForRemount()
        #expect(store.devices.count == 2)
        #expect(!automation.parkedForSleep)
    }

    @Test func neverRemountIsRespected() async {
        let store = DiskStore(service: FakeDiskService(disks))
        store.neverRemount = ["Photos"]
        let settings = AppSettings(defaults: isolatedDefaults())
        settings.remountDelaySeconds = 0
        let automation = AutomationController(store: store, settings: settings)
        await automation.systemWillSleep()
        automation.userDidReturn()
        await automation.waitForRemount()
        #expect(store.devices.map(\.id) == ["disk8"])
    }

    @Test func disabledTriggersDoNothing() async {
        let store = DiskStore(service: FakeDiskService(disks))
        let settings = AppSettings(defaults: isolatedDefaults())
        settings.ejectBeforeSleep = false
        let automation = AutomationController(store: store, settings: settings, clock: ImmediateClock())
        await store.refresh()
        await automation.systemWillSleep()
        await automation.displayDidSleep()   // off by default
        #expect(store.devices.count == 2)
        #expect(!automation.parkedForSleep)
    }

    /// With an immediate clock the deadline wins at once; the ejection keeps running.
    @Test func immediateDeadlineDoesNotWaitForEjection() async {
        let store = DiskStore(service: FakeDiskService(disks))
        let automation = AutomationController(store: store, settings: AppSettings(defaults: isolatedDefaults()), clock: ImmediateClock())
        #expect(await automation.systemWillSleep().isEmpty)
        #expect(automation.parkedForSleep)
    }

    @Test func sleepDeadlineReturnsEarly() async {
        let service = FakeDiskService(disks)
        service.ejectDelay = .seconds(2)
        let store = DiskStore(service: service)
        let automation = AutomationController(store: store, settings: AppSettings(defaults: isolatedDefaults()))
        let start = ContinuousClock.now
        await automation.systemWillSleep(deadline: .milliseconds(50))
        #expect(ContinuousClock.now - start < .seconds(1))
    }
}

// MARK: - Disk image auto-eject

@MainActor
@Suite struct ImageAutoEjectTests {
    nonisolated private static let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private static func image(_ bsd: String, name: String, file: String, writable: Bool = false, encrypted: Bool = false) -> [DiskInfo] {
        let url = URL(filePath: file)
        return [
            DiskInfo(bsdName: bsd, kind: .diskImage, isWhole: true, deviceProtocol: "Virtual Interface",
                     physicalRootBSDName: bsd, diskImageURL: url, attachedAt: t0),
            DiskInfo(bsdName: bsd + "s1", kind: .volume, volumeName: name, volumePath: URL(filePath: "/Volumes/\(name)"),
                     volumeKind: "hfs", isWritable: writable, isEncrypted: encrypted, deviceProtocol: "Virtual Interface",
                     physicalRootBSDName: bsd, diskImageURL: url, attachedAt: t0),
        ]
    }

    /// Mutable "now" for the scheduler.
    final class TestNow: @unchecked Sendable {
        var date = ImageAutoEjectTests.t0
        func advance(minutes: Double) { date = date.addingTimeInterval(minutes * 60) }
    }

    private func make(_ disks: [DiskInfo], configure: (AppSettings) -> Void = { _ in }) async
        -> (FakeDiskService, DiskStore, AppSettings, ImageAutoEjectScheduler, TestNow) {
        let service = FakeDiskService(disks)
        service.volumesInUse = []
        let store = DiskStore(service: service)
        await store.refresh()
        let settings = AppSettings(defaults: isolatedDefaults())
        settings.autoEjectImages = true
        settings.autoEjectMinutes = 10
        configure(settings)
        let now = TestNow()
        let scheduler = ImageAutoEjectScheduler(store: store, settings: settings, now: { now.date })
        scheduler.syncEntries()
        return (service, store, settings, scheduler, now)
    }

    @Test func disabledByDefault() async {
        let store = DiskStore(service: FakeDiskService(Self.image("disk8", name: "App", file: "/Users/me/Downloads/App.dmg")))
        await store.refresh()
        let scheduler = ImageAutoEjectScheduler(store: store, settings: AppSettings(defaults: isolatedDefaults()))
        scheduler.syncEntries()
        #expect(scheduler.statuses.isEmpty)
    }

    @Test func ejectsAfterTimeout() async {
        let (_, store, _, scheduler, now) = await make(Self.image("disk8", name: "App", file: "/Users/me/Downloads/App.dmg"))
        var ejected: [String] = []
        scheduler.onAutoEjected = { ejected.append($0.id) }
        #expect(scheduler.statuses["disk8"] == .scheduled(Self.t0.addingTimeInterval(600)))

        now.advance(minutes: 5)
        await scheduler.evaluate()
        #expect(store.devices.count == 1)

        now.advance(minutes: 6)
        await scheduler.evaluate()
        #expect(store.devices.isEmpty)
        #expect(ejected == ["disk8"])
        #expect(scheduler.statuses.isEmpty)
    }

    @Test func busyImageWaitsThenRestartsCountdownWhenIdle() async {
        let (service, store, _, scheduler, now) = await make(Self.image("disk8", name: "App", file: "/Users/me/Downloads/App.dmg"))
        service.volumesInUse = [URL(filePath: "/Volumes/App")]

        now.advance(minutes: 11)
        await scheduler.evaluate()
        #expect(store.devices.count == 1)
        #expect(scheduler.statuses["disk8"] == .waitingWhileInUse)

        service.volumesInUse = []
        now.advance(minutes: 6) // past the 5-minute re-check
        await scheduler.evaluate()
        #expect(store.devices.count == 1, "countdown restarts when it goes idle")
        #expect(scheduler.statuses["disk8"] == .scheduled(now.date.addingTimeInterval(600)))

        now.advance(minutes: 10)
        await scheduler.evaluate()
        #expect(store.devices.isEmpty)
    }

    @Test func afterMountModeEjectsAsSoonAsIdle() async {
        let (service, store, _, scheduler, now) = await make(Self.image("disk8", name: "App", file: "/Users/me/Downloads/App.dmg")) {
            $0.autoEjectMode = .afterMount
        }
        service.volumesInUse = [URL(filePath: "/Volumes/App")]
        now.advance(minutes: 11)
        await scheduler.evaluate()
        service.volumesInUse = []
        now.advance(minutes: 6)
        await scheduler.evaluate()
        #expect(store.devices.isEmpty)
    }

    @Test func eligibilityRules() async {
        let disks = Self.image("disk8", name: "Installer", file: "/Users/me/Downloads/A.dmg")
            + Self.image("disk9", name: "Work", file: "/Users/me/Work.sparsebundle", writable: true)
            + Self.image("disk10", name: "Secret", file: "/Users/me/Secret.dmg", encrypted: true)
            + Self.image("disk11", name: "Kept", file: "/Users/me/Downloads/Kept.iso")
            + [whole("disk4"), volume("disk4s1", root: "disk4", name: "USB")]
        let (_, _, settings, scheduler, _) = await make(disks) {
            $0.imageExceptions = [DiskRule(id: "/Users/me/Downloads/Kept.iso", name: "Kept.iso")]
        }
        #expect(Set(scheduler.statuses.keys) == ["disk8"])

        settings.autoEjectReadOnlyOnly = false
        scheduler.syncEntries()
        #expect(Set(scheduler.statuses.keys) == ["disk8", "disk9"], "writable allowed, encrypted never")
    }

    @Test func nestedImageIsEjectedBeforeItsHost() async {
        // disk5's .dmg lives on disk4's mounted volume (the real case seen on macOS 27).
        let disks = Self.image("disk4", name: "Outer", file: "/Users/me/Downloads/Outer.iso")
            + Self.image("disk5", name: "Inner", file: "/Volumes/Outer/Manual install/Inner.dmg")
        let (_, store, _, scheduler, now) = await make(disks)

        now.advance(minutes: 11)
        await scheduler.evaluate()
        #expect(store.devices.map(\.id) == ["disk4"], "inner ejected, outer waits")
        #expect(scheduler.statuses["disk4"] == .waitingWhileInUse)

        now.advance(minutes: 6)
        await scheduler.evaluate() // idle now → countdown restarts (when-idle mode)
        now.advance(minutes: 10)
        await scheduler.evaluate()
        #expect(store.devices.isEmpty)
    }

    @Test func settingsPersist() {
        let defaults = isolatedDefaults()
        let settings = AppSettings(defaults: defaults)
        #expect(!settings.autoEjectImages && settings.autoEjectMode == .whenIdle && settings.autoEjectMinutes == 10)
        settings.autoEjectImages = true
        settings.autoEjectMode = .afterMount
        settings.autoEjectMinutes = 30
        settings.imageExceptions = [DiskRule(id: "/x.dmg", name: "x.dmg")]
        let reloaded = AppSettings(defaults: defaults)
        #expect(reloaded.autoEjectImages && reloaded.autoEjectMode == .afterMount && reloaded.autoEjectMinutes == 30)
        #expect(reloaded.imageExceptions.map(\.id) == ["/x.dmg"])
    }
}

// MARK: - Idle physical disk auto-eject

@MainActor
@Suite struct IdleDiskAutoEjectTests {
    private let usb = [whole("disk6"), volume("disk6s1", root: "disk6", name: "JAVAD")]
    private let counters = IOCounters(bytesRead: 100, bytesWritten: 10, readOperations: 5, writeOperations: 1)

    private func make(_ configure: (AppSettings) -> Void = { _ in }) async
        -> (FakeDiskService, DiskStore, IdleDiskAutoEjector, ImageAutoEjectTests.TestNow) {
        let service = FakeDiskService(usb)
        service.volumesInUse = []
        service.counters = ["disk6": counters]
        let store = DiskStore(service: service)
        await store.refresh()
        let settings = AppSettings(defaults: isolatedDefaults())
        settings.idleEjectEnabled = true
        settings.idleEjectSeconds = 60
        configure(settings)
        let now = ImageAutoEjectTests.TestNow()
        let ejector = IdleDiskAutoEjector(store: store, settings: settings, now: { now.date })
        ejector.syncEntries()
        return (service, store, ejector, now)
    }

    @Test func parksAfterIdleTimeout() async {
        let (_, store, ejector, now) = await make()
        var ejected: [(String, EjectMode)] = []
        ejector.onIdleEjected = { ejected.append(($0.id, $1)) }
        #expect(ejector.sampleInterval == 10)

        now.advance(minutes: 0.5)
        await ejector.tick()
        #expect(store.devices.count == 1)

        now.advance(minutes: 0.6)
        await ejector.tick()
        #expect(store.devices.isEmpty)
        #expect(ejected.map(\.0) == ["disk6"])
        #expect(ejected.first?.1 == .park, "follows Unmount instead of ejecting")
        #expect(store.canRemount)
    }

    @Test func readsAndWritesResetTheTimer() async {
        let (service, store, ejector, now) = await make()
        now.advance(minutes: 0.9)
        service.counters["disk6"]?.bytesRead += 4096
        await ejector.tick()
        now.advance(minutes: 0.9)
        await ejector.tick()
        #expect(store.devices.count == 1, "only 54 s idle since the read")
        now.advance(minutes: 0.2)
        await ejector.tick()
        #expect(store.devices.isEmpty)
    }

    @Test func openFilesCountAsUse() async {
        let (service, store, ejector, now) = await make()
        service.volumesInUse = [URL(filePath: "/Volumes/JAVAD")]
        now.advance(minutes: 2)
        await ejector.tick()
        #expect(store.devices.count == 1)
        service.volumesInUse = []
        now.advance(minutes: 0.5)
        await ejector.tick()
        #expect(store.devices.count == 1, "timer restarted when the blocker was seen")
        now.advance(minutes: 0.6)
        await ejector.tick()
        #expect(store.devices.isEmpty)
    }

    @Test func eligibility() async {
        let (_, _, ejector, _) = await make { $0.idleEjectCategories = [.sdCard] }
        #expect(ejector.entries.isEmpty, "a USB drive is a hard disk, not an SD card")
        let (_, _, off, _) = await make { $0.idleEjectEnabled = false }
        #expect(off.entries.isEmpty)
        let (_, _, never, _) = await make { $0.neverEject = [DiskRule(id: "JAVAD", name: "JAVAD")] }
        #expect(never.entries.isEmpty)
    }
}
