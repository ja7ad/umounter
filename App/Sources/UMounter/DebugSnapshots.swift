#if DEBUG
import AppKit
import SwiftUI

/// Debug builds only: `UMOUNTER_SNAPSHOT_DIR=/path .build/debug/UMounter` renders
/// every Settings tab to PNG (light and dark) and exits. Lets UI be reviewed in CI
/// or when the display is unavailable.
@MainActor
enum DebugSnapshots {
    static func runIfRequested(model: AppModel) {
        // `UMOUNTER_DEBUG_SETTINGS_CYCLE=1`: open Settings, close it after 5 s — for
        // measuring that the window's memory is released (`footprint` before/after).
        if ProcessInfo.processInfo.environment["UMOUNTER_DEBUG_SETTINGS_CYCLE"] != nil {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(5))
                model.showSettings()
                print("settings opened"); fflush(stdout)
                try? await Task.sleep(for: .seconds(5))
                NSApp.windows.first { $0.isVisible && $0.styleMask.contains(.titled) }?.performClose(nil)
                print("settings closed"); fflush(stdout)
            }
        }
        guard let dir = ProcessInfo.processInfo.environment["UMOUNTER_SNAPSHOT_DIR"] else { return }
        let output = URL(filePath: dir, directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        Task { @MainActor in
            await model.store.refresh()
            let panes: [(String, AnyView)] = [
                ("general", AnyView(GeneralPane(model: model))),
                ("what-to-eject", AnyView(WhatToEjectPane(model: model))),
                ("notifications", AnyView(NotificationsPane(settings: model.settings))),
                ("hotkeys", AnyView(HotkeysPane(settings: model.settings, recorder: model.hotkeyRecorder))),
                ("options", AnyView(OptionsPane(settings: model.settings, store: model.store))),
            ]
            for (name, view) in panes {
                for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                    render(view, appearance: appearance, to: output.appending(path: "\(name)-\(suffix).png"))
                }
            }
            exit(0)
        }
    }

    private static func render(_ view: AnyView, appearance: NSAppearance.Name, to url: URL) {
        let host = NSHostingView(rootView: view.frame(width: 560).fixedSize(horizontal: false, vertical: true))
        host.setFrameSize(host.fittingSize)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
#endif
