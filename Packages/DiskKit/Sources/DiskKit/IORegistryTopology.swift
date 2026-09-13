import Foundation
import IOKit

/// Where a disk sits in the IORegistry storage stack.
struct MediaTopology: Sendable, Equatable {
    /// BSD name of the outermost whole `IOMedia` (the physical device or disk image).
    var physicalRootBSDName: String?
    /// `true` when this media has another `IOMedia` above it in the service plane,
    /// i.e. it is synthesized by a container scheme such as APFS.
    var hasMediaAncestor: Bool
    /// Backing file of the disk image this media lives on, e.g.
    /// `file:///Users/me/Downloads/App.dmg` (see `imageBackingURL(of:)`).
    var diskImageURL: URL? = nil
}

enum IORegistryTopology {
    /// Walks the service plane from `media` towards the root and records the
    /// outermost whole `IOMedia`. Does not consume the caller's reference.
    static func topology(of media: io_service_t) -> MediaTopology {
        var root = bsdName(of: media)
        var hasMediaAncestor = false
        var diskImageURL: URL?

        var current = media
        IOObjectRetain(current)
        while true {
            var parent: io_registry_entry_t = 0
            let kr = IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent)
            IOObjectRelease(current)
            guard kr == KERN_SUCCESS else { break }
            if diskImageURL == nil { diskImageURL = imageBackingURL(of: parent) }
            if IOObjectConformsTo(parent, "IOMedia") != 0 {
                hasMediaAncestor = true
                if boolProperty(parent, "Whole"), let name = bsdName(of: parent) {
                    root = name
                }
            }
            current = parent
        }
        return MediaTopology(physicalRootBSDName: root, hasMediaAncestor: hasMediaAncestor, diskImageURL: diskImageURL)
    }

    /// Disk images reach the registry through two drivers (verified on macOS 27):
    /// - Finder / DiskImageMounter (DiskImages2): `AppleDiskImageDevice`, `"DiskImageURL"` (URL string).
    /// - `hdiutil attach`: `IOHDIXHDDriveOutKernel`, `"image-path"` (NUL-terminated bytes).
    /// Both block devices also carry `"Protocol Characteristics"` →
    /// `"Virtual Interface Location Path"` on the hdiutil path, used as a fallback.
    static func imageBackingURL(of entry: io_registry_entry_t) -> URL? {
        if let url = stringProperty(entry, "DiskImageURL").flatMap(URL.init(string:)) { return url }
        if let path = pathProperty(property(entry, "image-path")) { return URL(filePath: path) }
        if let characteristics = property(entry, "Protocol Characteristics") as? [String: Any],
           let path = pathProperty(characteristics["Virtual Interface Location Path"] as AnyObject?) {
            return URL(filePath: path)
        }
        return nil
    }

    private static func pathProperty(_ value: AnyObject?) -> String? {
        if let string = value as? String, !string.isEmpty { return string }
        guard let data = value as? Data else { return nil }
        let path = String(decoding: data.prefix { $0 != 0 }, as: UTF8.self)
        return path.isEmpty ? nil : path
    }

    private static func property(_ entry: io_registry_entry_t, _ key: String) -> AnyObject? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    private static func bsdName(of entry: io_registry_entry_t) -> String? {
        stringProperty(entry, "BSD Name")
    }

    private static func stringProperty(_ entry: io_registry_entry_t, _ key: String) -> String? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? String
    }

    private static func boolProperty(_ entry: io_registry_entry_t, _ key: String) -> Bool {
        (IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? Bool) ?? false
    }

    /// Visits every `IOMedia` object currently registered.
    static func forEachMedia(_ body: (io_service_t) -> Void) {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOMedia"), &iterator) == KERN_SUCCESS
        else { return }
        defer { IOObjectRelease(iterator) }
        while case let service = IOIteratorNext(iterator), service != 0 {
            body(service)
            IOObjectRelease(service)
        }
    }
}
