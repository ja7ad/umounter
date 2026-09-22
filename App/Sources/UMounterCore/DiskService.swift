import DiskKit
import Foundation

/// The DiskKit surface the app depends on, so `DiskStore` can be tested with a fake.
public protocol DiskService: Sendable {
    var events: AsyncStream<DiskEvent> { get }
    func disks() -> [DiskInfo]
    func ejectSafely(_ target: DiskTarget, mode: EjectMode) async throws
    func mount(_ target: DiskTarget, whole: Bool, readOnly: Bool) async throws
    func mountVolumes(onDevice bsdName: String, readOnly: Bool) async throws
    /// Processes holding files on the volume; `includeFiles` also lists which files (slower).
    func blockers(onVolume volume: URL, includeFiles: Bool) -> [Blocker]
    /// Cumulative I/O counters of a whole disk (physical root).
    func ioCounters(bsdName: String) -> IOCounters?
}

extension DiskArbitrationSession: DiskService {
    public func blockers(onVolume volume: URL, includeFiles: Bool) -> [Blocker] {
        (try? BlockerScanner().blockers(onVolume: volume, includeFiles: includeFiles)) ?? []
    }

    public func ioCounters(bsdName: String) -> IOCounters? {
        IOActivity.counters(forBSDName: bsdName)
    }
}
