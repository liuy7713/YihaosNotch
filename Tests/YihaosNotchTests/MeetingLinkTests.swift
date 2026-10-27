import Foundation
import Testing
@testable import YihaosNotch

/// Invites can come from anyone, so Join must only ever appear for real meeting links,
/// and only ever open https.
struct MeetingLinkTests {
    @Test func findsAZoomLink() throws {
        let link = try #require(MeetingLink.find(in: "Join at https://acme.zoom.us/j/123?pwd=abc please"))
        #expect(link.provider == .zoom)
        #expect(link.url.absoluteString == "https://acme.zoom.us/j/123?pwd=abc")
    }

    @Test(arguments: [
        "https://evilzoom.us/j/123",
        "https://zoom.us.evil.com/j/123",
        "https://teams.microsoft.com.evil.com/l/meetup-join/x",
        "https://meet.google.com.evil.com/abc-defg-hij",
    ])
    func ignoresLookAlikeDomains(_ text: String) {
        #expect(MeetingLink.find(in: text) == nil)
    }

    @Test func rebuildsAsHttpsWithoutCredentials() throws {
        let link = try #require(MeetingLink.find(in: "http://user:secret@zoom.us/j/1"))
        #expect(link.url.absoluteString == "https://zoom.us/j/1")
    }

    @Test(arguments: ["zoommtg://zoom.us/join?confno=1", "file:///zoom.us/j/1", "smb://zoom.us/j/1"])
    func ignoresNonWebSchemes(_ text: String) {
        #expect(MeetingLink.find(in: text) == nil)
    }

    @Test func unwrapsOutlookSafeLinks() throws {
        let wrapped = "https://eur01.safelinks.protection.outlook.com/?url=https%3A%2F%2Fteams.microsoft.com%2Fl%2Fmeetup-join%2Fabc&data=x"
        let link = try #require(MeetingLink.find(in: wrapped))
        #expect(link.provider == .teams)
        #expect(link.url.host == "teams.microsoft.com")
    }

    @Test func unwrapsGoogleRedirects() throws {
        let link = try #require(MeetingLink.find(in: "https://www.google.com/url?q=https://meet.google.com/abc-defg-hij&sa=D"))
        #expect(link.provider == .meet)
    }

    @Test func webexMeetingsButNotItsHelpPages() {
        #expect(MeetingLink.find(in: "https://acme.webex.com/meet/jane")?.provider == .webex)
        #expect(MeetingLink.find(in: "https://help.webex.com/en-us/article/abc") == nil)
    }

    @Test func aBareMeetHostIsNotAMeeting() {
        #expect(MeetingLink.find(in: "https://meet.google.com/") == nil)
    }

    @Test func zoomOpensInItsAppWithOnlyTheJoinParameters() throws {
        let link = MeetingLink(provider: .zoom, url: try #require(URL(string: "https://acme.zoom.us/j/123?pwd=abc&evil=1&tk=t")))
        #expect(link.zoomAppURL?.absoluteString == "zoommtg://acme.zoom.us/join?action=join&confno=123&pwd=abc&tk=t")
    }

    @Test func zoomPersonalLinksStayInTheBrowser() throws {
        let link = MeetingLink(provider: .zoom, url: try #require(URL(string: "https://acme.zoom.us/my/jane")))
        #expect(link.zoomAppURL == nil)
    }

    @Test func teamsOpensInItsApp() throws {
        let link = MeetingLink(provider: .teams, url: try #require(URL(string: "https://teams.microsoft.com/l/meetup-join/19%3ameeting/0?context=x")))
        #expect(link.teamsAppURL?.absoluteString == "msteams:/l/meetup-join/19%3ameeting/0?context=x")
    }
}
