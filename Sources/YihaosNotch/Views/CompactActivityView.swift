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
            // charger connects, and stays there when full or holding at the charge limit.
            let status = Self.chargeStatus(battery.powerState)
            HStack(spacing: 4) {
                Image(systemName: status.symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .contentTransition(.symbolEffect(.replace))
                Text(status.label)
                    .font(.system(size: 11, weight: .semibold))
                    .contentTransition(.opacity)
                    .lineLimit(1)
            }
            .foregroundStyle(status.color)
            .animation(.easeOut(duration: 0.25), value: battery.powerState)
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
        case .converting:
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.primary)
                .symbolEffect(.rotate, options: .repeat(.continuous))
        case .converted(let count, let total):
            Image(systemName: count < total ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(count == 0 ? Theme.low : count < total ? Color.yellow : Theme.charge)
        }
    }

    @ViewBuilder
    private var trailing: some View {
        switch activity {
        case .music:
            AudioBars(color: nowPlaying.accent, isPlaying: nowPlaying.isPlaying)
        case .charging:
            // The charger's rating, which macOS knows a moment after it connects.
            HStack(spacing: 5) {
                if let watts = battery.adapterWatts {
                    Text("\(watts) W")
                        .foregroundStyle(Theme.secondary)
                        .transition(.opacity)
                }
                Text("\(battery.level)%")
                    .foregroundStyle(Theme.primary)
            }
            .font(.system(size: 11, weight: .semibold).monospacedDigit())
            .lineLimit(1)
            .animation(.easeOut(duration: 0.25), value: battery.adapterWatts)
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
            let isPaused = timer.isPaused
            TimelineView(.animation(minimumInterval: 1, paused: isPaused)) { context in
                let remaining = timer.remaining(at: context.date)
                Text(remaining.compactCountdownText)
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .foregroundStyle(isPaused ? Theme.secondary : remaining <= 10 ? Theme.today : Theme.primary)
            }
        case .timerDone:
            Text("Done")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.primary)
        case .converting(let progress):
            Text("\(Int((min(max(progress, 0), 1) * 100).rounded()))%")
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .foregroundStyle(Theme.primary)
                .contentTransition(.numericText())
        case .converted(let count, let total):
            // "Failed", "3 of 4", "4 done", "Done".
            Text(count == 0 ? "Failed" : count < total ? "\(count) of \(total)" : count > 1 ? "\(count) done" : "Done")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }

    /// Symbol, word and colour for the charging wings. "Charging" and "Charged" are
    /// green like the battery's fill; "Plugged In" (on power, not charging) stays grey.
    static func chargeStatus(_ state: PowerState) -> (symbol: String, label: String, color: Color) {
        switch state {
        case .charging: ("bolt.fill", "Charging", Theme.charge)
        case .charged: ("powerplug.portrait.fill", "Charged", Theme.charge)
        case .pluggedIn: ("powerplug.portrait.fill", "Plugged In", Theme.secondary)
        case .battery: ("powerplug.portrait", "Unplugged", Theme.secondary)
        }
    }

    /// Wide enough for the longest charging word and "100 W 100%", so the wings don't
    /// change size when the state flips from "Plugged In" to "Charging".
    static let chargingWingWidth: CGFloat = {
        let font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        func width(_ text: String) -> CGFloat { (text as NSString).size(withAttributes: [.font: font]).width }
        let left = 15 + 4 + ["Charging", "Charged", "Plugged In", "Unplugged"].map(width).max()!
        let right = width("100 W") + 5 + width("100%")
        return (max(left, right) + 14).rounded(.up)
    }()

    static func speakerSymbol(level: Float, muted: Bool) -> String {
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

/// A level meter for volume and brightness: short in the wings, longer in the open
/// panel's header.
struct LevelBar: View {
    let level: Float
    var width: CGFloat = 26

    var body: some View {
        ZStack(alignment: .leading) {
            Capsule().fill(Theme.fillStrong)
            Capsule()
                .fill(Theme.primary)
                .frame(width: width * CGFloat(min(max(level, 0), 1)))
        }
        .frame(width: width, height: 4)
        .animation(.spring(response: 0.25, dampingFraction: 0.85), value: level)
        .accessibilityElement()
        .accessibilityValue(level.isFinite ? "\(Int((min(max(level, 0), 1) * 100).rounded())) percent" : "")
    }
}
