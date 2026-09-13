import Darwin
import Dispatch
import Foundation

/// Forces cached writes for a volume all the way to the medium before unmount.
public struct VolumeFlusher: Sendable {
    public init() {}

    /// Runs `sync_volume_np(path, SYNC_VOLUME_FULLSYNC | SYNC_VOLUME_WAIT)` off the
    /// caller's thread. FULLSYNC asks the device to flush its own write cache too,
    /// not just the kernel buffer cache.
    public func flush(_ volume: URL) async throws {
        let path = volume.path
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .utility).async {
                let result = sync_volume_np(path, SYNC_VOLUME_FULLSYNC | SYNC_VOLUME_WAIT)
                if result == 0 {
                    continuation.resume()
                } else {
                    let code = result == -1 ? errno : result
                    continuation.resume(throwing: DiskError(code: .unix(errno: code), operation: "flush \(path)"))
                }
            }
        }
    }
}
