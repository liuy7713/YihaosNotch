import Foundation
import Observation

/// The optional "join the next meeting" shortcut (⌃⌥J unless changed): joins the call
/// that's on now or starts within 10 minutes, through the same code as the Join button.
/// Off by default, and only registered once the welcome is finished and the calendar is on.
@MainActor
@Observable
final class MeetingShortcut {
    static let shared = MeetingShortcut()

    /// Set while Settings records a new combination: pressing the current one there
    /// records it instead of joining.
    var isRecording = false {
        didSet { if isRecording != oldValue { update() } }
    }
    /// macOS refused the combination (reserved, or another app holds it exclusively).
    private(set) var isUnavailable = false

    /// Set once the welcome is finished; nothing is registered before then.
    @ObservationIgnored var isAllowed = false {
        didSet { if isAllowed != oldValue { update() } }
    }
    @ObservationIgnored var onPress: (() -> Void)? {
        didSet { hotKey.onPress = onPress }
    }

    @ObservationIgnored private let settings = AppSettings.shared
    @ObservationIgnored private let hotKey = GlobalHotKey()
    @ObservationIgnored private var registered: KeyCombo?

    private init() {}

    /// Registers or drops the hot key to match Settings. Call when they change.
    func update() {
        let wanted = isAllowed && settings.calendarEnabled && settings.joinMeetingShortcutEnabled && !isRecording
            ? settings.joinMeetingShortcut : nil
        guard wanted != registered || (wanted != nil && isUnavailable) else { return }
        hotKey.unregister()
        registered = nil
        guard let wanted else {
            isUnavailable = false
            return
        }
        if hotKey.register(wanted) {
            registered = wanted
            isUnavailable = false
        } else {
            isUnavailable = true
        }
    }

    // MARK: Choosing the meeting

    /// How far ahead a meeting counts as "next": the Join button turns solid then too.
    nonisolated static let lead: TimeInterval = 10 * 60
    /// A meeting with this little left is wrapping up: the next one wins over it.
    nonisolated static let wrappingUp: TimeInterval = 5 * 60

    /// The meeting the shortcut joins, from `items`: timed events with a meeting link
    /// that haven't ended and start within `lead`.
    ///
    /// The one that's on wins (the latest to start, if several overlap), so being a few
    /// minutes late still joins it. Back to back, a meeting in its last five minutes
    /// gives way to the one starting next. Otherwise the soonest to start.
    nonisolated static func meetingToJoin(in items: [CalendarItem], at now: Date) -> CalendarItem? {
        let joinable = items.filter {
            !$0.isAllDay && $0.meeting != nil && $0.end > now && $0.start.timeIntervalSince(now) <= lead
        }
        let ongoing = joinable.filter { $0.start <= now }.sorted { $0.start > $1.start }
        let upcoming = joinable.filter { $0.start > now }.sorted { $0.start < $1.start }
        if let current = ongoing.first(where: { $0.end.timeIntervalSince(now) > wrappingUp }) { return current }
        return upcoming.first ?? ongoing.first
    }
}

extension CalendarService {
    /// What the shortcut would join right now. Tomorrow's events count too, for a
    /// meeting just after midnight.
    func meetingToJoin(at now: Date = .now) -> CalendarItem? {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today).map(calendar.startOfDay(for:))
        var seen = Set<String>()
        // Multi-day events are listed on each day they touch.
        let items = ([today] + [tomorrow].compactMap { $0 }).flatMap(events(on:)).filter { seen.insert($0.id).inserted }
        return MeetingShortcut.meetingToJoin(in: items, at: now)
    }
}
