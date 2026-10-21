import Foundation

/// Time-synced lyrics for one track.
struct Lyrics: Equatable, Sendable {
    struct Line: Equatable, Sendable {
        let time: Double
        let text: String
    }

    let lines: [Line]

    /// The line being sung at `position` seconds, or nil before the first line.
    func line(at position: Double) -> String? {
        // Binary search for the last line whose timestamp has passed.
        var low = 0, high = lines.count
        while low < high {
            let mid = (low + high) / 2
            if lines[mid].time <= position { low = mid + 1 } else { high = mid }
        }
        return low > 0 ? lines[low - 1].text : nil
    }

    /// Parses LRC text: lines like `[01:23.45] words`, possibly starting with several
    /// timestamps. Only the run of stamps at the start of a line counts, so a time
    /// mentioned in the lyric itself ("meet at [10:30]") stays part of the text. An
    /// `[offset:±ms]` tag shifts every line.
    init?(lrc: String) {
        // ASCII digits only: `\d` alone also matches full-width digits that Double can't parse.
        let stamp = /\[(\d+):(\d+(?:[.:]\d+)?)\]/.asciiOnlyDigits()
        let offsetTag = /\[offset:\s*([+-]?\d+)\]/.asciiOnlyDigits()

        var offset = 0.0
        var parsed: [Line] = []
        for raw in lrc.split(whereSeparator: \.isNewline) {
            var rest = raw.drop(while: \.isWhitespace)
            if let match = rest.prefixMatch(of: offsetTag), let ms = Double(match.output.1) {
                // Positive offsets make lyrics appear sooner.
                offset = ms / 1000
                continue
            }
            var times: [Double] = []
            while let match = rest.prefixMatch(of: stamp) {
                guard let minutes = Double(match.output.1),
                      let seconds = Double(match.output.2.replacingOccurrences(of: ":", with: "."))
                else { break }
                times.append(minutes * 60 + seconds)
                rest = rest[match.range.upperBound...]
            }
            guard !times.isEmpty else { continue }
            let text = rest.trimmingCharacters(in: .whitespaces)
            parsed += times.map { Line(time: $0, text: text) }
        }
        guard !parsed.isEmpty else { return nil }
        lines = parsed
            .map { Line(time: $0.time - offset, text: $0.text) }
            .sorted { $0.time < $1.time }
    }
}

/// Fetches synced lyrics from LRCLIB (lrclib.net), a free, keyless lyrics database.
/// Only the track title, artist, album and duration are sent.
enum LyricsFetcher {
    enum Result: Sendable {
        case found(Lyrics)
        /// LRCLIB answered and has no synced lyrics for this track.
        case notFound
        /// Offline, timed out or cancelled; worth trying again later.
        case failed
    }

    private struct Record: Decodable {
        let syncedLyrics: String?
        let duration: Double?
    }

    private enum Response<T> {
        case ok(T)
        case notFound
        case failed
    }

    static func fetch(for track: Track) async -> Result {
        // Exact lookup first: it matches on duration, so it rarely picks the wrong version.
        switch await get(track) {
        case .ok(let record):
            if let lyrics = record.syncedLyrics.flatMap(Lyrics.init(lrc:)) { return .found(lyrics) }
        case .notFound:
            break
        case .failed:
            return .failed
        }
        guard !Task.isCancelled else { return .failed }

        // Fall back to a search, using only the first artist ("A, B" → "A").
        let firstArtist = track.artist.split(separator: ",").first.map(String.init) ?? track.artist
        switch await search(title: track.title, artist: firstArtist) {
        case .ok(let records):
            let match = records.first { record in
                record.syncedLyrics != nil
                    && (track.duration <= 0 || abs((record.duration ?? track.duration) - track.duration) <= 4)
            }
            return match?.syncedLyrics.flatMap(Lyrics.init(lrc:)).map(Result.found) ?? .notFound
        case .notFound:
            return .notFound
        case .failed:
            return .failed
        }
    }

    private static func get(_ track: Track) async -> Response<Record> {
        var items = [
            URLQueryItem(name: "track_name", value: track.title),
            URLQueryItem(name: "artist_name", value: track.artist),
            URLQueryItem(name: "album_name", value: track.album),
        ]
        if track.duration > 0 {
            items.append(URLQueryItem(name: "duration", value: String(Int(track.duration.rounded()))))
        }
        return await request(path: "/api/get", query: items)
    }

    private static func search(title: String, artist: String) async -> Response<[Record]> {
        await request(path: "/api/search", query: [
            URLQueryItem(name: "track_name", value: title),
            URLQueryItem(name: "artist_name", value: artist),
        ])
    }

    private static func request<T: Decodable>(path: String, query: [URLQueryItem]) async -> Response<T> {
        var components = URLComponents(string: "https://lrclib.net")!
        components.path = path
        components.queryItems = query
        // URLComponents leaves "+" alone, but servers read it as a space ("C++" → "C  ").
        components.percentEncodedQuery = components.percentEncodedQuery?
            .replacingOccurrences(of: "+", with: "%2B")
        guard let url = components.url else { return .failed }
        var request = URLRequest(url: url, timeoutInterval: 8)
        request.setValue("YihaosNotch/0.1", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let status = (response as? HTTPURLResponse)?.statusCode
        else { return .failed }
        if status == 404 { return .notFound }
        guard status == 200, let decoded = try? JSONDecoder().decode(T.self, from: data) else { return .failed }
        return .ok(decoded)
    }
}
