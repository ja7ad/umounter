import DiskArbitration
import Foundation
import os

/// Identifies a disk for an operation.
public enum DiskTarget: Sendable, Hashable, CustomStringConvertible {
    case bsdName(String)
    case volume(URL)

    public init(_ info: DiskInfo) {
        if let bsd = info.bsdName { self = .bsdName(bsd) } else { self = .volume(info.volumePath ?? URL(filePath: "/")) }
    }

    public var description: String {
        switch self {
        case .bsdName(let name): name
        case .volume(let url): url.path
        }
    }
}

/// A change reported by DiskArbitration.
public enum DiskEvent: Sendable {
    case appeared(DiskInfo)
    case disappeared(DiskInfo)
    case changed(DiskInfo, keys: [String])
}

/// What to do with the physical device after its volumes are unmounted.
public enum EjectMode: Sendable {
    /// Unmount and send an eject to the device (it leaves the bus; HDDs spin down).
    case eject
    /// Unmount only, so the volumes can be remounted without replugging.
    case park
}

/// Thin, event-driven wrapper over one `DASession`.
///
/// All DiskArbitration callbacks are delivered on a private serial queue; nothing
/// polls. Create one per process and keep it alive for the app's lifetime.
public final class DiskArbitrationSession: @unchecked Sendable {
    // `@unchecked`: `session` is only mutated in `init`/`invalidate`; DiskArbitration
    // itself is thread-safe and delivers every callback on `queue`.

    /// Live disk events. Single consumer; buffers the newest 256 events.
    public let events: AsyncStream<DiskEvent>

    private let queue = DispatchQueue(label: "umounter.diskkit.da", qos: .utility)
    private let session: DASession
    private let continuation: AsyncStream<DiskEvent>.Continuation
    private let flusher = VolumeFlusher()
    private let log = Logger(subsystem: "app.umounter.diskkit", category: "session")

    public init() throws {
        guard let session = DASessionCreate(kCFAllocatorDefault) else {
            throw DiskError(code: .noResources, operation: "create session")
        }
        self.session = session
        (events, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(256))

        let ctx = Unmanaged.passUnretained(self).toOpaque()
        let watchKeys = [kDADiskDescriptionVolumePathKey, kDADiskDescriptionVolumeNameKey] as CFArray
        DARegisterDiskAppearedCallback(session, nil, appearedCallback, ctx)
        DARegisterDiskDisappearedCallback(session, nil, disappearedCallback, ctx)
        DARegisterDiskDescriptionChangedCallback(session, nil, watchKeys, changedCallback, ctx)
        DASessionSetDispatchQueue(session, queue)
    }

    deinit { invalidate() }

    /// Stops callbacks and finishes `events`. Safe to call more than once.
    public func invalidate() {
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        DAUnregisterCallback(session, unsafeBitCast(appearedCallback, to: UnsafeMutableRawPointer.self), ctx)
        DAUnregisterCallback(session, unsafeBitCast(disappearedCallback, to: UnsafeMutableRawPointer.self), ctx)
        DAUnregisterCallback(session, unsafeBitCast(changedCallback, to: UnsafeMutableRawPointer.self), ctx)
        DASessionSetDispatchQueue(session, nil)
        continuation.finish()
    }

    // MARK: - Listing

    /// A deterministic snapshot of every disk the system knows about right now:
    /// all `IOMedia` objects plus non-local (network) mounts.
    public func disks() -> [DiskInfo] {
        var result: [DiskInfo] = []
        IORegistryTopology.forEachMedia { media in
            guard let disk = DADiskCreateFromIOMedia(kCFAllocatorDefault, session, media),
                  let info = makeInfo(disk) else { return }
            result.append(info)
        }
        for url in Self.networkMountPoints() {
            if let disk = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, url as CFURL),
               let info = makeInfo(disk) {
                result.append(info)
            }
        }
        return result.sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
    }

    public func disk(_ target: DiskTarget) -> DiskInfo? {
        daDisk(for: target).flatMap(makeInfo)
    }

    // MARK: - Operations

    /// Unmounts one volume, or every volume on a whole disk when `whole` is set.
    public func unmount(_ target: DiskTarget, whole: Bool = false, force: Bool = false) async throws {
        let disk = try requireDisk(target)
        var options = DADiskUnmountOptions(kDADiskUnmountOptionDefault)
        if whole { options |= DADiskUnmountOptions(kDADiskUnmountOptionWhole) }
        if force { options |= DADiskUnmountOptions(kDADiskUnmountOptionForce) }
        try await perform("unmount \(target)") { callback, ctx in
            DADiskUnmount(disk, options, callback, ctx)
        }
    }

    /// Ejects a whole disk. Its volumes must already be unmounted.
    public func eject(_ target: DiskTarget) async throws {
        let disk = try requireDisk(target)
        try await perform("eject \(target)") { callback, ctx in
            DADiskEject(disk, DADiskEjectOptions(kDADiskEjectOptionDefault), callback, ctx)
        }
    }

    /// Mounts a volume, or every mountable volume of a whole disk when `whole` is set.
    public func mount(_ target: DiskTarget, whole: Bool = false, readOnly: Bool = false) async throws {
        let disk = try requireDisk(target)
        // DiskArbitration rejects mount arguments combined with kDADiskMountOptionWhole
        // (kDAReturnBadArgument), so mount each unmounted volume of the disk instead.
        if whole && readOnly {
            guard let bsd = self.disk(target)?.bsdName else { throw DiskError(code: .notFound, operation: "mount \(target)") }
            try await mountVolumes(onDevice: bsd, readOnly: true)
            return
        }
        let options = DADiskMountOptions(whole ? kDADiskMountOptionWhole : kDADiskMountOptionDefault)
        try await perform("mount \(target)") { callback, ctx in
            if readOnly {
                var args: [Unmanaged<CFString>?] = [Unmanaged.passUnretained("rdonly" as CFString), nil]
                args.withUnsafeMutableBufferPointer { buffer in
                    DADiskMountWithArguments(disk, nil, options, callback, ctx, buffer.baseAddress)
                }
            } else {
                DADiskMount(disk, nil, options, callback, ctx)
            }
        }
    }

    /// Mounts every unmounted volume that lives on a whole disk: its own slices and,
    /// for a physical disk, the volumes of APFS containers stored on it. Tries all
    /// volumes and throws the first failure.
    public func mountVolumes(onDevice bsdName: String, readOnly: Bool = false) async throws {
        let volumes = disks().filter { volume in
            volume.kind == .volume && volume.volumeKind != nil && !volume.isMounted
                && (volume.physicalRootBSDName == bsdName || volume.bsdName?.hasPrefix(bsdName + "s") == true)
        }
        var firstError: Error?
        for volume in volumes {
            do { try await mount(DiskTarget(volume), readOnly: readOnly) } catch {
                firstError = firstError ?? error
            }
        }
        if let firstError { throw firstError }
    }

    /// The safe path: flush every mounted volume on the device, unmount
    /// synthesized containers before the physical disk, then eject or park.
    ///
    /// For a network volume this flushes and unmounts just that volume.
    public func ejectSafely(_ target: DiskTarget, mode: EjectMode = .eject) async throws {
        guard let info = disk(target) else {
            throw DiskError(code: .notFound, operation: "eject \(target)")
        }
        if info.kind == .network {
            if let path = info.volumePath { try await flusher.flush(path) }
            try await unmount(target)
            return
        }
        guard let root = info.physicalRootBSDName else {
            throw DiskError(code: .notFound, operation: "eject \(target)")
        }

        let family = disks().filter { $0.physicalRootBSDName == root }
        for path in family.compactMap(\.volumePath) {
            do { try await flusher.flush(path) } catch {
                log.error("flush \(path.path, privacy: .public) failed: \(error, privacy: .public)")
            }
        }

        // Containers (e.g. APFS disk5 on disk4s2) before the physical disk.
        for container in family where container.kind == .containerWhole {
            if let bsd = container.bsdName { try await unmount(.bsdName(bsd), whole: true) }
        }
        try await unmount(.bsdName(root), whole: true)

        // Never report success on DiskArbitration's word alone: re-read the mount table.
        let stillMounted = disks().filter { $0.physicalRootBSDName == root && $0.isMounted }
        if let volume = stillMounted.first {
            throw DiskError(code: .busy, message: "\(volume.volumePath?.path ?? volume.id) is still mounted",
                            operation: "unmount \(root)")
        }

        if mode == .eject {
            try await eject(.bsdName(root))
        }
    }

    // MARK: - Internals

    fileprivate func emit(_ event: DiskEvent) { continuation.yield(event) }

    fileprivate func makeInfo(_ disk: DADisk) -> DiskInfo? {
        guard let description = DADiskCopyDescription(disk) as? [String: Any] else { return nil }
        let media = DADiskCopyIOMedia(disk)
        guard media != 0 else { return DiskInfo(description: description) }
        defer { IOObjectRelease(media) }
        let topology = IORegistryTopology.topology(of: media)
        return DiskInfo(
            description: description,
            physicalRootBSDName: topology.physicalRootBSDName,
            isContainerWhole: topology.hasMediaAncestor,
            diskImageURL: topology.diskImageURL,
            attachedAt: topology.diskImageURL == nil ? nil : topology.physicalRootBSDName.flatMap(Self.attachTime)
        )
    }

    private func daDisk(for target: DiskTarget) -> DADisk? {
        switch target {
        case .bsdName(let name):
            let bare = name.hasPrefix("/dev/") ? String(name.dropFirst(5)) : name
            return DADiskCreateFromBSDName(kCFAllocatorDefault, session, bare)
        case .volume(let url):
            return DADiskCreateFromVolumePath(kCFAllocatorDefault, session, url as CFURL)
        }
    }

    private func requireDisk(_ target: DiskTarget) throws -> DADisk {
        guard let disk = daDisk(for: target) else { throw DiskError(code: .notFound, operation: "find \(target)") }
        return disk
    }

    /// Bridges one DiskArbitration completion callback to `async`.
    private func perform(
        _ operation: String,
        _ start: (DACompletionCallback, UnsafeMutableRawPointer) -> Void
    ) async throws {
        let signposter = OSSignposter(logger: log)
        let state = signposter.beginInterval("DiskOperation", "\(operation, privacy: .public)")
        defer { signposter.endInterval("DiskOperation", state) }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let box = CompletionBox(continuation: continuation, operation: operation)
            start(completionCallback, Unmanaged.passRetained(box).toOpaque())
        }
    }

    /// The device node's status-change time is set when the disk is attached
    /// (its birth time is always the epoch on devfs).
    static func attachTime(ofBSDName name: String) -> Date? {
        var info = stat()
        guard stat("/dev/\(name)", &info) == 0 else { return nil }
        let time = info.st_ctimespec
        return Date(timeIntervalSince1970: TimeInterval(time.tv_sec) + TimeInterval(time.tv_nsec) / 1_000_000_000)
    }

    private static func networkMountPoints() -> [URL] {
        // getmntinfo returns a buffer owned by libc; MNT_NOWAIT avoids blocking on dead servers.
        var mounts: UnsafeMutablePointer<statfs>?
        let count = getmntinfo(&mounts, MNT_NOWAIT)
        guard count > 0, let mounts else { return [] }
        return UnsafeBufferPointer(start: mounts, count: Int(count)).compactMap { fs in
            guard fs.f_flags & UInt32(MNT_LOCAL) == 0 else { return nil }
            // autofs trigger points (e.g. /System/Volumes/Data/home) are not user volumes.
            var type = fs.f_fstypename
            guard CStringTuple.string(&type) != "autofs" else { return nil }
            var name = fs.f_mntonname
            return URL(filePath: CStringTuple.string(&name), directoryHint: .isDirectory)
        }
    }
}

// MARK: - C callbacks (non-capturing, shared so they can be unregistered)

typealias DACompletionCallback = @convention(c) (DADisk, DADissenter?, UnsafeMutableRawPointer?) -> Void

private final class CompletionBox: @unchecked Sendable {
    let continuation: CheckedContinuation<Void, Error>
    let operation: String
    init(continuation: CheckedContinuation<Void, Error>, operation: String) {
        self.continuation = continuation
        self.operation = operation
    }
}

private let completionCallback: DACompletionCallback = { _, dissenter, ctx in
    let box = Unmanaged<CompletionBox>.fromOpaque(ctx!).takeRetainedValue()
    if let dissenter {
        box.continuation.resume(throwing: DiskError(dissenter: dissenter, operation: box.operation))
    } else {
        box.continuation.resume()
    }
}

private let appearedCallback: DADiskAppearedCallback = { disk, ctx in
    let session = Unmanaged<DiskArbitrationSession>.fromOpaque(ctx!).takeUnretainedValue()
    if let info = session.makeInfo(disk) { session.emit(.appeared(info)) }
}

private let disappearedCallback: DADiskDisappearedCallback = { disk, ctx in
    let session = Unmanaged<DiskArbitrationSession>.fromOpaque(ctx!).takeUnretainedValue()
    // The cached description is still available while the disk disappears.
    if let description = DADiskCopyDescription(disk) as? [String: Any] {
        session.emit(.disappeared(DiskInfo(description: description)))
    }
}

private let changedCallback: DADiskDescriptionChangedCallback = { disk, keys, ctx in
    let session = Unmanaged<DiskArbitrationSession>.fromOpaque(ctx!).takeUnretainedValue()
    if let info = session.makeInfo(disk) {
        session.emit(.changed(info, keys: (keys as? [String]) ?? []))
    }
}
