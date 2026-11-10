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
    /// Volume and brightness keys show in the notch instead of the system pop-up.
    /// Needs Accessibility permission, so it's off until turned on in Settings.
    var replaceSystemHUD: Bool {
        didSet { defaults.set(replaceSystemHUD, forKey: Key.systemHUD) }
    }
    var showHeadphonesActivity: Bool {
        didSet { defaults.set(showHeadphonesActivity, forKey: Key.headphones) }
    }
    /// How long before an event the notch shows a countdown. 0 turns it off.
    var eventReminderMinutes: Int {
        didSet { defaults.set(eventReminderMinutes, forKey: Key.eventReminder) }
    }
    /// Synced lyrics in the panel, looked up on LRCLIB.
    var showLyrics: Bool {
        didSet { defaults.set(showLyrics, forKey: Key.lyrics) }
    }
    /// Calendars left out of the panel and the countdown, by identifier. Stored as the
    /// ones hidden rather than shown, so a calendar added later appears by default.
    var hiddenCalendars: Set<String> {
        didSet { defaults.set(Array(hiddenCalendars).sorted(), forKey: Key.hiddenCalendars) }
    }
    /// The custom timer tile's length in minutes, kept between uses.
    var customTimerMinutes: Int {
        didSet { defaults.set(customTimerMinutes, forKey: Key.customTimer) }
    }
    /// Looks for a new version on GitHub once a day.
    var checkForUpdates: Bool {
        didSet { defaults.set(checkForUpdates, forKey: Key.updates) }
    }
    /// Center Stage in the camera mirror, when the camera supports it.
    var cameraCenterStage: Bool {
        didSet { defaults.set(cameraCenterStage, forKey: Key.centerStage) }
    }
    /// Files dragged onto the notch open it, to be converted.
    var convertDropEnabled: Bool {
        didSet { defaults.set(convertDropEnabled, forKey: Key.convertDrop) }
    }
    var convertSaveLocation: SaveLocation {
        didSet { defaults.set(convertSaveLocation.rawValue, forKey: Key.convertSave) }
    }
    /// The folder for `SaveLocation.folder`, as a path.
    var convertFolder: String {
        didSet { defaults.set(convertFolder, forKey: Key.convertFolder) }
    }
    /// Converted photos leave out where they were taken.
    var convertStripLocation: Bool {
        didSet { defaults.set(convertStripLocation, forKey: Key.convertStripLocation) }
    }
    /// Documents go through Microsoft Word when it's installed.
    var convertUseWord: Bool {
        didSet { defaults.set(convertUseWord, forKey: Key.convertWord) }
    }
    /// The version of the welcome screen last finished. It shows at launch while this is
    /// behind `Self.welcomeVersion`; raise that when the welcome gains something worth
    /// seeing again.
    private(set) var welcomeCompleted: Int {
        didSet { defaults.set(welcomeCompleted, forKey: Key.welcome) }
    }

    /// 2: the tour gained converting.
    nonisolated static let welcomeVersion = 2
    var needsWelcome: Bool { Self.needsWelcome(completed: welcomeCompleted) }
    /// Never finished any welcome: permissions haven't been asked for yet. (Someone
    /// who finished an older one sees only the tour again.)
    var isFirstRun: Bool { welcomeCompleted == 0 }

    /// Every release before 1.7 saved 1 on finishing the welcome (or 0 before it was
    /// ever finished): updaters from those see the tour again.
    nonisolated static func needsWelcome(completed: Int) -> Bool { completed < welcomeVersion }
    func completeWelcome() { welcomeCompleted = Self.welcomeVersion }

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
            Key.systemHUD: false,
            Key.headphones: true,
            Key.welcome: 0,
            Key.centerStage: true,
            Key.lyrics: true,
            Key.customTimer: TimerDurations.defaultCustom,
            Key.updates: true,
            Key.convertDrop: true,
            Key.convertSave: SaveLocation.downloads.rawValue,
            Key.convertStripLocation: true,
            Key.convertWord: true,
        ])
        openTrigger = OpenTrigger(rawValue: d.string(forKey: Key.openTrigger) ?? "") ?? .hover
        hoverDelay = d.double(forKey: Key.hoverDelay)
        hapticsEnabled = d.bool(forKey: Key.haptics)
        showMusicActivity = d.bool(forKey: Key.musicActivity)
        showBatteryActivity = d.bool(forKey: Key.batteryActivity)
        calendarEnabled = d.bool(forKey: Key.calendar)
        eventReminderMinutes = d.integer(forKey: Key.eventReminder)
        replaceSystemHUD = d.bool(forKey: Key.systemHUD)
        showHeadphonesActivity = d.bool(forKey: Key.headphones)
        welcomeCompleted = d.integer(forKey: Key.welcome)
        cameraCenterStage = d.bool(forKey: Key.centerStage)
        showLyrics = d.bool(forKey: Key.lyrics)
        customTimerMinutes = min(max(d.integer(forKey: Key.customTimer), 1), TimerService.maxMinutes)
        hiddenCalendars = Set(d.stringArray(forKey: Key.hiddenCalendars) ?? [])
        checkForUpdates = d.bool(forKey: Key.updates)
        convertDropEnabled = d.bool(forKey: Key.convertDrop)
        convertSaveLocation = SaveLocation(rawValue: d.string(forKey: Key.convertSave) ?? "") ?? .downloads
        convertFolder = d.string(forKey: Key.convertFolder) ?? ""
        convertStripLocation = d.bool(forKey: Key.convertStripLocation)
        convertUseWord = d.bool(forKey: Key.convertWord)
    }

    private enum Key {
        static let openTrigger = "openTrigger"
        static let hoverDelay = "hoverDelay"
        static let haptics = "hapticsEnabled"
        static let musicActivity = "showMusicActivity"
        static let batteryActivity = "showBatteryActivity"
        static let calendar = "calendarEnabled"
        static let eventReminder = "eventReminderMinutes"
        static let systemHUD = "replaceSystemHUD"
        static let headphones = "showHeadphonesActivity"
        static let welcome = "welcomeCompleted"
        static let centerStage = "cameraCenterStage"
        static let lyrics = "showLyrics"
        static let customTimer = "customTimerMinutes"
        static let hiddenCalendars = "hiddenCalendars"
        static let updates = "checkForUpdates"
        static let convertDrop = "convertDropEnabled"
        static let convertSave = "convertSaveLocation"
        static let convertFolder = "convertFolder"
        static let convertStripLocation = "convertStripLocation"
        static let convertWord = "convertUseWord"
    }
}
