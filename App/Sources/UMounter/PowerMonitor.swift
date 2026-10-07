import AppKit
import IOKit
import IOKit.pwr_mgt
import UMounterCore

/// Forwards power and session events to `AutomationController`.
///
/// - Sleep: `IORegisterForSystemPower`. On `SystemWillSleep` we eject first and only
///   then call `IOAllowPowerChange`, so macOS waits for us (up to ~30 s; the
///   controller enforces a 25 s deadline).
/// - Display off / on, logout: `NSWorkspace` notifications.
/// - Remount happens on *screens did wake* (a user is present), never on a dark wake.
@MainActor
final class PowerMonitor {
    private let automation: AutomationController
    private var rootPort: io_connect_t = 0
    private var notifyPort: IONotificationPortRef?
    private var notifier: io_object_t = 0
    private var observers: [NSObjectProtocol] = []

    // iokit_common_msg(x) = sys_iokit | sub_iokit_common | x — function-like macros don't import into Swift.
    private static let canSystemSleep: natural_t = 0xE000_0270
    private static let systemWillSleep: natural_t = 0xE000_0280

    init(automation: AutomationController) {
        self.automation = automation
    }

    func start() {
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        rootPort = IORegisterForSystemPower(refcon, &notifyPort, { refcon, _, messageType, argument in
            let monitor = Unmanaged<PowerMonitor>.fromOpaque(refcon!).takeUnretainedValue()
            let notificationID = Int(bitPattern: argument)
            MainActor.assumeIsolated { monitor.handle(messageType, notificationID: notificationID) }
        }, &notifier)
        if rootPort != 0, let notifyPort {
            IONotificationPortSetDispatchQueue(notifyPort, .main)
        }

        let center = NSWorkspace.shared.notificationCenter
        func observe(_ name: Notification.Name, _ action: @escaping @MainActor (AutomationController) async -> Void) {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [automation] _ in
                Task { @MainActor in await action(automation) }
            })
        }
        observe(NSWorkspace.screensDidSleepNotification) { await $0.displayDidSleep() }
        observe(NSWorkspace.screensDidWakeNotification) { $0.userDidReturn() }
        observe(NSWorkspace.willPowerOffNotification) { await $0.sessionWillEnd() }
    }

    func stop() {
        observers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        observers.removeAll()
        if rootPort != 0 {
            IODeregisterForSystemPower(&notifier)
            IOServiceClose(rootPort)
            rootPort = 0
        }
        if let notifyPort { IONotificationPortDestroy(notifyPort) }
        notifyPort = nil
    }

    private func handle(_ messageType: natural_t, notificationID: Int) {
        switch messageType {
        case Self.canSystemSleep:
            IOAllowPowerChange(rootPort, notificationID)
        case Self.systemWillSleep:
            let port = rootPort
            Task { @MainActor in
                await automation.systemWillSleep()
                IOAllowPowerChange(port, notificationID)
            }
        default:
            break
        }
    }
}
