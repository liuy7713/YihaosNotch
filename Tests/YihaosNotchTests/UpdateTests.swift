import Foundation
import Testing
@testable import YihaosNotch

/// What counts as a newer version, and which releases are offered at all.
struct AppVersionTests {
    @Test(arguments: [("1.5.3", "1.6.0"), ("1.9", "1.10"), ("v1.5.3", "1.5.4"), ("1.5", "1.5.1"), ("0.9.9", "1.0")])
    func ordering(_ older: String, _ newer: String) throws {
        #expect(try #require(AppVersion(older)) < #require(AppVersion(newer)))
        #expect(try !(#require(AppVersion(newer)) < #require(AppVersion(older))))
    }

    @Test func trailingZerosAreEqual() throws {
        #expect(try #require(AppVersion("1.5")) == #require(AppVersion("1.5.0")))
    }

    @Test(arguments: ["", "v", "1.6.0-beta", "1..2", "1.2.3.4.5", "-1.0", "latest"])
    func rejects(_ text: String) {
        #expect(AppVersion(text) == nil)
    }
}

struct ReleaseTests {
    private static let digest = String(repeating: "ab", count: 32)

    private static func payload(tag: String = "v1.6.0", draft: Bool = false, prerelease: Bool = false,
                                asset: String = "YihaosNotch.dmg",
                                url: String = "https://github.com/liuy7713/YihaosNotch/releases/download/v1.6.0/YihaosNotch.dmg",
                                digest: String? = "sha256:" + digest) -> Data {
        var assetJSON: [String: Any] = ["name": asset, "browser_download_url": url]
        if let digest { assetJSON["digest"] = digest }
        let json: [String: Any] = ["tag_name": tag, "draft": draft, "prerelease": prerelease,
                                   "body": "What's new", "assets": [assetJSON]]
        return try! JSONSerialization.data(withJSONObject: json)
    }

    @Test func parsesTheLatestRelease() throws {
        let release = try #require(Release.parse(Self.payload()))
        #expect(release.version == AppVersion("1.6.0"))
        #expect(release.sha256 == Self.digest)
        #expect(release.notes == "What's new")
    }

    @Test func skipsDraftsAndPrereleases() {
        #expect(Release.parse(Self.payload(draft: true)) == nil)
        #expect(Release.parse(Self.payload(prerelease: true)) == nil)
        #expect(Release.parse(Self.payload(tag: "v1.6.0-beta")) == nil)
    }

    @Test func needsTheImageAndItsDigest() {
        #expect(Release.parse(Self.payload(asset: "Other.dmg")) == nil)
        #expect(Release.parse(Self.payload(digest: nil)) == nil)
        #expect(Release.parse(Self.payload(digest: "md5:abc")) == nil)
        #expect(Release.parse(Self.payload(digest: "sha256:xyz")) == nil)
    }

    @Test(arguments: [
        "http://github.com/liuy7713/YihaosNotch/releases/download/v1.6.0/YihaosNotch.dmg",
        "https://example.com/liuy7713/YihaosNotch/releases/download/v1.6.0/YihaosNotch.dmg",
        "https://github.com/someone/YihaosNotch/releases/download/v1.6.0/YihaosNotch.dmg",
        "https://github.com.evil.com/liuy7713/YihaosNotch/releases/download/v1.6.0/YihaosNotch.dmg",
    ])
    func refusesDownloadsFromElsewhere(_ url: String) {
        #expect(Release.parse(Self.payload(url: url)) == nil)
    }

    /// Only a development feed (`--update-feed`) takes a download from elsewhere.
    @Test func testFeedsMayServeTheImageLocally() {
        let local = Self.payload(url: "http://127.0.0.1:8765/YihaosNotch.dmg")
        #expect(Release.parse(local) == nil)
        #expect(Release.parse(local, anyDownload: true) != nil)
    }
}
