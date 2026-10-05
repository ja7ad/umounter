import AppKit
import DiskKit
import SwiftUI
import UMounterCore

/// Settings window with the same tabs as Jettison (General, What to Eject,
/// Notifications, Hotkeys, Options) in today's macOS style: a toolbar-tab
/// `NSTabViewController` hosting SwiftUI grouped forms. macOS 26+ renders the
/// toolbar tabs with Liquid Glass; 14–15 get the classic toolbar.
///
/// An AppKit window instead of SwiftUI's `Settings` scene: a menu-bar-only app
/// cannot reliably open that scene from outside a view (e.g. on relaunch).
///
/// No `@State` in these views: the Command Line Tools toolchain lacks the SwiftUI
/// macro plugin `@State` needs on SDK 27, so view state lives in long-lived
/// `@Observable` models owned by `AppModel`.
@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    static let contentSize = NSSize(width: 560, height: 520)
    var onClose: (() -> Void)?

    convenience init(model: AppModel) {
        let tabs = NSTabViewController()
        tabs.tabStyle = .toolbar
        func add(_ title: String, _ symbol: String, _ view: some View) {
            // Every tab gets the same size (the General tab's); longer forms scroll.
            let host = NSHostingController(rootView: view.frame(width: Self.contentSize.width, height: Self.contentSize.height))
            host.sizingOptions = []
            host.preferredContentSize = Self.contentSize
            host.title = title // NSTabViewController shows the selected tab's title in the window
            let item = NSTabViewItem(viewController: host)
            item.label = title
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
            tabs.addTabViewItem(item)
        }
        add("General", "gearshape", GeneralPane(model: model))
        add("What to Eject", "externaldrive", WhatToEjectPane(model: model))
        add("Notifications", "bell.badge", NotificationsPane(settings: model.settings))
        add("Hotkeys", "command", HotkeysPane(settings: model.settings, recorder: model.hotkeyRecorder))
        add("Options", "slider.horizontal.3", OptionsPane(settings: model.settings, store: model.store))

        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable]
        window.toolbarStyle = .preference
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("UMounterSettings")
        self.init(window: window)
        window.delegate = self
    }

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }

    func show() {
        NSApp.activate()
        if window?.isVisible != true { window?.center() }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}

// MARK: - General

struct GeneralPane: View {
    let model: AppModel
    @Bindable private var settings: AppSettings
    private let loginItem: LoginItemModel

    init(model: AppModel) {
        self.model = model
        settings = model.settings
        loginItem = model.loginItem
    }

    var body: some View {
        Form {
            Section {
                StatusRow(store: model.store, style: settings.menuBarIconStyle)
            }

            Section("Startup") {
                Toggle("Launch at login", isOn: Binding(get: { loginItem.isEnabled }, set: { loginItem.set($0) }))
                if let message = loginItem.message {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("Menu bar") {
                Toggle("Show icon", isOn: $settings.showMenuBarIcon)
                Picker("Icon style", selection: $settings.menuBarIconStyle) {
                    ForEach(MenuBarIconStyle.allCases, id: \.self) { style in
                        Image(nsImage: MenuBarIcon.image(for: .mounted(count: 2), style: style, showCount: true))
                            .accessibilityLabel(style.title)
                            .help(style.title)
                            .tag(style)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(!settings.showMenuBarIcon)
                Toggle("Show number of disks to be ejected", isOn: $settings.showDiskCount)
                    .disabled(!settings.showMenuBarIcon)
                if !settings.showMenuBarIcon {
                    Text("Open UMounter again from Finder or Spotlight to get back to Settings.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section {
                Toggle("Before system sleep", isOn: $settings.ejectBeforeSleep)
                Toggle("After the display turns off", isOn: $settings.ejectAfterDisplayOff)
                Toggle("Before logout, restart and shutdown", isOn: $settings.ejectBeforeLogout)
            } header: {
                Text("Eject disks automatically")
            } footer: {
                Text("Disks are flushed and verified before macOS is allowed to sleep.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

/// The live summary at the top of General. A plain form row: Liquid Glass belongs
/// to controls and the toolbar (which macOS 26 renders as glass automatically),
/// not to content inside a grouped form, where it renders as an empty slab.
private struct StatusRow: View {
    let store: DiskStore
    let style: MenuBarIconStyle

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 26, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.tint)
                .frame(width: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text("UMounter").font(.headline)
                Text(summary).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }

    /// Same glyph family as the menu bar icon.
    private var icon: String {
        let (outline, filled) = switch style {
        case .eject: ("eject", "eject.fill")
        case .ejectCircle: ("eject.circle", "eject.circle.fill")
        case .drive: ("externaldrive", "externaldrive.fill")
        }
        switch store.statusIconState {
        case .empty: return outline
        case .safeToUnplug: return style == .drive ? "externaldrive.badge.checkmark" : "checkmark.circle"
        case .working, .mounted: return filled
        }
    }

    private var summary: String {
        switch store.statusIconState {
        case .empty: "No external disks connected."
        case .working: "Working…"
        case .safeToUnplug: "Disks are unmounted and safe to unplug."
        case .mounted(let count):
            count == 1 ? "1 disk will be ejected by Eject All." : "\(count) disks will be ejected by Eject All."
        }
    }
}

// MARK: - What to Eject

struct WhatToEjectPane: View {
    let model: AppModel
    @Bindable private var settings: AppSettings

    private let timeouts = [1, 5, 10, 30, 60]

    init(model: AppModel) {
        self.model = model
        settings = model.settings
    }

    var body: some View {
        Form {
            Section("Eject All includes") {
                ForEach(DiskCategory.allCases, id: \.self) { category in
                    Toggle(category.title, isOn: Binding(
                        get: { settings.categories.contains(category) },
                        set: { if $0 { settings.categories.insert(category) } else { settings.categories.remove(category) } }
                    ))
                }
            }
            Section {
                Toggle("Unmount instead of ejecting", isOn: $settings.unmountInsteadOfEject)
            } footer: {
                Text("Keeps flash drives and SD cards attached, so they can be remounted without unplugging them. On Mac laptops this also avoids the “Allow accessory to connect?” prompt after waking.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Toggle("Automatically eject disk images", isOn: Binding(
                    get: { settings.autoEjectImages },
                    set: { settings.autoEjectImages = $0; model.autoEjectSettingChanged($0) }
                ))
                Group {
                    Picker("Eject after", selection: $settings.autoEjectMinutes) {
                        ForEach(timeouts, id: \.self) { Text($0 == 1 ? "1 minute" : "\($0) minutes").tag($0) }
                    }
                    Picker("Start counting", selection: $settings.autoEjectMode) {
                        Text("When no longer in use").tag(ImageAutoEjectMode.whenIdle)
                        Text("When mounted").tag(ImageAutoEjectMode.afterMount)
                    }
                    Toggle("Only read-only images (installers, ISOs)", isOn: $settings.autoEjectReadOnlyOnly)
                    Toggle("Offer to move installers in Downloads to the Trash", isOn: $settings.offerTrashAfterAutoEject)
                }
                .disabled(!settings.autoEjectImages)
            } header: {
                Text("Disk images")
            } footer: {
                Text("Images that are in use, encrypted, or hold another mounted image are never ejected automatically. The notification lets you remount with one click.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Toggle("Automatically eject idle disks", isOn: Binding(
                    get: { settings.idleEjectEnabled },
                    set: { settings.idleEjectEnabled = $0; model.autoEjectSettingChanged($0) }
                ))
                Group {
                    Picker("After being idle for", selection: $settings.idleEjectSeconds) {
                        ForEach([30, 60, 120, 300, 600, 1800], id: \.self) { seconds in
                            Text(seconds < 60 ? "\(seconds) seconds" : seconds == 60 ? "1 minute" : "\(seconds / 60) minutes").tag(seconds)
                        }
                    }
                    Toggle("SD cards", isOn: categoryBinding(.sdCard))
                    Toggle("USB drives and external disks", isOn: categoryBinding(.hardDisk))
                }
                .disabled(!settings.idleEjectEnabled)
            } header: {
                Text("Idle disks")
            } footer: {
                Text("A disk is idle when nothing reads or writes it and no app has a file open on it. It is unmounted or ejected following “Unmount instead of ejecting” above. Activity is sampled only while such a disk is mounted.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            RuleList(title: "Never auto-eject these images", footer: "Also added with “Keep Mounted” in the Eject menu.",
                     rules: $settings.imageExceptions, candidates: imageCandidates)
        }
        .formStyle(.grouped)
    }

    private func categoryBinding(_ category: DiskCategory) -> Binding<Bool> {
        Binding(
            get: { settings.idleEjectCategories.contains(category) },
            set: { if $0 { settings.idleEjectCategories.insert(category) } else { settings.idleEjectCategories.remove(category) } }
        )
    }

    private var imageCandidates: [DiskRule] {
        model.store.devices.compactMap { device in
            device.diskImageURL.map { DiskRule(id: $0.path, name: $0.lastPathComponent) }
        }
    }
}

// MARK: - Notifications

struct NotificationsPane: View {
    @Bindable var settings: AppSettings

    var body: some View {
        Form {
            Section("Notifications") {
                Toggle("Notify after ejecting and remounting", isOn: $settings.notifyAfterOperations)
            }
            Section {
                soundRow("On success", isOn: $settings.playSuccessSound, sound: $settings.successSound)
                soundRow("On failure", isOn: $settings.playFailureSound, sound: $settings.failureSound)
            } header: {
                Text("Play sound")
            } footer: {
                Text("Sounds are not played when the Mac is going to sleep. To customize system notifications, go to Notifications in System Settings.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    /// One picker per outcome; "None" turns the sound off.
    private func soundRow(_ title: String, isOn: Binding<Bool>, sound: Binding<String>) -> some View {
        Picker(title, selection: Binding(
            get: { isOn.wrappedValue ? sound.wrappedValue : "" },
            set: { name in
                isOn.wrappedValue = !name.isEmpty
                if !name.isEmpty {
                    sound.wrappedValue = name
                    Feedback.play(name)
                }
            }
        )) {
            Text("None").tag("")
            Divider()
            ForEach(Feedback.availableSounds, id: \.self) { Text($0).tag($0) }
        }
    }
}

// MARK: - Hotkeys

struct HotkeysPane: View {
    let settings: AppSettings
    let recorder: HotkeyRecorderModel

    var body: some View {
        Form {
            Section {
                ForEach(HotkeyAction.allCases, id: \.self) { action in
                    LabeledContent(action.title) {
                        HStack(spacing: 6) {
                            Button(label(for: action)) { recorder.toggleRecording(action) }
                                .frame(minWidth: 150)
                                .tint(recorder.recording == action ? .accentColor : nil)
                            if settings.hotkeys[action] != nil {
                                Button {
                                    settings.hotkeys[action] = nil
                                } label: {
                                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                                }
                                .buttonStyle(.borderless)
                                .help("Clear shortcut")
                            }
                        }
                    }
                }
            } footer: {
                Text("Click a button, then press the shortcut. It needs ⌘, ⌥ or ⌃. Press Esc to cancel or Delete to clear.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func label(for action: HotkeyAction) -> String {
        if recorder.recording == action { return "Type shortcut…" }
        return settings.hotkeys[action]?.displayString ?? "Click to set"
    }
}

// MARK: - Options

struct OptionsPane: View {
    @Bindable var settings: AppSettings
    let store: DiskStore

    private let delays = [2, 5, 10, 15, 30, 60]

    var body: some View {
        Form {
            Section("Wake") {
                Picker("Remount drives after waking", selection: Binding(
                    get: { settings.remountAfterWake ? settings.remountDelaySeconds : 0 },
                    set: { delay in
                        settings.remountAfterWake = delay > 0
                        if delay > 0 { settings.remountDelaySeconds = delay }
                    }
                )) {
                    Text("Never").tag(0)
                    Divider()
                    ForEach(delays, id: \.self) { Text("After \($0) seconds").tag($0) }
                }
            }
            RuleList(title: "Also eject these disks", footer: "Ejected by Eject All even if their type is unchecked or they are internal.",
                     rules: $settings.alsoEject, candidates: candidates(includeInternal: true))
            RuleList(title: "Don’t eject these disks", footer: "Never ejected by Eject All or automatically.",
                     rules: $settings.neverEject, candidates: candidates(includeInternal: false))
            RuleList(title: "Don’t remount these disks", footer: "Stay unmounted after waking or Remount Ejected Disks.",
                     rules: $settings.neverRemount, candidates: candidates(includeInternal: false))
        }
        .formStyle(.grouped)
    }

    /// Volumes the user can pick for a rule: visible in /Volumes, or unmounted external.
    private func candidates(includeInternal: Bool) -> [DiskRule] {
        let rules = store.disks.filter { volume in
            guard volume.kind == .volume || volume.kind == .network, volume.volumeName != nil else { return false }
            if let path = volume.volumePath?.path {
                return path.hasPrefix("/Volumes/") && (includeInternal || !volume.isInternal)
            }
            return !volume.isInternal && volume.volumeKind != nil
        }
        .compactMap(DiskRule.init)
        var seen = Set<String>()
        return rules.filter { seen.insert($0.id).inserted }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

private struct RuleList: View {
    let title: String
    let footer: String
    @Binding var rules: [DiskRule]
    let candidates: [DiskRule]

    var body: some View {
        Section {
            if rules.isEmpty {
                Text("No disks").foregroundStyle(.secondary)
            }
            ForEach(rules) { rule in
                HStack {
                    Label(rule.name, systemImage: "externaldrive")
                    Spacer()
                    Button {
                        rules.removeAll { $0.id == rule.id }
                    } label: {
                        Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help("Remove \(rule.name)")
                }
            }
            let available = candidates.filter { candidate in !rules.contains { $0.id == candidate.id } }
            Menu("Add Disk…") {
                ForEach(available) { candidate in
                    Button(candidate.name) { rules.append(candidate) }
                }
            }
            .disabled(available.isEmpty)
        } header: {
            Text(title)
        } footer: {
            Text(footer).font(.caption).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Models and helpers

/// Records a global shortcut from the next key press in the Settings window.
@MainActor
@Observable
final class HotkeyRecorderModel {
    private(set) var recording: HotkeyAction?
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private var monitor: Any?

    init(settings: AppSettings) {
        self.settings = settings
    }

    func toggleRecording(_ action: HotkeyAction) {
        if recording == action { stop(); return }
        stop()
        recording = action
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let action = self.recording else { return event }
            switch Int(event.keyCode) {
            case 53: // Esc
                self.stop()
            case 51, 117: // Delete, Forward Delete
                self.settings.hotkeys[action] = nil
                self.stop()
            default:
                guard let combo = KeyCombo(event: event) else { NSSound.beep(); return nil }
                self.settings.hotkeys[action] = combo
                self.stop()
            }
            return nil
        }
    }

    /// Stops recording (e.g. when Settings closes).
    func cancel() { stop() }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = nil
    }
}

@MainActor
@Observable
final class LoginItemModel {
    private(set) var isEnabled = LoginItem.isEnabled
    private(set) var message: String?

    func set(_ enabled: Bool) {
        do {
            try LoginItem.set(enabled)
            message = LoginItem.needsApproval ? "Approve UMounter in System Settings → General → Login Items." : nil
        } catch {
            message = "Couldn’t change the login item: \(error.localizedDescription)"
        }
        isEnabled = LoginItem.isEnabled || LoginItem.needsApproval
    }
}
