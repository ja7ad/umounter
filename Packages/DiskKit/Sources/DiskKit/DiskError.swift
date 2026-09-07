import DiskArbitration
import Foundation

/// A typed DiskArbitration failure, mapped from a `DADissenter` status.
public struct DiskError: Error, Sendable, Hashable, CustomStringConvertible {
    public enum Code: Sendable, Hashable {
        case busy
        case notPrivileged
        case notPermitted
        case exclusiveAccess
        case notFound
        case notMounted
        case notReady
        case notWritable
        case unsupported
        case badArgument
        case noResources
        case unix(errno: Int32)
        case other(status: UInt32)
    }

    public var code: Code
    /// Optional human-readable reason supplied by the dissenting process.
    public var message: String?
    /// Which operation failed, e.g. "unmount disk4".
    public var operation: String

    public init(code: Code, message: String? = nil, operation: String) {
        self.code = code
        self.message = message
        self.operation = operation
    }

    /// Maps a raw `DAReturn` status. DiskArbitration encodes BSD errors as
    /// `unix_err(errno)` = `err_kern | err_sub(3) | errno`, i.e. `0x0000C000 | errno`.
    public static func code(forStatus status: Int32) -> Code {
        let raw = UInt32(bitPattern: status)
        switch raw {
        case 0xF8DA_0002: return .busy
        case 0xF8DA_0003: return .badArgument
        case 0xF8DA_0004: return .exclusiveAccess
        case 0xF8DA_0005: return .noResources
        case 0xF8DA_0006: return .notFound
        case 0xF8DA_0007: return .notMounted
        case 0xF8DA_0008: return .notPermitted
        case 0xF8DA_0009: return .notPrivileged
        case 0xF8DA_000A: return .notReady
        case 0xF8DA_000B: return .notWritable
        case 0xF8DA_000C: return .unsupported
        default:
            if raw & ~UInt32(0x3FFF) == 0xC000 {
                let errno = Int32(raw & 0x3FFF)
                return errno == EBUSY ? .busy : .unix(errno: errno)
            }
            return .other(status: raw)
        }
    }

    init(dissenter: DADissenter, operation: String) {
        self.init(
            code: Self.code(forStatus: DADissenterGetStatus(dissenter)),
            message: DADissenterGetStatusString(dissenter) as String?,
            operation: operation
        )
    }

    public var description: String {
        let reason: String = switch code {
        case .busy: "the disk is in use"
        case .notPrivileged: "administrator privileges are required"
        case .notPermitted: "the operation is not permitted"
        case .exclusiveAccess: "another process has exclusive access"
        case .notFound: "the disk was not found"
        case .notMounted: "the volume is not mounted"
        case .notReady: "the disk is not ready"
        case .notWritable: "the disk is not writable"
        case .unsupported: "the operation is not supported for this disk"
        case .badArgument: "bad argument"
        case .noResources: "out of resources"
        case .unix(let errno): String(cString: strerror(errno))
        case .other(let status): String(format: "status 0x%08X", status)
        }
        if let message, !message.isEmpty { return "\(operation) failed: \(reason) (\(message))" }
        return "\(operation) failed: \(reason)"
    }
}
