import AppKit
import os

private let log = Logger(subsystem: "com.yihao.YihaosNotch", category: "SingleInstance")

/// Keeps exactly one copy running, and makes sure it's the newest.
///
/// Two copies (one in Applications, one opened from the disk image, say) would draw two
/// notches over each other and both catch the volume keys. And opening an updated copy
/// that was dragged over the running one only reaches the old process, which would go
/// on running the old version.
@MainActor
enum SingleInstance {
    private static let quitRequest = Notification.Name("com.yihao.YihaosNotch.quitRequest")

    /// The build this process was started from (the bundle on disk may since have been
    /// replaced by an update).
    private static let runningBuild = build(at: Bundle.main.bundleURL) ?? 0

    /// Call first thing at launch. Returns false if another copy should carry on
    /// instead, in which case this one has passed the launch on to it and must quit.
    ///
    /// A launch with arguments is a developer's test copy, which runs beside the
    /// installed app; Finder, the Dock and login never pass any.
    static func claim() -> Bool {
        _ = runningBuild
        listenForQuitRequests()
        guard CommandLine.arguments.count == 1, let bundleID = Bundle.main.bundleIdentifier else { return true }
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != getpid() && !$0.isTerminated }
        guard !others.isEmpty else { return true }

        let ours = rank(of: Bundle.main.bundleURL, build: runningBuild)
        let me = NSRunningApplication.current
        // A tie goes to the copy that started first (opening the app again shows its
        // Settings, as it always has), and the lower pid if they started together, so
        // two copies launched at once never both bow out.
        func outranksUs(_ other: NSRunningApplication) -> Bool {
            let theirs = rank(of: other.bundleURL, build: nil)
            if theirs != ours { return theirs > ours }
            let (a, b) = (other.launchDate ?? .distantPast, me.launchDate ?? .distantPast)
            return a != b ? a < b : other.processIdentifier < me.processIdentifier
        }
        if let winner = others.first(where: outranksUs), let url = winner.bundleURL {
            log.info("another copy is running and is as new; handing over to it")
            // Opening the running copy's own bundle reaches that process (as a reopen).
            NSWorkspace.shared.open(url)
            return false
        }
        // Copies that tie with this one but started later bow out by themselves.
        for other in others where rank(of: other.bundleURL, build: nil) < ours { retire(other) }
        return true
    }

    /// Opening the app again while an update has replaced it on disk: start the new
    /// version once this one has gone. Returns true if that's under way.
    static func relaunchIfUpdated() -> Bool {
        let url = Bundle.main.bundleURL
        guard let onDisk = build(at: url), onDisk > runningBuild else { return false }
        log.info("build \(onDisk) replaced running build \(runningBuild); relaunching")
        return relaunch()
    }

    /// Quits and starts the bundle on disk afresh, passing `arguments` to it. Returns
    /// false, and carries on running, if that can't be arranged.
    @discardableResult
    static func relaunch(arguments: [String] = []) -> Bool {
        // A shell waits for this process to exit, then opens the bundle. The pid, path
        // and arguments are passed as arguments, never pasted into the script.
        // `open -n`: LaunchServices still lists this copy as running for a moment after
        // it exits, and a plain `open` in that moment does nothing.
        let relauncher = Process()
        relauncher.executableURL = URL(fileURLWithPath: "/bin/sh")
        let script = #"pid="$1"; app="$2"; shift 2; while kill -0 "$pid" 2>/dev/null; do sleep 0.1; done; "#
            + #"if [ $# -gt 0 ]; then exec /usr/bin/open -n "$app" --args "$@"; else exec /usr/bin/open -n "$app"; fi"#
        relauncher.arguments = ["-c", script, "sh", String(getpid()), Bundle.main.bundleURL.path] + arguments
        do {
            try relauncher.run()
        } catch {
            log.error("relaunch failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
        NSApp.terminate(nil)
        return true
    }

    /// Asks an older copy to quit, and makes sure it does: copies from before 1.3.2
    /// don't listen for the request.
    private static func retire(_ other: NSRunningApplication) {
        log.info("asking older copy \(other.processIdentifier) to quit")
        DistributedNotificationCenter.default().postNotificationName(
            quitRequest, object: String(other.processIdentifier), userInfo: nil, deliverImmediately: true)
        Task {
            try? await Task.sleep(for: .seconds(2))
            if !other.isTerminated { other.forceTerminate() }
        }
    }

    private static func listenForQuitRequests() {
        let me = String(getpid())
        DistributedNotificationCenter.default().addObserver(
            forName: quitRequest, object: me, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                log.info("a newer copy took over; quitting")
                NSApp.terminate(nil)
            }
        }
    }

    /// Orders copies: a copy on a disk image always loses (it disappears when the image
    /// is ejected), then the higher build wins.
    private static func rank(of url: URL?, build known: Int?) -> Rank {
        guard let url else { return Rank(installed: false, build: 0) }
        return Rank(installed: !WelcomePermissions.isDiskImagePath(url.path), build: known ?? build(at: url) ?? 0)
    }

    struct Rank: Comparable {
        let installed: Bool
        let build: Int

        static func < (a: Rank, b: Rank) -> Bool {
            a.installed != b.installed ? !a.installed : a.build < b.build
        }
    }

    /// CFBundleVersion as currently on disk, read fresh rather than from the cached
    /// bundle.
    nonisolated static func build(at bundleURL: URL) -> Int? {
        let plist = bundleURL.appendingPathComponent("Contents/Info.plist")
        guard let info = NSDictionary(contentsOf: plist) else { return nil }
        return (info["CFBundleVersion"] as? String).flatMap { Int($0) }
    }
}
