import AppKit
import os
import UMounterCore

/// "Check for Updates…": asks GitHub for the latest release and offers to open its
/// page. Runs only when the user asks — there is no background polling.
@MainActor
final class UpdateChecker {
    nonisolated static let latestReleaseAPI = URL(string: "https://api.github.com/repos/ja7ad/umounter/releases/latest")!
    nonisolated static let releasesPage = URL(string: "https://github.com/ja7ad/umounter/releases")!

    private var isChecking = false
    private let log = Logger(subsystem: "app.umounter", category: "update")

    /// The running version (`CFBundleShortVersionString`); 0.0.0 for the unbundled debug binary.
    static var currentVersion: ReleaseVersion {
        let string = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return string.flatMap(ReleaseVersion.init) ?? ReleaseVersion("0.0.0")!
    }

    func check(completion: @escaping @MainActor () -> Void = {}) {
        guard !isChecking else { return }
        isChecking = true
        Task { @MainActor in
            defer { isChecking = false; completion() }
            let current = Self.currentVersion
            do {
                let release = try await Self.fetchLatest()
                if release.isNewer(than: current) {
                    offer(release, current: current)
                } else {
                    inform("UMounter is up to date", "Version \(current) is the latest version.")
                }
            } catch {
                log.error("update check failed: \(error, privacy: .public)")
                inform("Couldn’t check for updates", error.localizedDescription)
            }
        }
    }

    private static func fetchLatest() async throws -> GitHubRelease {
        var request = URLRequest(url: latestReleaseAPI, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("UMounter/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: request)
        switch (response as? HTTPURLResponse)?.statusCode ?? 0 {
        case 200: return try JSONDecoder().decode(GitHubRelease.self, from: data)
        case 404: throw UpdateError.noReleases
        case let status: throw UpdateError.http(status)
        }
    }

    private func offer(_ release: GitHubRelease, current: ReleaseVersion) {
        let alert = NSAlert()
        alert.messageText = "A new version of UMounter is available"
        alert.informativeText = "UMounter \(release.version?.description ?? release.tagName) is available — you have \(current). Do you want to open the download page?"
        alert.addButton(withTitle: "Yes")
        alert.addButton(withTitle: "No")
        NSApp.activate()
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(release.htmlURL)
        }
    }

    private func inform(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        NSApp.activate()
        alert.runModal()
    }
}

enum UpdateError: LocalizedError {
    case noReleases
    case http(Int)

    var errorDescription: String? {
        switch self {
        case .noReleases: "No release has been published yet. See \(UpdateChecker.releasesPage.absoluteString)."
        case .http(403), .http(429): "GitHub is limiting requests right now. Try again later."
        case let .http(status): "GitHub returned an error (HTTP \(status))."
        }
    }
}
