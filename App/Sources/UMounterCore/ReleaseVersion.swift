import Foundation

/// A release version such as `1.2.0` or `v1.3.0-beta.1`, compared numerically.
/// A pre-release sorts before the same version without one (`1.3.0-beta < 1.3.0`).
public struct ReleaseVersion: Comparable, Sendable, CustomStringConvertible {
    public let numbers: [Int]
    public let preRelease: String?

    public init?(_ string: String) {
        var text = string.trimmingCharacters(in: .whitespaces)
        if text.first == "v" || text.first == "V" { text.removeFirst() }
        let parts = text.split(separator: "-", maxSplits: 1)
        guard let core = parts.first else { return nil }
        let numbers = core.split(separator: ".").map { Int($0) }
        guard !numbers.isEmpty, numbers.allSatisfy({ $0 != nil }) else { return nil }
        self.numbers = numbers.compactMap { $0 }
        preRelease = parts.count > 1 ? String(parts[1]) : nil
    }

    public var description: String {
        numbers.map(String.init).joined(separator: ".") + (preRelease.map { "-\($0)" } ?? "")
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        for index in 0..<max(lhs.numbers.count, rhs.numbers.count) {
            let left = index < lhs.numbers.count ? lhs.numbers[index] : 0
            let right = index < rhs.numbers.count ? rhs.numbers[index] : 0
            if left != right { return left < right }
        }
        switch (lhs.preRelease, rhs.preRelease) {
        case let (left?, right?): return left.compare(right, options: .numeric) == .orderedAscending
        case (.some, nil): return true
        default: return false
        }
    }

    public static func == (lhs: Self, rhs: Self) -> Bool { !(lhs < rhs) && !(rhs < lhs) }
}

/// The fields UMounter reads from GitHub's "latest release" API response.
public struct GitHubRelease: Decodable, Sendable {
    public let tagName: String
    public let htmlURL: URL

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlURL = "html_url"
    }

    public var version: ReleaseVersion? { ReleaseVersion(tagName) }

    /// True when this release is newer than `current` (an unparsable tag never is).
    public func isNewer(than current: ReleaseVersion) -> Bool {
        guard let version else { return false }
        return version > current
    }
}
