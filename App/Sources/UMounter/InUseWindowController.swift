import AppKit
import DiskKit
import UMounterCore

/// "Disk in use" window (Jettison-style, with more detail): lists the processes
/// holding a disk — including command-line ones such as a shell whose working
/// directory is on the disk — with Quit / Force Quit buttons. When the last
/// blocker exits, the eject is retried automatically.
///
/// Plain AppKit (no SwiftUI) so showing it doesn't grow the idle footprint; the
/// controller is released when the window closes.
@MainActor
final class InUseWindowController: NSWindowController, NSWindowDelegate {
    struct Item {
        var deviceID: String
        var deviceName: String
        var blockers: [Blocker]
        var message: String
    }

    var onClose: (() -> Void)?

    /// Retries ejecting a device; returns nil on success.
    private let retry: (String) async -> OperationFailure?
    /// Called with the names of devices ejected from this window.
    private let onEjected: ([String]) -> Void

    private var items: [Item] = []
    private var quitRequested: [pid_t: Date] = [:]
    private var exitSources: [pid_t: DispatchSourceProcess] = [:]
    private var retrying: Set<String> = []
    private let content = NSStackView()
    private let statusLabel = NSTextField(labelWithString: "")

    /// Interactive shells ignore SIGTERM; SIGHUP is what closing their terminal sends.
    private static let shells: Set<String> = ["zsh", "bash", "sh", "fish", "tcsh", "csh", "ksh", "dash", "nu"]
    private static let forceQuitDelay: TimeInterval = 3

    init(retry: @escaping (String) async -> OperationFailure?, onEjected: @escaping ([String]) -> Void) {
        self.retry = retry
        self.onEjected = onEjected
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 200),
            styleMask: [.titled, .closable], backing: .buffered, defer: true
        )
        window.title = "Couldn’t Eject"
        window.isReleasedWhenClosed = false
        // A menu bar app can't take focus while the user works elsewhere (cooperative
        // activation), so the prompt floats above other apps' windows instead.
        window.level = .floating
        window.collectionBehavior = [.moveToActiveSpace]
        super.init(window: window)
        window.delegate = self

        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 12
        content.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        content.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = content
        content.widthAnchor.constraint(equalToConstant: 520).isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Shows (or updates) the window for busy-disk failures.
    func show(_ failures: [OperationFailure]) {
        for failure in failures {
            guard let id = failure.deviceID else { continue }
            let item = Item(deviceID: id, deviceName: failure.deviceName, blockers: failure.blockers, message: failure.message)
            if let index = items.firstIndex(where: { $0.deviceID == id }) { items[index] = item } else { items.append(item) }
        }
        watchBlockers()
        rebuild()
        NSApp.activate()
        if window?.isVisible != true { window?.center() }
        showWindow(nil)
        window?.orderFrontRegardless()
        window?.makeKey()
    }

    func windowWillClose(_ notification: Notification) {
        exitSources.values.forEach { $0.cancel() }
        exitSources.removeAll()
        onClose?()
    }

    // MARK: - Actions

    private func quit(_ blocker: Blocker) {
        let force = canForceQuit(blocker)
        if let app = NSRunningApplication(processIdentifier: blocker.pid) {
            _ = force ? app.forceTerminate() : app.terminate()
        } else {
            kill(blocker.pid, force ? SIGKILL : (Self.shells.contains(blocker.name) ? SIGHUP : SIGTERM))
        }
        quitRequested[blocker.pid] = Date()
        rebuild()
        // Offer Force Quit if it is still running after a few seconds.
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.forceQuitDelay + 0.1) { [weak self] in self?.rebuild() }
    }

    @objc private func quitAll() {
        for blocker in items.flatMap(\.blockers) where canQuit(blocker) { quit(blocker) }
    }

    @objc private func tryAgain() {
        for item in items { retryEject(item.deviceID) }
    }

    @objc private func cancel() { close() }

    private func retryEject(_ id: String) {
        guard retrying.insert(id).inserted else { return }
        rebuild()
        Task { @MainActor in
            var failure = await retry(id)
            // Right after a blocker exits, the kernel (or an FSKit file system) may not
            // have released its files yet: retry briefly when no process is visible.
            for delay in [0.5, 1.0, 2.0] where failure != nil && failure?.blockers.isEmpty == true {
                try? await Task.sleep(for: .seconds(delay))
                failure = await retry(id)
            }
            retrying.remove(id)
            guard let index = items.firstIndex(where: { $0.deviceID == id }) else { return }
            if let failure {
                items[index].blockers = failure.blockers
                items[index].message = failure.message
                watchBlockers()
                rebuild()
            } else {
                onEjected([items[index].deviceName])
                items.remove(at: index)
                if items.isEmpty { close() } else { rebuild() }
            }
        }
    }

    // MARK: - Process exit tracking (event-driven, no polling)

    private func watchBlockers() {
        let pids = Set(items.flatMap(\.blockers).map(\.pid))
        for (pid, source) in exitSources where !pids.contains(pid) {
            source.cancel()
            exitSources[pid] = nil
        }
        for pid in pids where exitSources[pid] == nil {
            let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated { self?.processExited(pid) }
            }
            source.resume()
            exitSources[pid] = source
            // The process may already be gone (it exited between scan and watch).
            if kill(pid, 0) != 0 && errno == ESRCH { processExited(pid) }
        }
    }

    private func processExited(_ pid: pid_t) {
        exitSources[pid]?.cancel()
        exitSources[pid] = nil
        quitRequested[pid] = nil
        for index in items.indices {
            items[index].blockers.removeAll { $0.pid == pid }
        }
        rebuild()
        // A disk with no blockers left is retried at once.
        for item in items where item.blockers.isEmpty { retryEject(item.deviceID) }
    }

    // MARK: - UI

    private func canQuit(_ blocker: Blocker) -> Bool {
        blocker.isOwnedByCurrentUser && blocker.pid != getpid()
    }

    private func canForceQuit(_ blocker: Blocker) -> Bool {
        guard let asked = quitRequested[blocker.pid] else { return false }
        return Date().timeIntervalSince(asked) >= Self.forceQuitDelay
    }

    private func rebuild() {
        content.arrangedSubviews.forEach { $0.removeFromSuperview() }

        content.addArrangedSubview(header())
        for item in items {
            if items.count > 1 {
                let title = NSTextField(labelWithString: item.deviceName)
                title.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
                content.addArrangedSubview(title)
            }
            if item.blockers.isEmpty, items.count > 1 || retrying.contains(item.deviceID) {
                let text = retrying.contains(item.deviceID) ? "Ejecting…" : item.message
                content.addArrangedSubview(secondaryLabel(text))
            }
            for blocker in item.blockers {
                let row = self.row(for: blocker, volumeHint: item.deviceName)
                content.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -40).isActive = true
            }
        }
        let footer = self.footer()
        content.addArrangedSubview(footer)
        footer.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -40).isActive = true

        let waiting = items.flatMap(\.blockers).count
        statusLabel.stringValue = waiting == 0 ? "" : waiting == 1
            ? "Waiting for 1 process to quit…" : "Waiting for \(waiting) processes to quit…"
        window?.setContentSize(content.fittingSize)
    }

    private func header() -> NSView {
        let icon = NSImageView(image: NSImage(systemSymbolName: "externaldrive.badge.exclamationmark", accessibilityDescription: nil) ?? NSImage())
        icon.symbolConfiguration = .init(pointSize: 30, weight: .regular)
        icon.contentTintColor = .systemOrange

        let hasBlockers = items.contains { !$0.blockers.isEmpty }
        let title = NSTextField(labelWithString: items.count == 1
            ? "“\(items[0].deviceName)” can’t be ejected yet"
            : "\(items.count) disks can’t be ejected yet")
        title.font = .boldSystemFont(ofSize: 15)
        let subtitle = secondaryLabel(hasBlockers
            ? "These processes are using it. Quit them and UMounter ejects it automatically — nothing is force-unmounted."
            : items.count == 1 ? items[0].message : "Nothing is force-unmounted. Try again in a moment.")
        subtitle.preferredMaxLayoutWidth = 410

        let texts = NSStackView(views: [title, subtitle])
        texts.orientation = .vertical
        texts.alignment = .leading
        texts.spacing = 4
        let stack = NSStackView(views: [icon, texts])
        stack.alignment = .top
        stack.spacing = 12
        return stack
    }

    private func row(for blocker: Blocker, volumeHint: String) -> NSView {
        let app = NSRunningApplication(processIdentifier: blocker.pid)
        let owner = app == nil ? owningApp(of: blocker) : nil
        let iconImage = app?.icon ?? owner?.icon ?? NSWorkspace.shared.icon(for: .unixExecutable)
        iconImage.size = NSSize(width: 28, height: 28)
        let icon = NSImageView(image: iconImage)

        let name = NSTextField(labelWithString: app?.localizedName ?? blocker.name)
        name.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        var details: [String] = []
        if let owner { details.append("in \(owner.localizedName ?? "another app")") }
        if let file = blocker.openFiles.first {
            details.append(file.hasSuffix("(working directory)") ? "working directory on the disk" : (file as NSString).lastPathComponent)
            if blocker.openFiles.count > 1 { details.append("+\(blocker.openFiles.count - 1) more") }
        }
        details.append("PID \(blocker.pid)")
        let detail = secondaryLabel(details.joined(separator: " · "))
        detail.lineBreakMode = .byTruncatingMiddle
        detail.toolTip = blocker.openFiles.joined(separator: "\n")

        let texts = NSStackView(views: [name, detail])
        texts.orientation = .vertical
        texts.alignment = .leading
        texts.spacing = 2
        texts.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let button: NSButton
        if !canQuit(blocker) {
            button = NSButton(title: "Quit", target: nil, action: nil)
            button.isEnabled = false
            button.toolTip = "Owned by another user — quit it from that account or Activity Monitor."
        } else {
            let force = canForceQuit(blocker)
            let asked = quitRequested[blocker.pid] != nil && !force
            button = ClosureButton(title: force ? "Force Quit" : (asked ? "Quitting…" : "Quit")) { [weak self] in self?.quit(blocker) }
            button.isEnabled = !asked
            if force { button.contentTintColor = .systemRed }
        }
        button.bezelStyle = .push
        button.setContentHuggingPriority(.required, for: .horizontal)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let stack = NSStackView(views: [icon, texts, spacer, button])
        stack.alignment = .centerY
        stack.spacing = 10
        return stack
    }

    private func footer() -> NSView {
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        let quitAll = NSButton(title: "Quit All", target: self, action: #selector(quitAll))
        quitAll.isEnabled = items.flatMap(\.blockers).contains(where: canQuit)
        quitAll.isHidden = items.allSatisfy(\.blockers.isEmpty)
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancel.keyEquivalent = "\u{1b}"
        let again = NSButton(title: "Try Again", target: self, action: #selector(tryAgain))
        again.keyEquivalent = "\r"
        again.isEnabled = retrying.isEmpty
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let stack = NSStackView(views: [statusLabel, spacer, quitAll, cancel, again])
        stack.spacing = 8
        return stack
    }

    private func secondaryLabel(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.textColor = .secondaryLabelColor
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        return label
    }

    /// The app a helper process belongs to, e.g. Terminal for a `zsh` sitting in the disk.
    private func owningApp(of blocker: Blocker) -> NSRunningApplication? {
        var pid = blocker.parentPID
        for _ in 0..<12 {
            guard let current = pid, current > 1 else { return nil }
            if let app = NSRunningApplication(processIdentifier: current), app.activationPolicy == .regular { return app }
            pid = BlockerScanner.parentPID(of: current)
        }
        return nil
    }
}

/// An `NSButton` that runs a closure.
@MainActor
private final class ClosureButton: NSButton {
    private var handler: (() -> Void)?

    convenience init(title: String, handler: @escaping () -> Void) {
        self.init(frame: .zero)
        self.title = title
        self.handler = handler
        target = self
        action = #selector(run)
    }

    @objc private func run() { handler?() }
}
