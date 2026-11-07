import AppKit
import Observation
import os

private let log = Logger(subsystem: "com.yihao.YihaosNotch", category: "Updater")

/// Looks for a newer release on GitHub once a day (or when asked), and installs it
/// when the user clicks Update. Checking is one request to GitHub's API; nothing about
/// the user is sent.
@MainActor
@Observable
final class UpdateService {
    enum State: Equatable {
        /// Not checked since launch.
        case idle
        case checking
        case upToDate
        case available(Release)
        case installing
        /// A check the user asked for couldn't reach GitHub.
        case checkFailed
        /// The install stopped; the reason is for Settings.
        case installFailed(String)
    }

    private(set) var state: State = .idle

    var available: Release? {
        if case .available(let release) = state { release } else { nil }
    }

    /// Daily checks; follows the setting.
    var automatic = false {
        didSet { automatic ? schedule() : unschedule() }
    }

    static let currentVersion = AppVersion(
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")

    /// Development aid: `--update-feed URL` reads a release description from URL (a
    /// local copy of GitHub's JSON, say) instead of GitHub, accepts its download from
    /// anywhere (the signature check still applies), and checks right after launch.
    @ObservationIgnored private let feed: URL
    @ObservationIgnored private let testFeed: Bool
    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored private let defaults = UserDefaults.standard

    private static let interval: TimeInterval = 24 * 60 * 60
    private static let lastCheckKey = "lastUpdateCheck"

    init() {
        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: "--update-feed"), arguments.indices.contains(index + 1),
           let url = URL(string: arguments[index + 1]) {
            feed = url
            testFeed = true
        } else {
            feed = Release.latestURL
            testFeed = false
        }
    }

    /// Checks now. Failures of a background check stay quiet: there'll be another
    /// tomorrow, and an offline Mac isn't news.
    func check(userInitiated: Bool = true) async {
        switch state {
        case .checking, .installing: return
        default: break
        }
        let previous = state
        state = .checking
        var request = URLRequest(url: feed)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue(Network.userAgent, forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await Network.data(for: request, limit: 2_000_000),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let release = Release.parse(data, anyDownload: testFeed)
        else {
            log.error("update check failed")
            state = userInitiated ? .checkFailed : previous
            return
        }
        defaults.set(Date.now, forKey: Self.lastCheckKey)
        if let current = Self.currentVersion, current < release.version {
            log.info("version \(release.version.description, privacy: .public) is available")
            state = .available(release)
        } else {
            state = .upToDate
        }
    }

    /// Replaces this copy with the available release and restarts it. When this copy
    /// can't replace itself (run from the disk image or Downloads, or a folder this
    /// account can't change), the release page opens instead.
    func install() {
        guard let release = available else { return }
        guard UpdateInstaller.canReplace() else {
            NSWorkspace.shared.open(Release.pageURL)
            return
        }
        state = .installing
        Task {
            do {
                try await UpdateInstaller.install(from: release.download, sha256: release.sha256)
                // A test copy keeps its development flags, so it stays beside the
                // installed app; a normal copy has none.
                SingleInstance.relaunch(arguments: Array(CommandLine.arguments.dropFirst()))
            } catch {
                log.error("update failed: \(String(describing: error), privacy: .public)")
                state = .installFailed(String(describing: error))
            }
        }
    }

    func openReleasePage() {
        NSWorkspace.shared.open(Release.pageURL)
    }

    /// Checks when a day has passed since the last check (at the earliest a minute
    /// after launch, so it never competes with starting up), then daily. Rechecked
    /// hourly rather than slept through in one go, because a sleeping Mac pauses the
    /// countdown.
    private func schedule() {
        guard timer == nil else { return }
        timer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(self?.testFeed == true ? 2 : 60))
            while !Task.isCancelled {
                guard let self else { return }
                let last = defaults.object(forKey: Self.lastCheckKey) as? Date ?? .distantPast
                if testFeed || Date.now.timeIntervalSince(last) >= Self.interval {
                    await check(userInitiated: false)
                    if testFeed { return }
                }
                try? await Task.sleep(for: .seconds(60 * 60))
            }
        }
    }

    private func unschedule() {
        timer?.cancel()
        timer = nil
    }
}
