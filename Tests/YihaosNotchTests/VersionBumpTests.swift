import Foundation
import Testing

/// scripts/bump-version.sh, run on a copy of Info.plist.
struct VersionBumpTests {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()

    /// Runs the script on a plist holding `version` and `build`; returns the exit status
    /// and what the plist holds afterwards.
    func bump(_ part: String, version: String = "1.3.2", build: String = "16") throws -> (Int32, String, String) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let plist = directory.appendingPathComponent("Info.plist")
        let contents: NSDictionary = ["CFBundleShortVersionString": version, "CFBundleVersion": build]
        try contents.write(to: plist)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [Self.root.appendingPathComponent("scripts/bump-version.sh").path, part]
        process.environment = ["PLIST": plist.path, "PATH": "/usr/bin:/bin"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()

        let after = NSDictionary(contentsOf: plist)
        return (process.terminationStatus,
                after?["CFBundleShortVersionString"] as? String ?? "",
                after?["CFBundleVersion"] as? String ?? "")
    }

    @Test(arguments: [("patch", "1.3.3"), ("minor", "1.4.0"), ("major", "2.0.0")])
    func partsAndTheBuildNumber(_ part: String, _ expected: String) throws {
        let (status, version, build) = try bump(part)
        #expect(status == 0)
        #expect(version == expected)
        #expect(build == "17")
    }

    @Test func unknownPartIsRefused() throws {
        let (status, version, build) = try bump("tiny")
        #expect(status != 0)
        #expect(version == "1.3.2")
        #expect(build == "16")
    }

    @Test(arguments: [("1.3", "16"), ("1.3.2-beta", "16"), ("1.3.2", "sixteen")])
    func malformedVersionsAreRefused(_ version: String, _ build: String) throws {
        let (status, after, _) = try bump("patch", version: version, build: build)
        #expect(status != 0)
        #expect(after == version)
    }
}
