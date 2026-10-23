import AppKit
import EventKit
import SwiftUI

struct CalendarItem: Identifiable, Equatable {
    let id: String
    let eventIdentifier: String?
    let title: String
    let start: Date
    let end: Date
    let isAllDay: Bool
    let location: String?
    let color: Color
    let meeting: MeetingLink?

    func isOngoing(at now: Date) -> Bool { !isAllDay && start <= now && end > now }
    func hasEnded(at now: Date) -> Bool { end <= now }

    /// Opens the video call if there is one, otherwise the event in Calendar.
    @MainActor
    func open() {
        if let meeting {
            meeting.open()
        } else if let eventIdentifier,
                  let encoded = eventIdentifier.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
                  let url = URL(string: "ical://ekevent/\(encoded)?method=show&options=more") {
            NSWorkspace.shared.open(url)
        } else if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.iCal") {
            NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
        }
    }
}

/// Loads events for a window of days around today (a week either side) and keeps
/// them current.
@MainActor
@Observable
final class CalendarService {
    enum Access { case notDetermined, granted, denied }

    static let daysBefore = 7
    static let daysAfter = 7

    private(set) var access: Access = .notDetermined
    /// Start-of-day dates from `daysBefore` days ago to `daysAfter` days ahead.
    private(set) var days: [Date] = []
    /// Advances on each minute boundary, so countdowns and "now" stay accurate.
    private(set) var now = Date()
    private var eventsByDay: [Date: [CalendarItem]] = [:]

    @ObservationIgnored private let store = EKEventStore()
    @ObservationIgnored private var minuteTimer: Timer?
    @ObservationIgnored private var observers: [(center: NotificationCenter, token: NSObjectProtocol)] = []
    @ObservationIgnored private var started = false
    @ObservationIgnored private var loadedDay: Date?
    /// Meeting-link detection runs NSDataDetector over long invite notes, so results are
    /// kept per event revision (identifier + last-modified date).
    @ObservationIgnored private var meetingCache: [String: MeetingLink?] = [:]
    @ObservationIgnored private var pendingRefresh: Task<Void, Never>?

    var today: Date { Calendar.current.startOfDay(for: now) }

    /// All-day events first, then timed events by start time.
    func events(on day: Date) -> [CalendarItem] {
        eventsByDay[day] ?? []
    }

    /// `requestingAccess: false` leaves the permission prompt to the welcome screen, so
    /// a new user isn't asked before they know what the app is.
    func start(requestingAccess: Bool = true) {
        guard !started else { return }
        started = true
        updateAccess()

        let center = NotificationCenter.default
        observers.append((center, center.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { _ in
            MainActor.assumeIsolated { self.scheduleRefresh() }
        }))
        // Midnight, a time-zone change and waking from sleep can all change "today".
        for name in [Notification.Name.NSCalendarDayChanged, .NSSystemTimeZoneDidChange] {
            observers.append((center, center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { self.refresh() }
            }))
        }
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append((workspace, workspace.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { self.tick() }
        }))
        scheduleMinuteTick()

        if access == .notDetermined, requestingAccess { requestAccess() } else { refresh() }
    }

    /// Called when the calendar is turned off in Settings.
    func stop() {
        guard started else { return }
        started = false
        minuteTimer?.invalidate()
        minuteTimer = nil
        pendingRefresh?.cancel()
        observers.forEach { $0.center.removeObserver($0.token) }
        observers.removeAll()
        eventsByDay = [:]
        meetingCache = [:]
    }

    func requestAccess() {
        store.requestFullAccessToEvents { _, _ in
            Task { @MainActor in self.refresh() }
        }
    }

    /// Cheap check when the notch opens: picks up access granted or revoked in System
    /// Settings, without re-reading events (store notifications keep those current).
    func noteOpened() {
        guard started else { return }
        let previous = access
        updateAccess()
        if access != previous { refresh() } else { now = .now }
    }

    /// The next timed event today starting within `minutes`, or one that started in
    /// the last two.
    func imminentEvent(withinMinutes minutes: Int) -> CalendarItem? {
        events(on: today).first { item in
            guard !item.isAllDay else { return false }
            let untilStart = item.start.timeIntervalSince(now)
            return untilStart <= Double(minutes) * 60 && untilStart > -120
        }
    }

    func refresh() {
        guard started else { return }
        let previousAccess = access
        updateAccess()
        now = .now
        let calendar = Calendar.current
        let today = self.today
        loadedDay = today

        // startOfDay on each step: where DST begins at midnight, "+1 day" can land at 01:00.
        let newDays = (-Self.daysBefore...Self.daysAfter).compactMap {
            calendar.date(byAdding: .day, value: $0, to: today).map(calendar.startOfDay(for:))
        }
        if newDays != days { days = newDays }

        guard access == .granted, let rangeStart = newDays.first, let lastDay = newDays.last,
              let rangeEnd = calendar.date(byAdding: .day, value: 1, to: lastDay).map(calendar.startOfDay(for:))
        else {
            if !eventsByDay.isEmpty { eventsByDay = [:] }
            return
        }
        if previousAccess != .granted { store.reset() }

        let predicate = store.predicateForEvents(withStart: rangeStart, end: rangeEnd, calendars: nil)
        var buckets: [Date: [CalendarItem]] = [:]
        var seenMeetingKeys = Set<String>()
        for event in store.events(matching: predicate) where event.status != .canceled && !Self.isDeclined(event) {
            let item = item(from: event, seenMeetingKeys: &seenMeetingKeys)
            // Multi-day events appear on every day they touch.
            var day = max(calendar.startOfDay(for: event.startDate), rangeStart)
            repeat {
                buckets[day, default: []].append(item)
                guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
                day = calendar.startOfDay(for: next)
            } while day < event.endDate && day < rangeEnd
        }
        for (day, items) in buckets {
            buckets[day] = items.sorted { a, b in
                if a.isAllDay != b.isAllDay { return a.isAllDay }
                return a.start < b.start
            }
        }
        if buckets != eventsByDay { eventsByDay = buckets }
        meetingCache = meetingCache.filter { seenMeetingKeys.contains($0.key) }
    }

    /// A calendar sync posts store changes in bursts; refetch once it settles.
    private func scheduleRefresh() {
        pendingRefresh?.cancel()
        pendingRefresh = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            refresh()
        }
    }

    func openPrivacySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!
        NSWorkspace.shared.open(url)
    }

    // MARK: Private

    private func tick() {
        now = .now
        if today != loadedDay { refresh() }
    }

    /// Fires just after each minute boundary rather than on a free-running interval,
    /// so a "2 minutes before" countdown appears on time instead of up to 30 s late.
    private func scheduleMinuteTick() {
        minuteTimer?.invalidate()
        let nextMinute = (Date.now.timeIntervalSinceReferenceDate / 60).rounded(.down) * 60 + 60.2
        let timer = Timer(fire: Date(timeIntervalSinceReferenceDate: nextMinute), interval: 0, repeats: false) { _ in
            MainActor.assumeIsolated {
                self.tick()
                self.scheduleMinuteTick()
            }
        }
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        minuteTimer = timer
    }

    private func updateAccess() {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: access = .granted
        case .notDetermined: access = .notDetermined
        default: access = .denied
        }
    }

    private static func isDeclined(_ event: EKEvent) -> Bool {
        event.attendees?.first(where: \.isCurrentUser)?.participantStatus == .declined
    }

    private func item(from event: EKEvent, seenMeetingKeys: inout Set<String>) -> CalendarItem {
        let location = event.location?.trimmingCharacters(in: .whitespacesAndNewlines)
        let revision = event.lastModifiedDate?.timeIntervalSince1970 ?? 0
        // A detached occurrence (one edited on its own) can carry a different link from
        // its series, so it gets its own entry; ordinary occurrences share the series'.
        let occurrence = event.isDetached ? "-\(event.occurrenceDate?.timeIntervalSince1970 ?? 0)" : ""
        let meetingKey = "\(event.calendarItemIdentifier)-\(revision)\(occurrence)"
        seenMeetingKeys.insert(meetingKey)
        let meeting: MeetingLink?
        if let cached = meetingCache[meetingKey] {
            meeting = cached
        } else {
            meeting = MeetingLink.find(in: event)
            meetingCache[meetingKey] = meeting
        }
        return CalendarItem(
            // Recurring events share an identifier, so add the occurrence's start.
            id: "\(event.calendarItemIdentifier)-\(event.startDate.timeIntervalSince1970)",
            eventIdentifier: event.eventIdentifier,
            title: event.title?.isEmpty == false ? event.title : "Untitled",
            start: event.startDate,
            end: event.endDate,
            isAllDay: event.isAllDay,
            location: location?.isEmpty == false ? location : nil,
            color: Color(nsColor: event.calendar.color),
            meeting: meeting
        )
    }
}
