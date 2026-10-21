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

    /// Stable identity for animations, ignoring the changing payload.
    var kind: String {
        switch self {
        case .music: "music"
        case .charging: "charging"
        case .lowBattery: "lowBattery"
        case .event(let title, let start, _): "event-\(title)-\(start.timeIntervalSince1970)"
        }
    }
}

@MainActor
@Observable
final class NotchViewModel {
    var state: NotchState = .closed
    var notchSize = CGSize(width: 185, height: 32)
    var showingCamera = false

    /// Body size of the open panel (excluding the top flares).
    let openSize = CGSize(width: 640, height: 244)
    let openTopRadius: CGFloat = 14
    /// Width of each side wing of a live activity.
    let sideWidth: CGFloat = 40

    private(set) var transient: LiveActivity?
    @ObservationIgnored private var transientTask: Task<Void, Never>?

    private let settings: AppSettings
    private let nowPlaying: NowPlayingService
    private let calendar: CalendarService

    init(settings: AppSettings, nowPlaying: NowPlayingService, calendar: CalendarService) {
        self.settings = settings
        self.nowPlaying = nowPlaying
        self.calendar = calendar
    }

    /// The highest-priority activity right now: brief power events, then an
    /// imminent calendar event, then music.
    var activity: LiveActivity? {
        if let transient { return transient }
        if settings.calendarEnabled, settings.eventReminderMinutes > 0,
           let event = calendar.imminentEvent(withinMinutes: settings.eventReminderMinutes) {
            return .event(title: event.title, start: event.start, color: event.color)
        }
        // Stays while paused (the player still has a track); only quitting or a
        // full stop removes it.
        if settings.showMusicActivity, nowPlaying.track != nil {
            return .music
        }
        return nil
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

    var closedWidth: CGFloat {
        activity == nil ? notchSize.width : notchSize.width + sideWidth * 2
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
