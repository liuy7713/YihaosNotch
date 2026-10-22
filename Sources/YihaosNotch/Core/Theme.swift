import SwiftUI

/// Visual language: pure black that disappears into the bezel, white text at a few
/// fixed opacities, and colour only where it carries meaning (album art, calendars,
/// battery state).
enum Theme {
    static let primary = Color.white.opacity(0.94)
    static let secondary = Color.white.opacity(0.58)
    static let tertiary = Color.white.opacity(0.36)
    static let hairline = Color.white.opacity(0.09)
    static let fill = Color.white.opacity(0.07)
    static let fillStrong = Color.white.opacity(0.13)

    static let charge = Color(red: 0.40, green: 0.86, blue: 0.50)
    static let low = Color(red: 1.00, green: 0.38, blue: 0.34)
    static let today = Color(red: 1.00, green: 0.33, blue: 0.30)

    /// Overshoots by under 1%, so the shape plus its shadow stays inside the panel
    /// window's margins even at the peak.
    static let open = Animation.spring(response: 0.42, dampingFraction: 0.85)
    /// Slightly softer than before, with a whisper of overshoot so the shape settles
    /// into the notch rather than stopping dead. Any undershoot hides inside the
    /// hardware notch.
    static let close = Animation.spring(response: 0.40, dampingFraction: 0.86)
    static let nudge = Animation.spring(response: 0.30, dampingFraction: 0.68)
    /// Swapping what an area shows (calendar ↔ camera ↔ timer, presets ↔ countdown…).
    static let swap = Animation.spring(response: 0.36, dampingFraction: 0.9)

    static func swapAnimation(reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeInOut(duration: 0.15) : swap
    }
}

extension AnyTransition {
    /// Outgoing content fades quickly; incoming content starts a beat later and
    /// settles in from slightly smaller and soft-focused, so the two never read as a
    /// double exposure. Reduce Motion gets a plain crossfade.
    static func contentSwap(reduceMotion: Bool) -> AnyTransition {
        if reduceMotion { return .opacity }
        return .asymmetric(
            insertion: .opacity
                .combined(with: .scale(scale: 0.97))
                .combined(with: .modifier(active: BlurEffect(radius: 4), identity: BlurEffect(radius: 0)))
                .animation(Theme.swap.delay(0.1)),
            removal: .opacity.animation(.easeOut(duration: 0.12))
        )
    }
}

struct BlurEffect: ViewModifier {
    let radius: CGFloat

    func body(content: Content) -> some View {
        content.blur(radius: radius)
    }
}

/// Shrinks slightly on press. Used for every tappable control in the notch.
struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.88 : 1)
            .opacity(configuration.isPressed ? 0.7 : 1)
            .animation(.spring(response: 0.2, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

/// A soft rounded highlight that appears while the pointer is over the view.
struct HoverHighlight: ViewModifier {
    var cornerRadius: CGFloat = 8
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(hovering ? Theme.fill : .clear)
            )
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.15), value: hovering)
    }
}

extension View {
    func hoverHighlight(cornerRadius: CGFloat = 8) -> some View {
        modifier(HoverHighlight(cornerRadius: cornerRadius))
    }
}
