import Foundation
import IOKit

/// Cumulative I/O counters of a disk's block storage driver.
public struct IOCounters: Sendable, Equatable {
    public var bytesRead: UInt64
    public var bytesWritten: UInt64
    public var readOperations: UInt64
    public var writeOperations: UInt64

    public init(bytesRead: UInt64, bytesWritten: UInt64, readOperations: UInt64, writeOperations: UInt64) {
        self.bytesRead = bytesRead
        self.bytesWritten = bytesWritten
        self.readOperations = readOperations
        self.writeOperations = writeOperations
    }
}

/// Reads I/O statistics from the IORegistry (`IOBlockStorageDriver` → `"Statistics"`).
/// One registry lookup, no process spawning — cheap enough to sample every few
/// seconds, and only sampled while a feature actually needs it.
public enum IOActivity {
    /// Counters for the whole disk `bsdName` (use the physical root, e.g. `disk4`).
    public static func counters(forBSDName bsdName: String) -> IOCounters? {
        let name = bsdName.hasPrefix("/dev/") ? String(bsdName.dropFirst(5)) : bsdName
        // IOServiceGetMatchingService consumes the matching dictionary.
        let media = IOServiceGetMatchingService(kIOMainPortDefault, IOBSDNameMatching(kIOMainPortDefault, 0, name))
        guard media != 0 else { return nil }

        var current = media
        while true {
            if IOObjectConformsTo(current, "IOBlockStorageDriver") != 0 {
                defer { IOObjectRelease(current) }
                return statistics(of: current)
            }
            var parent: io_registry_entry_t = 0
            let kr = IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent)
            IOObjectRelease(current)
            guard kr == KERN_SUCCESS else { return nil }
            current = parent
        }
    }

    private static func statistics(of driver: io_registry_entry_t) -> IOCounters? {
        guard let stats = IORegistryEntryCreateCFProperty(driver, "Statistics" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? [String: Any] else { return nil }
        // Keys from IOKit/storage/IOBlockStorageDriver.h (C macros, not imported into Swift).
        func value(_ key: String) -> UInt64 { (stats[key] as? NSNumber)?.uint64Value ?? 0 }
        return IOCounters(
            bytesRead: value("Bytes (Read)"),
            bytesWritten: value("Bytes (Write)"),
            readOperations: value("Operations (Read)"),
            writeOperations: value("Operations (Write)")
        )
    }
}
