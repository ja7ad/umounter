import DiskArbitration
import Foundation
import Testing
@testable import DiskKit

@Suite struct DiskInfoParsingTests {
    private func description(_ pairs: [(CFString, Any)]) -> [String: Any] {
        Dictionary(uniqueKeysWithValues: pairs.map { ($0.0 as String, $0.1) })
    }

    @Test func externalAPFSVolume() {
        let info = DiskInfo(
            description: description([
                (kDADiskDescriptionMediaBSDNameKey, "disk5s1"),
                (kDADiskDescriptionMediaWholeKey, false),
                (kDADiskDescriptionVolumeNameKey, "Photos SSD"),
                (kDADiskDescriptionVolumePathKey, URL(filePath: "/Volumes/Photos SSD")),
                (kDADiskDescriptionVolumeKindKey, "apfs"),
                (kDADiskDescriptionDeviceInternalKey, false),
                (kDADiskDescriptionDeviceProtocolKey, "USB"),
                (kDADiskDescriptionMediaSizeKey, NSNumber(value: 1_000_000_000)),
                (kDADiskDescriptionVolumeUUIDKey, CFUUIDCreateFromString(nil, "11111111-2222-3333-4444-555555555555" as CFString)!),
            ]),
            physicalRootBSDName: "disk4"
        )
        #expect(info.kind == .volume)
        #expect(info.id == "disk5s1")
        #expect(info.physicalRootBSDName == "disk4")
        #expect(info.volumeUUID == "11111111-2222-3333-4444-555555555555")
        #expect(info.mediaSize == 1_000_000_000)
        #expect(info.isMounted)
        #expect(info.isUserEjectableVolume)
    }

    @Test func wholeDiskKinds() {
        let physical = DiskInfo(description: description([
            (kDADiskDescriptionMediaBSDNameKey, "disk4"), (kDADiskDescriptionMediaWholeKey, true),
        ]))
        let container = DiskInfo(description: description([
            (kDADiskDescriptionMediaBSDNameKey, "disk5"), (kDADiskDescriptionMediaWholeKey, true),
        ]), physicalRootBSDName: "disk4", isContainerWhole: true)
        let image = DiskInfo(description: description([
            (kDADiskDescriptionMediaBSDNameKey, "disk6"), (kDADiskDescriptionMediaWholeKey, true),
            (kDADiskDescriptionDeviceModelKey, "Disk Image"),
        ]))
        #expect(physical.kind == .physicalWhole)
        #expect(physical.physicalRootBSDName == "disk4")
        #expect(container.kind == .containerWhole)
        #expect(image.kind == .diskImage)
    }

    /// An APFS container synthesized on a disk image reports the image's protocol.
    @Test func containerOnDiskImageIsContainer() {
        let info = DiskInfo(description: description([
            (kDADiskDescriptionMediaBSDNameKey, "disk7"), (kDADiskDescriptionMediaWholeKey, true),
            (kDADiskDescriptionDeviceProtocolKey, "Virtual Interface"),
        ]), physicalRootBSDName: "disk6", isContainerWhole: true)
        #expect(info.kind == .containerWhole)
    }

    @Test func networkVolume() {
        let info = DiskInfo(description: description([
            (kDADiskDescriptionVolumeNetworkKey, true),
            (kDADiskDescriptionVolumePathKey, URL(filePath: "/Volumes/share")),
        ]))
        #expect(info.kind == .network)
        #expect(info.id == "/Volumes/share")
        #expect(info.physicalRootBSDName == nil)
        #expect(info.isUserEjectableVolume)
    }

    @Test func internalVolumeIsNotEjectedByEjectAll() {
        let info = DiskInfo(description: description([
            (kDADiskDescriptionMediaBSDNameKey, "disk3s5"),
            (kDADiskDescriptionDeviceInternalKey, true),
            (kDADiskDescriptionVolumePathKey, URL(filePath: "/System/Volumes/Data")),
        ]))
        #expect(!info.isUserEjectableVolume)
    }
}

@Suite struct DiskErrorMappingTests {
    @Test(arguments: [
        (UInt32(0xF8DA_0002), DiskError.Code.busy),
        (UInt32(0xF8DA_0009), .notPrivileged),
        (UInt32(0xF8DA_0008), .notPermitted),
        (UInt32(0xF8DA_000C), .unsupported),
        (UInt32(0x0000_C000) | UInt32(EBUSY), .busy),
        (UInt32(0x0000_C000) | UInt32(EPERM), .unix(errno: EPERM)),
        (UInt32(0x1234_5678), .other(status: 0x1234_5678)),
    ])
    func mapsStatus(raw: UInt32, expected: DiskError.Code) {
        #expect(DiskError.code(forStatus: Int32(bitPattern: raw)) == expected)
    }

    @Test func descriptionIncludesMessage() {
        let error = DiskError(code: .busy, message: "Finder", operation: "unmount disk4")
        #expect(error.description == "unmount disk4 failed: the disk is in use (Finder)")
    }
}

@Suite struct BlockerScannerTests {
    /// Opening a file on the boot volume must make this process show up as a blocker.
    @Test func findsOwnOpenFile() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "diskkit-\(UUID().uuidString)")
        try Data("x".utf8).write(to: file)
        let handle = try FileHandle(forReadingFrom: file)
        defer {
            try? handle.close()
            try? FileManager.default.removeItem(at: file)
        }

        let scanner = BlockerScanner()
        let pids = try scanner.pidsUsing(volume: file.path)
        #expect(pids.contains(getpid()))

        let files = BlockerScanner.openFiles(of: getpid(), under: "/")
        #expect(files.contains { $0.hasSuffix(file.lastPathComponent) })

        let blockers = try scanner.blockers(onVolume: file, excludingSelf: true)
        #expect(!blockers.contains { $0.pid == getpid() })
    }
}

@Suite struct SessionSmokeTests {
    @Test func listsBootDisk() throws {
        let session = try DiskArbitrationSession()
        defer { session.invalidate() }
        let disks = session.disks()
        #expect(!disks.isEmpty)
        #expect(disks.contains { $0.volumePath?.path == "/" })
        // Every device-backed disk resolves to some physical root.
        #expect(disks.filter { $0.kind != .network }.allSatisfy { $0.physicalRootBSDName != nil })
    }
}

@Suite struct IOActivityTests {
    /// The boot disk has done I/O since boot, so its counters are non-zero.
    @Test func readsBootDiskCounters() throws {
        let session = try DiskArbitrationSession()
        defer { session.invalidate() }
        let root = try #require(session.disks().first { $0.volumePath?.path == "/" }?.physicalRootBSDName)
        let counters = try #require(IOActivity.counters(forBSDName: root))
        #expect(counters.bytesRead > 0 && counters.readOperations > 0)
        #expect(IOActivity.counters(forBSDName: "disk999") == nil)
    }
}
