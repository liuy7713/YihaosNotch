import SwiftUI

/// The expanded notch: a header row either side of the hardware notch, then Now
/// Playing on the left and Calendar (or the camera mirror, or the timer) on the right.
struct OpenPanelView: View {
    @Environment(NotchViewModel.self) private var model
    @Environment(AppSettings.self) private var settings
    @Environment(BatteryService.self) private var battery
    @Environment(CalendarService.self) private var calendar
    @Environment(TimerService.self) private var timer
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private enum RightMode { case camera, timer, calendar, clock }

    private var rightMode: RightMode {
        if model.showingCamera { return .camera }
        if model.showingTimer { return .timer }
        return settings.calendarEnabled ? .calendar : .clock
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            HStack(alignment: .top, spacing: 18) {
                // 300 + 37 (gap and divider) leaves 259 for the calendar: five 52 pt days,
                // and room for event titles beside the Join button.
                NowPlayingCard()
                    .frame(width: 300)
                Rectangle()
                    .fill(Theme.hairline)
                    .frame(width: 1)
                    .padding(.vertical, 6)
                // Both the outgoing and incoming views share the space during a swap.
                ZStack(alignment: .topLeading) {
                    rightColumn
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .animation(Theme.swapAnimation(reduceMotion: reduceMotion), value: rightMode)
            }
            .padding(.horizontal, 22)
            .padding(.top, 12)
            .padding(.bottom, 20)
        }
    }

    // Nothing may be drawn in the middle: the hardware notch covers it.
    private var header: some View {
        HStack(spacing: 0) {
            TimelineView(.everyMinute) { context in
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    // Shortened while a timer shares the space.
                    Text(context.date.formatted(.dateTime
                        .weekday(timer.isActive ? .abbreviated : .wide).day().month(.abbreviated)))
                        .foregroundStyle(Theme.secondary)
                    ClockButton(now: context.date)
                }
                .font(.system(size: 12, weight: .semibold))
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Color.clear.frame(width: model.notchSize.width + 16)

            HStack(spacing: 4) {
                HeaderIconButton(systemName: "video.fill", label: "Camera mirror", active: model.showingCamera) {
                    model.showingCamera.toggle()
                    model.showingTimer = false
                }
                HeaderIconButton(systemName: "gearshape.fill", label: "Settings") {
                    SettingsWindowController.shared.show()
                }
                batteryIndicator
                    .padding(.leading, 6)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 22)
        .frame(height: model.notchSize.height)
    }

    private var batteryIndicator: some View {
        HStack(spacing: 5) {
            if battery.isCharging {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Theme.charge)
            } else if battery.isPluggedIn {
                // On power but not charging (full, or holding at the optimised limit).
                Image(systemName: "powerplug.portrait.fill")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Theme.secondary)
            }
            Text("\(battery.level)%")
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(Theme.secondary)
            BatteryGlyph(level: battery.level, charging: battery.isCharging)
        }
    }

    @ViewBuilder
    private var rightColumn: some View {
        let swap = AnyTransition.contentSwap(reduceMotion: reduceMotion)
        switch rightMode {
        case .camera: CameraMirrorView().transition(swap)
        case .timer: TimerPanel().transition(swap)
        case .calendar: CalendarCard().transition(swap)
        case .clock: ClockView().transition(swap)
        }
    }
}

/// Shown in place of the calendar when it's turned off.
private struct ClockView: View {
    var body: some View {
        TimelineView(.everyMinute) { context in
            VStack(alignment: .leading, spacing: 2) {
                Text(context.date.time24)
                    .font(.system(size: 40, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(Theme.primary)
                Text(context.date.formatted(.dateTime.weekday(.wide).day().month(.wide)))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.tertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
    }
}

/// The header clock, which doubles as the way into the timer, so the timer needs no
/// button of its own. Hovering reveals a timer glyph to say what it does; while a
/// timer runs, its countdown sits beside the time.
private struct ClockButton: View {
    let now: Date

    @Environment(NotchViewModel.self) private var model
    @Environment(TimerService.self) private var timer
    @State private var hovering = false

    var body: some View {
        Button {
            model.showingTimer.toggle()
            model.showingCamera = false
        } label: {
            HStack(spacing: 6) {
                Text(now.time24)
                    .foregroundStyle(Theme.primary)
                if timer.isActive {
                    let isPaused: Bool = if case .paused = timer.phase { true } else { false }
                    TimelineView(.animation(minimumInterval: 1, paused: isPaused)) { context in
                        HStack(spacing: 3) {
                            Image(systemName: "timer")
                                .font(.system(size: 10, weight: .bold))
                            Text(timer.remaining(at: context.date).countdownText)
                        }
                        .foregroundStyle(Theme.secondary)
                    }
                } else if hovering || model.showingTimer {
                    Image(systemName: "timer")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Theme.secondary)
                        .transition(.opacity.combined(with: .scale(scale: 0.8)))
                }
            }
            .monospacedDigit()
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Capsule().fill(model.showingTimer ? Theme.fillStrong : hovering ? Theme.fill : .clear))
            .contentShape(Capsule())
        }
        .buttonStyle(PressableStyle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .animation(.easeOut(duration: 0.2), value: model.showingTimer)
        .animation(.easeOut(duration: 0.2), value: timer.isActive)
        .help("Timer")
        .accessibilityLabel(timer.isActive ? "Timer running" : "Timer")
    }
}
