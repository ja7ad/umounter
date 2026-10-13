import AppKit
import DiskKit
import Observation
import UMounterCore

/// The menu bar item, in plain AppKit.
///
/// Why not SwiftUI `MenuBarExtra`: it keeps a full SwiftUI view graph alive for the
/// whole app lifetime (~20 MB of heap measured: `PropertyList.Element`,
/// `PlatformItemList.Item`, tracked-value dictionaries). Here the `NSMenu` is built
/// only when the user opens it (`menuNeedsUpdate`) and the icon is redrawn only when
/// its state actually changes, so an idle UMounter holds almost nothing.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let model: AppModel
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()

    init(model: AppModel) {
        self.model = model
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        statusItem.autosaveName = "UMounterStatusItem"
        observeIcon()
    }

    // MARK: - Icon

    /// How long the "safe to unplug" checkmark stays after an eject before the icon
    /// returns to normal. Parked disks stay attached, so a lasting checkmark would
    /// look like a stuck state.
    static let safeConfirmationDuration: Duration = .seconds(4)

    private var current: (state: StatusIconState, style: MenuBarIconStyle, showCount: Bool) = (.empty, .eject, true)
    private var safeConfirmationEnded = false
    private var safeConfirmationTask: Task<Void, Never>?

    private func observeIcon() {
        let (state, style, showCount, visible) = withObservationTracking {
            (model.store.statusIconState, model.settings.menuBarIconStyle, model.settings.showDiskCount, model.settings.showMenuBarIcon)
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeIcon() }
        }
        statusItem.isVisible = visible

        if state == .safeToUnplug, current.state != .safeToUnplug {
            // Entering "safe to unplug": show the checkmark briefly, then the normal icon.
            safeConfirmationEnded = false
            safeConfirmationTask?.cancel()
            safeConfirmationTask = Task { [weak self] in
                try? await Task.sleep(for: Self.safeConfirmationDuration)
                guard !Task.isCancelled, let self else { return }
                self.safeConfirmationEnded = true
                self.render()
            }
        } else if state != .safeToUnplug {
            safeConfirmationTask?.cancel()
            safeConfirmationTask = nil
        }
        current = (state, style, showCount)
        render()
    }

    private func render() {
        guard let button = statusItem.button else { return }
        let state = current.state == .safeToUnplug && safeConfirmationEnded ? .empty : current.state
        button.image = MenuBarIcon.image(for: state, style: current.style, showCount: current.showCount)
        let text = current.state == .safeToUnplug ? "UMounter — disks unmounted, safe to unplug" : Self.accessibilityText(state)
        button.setAccessibilityLabel(text)
        button.toolTip = text
    }

    private static func accessibilityText(_ state: StatusIconState) -> String {
        switch state {
        case .empty: "UMounter — no external disks"
        case .working: "UMounter — working"
        case .safeToUnplug: "UMounter — safe to unplug"
        case .mounted(let count): count == 1 ? "UMounter — 1 disk" : "UMounter — \(count) disks"
        }
    }

    // MARK: - Menu (built on open, discarded on the next open)

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let store = model.store

        menu.addItem(item("Eject External Disks", hotkey: .ejectAll, enabled: !store.ejectAllDevices.isEmpty) { [model] in model.ejectAll() })
        menu.addItem(item("Eject and Sleep", hotkey: .ejectAndSleep) { [model] in model.ejectAllAndSleep() })
        menu.addItem(item("Sleep") { SystemSleep.sleepNow() })
        menu.addItem(.separator())
        menu.addItem(item("Remount Ejected Disks", hotkey: .remount, enabled: store.canRemount) { [model] in model.remount() })
        menu.addItem(.separator())

        let eject = NSMenu()
        for device in store.devices { eject.addItem(ejectItem(for: device)) }
        menu.addItem(submenu("Eject", eject))

        let mount = NSMenu()
        for volume in store.mountableVolumes {
            mount.addItem(item(volume.volumeName ?? volume.id, symbol: "externaldrive.badge.plus") { [model] in model.mount(volume) })
        }
        menu.addItem(submenu("Mount", mount))

        menu.addItem(.separator())
        menu.addItem(item("Settings…", key: ",") { [model] in model.showSettings() })
        menu.addItem(item("About UMounter") {
            NSApp.activate()
            NSApp.orderFrontStandardAboutPanel(nil)
        })
        menu.addItem(.separator())
        menu.addItem(item("Quit UMounter", key: "q") { NSApp.terminate(nil) })
    }

    #if DEBUG
    /// Builds the menu as if opened and returns its titles (debug hook).
    func debugMenuDump() -> String {
        menuNeedsUpdate(menu)
        func dump(_ menu: NSMenu, indent: String) -> [String] {
            menu.items.flatMap { item -> [String] in
                let line = item.isSeparatorItem ? "\(indent)———" : "\(indent)\(item.title)\(item.isEnabled ? "" : " [disabled]")"
                return [line] + (item.submenu.map { dump($0, indent: indent + "    ") } ?? [])
            }
        }
        return dump(menu, indent: "").joined(separator: "\n")
    }
    #endif

    /// Frees the per-open menu (items, closures, images) once it closes.
    func menuDidClose(_ menu: NSMenu) {
        DispatchQueue.main.async { menu.removeAllItems() }
    }

    private func ejectItem(for device: Device) -> NSMenuItem {
        let busy = model.store.busyDeviceIDs.contains(device.id)
        var title = device.name
        if let proto = device.deviceProtocol, !device.isNetwork, device.category != .diskImage { title += " — \(proto)" }
        if busy { title += " — working…" }

        if let status = model.imageAutoEject.statuses[device.id], let url = device.diskImageURL {
            // Disk image with auto-eject armed: show when, and let the user keep it.
            let sub = NSMenu()
            sub.addItem(item("Eject Now") { [model] in model.eject(device) })
            sub.addItem(item("Keep Mounted") { [model] in model.keepMounted(device) })
            sub.addItem(item("Show Image File in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) })
            let parent = submenu("\(title) — \(Self.describe(status))", sub)
            parent.image = Self.symbol(Self.icon(for: device))
            return parent
        }
        return item(title, symbol: Self.icon(for: device), enabled: !busy) { [model] in model.eject(device) }
    }

    static func describe(_ status: ImageEjectStatus, now: Date = .now) -> String {
        switch status {
        case .waitingWhileInUse:
            return "in use, waiting"
        case .scheduled(let date):
            let minutes = Int((date.timeIntervalSince(now) / 60).rounded(.up))
            return minutes <= 0 ? "ejects soon" : minutes == 1 ? "ejects in 1 min" : "ejects in \(minutes) min"
        }
    }

    private static func icon(for device: Device) -> String {
        switch device.category {
        case .network: "network"
        case .diskImage: "opticaldisc"
        case .optical: "opticaldiscdrive"
        case .sdCard: "sdcard"
        case .hardDisk: "externaldrive"
        }
    }

    // MARK: - Item helpers

    private func item(
        _ title: String, symbol: String? = nil, key: String = "", hotkey: HotkeyAction? = nil,
        enabled: Bool = true, action: @escaping @MainActor () -> Void
    ) -> NSMenuItem {
        let item = ActionMenuItem(title: title, action: action)
        item.keyEquivalent = key
        item.isEnabled = enabled
        if let symbol { item.image = Self.symbol(symbol) }
        // Show the global hotkey next to the item (display only; Carbon handles it).
        if let hotkey, let combo = model.settings.hotkeys[hotkey], combo.keyLabel.count == 1 {
            item.keyEquivalent = combo.keyLabel.lowercased()
            item.keyEquivalentModifierMask = NSEvent.ModifierFlags(rawValue: combo.modifiers)
                .intersection([.command, .option, .control, .shift])
        }
        return item
    }

    private func submenu(_ title: String, _ submenu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        submenu.autoenablesItems = false
        item.submenu = submenu
        item.isEnabled = !submenu.items.isEmpty
        return item
    }

    private static func symbol(_ name: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)
    }
}

/// An `NSMenuItem` that runs a closure.
@MainActor
private final class ActionMenuItem: NSMenuItem {
    private let handler: @MainActor () -> Void

    init(title: String, action: @escaping @MainActor () -> Void) {
        handler = action
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func run() { handler() }
}
