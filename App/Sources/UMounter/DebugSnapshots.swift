#if DEBUG
import AppKit
import SwiftUI

/// Debug builds only: `UMOUNTER_SNAPSHOT_DIR=/path .build/debug/UMounter` renders
/// every Settings tab to PNG (light and dark) and exits. Lets UI be reviewed in CI
/// or when the display is unavailable.
@MainActor
enum DebugSnapshots {
    /// This process's physical footprint, as `footprint`/Activity Monitor report it.
    static func physicalFootprint() -> String {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return kr == KERN_SUCCESS ? String(format: "%.1f MB", Double(info.phys_footprint) / 1_048_576) : "?"
    }

    /// `UMOUNTER_DEBUG_EJECT_LOOP=/path/test.dmg`: attach and eject that image 6 times,
    /// printing the footprint after each round (checks that ejecting does not leak).
    static func runEjectLoopIfRequested(model: AppModel) {
        guard let image = ProcessInfo.processInfo.environment["UMOUNTER_DEBUG_EJECT_LOOP"] else { return }
        Task { @MainActor in
            for round in 1...6 {
                let attach = Process()
                attach.executableURL = URL(filePath: "/usr/bin/hdiutil")
                attach.arguments = ["attach", image, "-quiet"]
                try? attach.run()
                attach.waitUntilExit()
                try? await Task.sleep(for: .seconds(1.5))
                await model.store.refresh()
                if let device = model.store.devices.first(where: { $0.diskImageURL?.path == image }) {
                    model.eject(device)
                }
                try? await Task.sleep(for: .seconds(2))
                print("round \(round): \(physicalFootprint())"); fflush(stdout)
            }
            exit(0)
        }
    }

    static func runIfRequested(model: AppModel) {
        runEjectLoopIfRequested(model: model)
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
