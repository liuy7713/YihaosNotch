import Foundation

/// A version number like 1.5.3, compared part by part (so 1.10 is newer than 1.9).
struct AppVersion: Comparable, Sendable, CustomStringConvertible {
    let parts: [Int]

    /// Accepts "1.5.3" or a tag like "v1.5.3"; anything else (pre-release suffixes
    /// included) is nil, so it's never offered as an update.
    init?(_ text: String) {
        let trimmed = text.hasPrefix("v") ? String(text.dropFirst()) : text
        let parts = trimmed.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard (1...4).contains(parts.count), parts.allSatisfy({ ($0 ?? -1) >= 0 }) else { return nil }
        self.parts = parts.compactMap { $0 }
    }

    static func < (a: AppVersion, b: AppVersion) -> Bool {
        for index in 0..<max(a.parts.count, b.parts.count) {
            let (x, y) = (a.parts[safe: index] ?? 0, b.parts[safe: index] ?? 0)
            if x != y { return x < y }
        }
        return false
    }

    static func == (a: AppVersion, b: AppVersion) -> Bool { !(a < b) && !(b < a) }

    var description: String { parts.map(String.init).joined(separator: ".") }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

/// The newest published release, as GitHub's API describes it.
struct Release: Equatable, Sendable {
    let version: AppVersion
    /// What's new, as written in the release notes (Markdown).
    let notes: String
    let download: URL
    /// The image's SHA-256 in hex, from the digest GitHub computed when it was uploaded.
    let sha256: String

    /// The always-latest name every release carries (see scripts/publish-release.sh).
    static let assetName = "YihaosNotch.dmg"
    static let repository = "liuy7713/YihaosNotch"
    static let latestURL = URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!
    static let pageURL = URL(string: "https://github.com/\(repository)/releases/latest")!

    /// Parses `GET /repos/{owner}/{repo}/releases/latest`. Nil for a draft or
    /// pre-release, or one without the image, its digest, or a download link on this
    /// repository's own release page (`anyDownload` lifts that last rule, for a test
    /// feed served locally; the signature check still applies).
    static func parse(_ data: Data, anyDownload: Bool = false) -> Release? {
        struct Payload: Decodable {
            struct Asset: Decodable {
                let name: String
                let browser_download_url: URL
                let digest: String?
            }
            let tag_name: String
            let draft: Bool
            let prerelease: Bool
            let body: String?
            let assets: [Asset]
        }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data),
              !payload.draft, !payload.prerelease,
              let version = AppVersion(payload.tag_name),
              let asset = payload.assets.first(where: { $0.name == assetName }),
              anyDownload || isOwnDownload(asset.browser_download_url),
              let digest = asset.digest, digest.hasPrefix("sha256:")
        else { return nil }
        let hex = String(digest.dropFirst("sha256:".count)).lowercased()
        guard hex.count == 64, hex.allSatisfy(\.isHexDigit) else { return nil }
        return Release(version: version, notes: payload.body ?? "", download: asset.browser_download_url, sha256: hex)
    }

    /// Only images attached to this repository's releases. (The signature check is
    /// what really decides; this just refuses to fetch anything else at all.)
    static func isOwnDownload(_ url: URL) -> Bool {
        url.scheme == "https" && url.host == "github.com"
            && url.path.hasPrefix("/\(repository)/releases/download/")
    }
}
