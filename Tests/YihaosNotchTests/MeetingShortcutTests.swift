import Carbon.HIToolbox
import Foundation
import SwiftUI
import Testing
@testable import YihaosNotch

/// Which meeting the join shortcut picks. Made-up events only: nothing here touches
/// EventKit or registers a real hot key.
struct MeetingShortcutTests {
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private let zoom = MeetingLink(provider: .zoom, url: URL(string: "https://zoom.us/j/1")!)

    /// An event `start` minutes from now (negative: already started), `length` long.
    private func event(_ title: String, start: Double, length: Double = 30, link: Bool = true,
                       allDay: Bool = false) -> CalendarItem {
        let begin = now.addingTimeInterval(start * 60)
        return CalendarItem(id: title, eventIdentifier: nil, title: title, start: begin,
                            end: begin.addingTimeInterval(length * 60), isAllDay: allDay, location: nil,
                            color: .blue, meeting: link ? zoom : nil)
    }

    private func pick(_ items: [CalendarItem]) -> String? {
        MeetingShortcut.meetingToJoin(in: items, at: now)?.title
    }

    @Test func nothingToJoin() {
        #expect(pick([]) == nil)
        #expect(pick([event("Later", start: 11)]) == nil)
        #expect(pick([event("Ended", start: -40)]) == nil)
        #expect(pick([event("No link", start: 2, link: false)]) == nil)
        #expect(pick([event("Holiday", start: -60, length: 24 * 60, allDay: true)]) == nil)
    }

    @Test func joinsOneStartingWithinTenMinutes() {
        #expect(pick([event("Soon", start: 10)]) == "Soon")
        #expect(pick([event("Now", start: 0)]) == "Now")
    }

    @Test func joinsOneAlreadyOnWhenLate() {
        #expect(pick([event("Late", start: -12)]) == "Late")
    }

    @Test func theOngoingMeetingWinsOverTheNext() {
        #expect(pick([event("Next", start: 4), event("Workshop", start: -50, length: 120)]) == "Workshop")
    }

    @Test func backToBackTheNextWinsOverOneWrappingUp() {
        #expect(pick([event("Ending", start: -27), event("Next", start: 3)]) == "Next")
    }

    @Test func aMeetingWrappingUpIsStillJoinedWhenNothingFollows() {
        #expect(pick([event("Ending", start: -27), event("Too far", start: 20)]) == "Ending")
    }

    @Test func overlappingOngoingMeetingsPickTheLatestStarted() {
        #expect(pick([event("Long", start: -45, length: 90), event("Recent", start: -5)]) == "Recent")
    }

    @Test func picksTheSoonestOfSeveralUpcoming() {
        #expect(pick([event("Second", start: 8), event("First", start: 2)]) == "First")
    }

    @Test func eventsWithoutLinksDontHideOnesWithThem() {
        #expect(pick([event("Focus", start: -10, length: 60, link: false), event("Call", start: 5)]) == "Call")
    }

    // MARK: The combination

    @Test func defaultIsControlOptionJ() {
        #expect(KeyCombo.joinMeetingDefault.display == "⌃⌥J")
        #expect(KeyCombo.isAcceptable(modifiers: KeyCombo.joinMeetingDefault.modifiers))
    }

    @Test(arguments: [
        (controlKey | optionKey, true),
        (cmdKey | shiftKey, true),
        (controlKey | optionKey | shiftKey | cmdKey, true),
        (cmdKey, false),        // ⌘J belongs to apps
        (controlKey, false),
        (optionKey | shiftKey, false), // types a character
        (0, false),
    ])
    func acceptsOnlyCombinationsSafeToTakeGlobally(_ modifiers: Int, _ accepted: Bool) {
        #expect(KeyCombo.isAcceptable(modifiers: UInt32(modifiers)) == accepted)
    }

    @Test func showsModifiersInMenuOrder() {
        let combo = KeyCombo(keyCode: UInt32(kVK_Space), modifiers: UInt32(cmdKey | shiftKey | controlKey),
                             key: "Space")
        #expect(combo.display == "⌃⇧⌘Space")
    }

    @Test func survivesSaving() throws {
        let data = try JSONEncoder().encode(KeyCombo.joinMeetingDefault)
        #expect(try JSONDecoder().decode(KeyCombo.self, from: data) == .joinMeetingDefault)
    }
}
