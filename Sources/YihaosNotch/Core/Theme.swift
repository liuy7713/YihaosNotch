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

    static let open = Animation.spring(response: 0.42, dampingFraction: 0.80)
    static let close = Animation.spring(response: 0.34, dampingFraction: 0.92)
    static let nudge = Animation.spring(response: 0.30, dampingFraction: 0.68)
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
