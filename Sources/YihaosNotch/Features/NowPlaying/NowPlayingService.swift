import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum MusicSource: String, CaseIterable, Sendable {
    case music, spotify

    var bundleID: String {
        switch self {
        case .music: "com.apple.Music"
        case .spotify: "com.spotify.client"
        }
    }

    var appName: String {
        switch self {
        case .music: "Music"
        case .spotify: "Spotify"
        }
    }

    /// Both players broadcast a distributed notification on every play/pause/track
    /// change, so no polling is needed.
    var notificationName: Notification.Name {
        switch self {
        case .music: Notification.Name("com.apple.Music.playerInfo")
        case .spotify: Notification.Name("com.spotify.client.PlaybackStateChanged")
        }
    }

    var appURL: URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) }

    /// The player's app icon, looked up once.
    @MainActor var icon: NSImage? {
        if let cached = Self.iconCache[self] { return cached }
        let icon = appURL.map { NSWorkspace.shared.icon(forFile: $0.path) }
        Self.iconCache[self] = icon
        return icon
    }

    @MainActor private static var iconCache: [MusicSource: NSImage?] = [:]

    var isRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    /// Wraps `body` in a `tell` that only runs if the player is already running. The
    /// check happens inside the script, so a player that quits in the meantime is never
    /// relaunched. `trailer` runs afterwards, outside the `tell`.
    func script(_ body: String, trailer: String = "", timeout: Int = 3) -> String {
        """
        if application id "\(bundleID)" is running then
            tell application id "\(bundleID)"
                with timeout of \(timeout) seconds
                    \(body)
                end timeout
            end tell
            \(trailer)
        end if
        """
    }
}

struct Track: Equatable, Sendable {
    var id: String
    var title: String
    var artist: String
    var album: String
    /// Seconds. 0 for streams and radio, which have no fixed length.
    var duration: Double
}

/// One player's reported state, from a notification or a script query.
struct PlayerUpdate: Sendable {
    var state: String
    var track: Track?
    var position: Double?
    var artworkURL: String?

    var isPlaying: Bool { state.lowercased() == "playing" }
    var isStopped: Bool { state.lowercased() == "stopped" }

    /// Any process on the Mac can post these notifications, so every field is treated
    /// as untrusted: numbers must be finite and in range, strings are length-capped.
    static func fromNotification(_ info: [AnyHashable: Any], source: MusicSource) -> PlayerUpdate {
        let state = text(info["Player State"]) ?? "Stopped"
        guard let name = text(info["Name"]) else {
            return PlayerUpdate(state: state)
        }
        let duration: Double
        let id: String
        switch source {
        case .music:
            duration = seconds(info["Total Time"], scale: 1000) ?? 0
            id = musicTrackID(info["PersistentID"] ?? info["Persistent ID"]) ?? name
        case .spotify:
            duration = seconds(info["Duration"], scale: 1000) ?? 0
            id = text(info["Track ID"]) ?? name
        }
        let track = Track(id: id, title: name,
                          artist: text(info["Artist"]) ?? "",
                          album: text(info["Album"]) ?? "",
                          duration: duration)
        return PlayerUpdate(state: state, track: track, position: seconds(info["Playback Position"], scale: 1))
    }

    /// The longest track or position accepted: a day. Anything outside is dropped.
    static let maxSeconds: Double = 86_400

    /// A finite, in-range number of seconds, or nil.
    static func seconds(_ value: Any?, scale: Double) -> Double? {
        let raw: Double? = switch value {
        case let number as NSNumber: number.doubleValue
        case let string as String: Osascript.number(string)
        default: nil
        }
        guard let raw, raw.isFinite else { return nil }
        let result = raw / scale
        return (0...maxSeconds).contains(result) ? result : nil
    }

    /// A string, capped so a hostile value can't bloat the UI or lyrics requests.
    static func text(_ value: Any?, limit: Int = 500) -> String? {
        guard let string = value as? String else { return nil }
        return String(string.prefix(limit))
    }

    /// Music's notifications carry the persistent ID as a signed 64-bit number, while
    /// AppleScript returns it as 16 hex digits. Normalise both to uppercase hex so the
    /// same track is recognised from either source.
    static func musicTrackID(_ raw: Any?) -> String? {
        switch raw {
        case let number as NSNumber:
            String(format: "%016llX", UInt64(bitPattern: number.int64Value))
        case let string as String:
            string.uppercased()
        default:
            nil
        }
    }
}

/// Tracks what's playing in Music or Spotify and controls playback.
@MainActor
@Observable
final class NowPlayingService {
    private(set) var source: MusicSource?
    private(set) var track: Track?
    private(set) var isPlaying = false
    private(set) var artwork: NSImage?
    /// A colour pulled from the artwork, used for the visualizer and lyrics.
    private(set) var accent: Color = Theme.primary
    /// Synced lyrics for the current track, when LRCLIB has them.
    private(set) var lyrics: Lyrics?

    private var positionAnchor: Double = 0
    private var anchorDate = Date()

    @ObservationIgnored private var players: [MusicSource: (update: PlayerUpdate, at: Date)] = [:]
    @ObservationIgnored private var artworkTask: Task<Void, Never>?
    @ObservationIgnored private var lyricsTask: Task<Void, Never>?
    @ObservationIgnored private var positionRefresh: Task<Void, Never>?
    /// Keyed by track ID; nil entries remember tracks LRCLIB has no synced lyrics for.
    /// Failed lookups (offline, timeouts) are not cached, so they're retried next time.
    @ObservationIgnored private var lyricsCache: [String: Lyrics?] = [:]
    @ObservationIgnored private var lyricsCacheOrder: [String] = []
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    private static let lyricsCacheLimit = 200
    /// Separates fields in script output; never appears in track metadata.
    private static let fieldSeparator = "\u{1F}"

    func start() {
        let center = DistributedNotificationCenter.default()
        for source in MusicSource.allCases {
            observers.append(center.addObserver(forName: source.notificationName, object: nil, queue: .main) { note in
                let update = PlayerUpdate.fromNotification(note.userInfo ?? [:], source: source)
                MainActor.assumeIsolated { self.apply(update, from: source) }
            })
        }
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
        ) { note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard let source = MusicSource.allCases.first(where: { $0.bundleID == app?.bundleIdentifier })
            else { return }
            MainActor.assumeIsolated { self.apply(PlayerUpdate(state: "Stopped"), from: source) }
        })
        Task { await syncRunningPlayers() }
    }

    /// Elapsed playback time, extrapolated from the last known position.
    func position(at date: Date) -> Double {
        guard let track else { return 0 }
        let elapsed = isPlaying ? positionAnchor + date.timeIntervalSince(anchorDate) : positionAnchor
        let clamped = max(elapsed, 0)
        return track.duration > 0 ? min(clamped, track.duration) : clamped
    }

    // MARK: Controls

    func playPause() {
        setPlaying(!isPlaying)
        send("playpause")
    }

    func nextTrack() { send("next track") }
    func previousTrack() { send("previous track") }

    func seek(to seconds: Double) {
        guard let track, track.duration > 0 else { return }
        anchor(at: seconds)
        send("set player position to \(String(format: "%.2f", seconds))")
    }

    func openPlayer(_ source: MusicSource? = nil) {
        guard let url = (source ?? self.source)?.appURL else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    /// Re-reads the exact position from the player (notifications from Music don't include it).
    func refreshPosition() {
        // One at a time: a flood of (possibly spoofed) notifications mustn't spawn a
        // flood of osascript processes.
        guard positionRefresh == nil, let source, let trackID = track?.id, source.isRunning else { return }
        positionRefresh = Task {
            defer { positionRefresh = nil }
            guard let text = await Osascript.run(source.script("return player position")),
                  let value = Osascript.number(text),
                  // Ignore the answer if the track changed while the script ran.
                  source == self.source, trackID == track?.id
            else { return }
            anchor(at: value)
        }
    }

    // MARK: State

    private func apply(_ update: PlayerUpdate, from origin: MusicSource) {
        if update.isStopped {
            players[origin] = nil
        } else {
            var update = update
            if update.track == nil { update.track = players[origin]?.update.track }
            players[origin] = (update, .now)
        }

        // Prefer whichever player is playing; otherwise the one touched most recently.
        let active = players
            .filter { $0.value.update.track != nil }
            .max { ($0.value.update.isPlaying ? 1 : 0, $0.value.at) < ($1.value.update.isPlaying ? 1 : 0, $1.value.at) }

        guard let (activeSource, entry) = active, let newTrack = entry.update.track else {
            artworkTask?.cancel()
            lyricsTask?.cancel()
            self.source = nil
            track = nil
            isPlaying = false
            artwork = nil
            accent = Theme.primary
            lyrics = nil
            return
        }

        let trackChanged = newTrack.id != track?.id || activeSource != self.source
        self.source = activeSource
        if newTrack != track { track = newTrack }
        if trackChanged {
            anchor(at: entry.update.position ?? 0)
            loadArtwork(for: activeSource, track: newTrack, url: entry.update.artworkURL)
            loadLyrics(for: newTrack)
        }
        setPlaying(entry.update.isPlaying)
        if origin == activeSource {
            if let position = update.position { anchor(at: position) } else { refreshPosition() }
        }
    }

    private func setPlaying(_ playing: Bool) {
        guard playing != isPlaying else { return }
        anchor(at: position(at: .now))
        isPlaying = playing
    }

    private func anchor(at seconds: Double) {
        positionAnchor = seconds
        anchorDate = .now
    }

    private func send(_ command: String) {
        guard let source, source.isRunning else { return }
        Task { _ = await Osascript.run(source.script(command)) }
    }

    /// Notifications only fire on changes, so ask running players directly at launch.
    private func syncRunningPlayers() async {
        for source in MusicSource.allCases where source.isRunning {
            guard let output = await Osascript.run(Self.statusScript(for: source)), !output.isEmpty
            else { continue }
            let fields = output.components(separatedBy: Self.fieldSeparator)
            guard fields.count >= 7 else {
                apply(PlayerUpdate(state: fields.first ?? "stopped"), from: source)
                continue
            }
            let rawDuration = PlayerUpdate.seconds(fields[4], scale: source == .spotify ? 1000 : 1) ?? 0
            let id = source == .music ? (PlayerUpdate.musicTrackID(fields[6]) ?? fields[6]) : fields[6]
            let track = Track(id: id, title: fields[1], artist: fields[2], album: fields[3],
                              duration: rawDuration)
            apply(PlayerUpdate(state: fields[0], track: track, position: PlayerUpdate.seconds(fields[5], scale: 1),
                               artworkURL: fields.count > 7 ? fields[7] : nil),
                  from: source)
        }
    }

    private static func statusScript(for source: MusicSource) -> String {
        let idProperty = source == .music ? "persistent ID" : "id"
        let artwork = source == .spotify ? " & sep & (artwork url of t)" : ""
        return source.script("""
            set sep to character id 31
            set s to player state as string
            if s is "stopped" then return s
            set t to current track
            return s & sep & (name of t) & sep & (artist of t) & sep & (album of t) & sep & (duration of t) & sep & (player position) & sep & (\(idProperty) of t)\(artwork)
            """)
    }

    // MARK: Lyrics

    private func loadLyrics(for track: Track) {
        lyricsTask?.cancel()
        if let cached = lyricsCache[track.id] {
            lyrics = cached
            return
        }
        lyrics = nil
        lyricsTask = Task {
            let result = await LyricsFetcher.fetch(for: track)
            guard !Task.isCancelled else { return }
            let found: Lyrics?
            switch result {
            case .found(let fetched): found = fetched
            case .notFound: found = nil
            case .failed: return
            }
            cacheLyrics(found, for: track.id)
            if self.track?.id == track.id { lyrics = found }
        }
    }

    private func cacheLyrics(_ lyrics: Lyrics?, for id: String) {
        if lyricsCache.updateValue(lyrics, forKey: id) == nil { lyricsCacheOrder.append(id) }
        if lyricsCacheOrder.count > Self.lyricsCacheLimit {
            lyricsCache[lyricsCacheOrder.removeFirst()] = nil
        }
    }

    // MARK: Artwork

    private func loadArtwork(for source: MusicSource, track: Track, url: String?) {
        artworkTask?.cancel()
        artwork = nil
        accent = Theme.primary
        artworkTask = Task {
            let image = source == .spotify
                ? await Self.spotifyArtwork(knownURL: url)
                : await Self.musicArtwork()
            guard !Task.isCancelled, self.track?.id == track.id else { return }
            artwork = image
            accent = image.flatMap(ArtworkColor.accent(from:)) ?? Theme.primary
        }
    }

    private static func spotifyArtwork(knownURL: String?) async -> NSImage? {
        var urlString = knownURL
        if urlString == nil || urlString?.isEmpty == true {
            urlString = await Osascript.run(MusicSource.spotify.script("return artwork url of current track"))
        }
        guard let urlString, let url = URL(string: urlString), isSpotifyArtwork(url),
              let (data, _) = try? await Network.session.data(from: url)
        else { return nil }
        return downsampled(data)
    }

    /// Only https URLs on Spotify's image CDNs are fetched; anything else the player
    /// reports (file://, other hosts) is ignored.
    private static func isSpotifyArtwork(_ url: URL) -> Bool {
        guard url.scheme == "https", let host = url.host?.lowercased() else { return false }
        return ["scdn.co", "spotifycdn.com"].contains { host == $0 || host.hasSuffix("." + $0) }
    }

    /// Artwork is shown at 112 pt at most, but Music's originals can be 3000 px
    /// (tens of MB once decoded). Decode straight to a small thumbnail instead.
    ///
    /// Image decoders are a classic attack surface, and this process holds Camera and
    /// Accessibility, so only the formats album art actually uses are decoded, and only
    /// up to a sane size.
    private static func downsampled(_ data: Data, maxPixels: Int = 320) -> NSImage? {
        let allowedTypes = [UTType.jpeg.identifier, UTType.png.identifier]
        guard data.count <= 8_000_000,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let type = CGImageSourceGetType(source) as String?, allowedTypes.contains(type)
        else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }

    /// Music only hands artwork over as raw data, so the script writes it to a file.
    /// Each request gets its own file, so overlapping requests can't mix up images.
    private static func musicArtwork() async -> NSImage? {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("yihaosnotch-artwork-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: file) }
        let script = MusicSource.music.script("""
            try
                set d to raw data of artwork 1 of current track
            on error
                return "none"
            end try
            """, trailer: """
            set f to open for access (POSIX file "\(file.path)") with write permission
            write d to f
            close access f
            return "ok"
            """)
        guard await Osascript.run(script) == "ok", let data = try? Data(contentsOf: file) else { return nil }
        return downsampled(data)
    }
}
