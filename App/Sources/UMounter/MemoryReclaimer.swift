import AppKit
import os

/// Gives memory back by restarting UMounter quietly once it has been idle for a while.
///
/// Why: the first use of each piece of UI loads frameworks (menu rendering ~7 MB,
/// Settings/SwiftUI ~18 MB, alerts, notifications, audio). macOS never unloads
/// them from a running process, so the footprint only ratchets up (measured: no
/// leak — repeated ejects stay flat). A fresh process is back at ~13 MB.
///
/// When: only after `idleDelay` with no window, open menu or disk operation, and
/// only if the footprint is above `threshold`. It is armed by activity ending
/// (menu/window closed, operation finished) — there is no polling timer.
@MainActor
final class MemoryReclaimer {
    static let threshold: UInt64 = 30 * 1_048_576
    /// Growth over the settled launch footprint required before restarting, so a
    /// machine with a naturally higher baseline can never loop.
    static let minimumGrowth: UInt64 = 12 * 1_048_576
    static let parkedDevicesKey = "relaunchParkedDevices"

    /// Overridable for tests: `UMOUNTER_DEBUG_RECLAIM_DELAY=5`.
    let idleDelay: Duration

    /// True when nothing is going on (no window, no operation, menu closed...).
    var isQuiescent: () -> Bool = { false }
    /// State to carry into the new process.
    var parkedDeviceIDs: () -> Set<String> = { [] }
    var isEnabled: () -> Bool = { true }

    private var checkTask: Task<Void, Never>?
    /// Settled footprint shortly after launch (min of samples at 3 s and 15 s).
    private var baseline: UInt64?
    private let log = Logger(subsystem: "app.umounter", category: "memory")

    init() {
        let override = ProcessInfo.processInfo.environment["UMOUNTER_DEBUG_RECLAIM_DELAY"].flatMap(Double.init)
        idleDelay = .seconds(override ?? 120)
        // Settled launch footprint: the lower of two samples, so opening a window
        // right after launch does not inflate it.
        Task { [weak self] in
            for delay in [3, 12] {
                try? await Task.sleep(for: .seconds(delay))
                let now = Self.physicalFootprint()
                self?.baseline = min(self?.baseline ?? now, now)
            }
        }
    }

    /// Call when user-visible activity ends; (re)starts the idle countdown.
    func activityEnded() {
        checkTask?.cancel()
        guard isEnabled() else { return }
        checkTask = Task { [weak self, idleDelay] in
            try? await Task.sleep(for: idleDelay, tolerance: .seconds(10))
            guard !Task.isCancelled else { return }
            self?.checkAndRelaunch()
        }
    }

    /// Call when activity starts (menu opened, window shown).
    func activityStarted() {
        checkTask?.cancel()
        checkTask = nil
    }

    private func checkAndRelaunch() {
        let footprint = Self.physicalFootprint()
        guard isEnabled(), isQuiescent() else { return }
        let required = max(Self.threshold, (baseline ?? footprint) + Self.minimumGrowth)
        guard footprint > required else {
            log.debug("idle footprint \(footprint / 1_048_576) MB, below \(required / 1_048_576) MB")
            return
        }
        log.info("idle footprint \(footprint / 1_048_576) MB; restarting to release memory")
        relaunch()
    }

    /// Starts a fresh copy once this process has exited, then quits.
    private func relaunch() {
        UserDefaults.standard.set(Array(parkedDeviceIDs()), forKey: Self.parkedDevicesKey)
        let pid = ProcessInfo.processInfo.processIdentifier
        let process = Process()
        process.executableURL = URL(filePath: "/bin/sh")
        // Wait for this process to exit (so the status item and hotkeys are free),
        // then reopen the same bundle in the background with a clean environment
        // (`open` would pass ours on) and without restoring windows.
        process.arguments = [
            "-c",
            "while kill -0 \(pid) 2>/dev/null; do sleep 0.1; done; "
                + "/usr/bin/env -i HOME=\"$HOME\" /usr/bin/open -g \"$0\" --args -ApplePersistenceIgnoreState YES -UMounterReclaimRelaunch YES",
            Bundle.main.bundlePath,
        ]
        do {
            try process.run()
            NSApp.terminate(nil)
        } catch {
            log.error("relaunch failed: \(error, privacy: .public)")
        }
    }

    /// True in a process started by `relaunch()` (launch argument).
    static var isReclaimRelaunch: Bool { UserDefaults.standard.bool(forKey: "UMounterReclaimRelaunch") }

    /// Restores state saved by `relaunch()`; returns the parked device IDs.
    static func takeSavedParkedDevices() -> Set<String> {
        let ids = UserDefaults.standard.stringArray(forKey: parkedDevicesKey) ?? []
        UserDefaults.standard.removeObject(forKey: parkedDevicesKey)
        return Set(ids)
    }

    /// This process's physical footprint, as Activity Monitor's Memory column shows it.
    static func physicalFootprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? info.phys_footprint : 0
    }
}
