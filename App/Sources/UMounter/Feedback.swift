import AppKit
import DiskKit
import ServiceManagement
import UMounterCore
import UserNotifications

/// Sounds, system notifications and failure alerts after operations.
@MainActor
final class Feedback: NSObject, UNUserNotificationCenterDelegate {
    enum Operation {
        case eject, mount, remount

        var successTitle: String {
            switch self {
            case .eject: "Disks ejected"
            case .mount: "Disk mounted"
            case .remount: "Disks remounted"
            }
        }
    }

    private let settings: AppSettings
    private var requestedAuthorization = false

    private enum Identifier {
        static let autoEject = "autoEject"
        static let autoEjectWithTrash = "autoEjectWithTrash"
        static let idleParked = "idleParked"
        static let remountParked = "remountParked"
        static let remount = "remount"
        static let moveToTrash = "moveToTrash"
        static let imageURL = "imageURL"
    }

    /// `UNUserNotificationCenter` raises an exception outside an app bundle (e.g. the
    /// unbundled debug binary), so notifications are skipped there.
    private static let notificationsAvailable = Bundle.main.bundleIdentifier != nil

    private var centerConfigured = false

    /// Does not touch `UNUserNotificationCenter`: loading it costs memory and an XPC
    /// connection, so it is set up on first use (see `configureNotificationsIfNeeded`).
    init(settings: AppSettings) {
        self.settings = settings
        super.init()
    }

    /// Connects to the notification center and registers the Remount / Move to Trash
    /// actions. Called before the first notification, at launch when the app was
    /// opened from a notification, or when auto-eject is on (its notification
    /// actions must work even after a relaunch).
    func configureNotificationsIfNeeded() {
        guard Self.notificationsAvailable, !centerConfigured else { return }
        centerConfigured = true
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let remount = UNNotificationAction(identifier: Identifier.remount, title: "Remount")
        let trash = UNNotificationAction(identifier: Identifier.moveToTrash, title: "Move to Trash", options: [.destructive])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Identifier.autoEject, actions: [remount], intentIdentifiers: []),
            UNNotificationCategory(identifier: Identifier.autoEjectWithTrash, actions: [remount, trash], intentIdentifiers: []),
            UNNotificationCategory(
                identifier: Identifier.idleParked,
                actions: [UNNotificationAction(identifier: Identifier.remountParked, title: "Remount")], intentIdentifiers: []
            ),
        ])
    }

    /// Tells the user an image was ejected automatically, with Remount (and, for
    /// installers in Downloads, Move to Trash) actions. Always shown, because it is
    /// the way to undo an automatic action.
    func autoEjected(_ device: Device) {
        guard let url = device.diskImageURL else { return }
        let content = UNMutableNotificationContent()
        content.title = "“\(device.name)” was ejected automatically"
        content.body = url.lastPathComponent
        content.userInfo = [Identifier.imageURL: url.absoluteString]
        content.categoryIdentifier = settings.offerTrashAfterAutoEject && Self.isInDownloads(url)
            ? Identifier.autoEjectWithTrash : Identifier.autoEject
        content.interruptionLevel = .passive
        post(content)
    }

    /// Remounts parked disks (set by `AppModel`).
    var onRemountRequested: (() -> Void)?

    /// Tells the user an idle disk was unmounted or ejected. Parked disks get a
    /// Remount action; an ejected disk must be replugged anyway.
    func idleEjected(_ device: Device, mode: EjectMode) {
        let content = UNMutableNotificationContent()
        let minutes = settings.idleEjectSeconds >= 60 ? "\(settings.idleEjectSeconds / 60) min" : "\(settings.idleEjectSeconds) s"
        content.title = mode == .park
            ? "“\(device.name)” was unmounted after \(minutes) idle"
            : "“\(device.name)” was ejected after \(minutes) idle"
        content.body = mode == .park ? "It is still connected — remount it from the menu bar." : "It is safe to unplug."
        if mode == .park { content.categoryIdentifier = Identifier.idleParked }
        content.interruptionLevel = .passive
        post(content)
    }

    static func isInDownloads(_ url: URL) -> Bool {
        let downloads = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Downloads").standardizedFileURL.path + "/"
        return url.standardizedFileURL.path.hasPrefix(downloads) && FileManager.default.fileExists(atPath: url.path)
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
    ) async {
        let action = response.actionIdentifier
        if action == Identifier.remountParked {
            await MainActor.run { self.onRemountRequested?() }
            return
        }
        guard let string = response.notification.request.content.userInfo[Identifier.imageURL] as? String,
              let url = URL(string: string) else { return }
        await MainActor.run {
            switch action {
            case Identifier.remount:
                NSWorkspace.shared.open(url) // DiskImageMounter re-attaches it
            case Identifier.moveToTrash:
                NSWorkspace.shared.recycle([url])
            default:
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }

    /// Sound and notification for the outcome of a user-initiated operation. The
    /// failure UI (in-use window or alert) is shown by `AppModel`.
    func finished(_ operation: Operation, deviceNames: [String], failures: [OperationFailure]) {
        if failures.isEmpty {
            guard !deviceNames.isEmpty else { return }
            if settings.playSuccessSound { Self.play(settings.successSound) }
            notify(title: operation.successTitle, body: ListFormatter.localizedString(byJoining: deviceNames))
        } else if settings.playFailureSound {
            Self.play(settings.failureSound)
        }
    }

    /// Reports an automatic operation (wake remount) without sounds or dialogs.
    func finishedQuietly(_ operation: Operation, deviceNames: [String]) {
        guard !deviceNames.isEmpty else { return }
        notify(title: operation.successTitle, body: ListFormatter.localizedString(byJoining: deviceNames))
    }

    static func play(_ soundName: String) {
        NSSound(named: NSSound.Name(soundName))?.play()
    }

    /// System and user alert sounds, by name.
    static let availableSounds: [String] = {
        let folders = [URL(filePath: "/System/Library/Sounds"), FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Sounds")]
        let names = folders.flatMap { folder in
            ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
                .map { $0.deletingPathExtension().lastPathComponent }
        }
        return Array(Set(names)).sorted()
    }()

    private func notify(title: String, body: String) {
        guard settings.notifyAfterOperations else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.interruptionLevel = .passive
        post(content)
    }

    func requestAuthorizationIfNeeded() {
        guard Self.notificationsAvailable, !requestedAuthorization else { return }
        configureNotificationsIfNeeded()
        requestedAuthorization = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { _, _ in }
    }

    private func post(_ content: UNNotificationContent) {
        guard Self.notificationsAvailable else { return }
        requestAuthorizationIfNeeded()
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}

/// "Launch at login" through `SMAppService` (macOS 13+).
enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static var needsApproval: Bool { SMAppService.mainApp.status == .requiresApproval }

    static func set(_ enabled: Bool) throws {
        if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    }
}

/// Puts the Mac to sleep. `pmset sleepnow` needs no special privileges.
enum SystemSleep {
    static func sleepNow() {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/pmset")
        process.arguments = ["sleepnow"]
        process.standardOutput = FileHandle.nullDevice
        try? process.run()
    }
}

@MainActor
enum FailureAlert {
    static func present(_ failures: [OperationFailure]) {
        guard !failures.isEmpty else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = failures.count == 1
            ? "“\(failures[0].deviceName)” couldn’t be ejected"
            : "\(failures.count) disks couldn’t be ejected"
        alert.informativeText = failures.map(describe).joined(separator: "\n\n")
        NSApp.activate()
        alert.runModal()
    }

    private static func describe(_ failure: OperationFailure) -> String {
        var text = failure.message
        if !failure.blockers.isEmpty {
            let names = failure.blockers.map { "\($0.name) (\($0.pid))" }.joined(separator: ", ")
            text += "\nIn use by: \(names)"
        }
        return text
    }
}
