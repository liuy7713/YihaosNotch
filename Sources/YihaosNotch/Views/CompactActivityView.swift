import SwiftUI

/// Content for the two wings either side of the closed notch.
struct CompactActivityView: View {
    let activity: LiveActivity

    @Environment(NotchViewModel.self) private var model
    @Environment(NowPlayingService.self) private var nowPlaying
    @Environment(BatteryService.self) private var battery

    var body: some View {
        HStack(spacing: 0) {
            leading
                .frame(width: model.sideWidth, alignment: .center)
            Spacer(minLength: model.notchSize.width)
            trailing
                .frame(width: model.sideWidth, alignment: .center)
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
        }
    }

    private func countdown(to start: Date, now: Date) -> String {
        let minutes = Int((start.timeIntervalSince(now) / 60).rounded(.up))
        return minutes <= 0 ? "now" : "\(minutes)m"
    }
}
