import ApplicationServices
import SwiftUI

/// What each step says, shared by the notch panel and the overlay.
private struct CleaningCopy {
    let title: String
    let detail: String
    var caption: String?

    @MainActor
    init?(_ phase: CleanKeyboardSession.Phase, seconds: Int) {
        switch phase {
        case .leadIn:
            title = "Lift your hands"
            detail = "The keyboard and trackpad turn off for \(Self.duration(seconds))."
            caption = "Esc cancels."
        case .waitingForHands:
            title = "Lift your hands"
            detail = "It starts as soon as nothing is pressed."
            caption = "Esc cancels."
        case .cleaning:
            title = "Keyboard and trackpad are off"
            detail = "Wipe away. They come back on their own."
            caption = "To stop early, press Touch ID. It locks the Mac."
        case .done:
            title = "Back on"
            detail = "The keyboard and trackpad work again."
        default:
            return nil
        }
    }

    static func duration(_ seconds: Int) -> String {
        seconds == 60 ? "a minute" : "\(seconds) seconds"
    }
}

/// Whole seconds left until `until`, rounded up (so it reads 3, 2, 1, never 0).
private func secondsLeft(until: UInt64, now: UInt64 = Monotonic.now()) -> Int {
    until > now ? Int((Double(until - now) / 1_000_000_000).rounded(.up)) : 0
}

private func fractionLeft(until: UInt64, seconds: Int, now: UInt64 = Monotonic.now()) -> Double {
    guard until > now, seconds > 0 else { return 0 }
    return min(Double(until - now) / Double(Monotonic.nanoseconds(Double(seconds))), 1)
}

/// Takes the panel's body from "Clean Keyboard" until "Back on" has shown, and for the
/// permission and refusal cards. Laid out like the converting panel: the big number on
/// the left, the words on the right.
struct CleanKeyboardPanel: View {
    @Environment(CleanKeyboardSession.self) private var session
    @Environment(AppSettings.self) private var settings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .topTrailing) {
            switch session.phase {
            case .needsPermission(let prompted):
                PermissionCard(prompted: prompted)
            case .refused(let refusal):
                card(symbol: "exclamationmark.triangle.fill", title: refusal.title, detail: refusal.detail)
            default:
                running
            }
            switch session.phase {
            case .needsPermission, .refused:
                CloseButton { session.dismiss() }
            default:
                EmptyView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(Theme.swapAnimation(reduceMotion: reduceMotion), value: session.phase)
    }

    private var running: some View {
        HStack(alignment: .center, spacing: 24) {
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !session.phase.isRunning)) { context in
                countdown
            }
            .frame(width: 220, alignment: .leading)
            Divider().overlay(Theme.hairline).padding(.vertical, 8)
            words
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var countdown: some View {
        let phase = session.phase
        VStack(alignment: .leading, spacing: 12) {
            Group {
                switch phase {
                case .leadIn(let until):
                    Text("\(max(secondsLeft(until: until), 1))")
                        .contentTransition(.numericText(countsDown: true))
                case .cleaning(let until, _):
                    Text("\(max(secondsLeft(until: until), 1))")
                        .contentTransition(.numericText(countsDown: true))
                case .waitingForHands:
                    Image(systemName: "hand.raised.fill")
                        .font(.system(size: 34, weight: .semibold))
                case .done:
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 38, weight: .semibold))
                        .foregroundStyle(Theme.charge)
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                default:
                    EmptyView()
                }
            }
            .font(.system(size: 44, weight: .semibold, design: .rounded).monospacedDigit())
            .foregroundStyle(Theme.primary)
            .frame(height: 52, alignment: .leading)
            .animation(.snappy(duration: 0.3), value: phase)
            .animation(.snappy(duration: 0.3), value: shownSeconds(phase))

            // Drains over the cleaning time; full for the lead-in, gone when done.
            GeometryReader { geometry in
                let fraction: Double = switch phase {
                case .cleaning(let until, let seconds): fractionLeft(until: until, seconds: seconds)
                case .leadIn, .waitingForHands: 1
                default: 0
                }
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.fillStrong)
                    Capsule().fill(Theme.primary)
                        .frame(width: geometry.size.width * fraction)
                }
            }
            .frame(width: 180, height: 4)
            .opacity(phase == .done ? 0 : 1)
            .accessibilityHidden(true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityCountdown(phase))
    }

    private func shownSeconds(_ phase: CleanKeyboardSession.Phase) -> Int {
        switch phase {
        case .leadIn(let until), .cleaning(let until, _): secondsLeft(until: until)
        default: -1
        }
    }

    private func accessibilityCountdown(_ phase: CleanKeyboardSession.Phase) -> String {
        switch phase {
        case .leadIn(let until): "Starting in \(secondsLeft(until: until)) seconds"
        case .cleaning(let until, _): "\(secondsLeft(until: until)) seconds left"
        default: ""
        }
    }

    @ViewBuilder
    private var words: some View {
        if let copy = CleaningCopy(session.phase, seconds: duration) {
            VStack(alignment: .leading, spacing: 8) {
                Text(copy.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.primary)
                Text(copy.detail)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(alignment: .center) {
                    if let caption = copy.caption {
                        Text(caption)
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.tertiary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    switch session.phase {
                    case .leadIn, .waitingForHands:
                        Button("Cancel") { session.cancel() }
                            .buttonStyle(PillButtonStyle())
                    default:
                        EmptyView()
                    }
                }
                .padding(.top, 2)
            }
            .padding(.trailing, 30)
            .id(copy.title)
            .transition(.opacity)
        }
    }

    private var duration: Int {
        CleanKeyboardSession.clampedSeconds(settings.cleanKeyboardDuration)
    }

    private func card(symbol: String, title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.primary)
                .symbolRenderingMode(.multicolor)
            Text(detail)
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.trailing, 30)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// Clean Keyboard needs Accessibility. Asking shows the system dialog once; after that,
/// the button opens the setting. A grant never starts cleaning by itself.
private struct PermissionCard: View {
    let prompted: Bool
    @Environment(CleanKeyboardSession.self) private var session

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Clean Keyboard needs Accessibility", systemImage: "keyboard")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.primary)
            Text("macOS only lets an app with Accessibility access pause the keyboard and trackpad. Yihao's Notch uses it only while cleaning, and for volume and brightness if that's on.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondary)
                .lineLimit(4)
                .fixedSize(horizontal: false, vertical: true)
            Button(prompted ? "Open Settings…" : "Allow") {
                if prompted {
                    NSWorkspace.shared.open(URL(string:
                        "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                } else {
                    // The value of kAXTrustedCheckOptionPrompt, which Swift 6 won't read as a global.
                    AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
                    session.notePermissionPrompted()
                }
            }
            .buttonStyle(PillButtonStyle(prominent: true))
            .padding(.top, 2)
        }
        .padding(.trailing, 30)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

/// The overlay's content: a light dim, and the countdown big in the middle.
struct CleaningOverlayView: View {
    @Environment(CleanKeyboardSession.self) private var session
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Color.black.opacity(0.3)
            TimelineView(.periodic(from: .now, by: 0.25)) { context in
                card
            }
        }
        .ignoresSafeArea()
    }

    @ViewBuilder
    private var card: some View {
        let phase = session.phase
        if let copy = CleaningCopy(phase, seconds: seconds(phase)) {
            VStack(spacing: 12) {
                Group {
                    switch phase {
                    case .leadIn(let until), .cleaning(let until, _):
                        Text("\(max(secondsLeft(until: until), 1))")
                    case .waitingForHands:
                        Image(systemName: "hand.raised.fill")
                            .font(.system(size: 64, weight: .semibold))
                    default:
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 64, weight: .semibold))
                            .foregroundStyle(Theme.charge)
                    }
                }
                .font(.system(size: 96, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(.white)
                .contentTransition(.numericText(countsDown: true))
                .frame(height: 110)
                Text(copy.title)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white)
                Text(copy.detail)
                    .font(.system(size: 14))
                    .foregroundStyle(.white.opacity(0.75))
                if let caption = copy.caption {
                    Text(caption)
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.6))
                        .padding(.top, 4)
                }
            }
            .multilineTextAlignment(.center)
            .padding(.horizontal, 48)
            .padding(.vertical, 36)
            .frame(minWidth: 380)
            .background(RoundedRectangle(cornerRadius: 32, style: .continuous).fill(.black.opacity(0.62)))
            .animation(reduceMotion ? nil : .snappy(duration: 0.3), value: phase)
            .animation(reduceMotion ? nil : .snappy(duration: 0.3), value: shownSeconds(phase))
            .accessibilityElement(children: .combine)
        }
    }

    private func shownSeconds(_ phase: CleanKeyboardSession.Phase) -> Int {
        switch phase {
        case .leadIn(let until), .cleaning(let until, _): secondsLeft(until: until)
        default: -1
        }
    }

    private func seconds(_ phase: CleanKeyboardSession.Phase) -> Int {
        if case .cleaning(_, let seconds) = phase { return seconds }
        return CleanKeyboardSession.clampedSeconds(AppSettings.shared.cleanKeyboardDuration)
    }
}
