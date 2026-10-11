import DiskKit
import Foundation
import Observation

/// A global keyboard shortcut: a virtual key code plus Carbon-independent
/// modifier flags (`NSEvent.ModifierFlags.rawValue`).
public struct KeyCombo: Codable, Hashable, Sendable {
    public var keyCode: UInt16
    public var modifiers: UInt
    /// What the key prints, captured when recorded (e.g. "E", "F5").
    public var keyLabel: String

    public init(keyCode: UInt16, modifiers: UInt, keyLabel: String = "") {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.keyLabel = keyLabel
    }
}

/// The menu bar icon's glyph family.
public enum MenuBarIconStyle: String, Codable, CaseIterable, Sendable {
    case eject, ejectCircle, drive

    public var title: String {
        switch self {
        case .eject: "Eject"
        case .ejectCircle: "Eject Circle"
        case .drive: "Drive"
        }
    }
}

/// When the auto-eject timeout for disk images starts counting.
public enum ImageAutoEjectMode: String, Codable, CaseIterable, Sendable {
    /// From the moment the image is no longer in use (recommended).
    case whenIdle
    /// From the moment the image was attached.
    case afterMount
}

public enum HotkeyAction: String, CaseIterable, Codable, Sendable {
    case ejectAll, ejectAndSleep, remount

    public var title: String {
        switch self {
        case .ejectAll: "Eject external disks"
        case .ejectAndSleep: "Eject disks and sleep"
        case .remount: "Remount ejected disks"
        }
    }
}

/// Every user preference, persisted in `UserDefaults` on change. All options are
/// visible in Settings — no hidden `defaults write` switches.
@MainActor
@Observable
public final class AppSettings {
    // General
    public var showMenuBarIcon: Bool { didSet { save(showMenuBarIcon, Key.showMenuBarIcon) } }
    public var showDiskCount: Bool { didSet { save(showDiskCount, Key.showDiskCount) } }
    public var menuBarIconStyle: MenuBarIconStyle { didSet { save(menuBarIconStyle.rawValue, Key.menuBarIconStyle) } }
    public var ejectBeforeSleep: Bool { didSet { save(ejectBeforeSleep, Key.ejectBeforeSleep) } }
    public var ejectAfterDisplayOff: Bool { didSet { save(ejectAfterDisplayOff, Key.ejectAfterDisplayOff) } }
    public var ejectBeforeLogout: Bool { didSet { save(ejectBeforeLogout, Key.ejectBeforeLogout) } }

    // What to eject
    public var categories: Set<DiskCategory> { didSet { saveCodable(categories, Key.categories) } }
    public var unmountInsteadOfEject: Bool { didSet { save(unmountInsteadOfEject, Key.unmountInsteadOfEject) } }

    // Disk images (see docs/design/0002-disk-image-auto-eject.md)
    public var autoEjectImages: Bool { didSet { save(autoEjectImages, Key.autoEjectImages) } }
    public var autoEjectMinutes: Int { didSet { save(autoEjectMinutes, Key.autoEjectMinutes) } }
    public var autoEjectMode: ImageAutoEjectMode { didSet { save(autoEjectMode.rawValue, Key.autoEjectMode) } }
    public var autoEjectReadOnlyOnly: Bool { didSet { save(autoEjectReadOnlyOnly, Key.autoEjectReadOnlyOnly) } }
    public var offerTrashAfterAutoEject: Bool { didSet { save(offerTrashAfterAutoEject, Key.offerTrashAfterAutoEject) } }
    /// Images never auto-ejected, keyed by the image file path.
    public var imageExceptions: [DiskRule] { didSet { saveCodable(imageExceptions, Key.imageExceptions) } }

    // Idle physical disks (SD cards, USB drives, HDDs)
    public var idleEjectEnabled: Bool { didSet { save(idleEjectEnabled, Key.idleEjectEnabled) } }
    public var idleEjectSeconds: Int { didSet { save(idleEjectSeconds, Key.idleEjectSeconds) } }
    public var idleEjectCategories: Set<DiskCategory> { didSet { saveCodable(idleEjectCategories, Key.idleEjectCategories) } }

    // Notifications
    public var showProgressWhileEjecting: Bool { didSet { save(showProgressWhileEjecting, Key.showProgressWhileEjecting) } }
    public var showProgressWhileRemounting: Bool { didSet { save(showProgressWhileRemounting, Key.showProgressWhileRemounting) } }
    public var notifyAfterOperations: Bool { didSet { save(notifyAfterOperations, Key.notifyAfterOperations) } }
    public var playSuccessSound: Bool { didSet { save(playSuccessSound, Key.playSuccessSound) } }
    public var successSound: String { didSet { save(successSound, Key.successSound) } }
    public var playFailureSound: Bool { didSet { save(playFailureSound, Key.playFailureSound) } }
    public var failureSound: String { didSet { save(failureSound, Key.failureSound) } }

    // Hotkeys
    public var hotkeys: [HotkeyAction: KeyCombo] { didSet { saveCodable(hotkeys, Key.hotkeys) } }

    // Options
    public var remountAfterWake: Bool { didSet { save(remountAfterWake, Key.remountAfterWake) } }
    public var remountDelaySeconds: Int { didSet { save(remountDelaySeconds, Key.remountDelaySeconds) } }
    public var alsoEject: [DiskRule] { didSet { saveCodable(alsoEject, Key.alsoEject) } }
    public var neverEject: [DiskRule] { didSet { saveCodable(neverEject, Key.neverEject) } }
    public var neverRemount: [DiskRule] { didSet { saveCodable(neverRemount, Key.neverRemount) } }

    public var ejectMode: EjectMode { unmountInsteadOfEject ? .park : .eject }

    public var ejectFilter: EjectFilter {
        EjectFilter(categories: categories, alsoEject: Set(alsoEject.map(\.id)), neverEject: Set(neverEject.map(\.id)))
    }

    @ObservationIgnored private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        func bool(_ key: String, _ fallback: Bool) -> Bool { defaults.object(forKey: key) as? Bool ?? fallback }
        func decode<T: Decodable>(_ key: String, _ fallback: T) -> T {
            defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(T.self, from: $0) } ?? fallback
        }

        // Defaults follow Jettison's out-of-the-box behaviour.
        showMenuBarIcon = bool(Key.showMenuBarIcon, true)
        showDiskCount = bool(Key.showDiskCount, true)
        menuBarIconStyle = defaults.string(forKey: Key.menuBarIconStyle).flatMap(MenuBarIconStyle.init) ?? .eject
        ejectBeforeSleep = bool(Key.ejectBeforeSleep, true)
        ejectAfterDisplayOff = bool(Key.ejectAfterDisplayOff, false)
        ejectBeforeLogout = bool(Key.ejectBeforeLogout, false)
        categories = decode(Key.categories, [.hardDisk, .optical, .diskImage, .network])
        unmountInsteadOfEject = bool(Key.unmountInsteadOfEject, true)
        autoEjectImages = bool(Key.autoEjectImages, false)
        autoEjectMinutes = defaults.object(forKey: Key.autoEjectMinutes) as? Int ?? 10
        autoEjectMode = defaults.string(forKey: Key.autoEjectMode).flatMap(ImageAutoEjectMode.init) ?? .whenIdle
        autoEjectReadOnlyOnly = bool(Key.autoEjectReadOnlyOnly, true)
        offerTrashAfterAutoEject = bool(Key.offerTrashAfterAutoEject, true)
        imageExceptions = decode(Key.imageExceptions, [])
        idleEjectEnabled = bool(Key.idleEjectEnabled, false)
        idleEjectSeconds = defaults.object(forKey: Key.idleEjectSeconds) as? Int ?? 300
        idleEjectCategories = decode(Key.idleEjectCategories, [.sdCard, .hardDisk])
        showProgressWhileEjecting = bool(Key.showProgressWhileEjecting, true)
        showProgressWhileRemounting = bool(Key.showProgressWhileRemounting, false)
        notifyAfterOperations = bool(Key.notifyAfterOperations, true)
        playSuccessSound = bool(Key.playSuccessSound, true)
        successSound = defaults.string(forKey: Key.successSound) ?? "Glass"
        playFailureSound = bool(Key.playFailureSound, true)
        failureSound = defaults.string(forKey: Key.failureSound) ?? "Basso"
        hotkeys = decode(Key.hotkeys, [:])
        remountAfterWake = bool(Key.remountAfterWake, true)
        remountDelaySeconds = defaults.object(forKey: Key.remountDelaySeconds) as? Int ?? 5
        alsoEject = decode(Key.alsoEject, [])
        neverEject = decode(Key.neverEject, [])
        neverRemount = decode(Key.neverRemount, [])
    }

    private func save(_ value: Any, _ key: String) { defaults.set(value, forKey: key) }

    private func saveCodable<T: Encodable>(_ value: T, _ key: String) {
        defaults.set(try? JSONEncoder().encode(value), forKey: key)
    }

    enum Key {
        static let showMenuBarIcon = "showMenuBarIcon"
        static let showDiskCount = "showDiskCount"
        static let menuBarIconStyle = "menuBarIconStyle"
        static let ejectBeforeSleep = "ejectBeforeSleep"
        static let ejectAfterDisplayOff = "ejectAfterDisplayOff"
        static let ejectBeforeLogout = "ejectBeforeLogout"
        static let categories = "ejectCategories"
        static let unmountInsteadOfEject = "unmountInsteadOfEject"
        static let autoEjectImages = "autoEjectImages"
        static let autoEjectMinutes = "autoEjectMinutes"
        static let autoEjectMode = "autoEjectMode"
        static let autoEjectReadOnlyOnly = "autoEjectReadOnlyOnly"
        static let offerTrashAfterAutoEject = "offerTrashAfterAutoEject"
        static let imageExceptions = "imageExceptions"
        static let idleEjectEnabled = "idleEjectEnabled"
        static let idleEjectSeconds = "idleEjectSeconds"
        static let idleEjectCategories = "idleEjectCategories"
        static let showProgressWhileEjecting = "showProgressWhileEjecting"
        static let showProgressWhileRemounting = "showProgressWhileRemounting"
        static let notifyAfterOperations = "notifyAfterOperations"
        static let playSuccessSound = "playSuccessSound"
        static let successSound = "successSound"
        static let playFailureSound = "playFailureSound"
        static let failureSound = "failureSound"
        static let hotkeys = "hotkeys"
        static let remountAfterWake = "remountAfterWake"
        static let remountDelaySeconds = "remountDelaySeconds"
        static let alsoEject = "alsoEjectDisks"
        static let neverEject = "neverEjectDisks"
        static let neverRemount = "neverRemountDisks"
    }
}
