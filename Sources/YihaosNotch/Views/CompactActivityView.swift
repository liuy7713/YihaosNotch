import SwiftUI

/// Content for the two wings either side of the closed notch.
struct CompactActivityView: View {
    let activity: LiveActivity

    @Environment(NotchViewModel.self) private var model
    @Environment(NowPlayingService.self) private var nowPlaying
    @Environment(BatteryService.self) private var battery
    @Environment(TimerService.self) private var timer

    var body: some View {
        HStack(spacing: 0) {
            leading
                .frame(width: model.wingWidth, alignment: .center)
            Spacer(minLength: model.notchSize.width)
            trailing
                .frame(width: model.wingWidth, alignment: .center)
        }
        .frame(width: model.closedWidth, height: model.notchSize.height)
    }

    @ViewBuilder
    private var leading: some View {
        switch activity {
        case .music:
            ArtworkView(image: nowPlaying.artwork, size: 20, cornerRadius: 5)
        case .charging:
            // Reads the live state: macOS reports "not charging" for a moment after the
            // charger connects, and stays there when full or holding at the optimised limit.
            Image(systemName: battery.isCharging ? "bolt.fill" : "powerplug.portrait.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(battery.isCharging ? Theme.charge : Theme.secondary)
                .contentTransition(.symbolEffect(.replace))
        case .lowBattery(let level):
            BatteryGlyph(level: level, charging: false)
                .scaleEffect(0.85)
        case .event(_, _, let color):
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
        case .volume(let level, let muted):
            Image(systemName: Self.speakerSymbol(level: level, muted: muted))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.primary)
                .contentTransition(.symbolEffect(.replace))
        case .brightness(let level):
            Image(systemName: level < 0.5 ? "sun.min.fill" : "sun.max.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.primary)
                .contentTransition(.symbolEffect(.replace))
        case .headphones(_, let symbol):
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.primary)
        case .timer:
            Image(systemName: "timer")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.primary)
        case .timerDone:
            Image(systemName: "timer")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.today)
                .symbolEffect(.bounce, options: .repeat(2))
        }
    }

    @ViewBuilder
    private var trailing: some View {
        switch activity {
        case .music:
            AudioBars(color: nowPlaying.accent, isPlaying: nowPlaying.isPlaying)
        case .charging(let level):
            Text("\(level)%")
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .foregroundStyle(Theme.primary)
        case .lowBattery(let level):
            Text("\(level)%")
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .foregroundStyle(Theme.low)
        case .event(_, let start, _):
            TimelineView(.periodic(from: .now, by: 15)) { context in
                Text(countdown(to: start, now: context.date))
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Theme.primary)
            }
        case .volume(let level, let muted):
            LevelBar(level: muted ? 0 : level)
        case .brightness(let level):
            LevelBar(level: level)
        case .headphones(let name, _):
            Text(name)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.primary)
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.horizontal, 6)
        case .timer:
            let isPaused: Bool = if case .paused = timer.phase { true } else { false }
            TimelineView(.animation(minimumInterval: 1, paused: isPaused)) { context in
                let remaining = timer.remaining(at: context.date)
                Text(remaining.countdownText)
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .foregroundStyle(isPaused ? Theme.secondary : remaining <= 10 ? Theme.today : Theme.primary)
            }
        case .timerDone:
            Text("Done")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.primary)
        }
    }

    private static func speakerSymbol(level: Float, muted: Bool) -> String {
        if muted || level <= 0 { return "speaker.slash.fill" }
        if level < 0.34 { return "speaker.wave.1.fill" }
        if level < 0.67 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }

    private func countdown(to start: Date, now: Date) -> String {
        let minutes = Int((start.timeIntervalSince(now) / 60).rounded(.up))
        return minutes <= 0 ? "now" : "\(minutes)m"
    }
}

/// A short level meter for volume and brightness.
private struct LevelBar: View {
    let level: Float

    var body: some View {
        ZStack(alignment: .leading) {
            Capsule().fill(Theme.fillStrong)
            Capsule()
                .fill(Theme.primary)
                .frame(width: 26 * CGFloat(min(max(level, 0), 1)))
        }
        .frame(width: 26, height: 4)
        .animation(.spring(response: 0.25, dampingFraction: 0.85), value: level)
        .accessibilityElement()
        .accessibilityValue("\(Int((level * 100).rounded())) percent")
    }
}
