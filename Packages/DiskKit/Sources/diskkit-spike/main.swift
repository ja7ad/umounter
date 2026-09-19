// M0 spike CLI for exercising DiskKit by hand.
//
//   diskkit-spike list [--all]
//   diskkit-spike watch
//   diskkit-spike blockers <volume-path> [--files]
//   diskkit-spike unmount <diskN|path> [--whole] [--force]
//   diskkit-spike eject <diskN|path> [--park]
//   diskkit-spike mount <diskN|path> [--whole] [--readonly]
//   diskkit-spike io <diskN>

import DiskKit
import Foundation

setvbuf(stdout, nil, _IOLBF, 0)

var arguments = Array(CommandLine.arguments.dropFirst())
let command = arguments.isEmpty ? "list" : arguments.removeFirst()
let flags = Set(arguments.filter { $0.hasPrefix("--") })
let operands = arguments.filter { !$0.hasPrefix("--") }

func target(_ string: String) -> DiskTarget {
    string.hasPrefix("/") && !string.hasPrefix("/dev/") ? .volume(URL(filePath: string)) : .bsdName(string)
}

func formatSize(_ bytes: Int64?) -> String {
    guard let bytes else { return "-" }
    return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}

func describe(_ disk: DiskInfo) -> String {
    let flags = [
        disk.isInternal ? "internal" : "external",
        disk.isEjectable ? "ejectable" : nil,
        disk.isRemovable ? "removable" : nil,
        disk.isWritable ? nil : "read-only",
        disk.isEncrypted ? "encrypted" : nil,
        disk.isRepairRunning ? "REPAIRING" : nil,
    ].compactMap { $0 }.joined(separator: ",")
    let name = disk.volumeName ?? disk.mediaName ?? "-"
    let mount = disk.volumePath?.path ?? "-"
    return "\(disk.id.padding(toLength: 12, withPad: " ", startingAt: 0)) "
        + "\(disk.kind.rawValue.padding(toLength: 14, withPad: " ", startingAt: 0)) "
        + "root=\((disk.physicalRootBSDName ?? "-").padding(toLength: 8, withPad: " ", startingAt: 0)) "
        + "\(formatSize(disk.mediaSize).padding(toLength: 10, withPad: " ", startingAt: 0)) "
        + "\((disk.deviceProtocol ?? "-").padding(toLength: 16, withPad: " ", startingAt: 0)) "
        + "\(name) @ \(mount) [\(flags)]"
        + (disk.diskImageURL.map { " ← \($0.path(percentEncoded: false))" } ?? "")
        + (disk.attachedAt.map { " (attached \($0.formatted(date: .omitted, time: .standard)))" } ?? "")
}

func printBlockers(of volume: URL, files: Bool) {
    do {
        let blockers = try BlockerScanner().blockers(onVolume: volume, includeFiles: files)
        if blockers.isEmpty { print("  no visible blockers on \(volume.path)") }
        for blocker in blockers {
            let owner = blocker.isOwnedByCurrentUser ? "" : " (uid \(blocker.uid.map(String.init) ?? "?"))"
            print("  \(blocker.pid)\t\(blocker.name)\(owner)\t\(blocker.executablePath ?? "")")
            for file in blocker.openFiles { print("      \(file)") }
        }
    } catch {
        print("  blocker scan failed: \(error)")
    }
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

let session: DiskArbitrationSession
do { session = try DiskArbitrationSession() } catch { fail("\(error)") }

let clock = ContinuousClock()
func timed(_ label: String, _ body: () async throws -> Void) async {
    let start = clock.now
    do {
        try await body()
        print("\(label): ok (\(start.duration(to: clock.now).formatted(.units(allowed: [.milliseconds]))))")
    } catch let error as DiskError {
        print("\(label): \(error)")
        if error.code == .busy, case .volume(let url)? = operands.first.map(target) {
            printBlockers(of: url, files: true)
        } else if error.code == .busy, let disk = operands.first.map(target).flatMap(session.disk) {
            let root = disk.physicalRootBSDName
            for volume in session.disks() where volume.physicalRootBSDName == root {
                if let path = volume.volumePath { printBlockers(of: path, files: true) }
            }
        }
        exit(2)
    } catch {
        fail("\(label): \(error)")
    }
}

switch command {
case "list":
    let disks = session.disks()
    let shown = flags.contains("--all") ? disks : disks.filter { !$0.isInternal || $0.isNetwork || $0.kind == .diskImage }
    for disk in shown { print(describe(disk)) }
    let ejectable = disks.filter(\.isUserEjectableVolume)
    print("\n\(ejectable.count) volume(s) Eject All would act on: \(ejectable.compactMap { $0.volumeName }.joined(separator: ", "))")

case "watch":
    print("Watching disk events (Ctrl-C to stop)…")
    for await event in session.events {
        switch event {
        case .appeared(let disk): print("+ \(describe(disk))")
        case .disappeared(let disk): print("- \(disk.id) \(disk.volumeName ?? disk.mediaName ?? "")")
        case .changed(let disk, let keys): print("~ \(describe(disk)) changed: \(keys.joined(separator: ","))")
        }
    }

case "blockers":
    guard let path = operands.first else { fail("usage: blockers <volume-path> [--files]") }
    printBlockers(of: URL(filePath: path), files: flags.contains("--files"))

case "unmount":
    guard let operand = operands.first else { fail("usage: unmount <diskN|path> [--whole] [--force]") }
    await timed("unmount \(operand)") {
        try await session.unmount(target(operand), whole: flags.contains("--whole"), force: flags.contains("--force"))
    }

case "eject":
    guard let operand = operands.first else { fail("usage: eject <diskN|path> [--park]") }
    await timed("\(flags.contains("--park") ? "park" : "eject") \(operand)") {
        try await session.ejectSafely(target(operand), mode: flags.contains("--park") ? .park : .eject)
    }

case "mount":
    guard let operand = operands.first else { fail("usage: mount <diskN|path> [--whole] [--readonly]") }
    await timed("mount \(operand)") {
        try await session.mount(target(operand), whole: flags.contains("--whole"), readOnly: flags.contains("--readonly"))
    }

case "io":
    guard let operand = operands.first else { fail("usage: io <diskN>") }
    guard let c = IOActivity.counters(forBSDName: operand) else { fail("no statistics for \(operand)") }
    print("\(operand): read \(c.bytesRead) B in \(c.readOperations) ops, wrote \(c.bytesWritten) B in \(c.writeOperations) ops")

default:
    fail("unknown command \(command). Commands: list, watch, blockers, unmount, eject, mount")
}
