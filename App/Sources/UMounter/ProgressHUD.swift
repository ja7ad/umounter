import AppKit
import Observation
import UMounterCore

/// Jettison-style progress window: a small floating panel with a spinning
/// indicator — "Ejecting “JAVAD” (USB drive)…" — shown while disks are being
/// ejected, unmounted or remounted, whatever started it (menu, hotkey, sleep,
/// auto-eject).
///
/// Plain AppKit; the panel exists only while something is in progress, and it
/// appears after a short delay so instant operations don't flash it.
@MainActor
final class ProgressHUD {
    private let store: DiskStore
    private let settings: AppSettings
    private var panel: NSPanel?
    private var label: NSTextField?
    private var showTask: Task<Void, Never>?

    static let showDelay: Duration = .milliseconds(250)

    init(store: DiskStore, settings: AppSettings) {
        self.store = store
        self.settings = settings
        observe()
    }

    private func observe() {
        let message = withObservationTracking {
            DiskOperation.progressMessage(
                for: Array(store.activeOperations.values),
                showEjecting: settings.showProgressWhileEjecting,
                showMounting: settings.showProgressWhileRemounting
            )
        } onChange: { [weak self] in
            Task { @MainActor in self?.observe() }
        }
        update(message)
    }

    private func update(_ message: String?) {
        guard let message else {
            showTask?.cancel()
            showTask = nil
            hide()
            return
        }
        if let label {
            label.stringValue = message
            resize()
            return
        }
        guard showTask == nil else { return }
        showTask = Task { [weak self] in
            try? await Task.sleep(for: Self.showDelay)
            guard !Task.isCancelled, let self else { return }
            self.showTask = nil
            // Re-read: the operation may have finished during the delay.
            let current = DiskOperation.progressMessage(
                for: Array(self.store.activeOperations.values),
                showEjecting: self.settings.showProgressWhileEjecting,
                showMounting: self.settings.showProgressWhileRemounting
            )
            if let current { self.show(current) }
        }
    }

    private func show(_ message: String) {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 56),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false
        )
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
        panel.isReleasedWhenClosed = false

        let background = NSVisualEffectView()
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 14
        background.layer?.masksToBounds = true

        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isIndeterminate = true
        spinner.startAnimation(nil)

        let label = NSTextField(labelWithString: message)
        label.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        label.lineBreakMode = .byTruncatingMiddle
        label.maximumNumberOfLines = 1

        let stack = NSStackView(views: [spinner, label])
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 18, bottom: 16, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            stack.topAnchor.constraint(equalTo: background.topAnchor),
            stack.bottomAnchor.constraint(equalTo: background.bottomAnchor),
        ])
        panel.contentView = background
        panel.setAccessibilityLabel(message)

        self.panel = panel
        self.label = label
        resize()
        panel.orderFrontRegardless()
    }

    /// Fits the text (up to 520 pt) and centers the panel near the top of the screen
    /// with the menu bar, like the system volume/brightness HUDs but higher.
    private func resize() {
        guard let panel, let content = panel.contentView else { return }
        let size = content.fittingSize
        let width = min(max(size.width, 240), 520)
        let screen = NSScreen.main?.visibleFrame ?? .zero
        let frame = NSRect(x: screen.midX - width / 2, y: screen.maxY - size.height - 80, width: width, height: size.height)
        panel.setFrame(frame, display: true)
        panel.setAccessibilityLabel(label?.stringValue)
    }

    #if DEBUG
    /// Shows the panel with a fixed message (debug hook for screenshots).
    func debugShow(_ message: String) { show(message) }
    #endif

    private func hide() {
        panel?.orderOut(nil)
        panel = nil
        label = nil
    }
}
