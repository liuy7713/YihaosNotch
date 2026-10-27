import SwiftUI
import Testing
@testable import YihaosNotch

/// What the closed notch shows when several things want it at once.
@MainActor
struct PriorityTests {
    let event = LiveActivity.event(title: "Standup", start: Date(timeIntervalSince1970: 0), color: .blue)

    func pick(transient: LiveActivity? = nil, timer: Bool = false, track: Bool = false,
              playing: Bool = false, recent: Bool = false, event: LiveActivity? = nil) -> LiveActivity? {
        NotchViewModel.prioritise(transient: transient, timerRunning: timer, hasTrack: track,
                                  isPlaying: playing, recentlyPlayed: recent, event: event)
    }

    @Test func aFlashBeatsEverything() {
        let volume = LiveActivity.volume(level: 0.5, muted: false)
        #expect(pick(transient: volume, timer: true, track: true, playing: true, recent: true, event: event) == volume)
    }

    @Test func aRunningTimerBeatsMusicAndEvents() {
        #expect(pick(timer: true, track: true, playing: true, event: event) == .timer)
    }

    @Test func playingMusicBeatsAnEvent() {
        #expect(pick(track: true, playing: true, recent: true, event: event) == .music)
    }

    @Test func anEventBeatsRecentlyPausedMusic() {
        #expect(pick(track: true, recent: true, event: event) == event)
    }

    @Test func pausedMusicStaysForAWhileThenGoes() {
        #expect(pick(track: true, recent: true) == .music)
        #expect(pick(track: true, recent: false) == nil)
    }

    @Test func nothingToShow() {
        #expect(pick() == nil)
    }
}
