import AppKit
import UMounterCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var model: AppModel?
    private var statusItem: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let model = AppModel()
        self.model = model
        statusItem = StatusItemController(model: model)
        model.prepareNotifications(
            launchedFromNotification: notification.userInfo?[NSApplication.launchUserNotificationUserInfoKey] != nil
        )
        #if DEBUG
        DebugSnapshots.runIfRequested(model: model)
        // `UMOUNTER_DEBUG_HUD="Ejecting …"`: show the progress HUD with that text.
        if let text = ProcessInfo.processInfo.environment["UMOUNTER_DEBUG_HUD"] {
            model.progressHUD?.debugShow(text)
        }
        // `UMOUNTER_DEBUG_ALERT=1`: show a failure alert (measuring its memory cost).
        if ProcessInfo.processInfo.environment["UMOUNTER_DEBUG_ALERT"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                FailureAlert.present([OperationFailure(deviceID: nil, deviceName: "Test", message: "It is in use.", blockers: [])])
            }
        }
        // `UMOUNTER_DEBUG_EJECT=disk6`: eject that device at launch, as the menu would.
        if let id = ProcessInfo.processInfo.environment["UMOUNTER_DEBUG_EJECT"] {
            Task { @MainActor in
                await model.store.refresh()
                if let device = model.store.devices.first(where: { $0.id == id }) { model.eject(device) }
            }
        }
        if ProcessInfo.processInfo.environment["UMOUNTER_DEBUG_DUMP_MENU"] != nil, let statusItem {
            Task { @MainActor in
                await model.store.refresh()
                print(statusItem.debugMenuDump())
                exit(0)
            }
        }
        #endif
    }

    /// Launching UMounter again (Finder, Spotlight) opens Settings — the way back
    /// when the menu bar icon is hidden.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        model?.showSettings()
        return true
    }
}
