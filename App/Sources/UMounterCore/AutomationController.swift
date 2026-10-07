import Foundation
import os

/// Decides what to do on power and session events (sleep, display off, logout,
/// wake). The platform glue (IOKit / NSWorkspace) lives in the app target and
/// only forwards events here, so this logic is unit-tested with a fake clock.
@MainActor
public final class AutomationController {
    private let store: DiskStore
    private let settings: AppSettings
    private let clock: any Clock<Duration>
    private let log = Logger(subsystem: "app.umounter", category: "automation")

    /// Set when UMounter parked disks for sleep/display-off, so wake remounts only those.
    public private(set) var parkedForSleep = false
    private var remountTask: Task<Void, Never>?

    public init(store: DiskStore, settings: AppSettings, clock: any Clock<Duration> = ContinuousClock()) {
        self.store = store
        self.settings = settings
        self.clock = clock
    }

    /// The system is about to sleep. Returns within `deadline` even if ejection is
    /// still running, because the OS only waits about 30 s for the acknowledgement.
    @discardableResult
    public func systemWillSleep(deadline: Duration = .seconds(25)) async -> [OperationFailure] {
        remountTask?.cancel()
        guard settings.ejectBeforeSleep else { return [] }
        return await ejectAllForPowerEvent(deadline: deadline)
    }

    @discardableResult
    public func displayDidSleep() async -> [OperationFailure] {
        guard settings.ejectAfterDisplayOff else { return [] }
        remountTask?.cancel()
        return await ejectAllForPowerEvent(deadline: nil)
    }

    @discardableResult
    public func sessionWillEnd() async -> [OperationFailure] {
        guard settings.ejectBeforeLogout else { return [] }
        return await ejectAllForPowerEvent(deadline: .seconds(10))
    }

    /// The user is back (full wake or display on). Remounts what we parked after the
    /// configured delay. Called only on a *user* wake, never on dark wake.
    public func userDidReturn() {
        guard parkedForSleep, settings.remountAfterWake else { return }
        parkedForSleep = false
        let delay = Duration.seconds(settings.remountDelaySeconds)
        remountTask?.cancel()
        remountTask = Task { [weak self, clock] in
            try? await clock.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            await self.store.refresh()
            let failures = await self.store.remountParked()
            if !failures.isEmpty { self.log.error("remount after wake: \(failures.count) failure(s)") }
        }
    }

    /// Waits for a pending wake remount (tests).
    func waitForRemount() async { await remountTask?.value }

    private func ejectAllForPowerEvent(deadline: Duration?) async -> [OperationFailure] {
        await store.refresh()
        let mode = settings.ejectMode
        let store = self.store
        guard !store.ejectAllDevices.isEmpty else { return [] }
        if mode == .park { parkedForSleep = true }

        guard let deadline else { return await store.ejectAll(mode: mode) }
        // Not a task group: a group waits for all children, which would defeat the deadline.
        // The ejection keeps running in the background if the deadline wins.
        let result: [OperationFailure]? = await withCheckedContinuation { continuation in
            let once = ResumeOnce(continuation)
            Task { @MainActor in once.resume(await store.ejectAll(mode: mode)) }
            Task { [clock] in
                try? await clock.sleep(for: deadline)
                once.resume(nil)
            }
        }
        if result == nil { log.error("ejection hit the \(deadline) deadline") }
        return result ?? []
    }
}

/// Resumes a continuation with the first value only.
private final class ResumeOnce<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Never>?

    init(_ continuation: CheckedContinuation<T, Never>) { self.continuation = continuation }

    func resume(_ value: T) {
        lock.withLock {
            continuation?.resume(returning: value)
            continuation = nil
        }
    }
}
