import Darwin
import Foundation

/// A process that holds a file reference on a volume and would make an unmount fail.
public struct Blocker: Sendable, Hashable, Identifiable {
    public var id: pid_t { pid }
    public var pid: pid_t
    public var name: String
    public var executablePath: String?
    public var uid: uid_t?
    /// Parent process, e.g. Terminal's login process for a shell sitting in the volume.
    public var parentPID: pid_t?
    /// Open files (and working directory) on the volume. Filled only when requested,
    /// and only for processes we may inspect (own user, or root).
    public var openFiles: [String]

    public var isOwnedByCurrentUser: Bool { uid == getuid() }

    public init(
        pid: pid_t, name: String, executablePath: String? = nil, uid: uid_t? = nil, parentPID: pid_t? = nil,
        openFiles: [String] = []
    ) {
        self.pid = pid
        self.name = name
        self.executablePath = executablePath
        self.uid = uid
        self.parentPID = parentPID
        self.openFiles = openFiles
    }
}

/// Finds processes using a volume via `proc_listpidspath` — no `lsof` spawning.
///
/// Without root, processes of other users are invisible; a privileged helper can
/// run the same scan to close that gap.
public struct BlockerScanner: Sendable {
    public init() {}

    /// - Parameters:
    ///   - volume: any path on the volume (normally its mount point).
    ///   - includeFiles: also list the open files on the volume per process (slower).
    ///   - excludingSelf: drop this process from the result.
    public func blockers(onVolume volume: URL, includeFiles: Bool = false, excludingSelf: Bool = true) throws -> [Blocker] {
        let pids = try pidsUsing(volume: volume.path)
        let me = getpid()
        return pids
            .filter { !excludingSelf || $0 != me }
            .map { pid in
                let info = Self.shortInfo(of: pid)
                return Blocker(
                    pid: pid,
                    name: Self.name(of: pid),
                    executablePath: Self.executablePath(of: pid),
                    uid: info?.pbsi_uid,
                    parentPID: info.map { pid_t($0.pbsi_ppid) },
                    openFiles: includeFiles ? Self.openFiles(of: pid, under: volume.path) : []
                )
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// PIDs with open files, mapped files or a working directory on the volume.
    /// `O_EVTONLY` references (Finder/FSEvents watchers) are excluded because they
    /// never block an unmount.
    func pidsUsing(volume path: String) throws -> [pid_t] {
        let flags = UInt32(PROC_LISTPIDSPATH_PATH_IS_VOLUME | PROC_LISTPIDSPATH_EXCLUDE_EVTONLY)
        let needed = proc_listpidspath(UInt32(PROC_ALL_PIDS), 0, path, flags, nil, 0)
        guard needed >= 0 else { throw DiskError(code: .unix(errno: errno), operation: "scan \(path)") }

        // The process table can grow between calls; leave headroom.
        var pids = [pid_t](repeating: 0, count: Int(needed) / MemoryLayout<pid_t>.stride + 64)
        let bytes = pids.withUnsafeMutableBytes { raw in
            proc_listpidspath(UInt32(PROC_ALL_PIDS), 0, path, flags, raw.baseAddress, Int32(raw.count))
        }
        guard bytes >= 0 else { throw DiskError(code: .unix(errno: errno), operation: "scan \(path)") }
        return Array(pids.prefix(Int(bytes) / MemoryLayout<pid_t>.stride)).filter { $0 > 0 }
    }

    static func name(of pid: pid_t) -> String {
        var buffer = [CChar](repeating: 0, count: 2 * Int(MAXCOMLEN) + 1)
        let length = proc_name(pid, &buffer, UInt32(buffer.count))
        return length > 0 ? CStringTuple.string(buffer) : "pid \(pid)"
    }

    static func executablePath(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        return length > 0 ? CStringTuple.string(buffer) : nil
    }

    static func shortInfo(of pid: pid_t) -> proc_bsdshortinfo? {
        var info = proc_bsdshortinfo()
        let size = Int32(MemoryLayout<proc_bsdshortinfo>.size)
        return proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &info, size) == size ? info : nil
    }

    /// Parent PID of any process we may inspect (public for walking up to the owning app).
    public static func parentPID(of pid: pid_t) -> pid_t? {
        shortInfo(of: pid).map { pid_t($0.pbsi_ppid) }
    }

    static func openFiles(of pid: pid_t, under volumePath: String) -> [String] {
        let prefix = volumePath.hasSuffix("/") ? volumePath : volumePath + "/"
        func isOnVolume(_ path: String) -> Bool { path == volumePath || path.hasPrefix(prefix) }

        var files: [String] = []

        var vnodeInfo = proc_vnodepathinfo()
        let vnodeSize = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        if proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &vnodeInfo, vnodeSize) == vnodeSize {
            let cwd = CStringTuple.string(&vnodeInfo.pvi_cdir.vip_path)
            if isOnVolume(cwd) { files.append(cwd + " (working directory)") }
        }

        let needed = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard needed > 0 else { return files }
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(needed) / MemoryLayout<proc_fdinfo>.stride)
        let filled = fds.withUnsafeMutableBytes { raw in
            proc_pidinfo(pid, PROC_PIDLISTFDS, 0, raw.baseAddress, Int32(raw.count))
        }
        guard filled > 0 else { return files }

        for fd in fds.prefix(Int(filled) / MemoryLayout<proc_fdinfo>.stride)
        where fd.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) {
            var info = vnode_fdinfowithpath()
            let size = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDVNODEPATHINFO, &info, size) == size else { continue }
            let path = CStringTuple.string(&info.pvip.vip_path)
            if isOnVolume(path) { files.append(path) }
        }
        return files
    }
}
