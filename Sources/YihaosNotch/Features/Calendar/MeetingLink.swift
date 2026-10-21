import AppKit
import EventKit

/// A video-call link found in a calendar event, and how to open it in the right app.
struct MeetingLink: Equatable, Sendable {
    enum Provider: Sendable {
        case zoom, teams, meet, webex

        var name: String {
            switch self {
            case .zoom: "Zoom"
            case .teams: "Teams"
            case .meet: "Meet"
            case .webex: "Webex"
            }
        }
    }

    let provider: Provider
    let url: URL

    /// Looks in the event's URL field first, then location, then notes.
    static func find(in event: EKEvent) -> MeetingLink? {
        let fields = [event.url?.absoluteString, event.location, event.notes].compactMap { $0 }
        for field in fields {
            if let link = find(in: field) { return link }
        }
        return nil
    }

    static func find(in text: String) -> MeetingLink? {
        let range = NSRange(text.startIndex..., in: text)
        for match in detector.matches(in: text, range: range) {
            guard let raw = match.url else { continue }
            let url = unwrapRedirect(raw)
            if let provider = provider(for: url) {
                return MeetingLink(provider: provider, url: url)
            }
        }
        return nil
    }

    private static let detector =
        try! NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    /// Outlook Safe Links and Google redirects hide the real meeting URL in a query item.
    private static func unwrapRedirect(_ url: URL) -> URL {
        guard let host = url.host?.lowercased(),
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        else { return url }
        let key: String? = if isHost(host, in: "safelinks.protection.outlook.com") {
            "url"
        } else if isHost(host, in: "google.com"), url.path == "/url" {
            "q"
        } else {
            nil
        }
        guard let key, let value = items.first(where: { $0.name == key })?.value,
              let inner = URL(string: value)
        else { return url }
        return inner
    }

    /// True for `domain` itself or any subdomain of it, but not look-alikes:
    /// "acme.zoom.us" is in "zoom.us", "evilzoom.us" is not. Invites can come from
    /// anyone, so a trusted-looking Join button must only appear for real domains.
    private static func isHost(_ host: String, in domain: String) -> Bool {
        host == domain || host.hasSuffix("." + domain)
    }

    private static func provider(for url: URL) -> Provider? {
        guard let host = url.host?.lowercased() else { return nil }
        let path = url.path.lowercased()
        if isHost(host, in: "zoom.us") || isHost(host, in: "zoomgov.com"),
           ["/j/", "/my/", "/w/", "/s/", "/wc/"].contains(where: path.hasPrefix) {
            return .zoom
        }
        if isHost(host, in: "teams.microsoft.com") || host == "teams.live.com",
           path.contains("meetup-join") || path.hasPrefix("/meet") || path.hasPrefix("/l/meet") {
            return .teams
        }
        if host == "meet.google.com", path.count > 1 { return .meet }
        // Webex invites also carry help and download links; only meeting paths count.
        if isHost(host, in: "webex.com"),
           ["/meet/", "/join/", "/wbxmjs/"].contains(where: path.hasPrefix) || path.hasSuffix("/j.php") {
            return .webex
        }
        return nil
    }

    // MARK: Opening

    /// Opens the meeting straight in the native app when it's installed, skipping the
    /// browser hand-off page. Otherwise opens the link in the default browser.
    @MainActor
    func open() {
        let workspace = NSWorkspace.shared
        switch provider {
        case .zoom:
            if workspace.urlForApplication(withBundleIdentifier: "us.zoom.xos") != nil, let native = zoomAppURL {
                workspace.open(native)
                return
            }
        case .teams:
            let installed = ["com.microsoft.teams2", "com.microsoft.teams"]
                .contains { workspace.urlForApplication(withBundleIdentifier: $0) != nil }
            if installed, let native = teamsAppURL {
                workspace.open(native)
                return
            }
        case .meet, .webex:
            break
        }
        workspace.open(url)
    }

    /// https://company.zoom.us/j/123?pwd=abc&tk=x → zoommtg://company.zoom.us/join?action=join&confno=123&pwd=abc&tk=x
    ///
    /// Every original query item is carried over (webinar registrations need `tk`).
    /// Vanity `/my/` and web-client `/wc/` links deliberately stay in the browser,
    /// since the app scheme has no reliable equivalent for them.
    private var zoomAppURL: URL? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = components.host
        else { return nil }
        let parts = url.pathComponents
        guard parts.count >= 3, ["j", "w", "s"].contains(parts[1].lowercased()) else { return nil }
        var native = URLComponents()
        native.scheme = "zoommtg"
        native.host = host
        native.path = "/join"
        let ours: Set<String> = ["action", "confno"]
        native.queryItems = [URLQueryItem(name: "action", value: "join"), URLQueryItem(name: "confno", value: parts[2])]
            + (components.queryItems ?? []).filter { !ours.contains($0.name) }
        return native.url
    }

    /// https://teams.microsoft.com/l/meetup-join/... → msteams:/l/meetup-join/...
    private var teamsAppURL: URL? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        var string = "msteams:" + components.percentEncodedPath
        if let query = components.percentEncodedQuery { string += "?" + query }
        return URL(string: string)
    }
}
