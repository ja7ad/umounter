import DiskKit
import Foundation

/// The kinds of disks the user can include in or exclude from "Eject All"
/// (Jettison's "What to Eject").
public enum DiskCategory: String, CaseIterable, Codable, Sendable {
    case hardDisk, optical, diskImage, network, sdCard

    public var title: String {
        switch self {
        case .hardDisk: "Hard disks and SSDs"
        case .optical: "DVDs and CDs"
        case .diskImage: "Disk images"
        case .network: "Network drives"
        case .sdCard: "SD cards"
        }
    }
}

/// Something the user unplugs: a physical disk or disk image with its mounted
/// volumes, or one network volume.
public struct Device: Identifiable, Hashable, Sendable {
    /// Physical root BSD name (`disk4`), or the mount path for network volumes.
    public var id: String
    public var name: String
    /// Mounted, user-visible volumes on this device.
    public var volumes: [DiskInfo]
    public var isNetwork: Bool
    public var category: DiskCategory
    public var deviceProtocol: String?
    public var model: String?
    /// Backing file when the device is a disk image.
    public var diskImageURL: URL?
    /// When the disk image was attached.
    public var attachedAt: Date?

    public init(
        id: String, name: String, volumes: [DiskInfo], isNetwork: Bool, category: DiskCategory = .hardDisk,
        deviceProtocol: String? = nil, model: String? = nil, diskImageURL: URL? = nil, attachedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.volumes = volumes
        self.isNetwork = isNetwork
        self.category = category
        self.deviceProtocol = deviceProtocol
        self.model = model
        self.diskImageURL = diskImageURL
        self.attachedAt = attachedAt
    }

    public var target: DiskTarget {
        isNetwork ? .volume(volumes.first?.volumePath ?? .init(filePath: id)) : .bsdName(id)
    }

    /// Human-readable kind for messages: "USB drive", "SD card", "disk image"…
    public var kindDescription: String {
        switch category {
        case .network: "network drive"
        case .diskImage: "disk image"
        case .optical: "disc"
        case .sdCard: "SD card"
        case .hardDisk: Self.hardDiskDescription(protocol: deviceProtocol)
        }
    }

    /// The same, for a single disk/volume (uses its own protocol and flags).
    public static func kindDescription(for disk: DiskInfo) -> String {
        if disk.isNetwork { return "network drive" }
        if disk.diskImageURL != nil || disk.kind == .diskImage { return "disk image" }
        if disk.isOptical { return "disc" }
        if disk.deviceProtocol == "Secure Digital" { return "SD card" }
        return hardDiskDescription(protocol: disk.deviceProtocol)
    }

    private static func hardDiskDescription(protocol: String?) -> String {
        switch `protocol` {
        case "USB": "USB drive"
        case "Thunderbolt", "PCI-Express": "external drive"
        default: "hard drive"
        }
    }

    /// Rule IDs of the device's volumes (see `DiskInfo.ruleID`).
    public var ruleIDs: Set<String> { Set(volumes.compactMap(\.ruleID)) }
}

/// A disk the user named in a rule list ("Don't eject these disks").
public struct DiskRule: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }

    public init?(_ volume: DiskInfo) {
        guard let id = volume.ruleID else { return nil }
        self.init(id: id, name: volume.volumeName ?? volume.id)
    }
}

/// Which devices "Eject All" (and automatic ejection) acts on.
public struct EjectFilter: Equatable, Sendable {
    public var categories: Set<DiskCategory>
    /// Volumes to eject even when they would not be by default (e.g. internal disks).
    public var alsoEject: Set<String>
    /// Volumes never ejected by "Eject All"; a device is skipped if any volume matches.
    public var neverEject: Set<String>

    public static let all = EjectFilter(categories: Set(DiskCategory.allCases), alsoEject: [], neverEject: [])

    public init(categories: Set<DiskCategory>, alsoEject: Set<String>, neverEject: Set<String>) {
        self.categories = categories
        self.alsoEject = alsoEject
        self.neverEject = neverEject
    }

    public func includes(_ device: Device) -> Bool {
        let ids = device.ruleIDs
        if !ids.isDisjoint(with: neverEject) { return false }
        if !ids.isDisjoint(with: alsoEject) { return true }
        return categories.contains(device.category)
    }
}

public enum DiskCatalog {
    /// Groups the mounted user volumes by the device they live on. Volumes listed in
    /// `alsoEject` are included even if they are internal.
    public static func devices(from disks: [DiskInfo], alsoEject: Set<String> = []) -> [Device] {
        let byBSDName = Dictionary(disks.compactMap { d in d.bsdName.map { ($0, d) } }, uniquingKeysWith: { a, _ in a })
        let candidates = disks.filter { volume in
            if volume.isUserEjectableVolume { return true }
            guard let id = volume.ruleID, alsoEject.contains(id), let path = volume.volumePath?.path else { return false }
            return path.hasPrefix("/Volumes/")
        }
        let groups = Dictionary(grouping: candidates) { volume in
            volume.isNetwork ? volume.id : (volume.physicalRootBSDName ?? volume.id)
        }
        return groups.map { id, volumes in
            let sorted = volumes.sorted { ($0.volumeName ?? "").localizedStandardCompare($1.volumeName ?? "") == .orderedAscending }
            let root = byBSDName[id]
            return Device(
                id: id,
                name: sorted.map { $0.volumeName ?? $0.id }.joined(separator: ", "),
                volumes: sorted,
                isNetwork: sorted.contains(where: \.isNetwork),
                category: category(root: root, volume: sorted[0]),
                deviceProtocol: root?.deviceProtocol ?? sorted.first?.deviceProtocol,
                model: root?.deviceModel ?? root?.mediaName,
                diskImageURL: root?.diskImageURL ?? sorted.first?.diskImageURL,
                attachedAt: root?.attachedAt ?? sorted.first?.attachedAt
            )
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func category(root: DiskInfo?, volume: DiskInfo) -> DiskCategory {
        if volume.isNetwork { return .network }
        if volume.diskImageURL != nil || root?.kind == .diskImage { return .diskImage }
        if root?.isOptical == true || volume.isOptical { return .optical }
        let proto = root?.deviceProtocol ?? volume.deviceProtocol ?? ""
        let model = root?.deviceModel ?? volume.deviceModel ?? ""
        if proto == "Secure Digital" || ["SD Card", "SDXC", "SDHC", "Card Reader"].contains(where: { model.localizedCaseInsensitiveContains($0) }) {
            return .sdCard
        }
        return .hardDisk
    }

    /// Disk images whose backing file lives on one of `device`'s mounted volumes
    /// (direct children only). They must be ejected before `device` can be: the
    /// disk-image service keeps their files open.
    public static func nestedImages(of device: Device, in devices: [Device]) -> [Device] {
        let mountPoints = device.volumes.compactMap { $0.volumePath?.path }.map { $0.hasSuffix("/") ? $0 : $0 + "/" }
        guard !mountPoints.isEmpty else { return [] }
        return devices.filter { other in
            guard other.id != device.id, let path = other.diskImageURL?.path else { return false }
            return mountPoints.contains { path.hasPrefix($0) }
        }
    }

    /// External volumes that have a file system but are not mounted.
    public static func mountableVolumes(from disks: [DiskInfo]) -> [DiskInfo] {
        disks
            .filter { $0.kind == .volume && $0.volumeKind != nil && !$0.isMounted && !$0.isInternal && $0.physicalRootBSDName != nil }
            .sorted { ($0.volumeName ?? $0.id).localizedStandardCompare($1.volumeName ?? $1.id) == .orderedAscending }
    }
}
