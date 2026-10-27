import SwiftUI

enum NotchState: Equatable {
    /// Looks like the hardware notch (or a live activity, if one is showing).
    case closed
    /// Pointer is resting on the notch; it swells slightly before opening.
    case arming
    case open
}

/// Small status shown on either side of the closed notch.
enum LiveActivity: Equatable {
    case music
    case charging(level: Int)
    case lowBattery(level: Int)
    case event(title: String, start: Date, color: Color)
    case volume(level: Float, muted: Bool)
    case brightness(level: Float)
    case headphones(name: String, symbol: String)
    case timer
    case timerDone

    /// Stable identity for animations, ignoring the changing payload.
    var kind: String {
        switch self {
        case .music: "music"
        case .charging: "charging"
        case .lowBattery: "lowBattery"
        case .event(let title, let start, _): "event-\(title)-\(start.timeIntervalSince1970)"
        case .volume: "volume"
        case .brightness: "brightness"
        case .headphones(let name, _): "headphones-\(name)"
        case .timer: "timer"
        case .timerDone: "timerDone"
        }
    }
}

@MainActor
@Observable
final class NotchViewModel {
    var state: NotchState = .closed
    var notchSize = CGSize(width: 185, height: 32)
    var showingCamera = false
    var showingTimer = false

    /// Body size of the open panel (excluding the top flares).
    let openSize = CGSize(width: 640, height: 244)
    let openTopRadius: CGFloat = 14

    private(set) var transient: LiveActivity?
    @ObservationIgnored private var transientTask: Task<Void, Never>?

    private let settings: AppSettings
    private let nowPlaying: NowPlayingService
    private let calendar: CalendarService
    private let timer: TimerService

    init(settings: AppSettings, nowPlaying: NowPlayingService, calendar: CalendarService, timer: TimerService) {
        self.settings = settings
        self.nowPlaying = nowPlaying
        self.calendar = calendar
        self.timer = timer
    }

    /// The highest-priority activity right now: brief events (power, volume,
    /// headphones, a finished timer), then a running timer, then music that's
    /// playing, then an imminent calendar event, then music paused in the last two
    /// minutes. A meeting that's about to start (or just has) jumps the queue.
    var activity: LiveActivity? {
        var event: LiveActivity?
        var eventIsStarting = false
        if settings.calendarEnabled, settings.eventReminderMinutes > 0,
           let item = calendar.imminentEvent(withinMinutes: settings.eventReminderMinutes) {
            event = .event(title: item.title, start: item.start, color: item.color)
            eventIsStarting = Self.startingWindow.contains(item.start.timeIntervalSince(calendar.now))
        }
        return Self.prioritise(transient: transient,
                               timerRunning: timer.isActive,
                               hasTrack: settings.showMusicActivity && nowPlaying.track != nil,
                               isPlaying: nowPlaying.isPlaying,
                               recentlyPlayed: nowPlaying.isRecentlyActive,
                               event: event,
                               eventIsStarting: eventIsStarting)
    }

    /// Seconds until the start during which a meeting takes the wings from a timer or
    /// music: from a minute before until two minutes after.
    static let startingWindow: ClosedRange<TimeInterval> = -120...60

    /// The priority rules on their own, so they can be checked without live services.
    static func prioritise(transient: LiveActivity?, timerRunning: Bool, hasTrack: Bool,
                           isPlaying: Bool, recentlyPlayed: Bool, event: LiveActivity?,
                           eventIsStarting: Bool = false) -> LiveActivity? {
        if let transient { return transient }
        // Otherwise music played all day, or a focus timer, would hide the countdown at
        // exactly the moment it's for.
        if let event, eventIsStarting { return event }
        if timerRunning { return .timer }
        // A playing track keeps the wings; the event countdown waits until it pauses or stops.
        if hasTrack, isPlaying { return .music }
        if let event { return event }
        // Paused music stays a while, so a quick pause doesn't make the wings flicker,
        // then goes: a paused track would otherwise cover menu-bar items beside the
        // notch indefinitely.
        if hasTrack, recentlyPlayed { return .music }
        return nil
    }

    /// Clears a finished timer's "Done" once the user has come to the notch (it stays
    /// up to a minute otherwise, in case they were away).
    func acknowledgeTimerDone() {
        guard transient == .timerDone else { return }
        transientTask?.cancel()
        transient = nil
    }

    /// Shows an activity for a few seconds, then falls back to whatever is ongoing.
    func flash(_ activity: LiveActivity, seconds: Double = 3.5) {
        transient = activity
        transientTask?.cancel()
        transientTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.transient = nil
        }
    }

    // MARK: Geometry

    /// Width of each side wing: 40 normally, a little more for the timer's "mm:ss", and
    /// just enough for a headphone name (both wings match, so the notch stays centred).
    var wingWidth: CGFloat {
        switch activity {
        case .headphones(let name, _):
            let font = NSFont.systemFont(ofSize: 11, weight: .semibold)
            let textWidth = (name as NSString).size(withAttributes: [.font: font]).width
            return min(max(textWidth.rounded(.up) + 16, 40), 110)
        case .timer:
            return 48
        case .charging:
            return CompactActivityView.chargingWingWidth
        default:
            return 40
        }
    }

    var closedWidth: CGFloat {
        activity == nil ? notchSize.width : notchSize.width + wingWidth * 2
    }

    /// Body size of the black shape for the current state.
    var shapeSize: CGSize {
        switch state {
        case .open: openSize
        case .arming: CGSize(width: closedWidth + 20, height: notchSize.height + 6)
        case .closed: CGSize(width: closedWidth, height: notchSize.height)
        }
    }

    var topRadius: CGFloat { state == .open ? openTopRadius : 5 }

    var bottomRadius: CGFloat {
        switch state {
        case .open: 26
        case .arming: 13
        case .closed: 11
        }
    }
}
