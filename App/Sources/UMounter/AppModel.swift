import AppKit
import os
import DiskKit
import Observation
import UMounterCore

/// Owns the app's long-lived objects and routes user actions.
@MainActor
final class AppModel {
    let settings: AppSettings
    let store: DiskStore
    let automation: AutomationController
    let imageAutoEject: ImageAutoEjectScheduler
    let idleAutoEject: IdleDiskAutoEjector
    let hotkeyRecorder: HotkeyRecorderModel
    let loginItem = LoginItemModel()
    private let power: PowerMonitor
    private let hotkeys = HotkeyCenter()
    private let feedback: Feedback
    private(set) var progressHUD: ProgressHUD?
    private let log = Logger(subsystem: "app.umounter", category: "app")

    init() {
        let session: DiskArbitrationSession
        do { session = try DiskArbitrationSession() } catch {
            fatalError("DiskArbitration is unavailable: \(error)")
        }
        settings = AppSettings()
        store = DiskStore(service: session)
        automation = AutomationController(store: store, settings: settings)
        power = PowerMonitor(automation: automation)
        feedback = Feedback(settings: settings)
        hotkeyRecorder = HotkeyRecorderModel(settings: settings)
        imageAutoEject = ImageAutoEjectScheduler(store: store, settings: settings)
        idleAutoEject = IdleDiskAutoEjector(store: store, settings: settings)

        hotkeys.onAction = { [weak self] action in self?.perform(action) }
        syncSettings()
        store.start()
        power.start()
        imageAutoEject.onAutoEjected = { [weak self] device in self?.feedback.autoEjected(device) }
        imageAutoEject.start()
        idleAutoEject.onIdleEjected = { [weak self] device, mode in self?.feedback.idleEjected(device, mode: mode) }
        idleAutoEject.start()
        progressHUD = ProgressHUD(store: store, settings: settings)
        feedback.onRemountRequested = { [weak self] in self?.remount() }
    }

    // MARK: - Actions

    /// Exists only while Settings is open: SwiftUI and the hosted forms are released
    /// when the window closes, so they cost nothing at idle.
    private var settingsWindow: SettingsWindowController?

    /// Opens Settings, building the window on demand.
    func showSettings() {
        if settingsWindow == nil {
            let controller = SettingsWindowController(model: self)
            controller.onClose = { [weak self] in self?.settingsWindowClosed() }
            settingsWindow = controller
        }
        settingsWindow?.show()
    }

    private func settingsWindowClosed() {
        hotkeyRecorder.cancel()
        settingsWindow = nil
        // Note: the SwiftUI pages freed here are fragmented, so the footprint stays
        // ~18 MB higher until relaunch (measured; malloc_zone_pressure_relief frees 0).
    }

    /// Sets up notifications at launch only when they can be needed before the
    /// first post: launched from a notification, or auto-eject is on.
    func prepareNotifications(launchedFromNotification: Bool) {
        if launchedFromNotification || settings.autoEjectImages || settings.idleEjectEnabled {
            feedback.configureNotificationsIfNeeded()
        }
    }

    func perform(_ action: HotkeyAction) {
        switch action {
        case .ejectAll: ejectAll()
        case .ejectAndSleep: ejectAllAndSleep()
        case .remount: remount()
        }
    }

    func ejectAll() {
        Task {
            let names = store.ejectAllDevices.map(\.name)
            let failures = await store.ejectAll(mode: settings.ejectMode)
            report(.eject, deviceNames: names, failures: failures)
        }
    }

    /// Ejects everything, then sleeps — but only if every disk ejected, so a disk
    /// that is still in use is never left mounted on a sleeping Mac.
    func ejectAllAndSleep() {
        Task {
            let failures = await store.ejectAll(mode: settings.ejectMode)
            if failures.isEmpty {
                SystemSleep.sleepNow()
            } else {
                report(.eject, deviceNames: [], failures: failures)
            }
        }
    }

    func eject(_ device: Device) {
        Task {
            let failure = await store.eject(device, mode: settings.ejectMode)
            report(.eject, deviceNames: [device.name], failures: failure.map { [$0] } ?? [])
        }
    }

    func mount(_ volume: DiskInfo) {
        Task {
            let failure = await store.mount(volume)
            report(.mount, deviceNames: [volume.volumeName ?? volume.id], failures: failure.map { [$0] } ?? [])
        }
    }

    // MARK: - Failures

    private var inUseWindow: InUseWindowController?

    /// Sound/notification, then the failure UI: the in-use window for eject
    /// failures, an alert for the rest.
    private func report(_ operation: Feedback.Operation, deviceNames: [String], failures: [OperationFailure]) {
        feedback.finished(operation, deviceNames: deviceNames, failures: failures)
        // Every eject failure goes to the in-use window (with Quit buttons when processes
        // are visible, and Try Again either way): it costs ~3 MB vs ~9 MB for NSAlert,
        // and that memory is not returned. Only failures without a device (mount) alert.
        let busy = failures.filter { $0.deviceID != nil }
        log.info("\(failures.count) failure(s); blockers: \(busy.flatMap(\.blockers).map(\.name), privacy: .public)")
        FailureAlert.present(failures.filter { failure in !busy.contains { $0.id == failure.id } })
        guard !busy.isEmpty else { return }
        if inUseWindow == nil {
            let controller = InUseWindowController(
                retry: { [weak self] id in await self?.retryEject(id) },
                onEjected: { [weak self] names in self?.feedback.finished(.eject, deviceNames: names, failures: []) }
            )
            controller.onClose = { [weak self] in self?.inUseWindow = nil }
            inUseWindow = controller
        }
        inUseWindow?.show(busy)
    }

    /// Retries one device from the in-use window; nil means it is gone or ejected.
    private func retryEject(_ deviceID: String) async -> OperationFailure? {
        await store.refresh()
        guard let device = store.devices.first(where: { $0.id == deviceID }) else { return nil }
        return await store.eject(device, mode: settings.ejectMode)
    }

    /// Excludes a disk image from auto-eject (menu "Keep Mounted").
    func keepMounted(_ device: Device) {
        guard let url = device.diskImageURL,
              !settings.imageExceptions.contains(where: { $0.id == url.path }) else { return }
        settings.imageExceptions.append(DiskRule(id: url.path, name: url.lastPathComponent))
    }

    /// Asks for notification permission when an automatic feature is turned on, because its
    /// notification carries the Remount action.
    func autoEjectSettingChanged(_ enabled: Bool) {
        if enabled { feedback.requestAuthorizationIfNeeded() }
    }

    func remount() {
        Task {
            let failures = await store.remountParked()
            report(.remount, deviceNames: store.devices.map(\.name), failures: failures)
        }
    }

    // MARK: - Settings → runtime

    /// Pushes settings into the store and hotkeys, then re-arms observation so later
    /// changes in the Settings window apply immediately.
    private func syncSettings() {
        // Read inside the tracking closure, apply outside it, so only settings
        // (not the store's own state) are observed.
        let (filter, neverRemount, keys) = withObservationTracking {
            (settings.ejectFilter, Set(settings.neverRemount.map(\.id)), settings.hotkeys)
        } onChange: { [weak self] in
            Task { @MainActor in self?.syncSettings() }
        }
        store.filter = filter
        store.neverRemount = neverRemount
        hotkeys.update(keys)
    }
}
