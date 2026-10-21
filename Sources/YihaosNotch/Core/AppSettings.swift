import Foundation
import Observation

enum OpenTrigger: String, CaseIterable, Identifiable {
    case hover, click
    var id: String { rawValue }
}

@MainActor
@Observable
final class AppSettings {
    static let shared = AppSettings()

    @ObservationIgnored private let defaults = UserDefaults.standard

    var openTrigger: OpenTrigger {
        didSet { defaults.set(openTrigger.rawValue, forKey: Key.openTrigger) }
    }
    /// Seconds the pointer must rest on the notch before it opens (hover mode).
    var hoverDelay: Double {
        didSet { defaults.set(hoverDelay, forKey: Key.hoverDelay) }
    }
    var hapticsEnabled: Bool {
        didSet { defaults.set(hapticsEnabled, forKey: Key.haptics) }
    }
    var showMusicActivity: Bool {
        didSet { defaults.set(showMusicActivity, forKey: Key.musicActivity) }
    }
    var showBatteryActivity: Bool {
        didSet { defaults.set(showBatteryActivity, forKey: Key.batteryActivity) }
    }
    var calendarEnabled: Bool {
        didSet { defaults.set(calendarEnabled, forKey: Key.calendar) }
    }
    /// How long before an event the notch shows a countdown. 0 turns it off.
    var eventReminderMinutes: Int {
        didSet { defaults.set(eventReminderMinutes, forKey: Key.eventReminder) }
    }

    private init() {
        let d = UserDefaults.standard
        d.register(defaults: [
            Key.openTrigger: OpenTrigger.hover.rawValue,
            Key.hoverDelay: 0.4,
            Key.haptics: true,
            Key.musicActivity: true,
            Key.batteryActivity: true,
            Key.calendar: true,
            Key.eventReminder: 5,
        ])
        openTrigger = OpenTrigger(rawValue: d.string(forKey: Key.openTrigger) ?? "") ?? .hover
        hoverDelay = d.double(forKey: Key.hoverDelay)
        hapticsEnabled = d.bool(forKey: Key.haptics)
        showMusicActivity = d.bool(forKey: Key.musicActivity)
        showBatteryActivity = d.bool(forKey: Key.batteryActivity)
        calendarEnabled = d.bool(forKey: Key.calendar)
        eventReminderMinutes = d.integer(forKey: Key.eventReminder)
    }

    private enum Key {
        static let openTrigger = "openTrigger"
        static let hoverDelay = "hoverDelay"
        static let haptics = "hapticsEnabled"
        static let musicActivity = "showMusicActivity"
        static let batteryActivity = "showBatteryActivity"
        static let calendar = "calendarEnabled"
        static let eventReminder = "eventReminderMinutes"
    }
}
