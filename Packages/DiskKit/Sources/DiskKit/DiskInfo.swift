import DiskArbitration
import Foundation

/// An immutable, `Sendable` snapshot of one DiskArbitration disk (a whole disk,
/// a partition/volume, or a network volume).
public struct DiskInfo: Sendable, Hashable, Identifiable {
    public enum Kind: String, Sendable, Codable {
        /// A whole physical device (USB/Thunderbolt/SATA/SD…).
        case physicalWhole
        /// A whole disk synthesized by a container scheme (e.g. an APFS container).
        case containerWhole
        /// A whole disk backed by a disk image.
        case diskImage
        /// A slice/volume on some whole disk.
        case volume
        /// A network file system (SMB, AFP, NFS…) without a BSD device.
        case network
    }

    /// BSD name for device-backed disks (`disk4s1`), mount path otherwise.
    public var id: String { bsdName ?? volumePath?.path ?? "?" }

    public var bsdName: String?
    public var kind: Kind

    // Volume
    public var volumeName: String?
    public var volumePath: URL?
    public var volumeKind: String?
    public var volumeUUID: String?
    public var isNetwork: Bool

    // Media
    public var mediaName: String?
    public var mediaContent: String?
    /// IOKit media class: `IOMedia`, `IOCDMedia`, `IODVDMedia`, `IOBDMedia`.
    public var mediaKind: String?
    public var mediaSize: Int64?
    public var mediaUUID: String?
    public var isWhole: Bool
    public var isLeaf: Bool
    public var isEjectable: Bool
    public var isRemovable: Bool
    public var isWritable: Bool
    public var isEncrypted: Bool

    // Device
    public var isInternal: Bool
    public var deviceProtocol: String?
    public var deviceModel: String?
    public var deviceVendor: String?
    public var busPath: String?

    /// `true` while fsck/repair runs on this disk (macOS 26+, always `false` earlier).
    public var isRepairRunning: Bool

    /// BSD name of the outermost whole disk this disk lives on (the device you
    /// physically unplug). For an APFS volume `disk5s1` on container `disk5`
    /// stored on `disk4s2`, this is `disk4`. `nil` for network volumes.
    public var physicalRootBSDName: String?

    /// Backing file for disks that live on a disk image (DMG, ISO, sparse bundle…).
    public var diskImageURL: URL?

    /// When the disk image was attached (the `ctime` of its `/dev/diskN` node), so
    /// images attached before the app launched are timed correctly. Images only.
    public var attachedAt: Date?

    public var isMounted: Bool { volumePath != nil }

    /// Optical media (CD, DVD, Blu-ray).
    public var isOptical: Bool {
        ["IOCDMedia", "IODVDMedia", "IOBDMedia"].contains(mediaKind ?? "")
    }

    /// Stable identity for user rules ("never eject this disk"): volume UUID, else
    /// media UUID, else the volume name.
    public var ruleID: String? { volumeUUID ?? mediaUUID ?? volumeName }

    /// Heuristic for "things Eject All acts on": external or network, mounted,
    /// and not one of the hidden system mounts.
    public var isUserEjectableVolume: Bool {
        guard let path = volumePath?.path, volumeKind != "autofs" else { return false }
        if isNetwork { return true }
        return !isInternal && path.hasPrefix("/Volumes/")
    }

    public init(
        bsdName: String?, kind: Kind, volumeName: String? = nil, volumePath: URL? = nil,
        volumeKind: String? = nil, volumeUUID: String? = nil, isNetwork: Bool = false,
        mediaName: String? = nil, mediaContent: String? = nil, mediaKind: String? = nil, mediaSize: Int64? = nil,
        mediaUUID: String? = nil, isWhole: Bool = false, isLeaf: Bool = false,
        isEjectable: Bool = false, isRemovable: Bool = false, isWritable: Bool = false,
        isEncrypted: Bool = false, isInternal: Bool = false, deviceProtocol: String? = nil,
        deviceModel: String? = nil, deviceVendor: String? = nil, busPath: String? = nil,
        isRepairRunning: Bool = false, physicalRootBSDName: String? = nil, diskImageURL: URL? = nil,
        attachedAt: Date? = nil
    ) {
        self.bsdName = bsdName
        self.kind = kind
        self.volumeName = volumeName
        self.volumePath = volumePath
        self.volumeKind = volumeKind
        self.volumeUUID = volumeUUID
        self.isNetwork = isNetwork
        self.mediaName = mediaName
        self.mediaContent = mediaContent
        self.mediaKind = mediaKind
        self.mediaSize = mediaSize
        self.mediaUUID = mediaUUID
        self.isWhole = isWhole
        self.isLeaf = isLeaf
        self.isEjectable = isEjectable
        self.isRemovable = isRemovable
        self.isWritable = isWritable
        self.isEncrypted = isEncrypted
        self.isInternal = isInternal
        self.deviceProtocol = deviceProtocol
        self.deviceModel = deviceModel
        self.deviceVendor = deviceVendor
        self.busPath = busPath
        self.isRepairRunning = isRepairRunning
        self.physicalRootBSDName = physicalRootBSDName
        self.diskImageURL = diskImageURL
        self.attachedAt = attachedAt
    }
}

extension DiskInfo {
    /// Builds a snapshot from a `DADiskCopyDescription` dictionary.
    /// Kept free of DiskArbitration objects so it can be unit-tested with fixtures.
    public init(
        description d: [String: Any], physicalRootBSDName: String? = nil, isContainerWhole: Bool = false,
        diskImageURL: URL? = nil, attachedAt: Date? = nil
    ) {
        func string(_ key: CFString) -> String? { d[key as String] as? String }
        func bool(_ key: CFString) -> Bool { (d[key as String] as? Bool) ?? false }
        func uuid(_ key: CFString) -> String? {
            guard let value = d[key as String] else { return nil }
            if let uuid = value as? UUID { return uuid.uuidString }
            let cf = value as CFTypeRef
            guard CFGetTypeID(cf) == CFUUIDGetTypeID() else { return nil }
            return CFUUIDCreateString(nil, (cf as! CFUUID)) as String
        }

        let bsdName = string(kDADiskDescriptionMediaBSDNameKey)
        let isNetwork = bool(kDADiskDescriptionVolumeNetworkKey)
        let isWhole = bool(kDADiskDescriptionMediaWholeKey)
        let model = string(kDADiskDescriptionDeviceModelKey)
        let proto = string(kDADiskDescriptionDeviceProtocolKey)

        let kind: Kind
        if bsdName == nil || isNetwork {
            kind = .network
        } else if !isWhole {
            kind = .volume
        } else if isContainerWhole {
            // Checked before disk images: an APFS container synthesized on an image
            // inherits the image's "Virtual Interface" protocol.
            kind = .containerWhole
        } else if model == "Disk Image" || proto == "Disk Image" || proto == "Virtual Interface" {
            kind = .diskImage
        } else {
            kind = .physicalWhole
        }

        var repair = false
        if #available(macOS 26.0, *) { repair = bool(kDADiskDescriptionRepairRunningKey) }

        self.init(
            bsdName: bsdName,
            kind: kind,
            volumeName: string(kDADiskDescriptionVolumeNameKey),
            volumePath: d[kDADiskDescriptionVolumePathKey as String] as? URL,
            volumeKind: string(kDADiskDescriptionVolumeKindKey),
            volumeUUID: uuid(kDADiskDescriptionVolumeUUIDKey),
            isNetwork: isNetwork,
            mediaName: string(kDADiskDescriptionMediaNameKey),
            mediaContent: string(kDADiskDescriptionMediaContentKey),
            mediaKind: string(kDADiskDescriptionMediaKindKey),
            mediaSize: (d[kDADiskDescriptionMediaSizeKey as String] as? NSNumber)?.int64Value,
            mediaUUID: uuid(kDADiskDescriptionMediaUUIDKey),
            isWhole: isWhole,
            isLeaf: bool(kDADiskDescriptionMediaLeafKey),
            isEjectable: bool(kDADiskDescriptionMediaEjectableKey),
            isRemovable: bool(kDADiskDescriptionMediaRemovableKey),
            isWritable: bool(kDADiskDescriptionMediaWritableKey),
            isEncrypted: bool(kDADiskDescriptionMediaEncryptedKey),
            isInternal: bool(kDADiskDescriptionDeviceInternalKey),
            deviceProtocol: proto,
            deviceModel: model?.trimmingCharacters(in: .whitespaces),
            deviceVendor: string(kDADiskDescriptionDeviceVendorKey)?.trimmingCharacters(in: .whitespaces),
            busPath: string(kDADiskDescriptionBusPathKey),
            isRepairRunning: repair,
            physicalRootBSDName: isNetwork ? nil : (physicalRootBSDName ?? bsdName),
            diskImageURL: diskImageURL,
            attachedAt: attachedAt
        )
    }
}
