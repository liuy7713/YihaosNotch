import AppKit
import CryptoKit
import Foundation
import os
import Security

private let log = Logger(subsystem: "com.yihao.YihaosNotch", category: "Updater")

/// Installs a new version over the running app: downloads the disk image, checks it
/// against the release's checksum, and only swaps in an app signed by the same
/// certificate as this one. A copy the app fetches itself isn't quarantined, so
/// macOS doesn't ask to Open Anyway again.
enum UpdateInstaller {
    enum Failure: Error, CustomStringConvertible {
        case download, checksum, mount, noApp, signature, notNewer, notWritable, appManagement, swap

        var description: String {
            switch self {
            case .download: "The download didn't finish."
            case .checksum: "The download didn't match the release."
            case .mount: "The disk image couldn't be opened."
            case .noApp: "The disk image doesn't contain the app."
            case .signature: "The new version isn't signed by the same developer."
            case .notNewer: "The download isn't newer than this version."
            case .notWritable: "The app's folder can't be changed from this account."
            case .appManagement: "macOS stopped the app from replacing itself (App Management)."
            case .swap: "The new version couldn't be put in place."
            }
        }
    }

    static let appName = "Yihao's Notch.app"
    /// Far above the ~2 MB image, but stops a runaway download.
    private static let maximumBytes: Int64 = 100_000_000

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 600
        return URLSession(configuration: configuration)
    }()

    /// Whether this copy can replace itself: not run from a disk image or a translocated
    /// download, in a folder this account can change, and owned by this user. When it
    /// can't, the download page is the way to update.
    static func canReplace(_ target: URL = Bundle.main.bundleURL) -> Bool {
        let path = target.path
        let folder = target.deletingLastPathComponent().path
        guard !path.contains("/AppTranslocation/"), !WelcomePermissions.isDiskImagePath(path),
              access(folder, W_OK) == 0, access(path, W_OK) == 0,
              let owner = (try? FileManager.default.attributesOfItem(atPath: path))?[.ownerAccountID] as? NSNumber,
              owner.uint32Value == getuid()
        else { return false }
        return true
    }

    /// Downloads, verifies and puts in place the image at `url`, replacing the app at
    /// `target`. `sha256` (hex) is checked before the image is even opened. Doesn't
    /// relaunch.
    ///
    /// Nothing is ever written inside the live bundle: the new copy is made and
    /// checked in a staging folder on the same volume, then the old bundle is moved
    /// aside and the new one moved in (two renames, undone if the second fails).
    static func install(from url: URL, sha256: String?, replacing target: URL = Bundle.main.bundleURL) async throws {
        guard canReplace(target) else { throw Failure.notWritable }
        let staging = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                                  appropriateFor: target, create: true)
        defer { try? FileManager.default.removeItem(at: staging) }

        let image = try await download(url, into: staging)
        if let sha256 {
            let actual = try SHA256.hash(data: Data(contentsOf: image)).map { String(format: "%02x", $0) }.joined()
            guard actual == sha256.lowercased() else {
                log.error("checksum mismatch")
                throw Failure.checksum
            }
        }

        let new = staging.appendingPathComponent("new").appendingPathComponent(appName)
        let mount = try attach(image, under: staging)
        do {
            let candidate = mount.appendingPathComponent(appName)
            guard FileManager.default.fileExists(atPath: candidate.path) else { throw Failure.noApp }
            try run("/usr/bin/ditto", [candidate.path, new.path])
        } catch {
            detach(mount)
            throw error
        }
        detach(mount)
        // The copy is what gets installed, so it's the copy that's checked.
        try verify(new, newerThan: target)

        let old = staging.appendingPathComponent("old")
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        let aside = old.appendingPathComponent(appName)
        try move(target, to: aside)
        do {
            try move(new, to: target)
        } catch {
            try? move(aside, to: target)
            throw error
        }
        LSRegisterURL(target as CFURL, true)
        log.info("installed the update over \(target.path, privacy: .public)")
    }

    private static func download(_ url: URL, into folder: URL) async throws -> URL {
        let destination = folder.appendingPathComponent("update.dmg")
        do {
            let (file, response) = try await session.download(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw Failure.download }
            try FileManager.default.moveItem(at: file, to: destination)
        } catch let failure as Failure {
            throw failure
        } catch {
            log.error("download failed: \(error.localizedDescription, privacy: .public)")
            throw Failure.download
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? Int64) ?? 0
        guard size > 0, size <= maximumBytes else { throw Failure.download }
        log.info("downloaded \(size) bytes")
        return destination
    }

    /// Mounts read-only, out of sight (no Finder window or desktop icon).
    private static func attach(_ image: URL, under work: URL) throws -> URL {
        let mounts = work.appendingPathComponent("mount")
        try FileManager.default.createDirectory(at: mounts, withIntermediateDirectories: true)
        let output: Data
        do {
            output = try run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly", "-noautoopen",
                                                  "-mountrandom", mounts.path, "-plist", image.path])
        } catch {
            throw Failure.mount
        }
        guard let plist = try? PropertyListSerialization.propertyList(from: output, format: nil) as? [String: Any],
              let entities = plist["system-entities"] as? [[String: Any]],
              let path = entities.compactMap({ $0["mount-point"] as? String }).first
        else { throw Failure.mount }
        return URL(fileURLWithPath: path)
    }

    private static func detach(_ mount: URL) {
        if (try? run("/usr/bin/hdiutil", ["detach", mount.path, "-quiet"])) == nil {
            _ = try? run("/usr/bin/hdiutil", ["detach", mount.path, "-force", "-quiet"])
        }
    }

    /// The candidate must carry this app's identifier, satisfy this app's own
    /// designated requirement (the same signing certificate), and be a newer build.
    /// An ad-hoc signed development build has no certificate to match, so it can
    /// never install an update.
    static func verify(_ candidate: URL, newerThan target: URL) throws {
        var running: SecCode?
        var me: SecStaticCode?
        var requirement: SecRequirement?
        var code: SecStaticCode?
        guard SecCodeCopySelf([], &running) == errSecSuccess, let running,
              SecCodeCopyStaticCode(running, [], &me) == errSecSuccess, let me,
              SecCodeCopyDesignatedRequirement(me, [], &requirement) == errSecSuccess, let requirement,
              SecStaticCodeCreateWithPath(candidate as CFURL, [], &code) == errSecSuccess, let code
        else { throw Failure.signature }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        let status = SecStaticCodeCheckValidity(code, flags, requirement)
        guard status == errSecSuccess else {
            log.error("signature check failed: \(status)")
            throw Failure.signature
        }
        guard Bundle(url: candidate)?.bundleIdentifier == Bundle.main.bundleIdentifier,
              let new = SingleInstance.build(at: candidate),
              new > (SingleInstance.build(at: target) ?? 0)
        else { throw Failure.notNewer }
    }

    /// A plain rename. EPERM is App Management refusing; anything else is a
    /// permissions or disk problem.
    private static func move(_ source: URL, to destination: URL) throws {
        guard rename(source.path, destination.path) != 0 else { return }
        let code = errno
        log.error("rename failed: errno \(code)")
        throw code == EPERM ? Failure.appManagement : Failure.swap
    }

    @discardableResult
    private static func run(_ tool: String, _ arguments: [String]) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            log.error("\(tool, privacy: .public) exited with \(process.terminationStatus)")
            throw Failure.swap
        }
        return data
    }
}
