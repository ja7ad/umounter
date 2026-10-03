import AppKit
import Carbon.HIToolbox
import UMounterCore

/// Global hotkeys via Carbon `RegisterEventHotKey`: it needs no Accessibility or
/// Input Monitoring permission and wakes the app only when the hotkey is pressed
/// (unlike an event tap, which sees every keystroke).
@MainActor
final class HotkeyCenter {
    var onAction: ((HotkeyAction) -> Void)?

    private var handler: EventHandlerRef?
    private var registered: [EventHotKeyRef] = []
    private var actionsByID: [UInt32: HotkeyAction] = [:]
    private static let signature: OSType = 0x554D_4E54 // "UMNT"

    func update(_ hotkeys: [HotkeyAction: KeyCombo]) {
        installHandlerIfNeeded()
        registered.forEach { UnregisterEventHotKey($0) }
        registered.removeAll()
        actionsByID.removeAll()

        for (index, (action, combo)) in hotkeys.sorted(by: { $0.key.rawValue < $1.key.rawValue }).enumerated() {
            let id = UInt32(index + 1)
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(
                UInt32(combo.keyCode), Self.carbonModifiers(combo.modifiers),
                EventHotKeyID(signature: Self.signature, id: id), GetApplicationEventTarget(), 0, &ref
            )
            if status == noErr, let ref {
                registered.append(ref)
                actionsByID[id] = action
            }
        }
    }

    private func installHandlerIfNeeded() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, refcon in
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID
            )
            guard status == noErr, let refcon else { return status }
            let center = Unmanaged<HotkeyCenter>.fromOpaque(refcon).takeUnretainedValue()
            MainActor.assumeIsolated {
                if let action = center.actionsByID[hotKeyID.id] { center.onAction?(action) }
            }
            return noErr
        }, 1, &spec, refcon, &handler)
    }

    private static func carbonModifiers(_ raw: UInt) -> UInt32 {
        let flags = NSEvent.ModifierFlags(rawValue: raw)
        var result: UInt32 = 0
        if flags.contains(.command) { result |= UInt32(cmdKey) }
        if flags.contains(.option) { result |= UInt32(optionKey) }
        if flags.contains(.control) { result |= UInt32(controlKey) }
        if flags.contains(.shift) { result |= UInt32(shiftKey) }
        return result
    }
}

extension KeyCombo {
    /// "⌃⌥⌘E" style label.
    var displayString: String {
        let flags = NSEvent.ModifierFlags(rawValue: modifiers)
        var text = ""
        if flags.contains(.control) { text += "⌃" }
        if flags.contains(.option) { text += "⌥" }
        if flags.contains(.shift) { text += "⇧" }
        if flags.contains(.command) { text += "⌘" }
        return text + keyLabel
    }

    /// Builds a combo from a key-down event, or nil if it lacks a ⌘/⌥/⌃ modifier.
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard !flags.intersection([.command, .option, .control]).isEmpty else { return nil }
        let label = Self.specialKeys[event.keyCode]
            ?? (event.charactersIgnoringModifiers ?? "").uppercased()
        self.init(keyCode: event.keyCode, modifiers: flags.rawValue, keyLabel: label)
    }

    private static let specialKeys: [UInt16: String] = [
        UInt16(kVK_Space): "Space", UInt16(kVK_Return): "↩", UInt16(kVK_Tab): "⇥",
        UInt16(kVK_LeftArrow): "←", UInt16(kVK_RightArrow): "→", UInt16(kVK_UpArrow): "↑", UInt16(kVK_DownArrow): "↓",
        UInt16(kVK_F1): "F1", UInt16(kVK_F2): "F2", UInt16(kVK_F3): "F3", UInt16(kVK_F4): "F4",
        UInt16(kVK_F5): "F5", UInt16(kVK_F6): "F6", UInt16(kVK_F7): "F7", UInt16(kVK_F8): "F8",
        UInt16(kVK_F9): "F9", UInt16(kVK_F10): "F10", UInt16(kVK_F11): "F11", UInt16(kVK_F12): "F12",
    ]
}
