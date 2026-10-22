import SwiftUI

/// Shown in the right column when the header clock is clicked: presets to start a
/// timer, or the running countdown with its controls.
struct TimerPanel: View {
    @Environment(TimerService.self) private var timer

    private static let presets = [1, 3, 5, 10, 15, 25, 45, 60]

    var body: some View {
        Group {
            if timer.isActive {
                running
            } else {
                presets
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .animation(.easeOut(duration: 0.18), value: timer.isActive)
    }

    private var presets: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Timer")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.secondary)
                .padding(.leading, CalendarCard.inset)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
                ForEach(Self.presets, id: \.self) { minutes in
                    Button { timer.start(minutes: minutes) } label: {
                        VStack(spacing: 0) {
                            Text("\(minutes)")
                                .font(.system(size: 16, weight: .semibold, design: .rounded).monospacedDigit())
                                .foregroundStyle(Theme.primary)
                            Text("min")
                                .font(.system(size: 9.5, weight: .medium))
                                .foregroundStyle(Theme.tertiary)
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 46)
                        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Theme.fill))
                        .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                    }
                    .buttonStyle(PressableStyle())
                    .accessibilityLabel("\(minutes) minute timer")
                }
            }
        }
    }

    private var running: some View {
        let isPaused: Bool = if case .paused = timer.phase { true } else { false }
        return VStack(alignment: .leading, spacing: 12) {
            TimelineView(.animation(minimumInterval: 1, paused: isPaused)) { context in
                let remaining = timer.remaining(at: context.date)
                VStack(alignment: .leading, spacing: 10) {
                    Text(remaining.countdownText)
                        .font(.system(size: 44, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(isPaused ? Theme.secondary : Theme.primary)
                        .contentTransition(.numericText(countsDown: true))
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Theme.fillStrong)
                            Capsule()
                                .fill(Theme.primary)
                                .frame(width: geo.size.width * (timer.total > 0 ? remaining / timer.total : 0))
                        }
                    }
                    .frame(height: 4)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Timer, \(remaining.countdownText) left")
            }
            Text(isPaused ? "Paused" : "Ends at \((Date.now + timer.remaining()).time24)")
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(Theme.tertiary)
            HStack(spacing: 6) {
                pill(isPaused ? "Resume" : "Pause", symbol: isPaused ? "play.fill" : "pause.fill") {
                    isPaused ? timer.resume() : timer.pause()
                }
                pill("1 min", symbol: "plus") { timer.addMinute() }
                Spacer(minLength: 0)
                pill(nil, symbol: "xmark") { timer.cancel() }
                    .accessibilityLabel("Cancel timer")
            }
        }
        .padding(.horizontal, CalendarCard.inset)
        .padding(.top, 4)
    }

    private func pill(_ title: String?, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.system(size: 9, weight: .bold))
                if let title { Text(title) }
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Theme.primary)
            .padding(.horizontal, title == nil ? 8 : 10)
            .frame(height: 24)
            .background(Capsule().fill(Theme.fillStrong))
            .contentShape(Capsule())
        }
        .buttonStyle(PressableStyle())
    }
}
