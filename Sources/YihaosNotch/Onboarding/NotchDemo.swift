import SwiftUI

/// A small looping animation of the top of a MacBook screen: the pointer rests on the
/// notch and it opens, then a two-finger swipe opens it again. `activeTip` follows
/// along (0 = hover, 1 = swipe) so the matching tip beside it can light up. With
/// Reduce Motion it's a still picture of the open notch.
struct NotchDemo: View {
    @Binding var activeTip: Int

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isOpen = false
    @State private var pointer = PointerSpot.away
    @State private var pointerVisible = true
    @State private var fingersVisible = false
    @State private var fingersDown = false

    private let screenSize = CGSize(width: 280, height: 178)
    private let closedSize = CGSize(width: 62, height: 13)
    private let openSize = CGSize(width: 190, height: 70)

    enum PointerSpot {
        case away, notch, leaving

        var offset: CGSize {
            switch self {
            case .away: CGSize(width: 70, height: 118)
            case .notch: CGSize(width: 4, height: 4)
            case .leaving: CGSize(width: -84, height: 128)
            }
        }
    }

    var body: some View {
        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(LinearGradient(colors: [Color(white: 0.2), Color(white: 0.1)],
                                     startPoint: .top, endPoint: .bottom))
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Theme.hairline)
            // A faint menu bar, so it reads as the top of a screen.
            Rectangle()
                .fill(Color.white.opacity(0.07))
                .frame(height: closedSize.height)

            notch

            fingers
            Image(systemName: "cursorarrow")
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.6), radius: 1.5, y: 1)
                .offset(pointer.offset)
                .opacity(pointerVisible ? 1 : 0)
        }
        .frame(width: screenSize.width, height: screenSize.height)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityHidden(true)
        .task { await loop() }
    }

    private var notch: some View {
        let size = isOpen ? openSize : closedSize
        let topRadius: CGFloat = isOpen ? 8 : 4
        return ZStack(alignment: .top) {
            NotchShape(topRadius: topRadius, bottomRadius: isOpen ? 16 : 5)
                .fill(Color.black)
            if isOpen {
                demoContent
                    .padding(.horizontal, topRadius + 14)
                    .padding(.top, 16)
                    .transition(.opacity.animation(.easeOut(duration: 0.2).delay(0.12)))
            }
        }
        .frame(width: size.width + topRadius * 2, height: size.height)
    }

    /// Placeholder shapes standing in for the music and calendar cards.
    private var demoContent: some View {
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(LinearGradient(colors: [Color(red: 1, green: 0.45, blue: 0.38), Color(red: 0.62, green: 0.2, blue: 0.42)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 38, height: 38)
            VStack(alignment: .leading, spacing: 6) {
                Capsule().fill(Theme.primary).frame(width: 52, height: 5)
                Capsule().fill(Theme.tertiary).frame(width: 36, height: 4)
                Capsule().fill(Theme.fillStrong).frame(width: 60, height: 3).padding(.top, 6)
            }
            .padding(.top, 4)
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: 7) {
                ForEach(Array([Theme.today, Color.blue, Theme.charge].enumerated()), id: \.offset) { _, color in
                    HStack(spacing: 5) {
                        Circle().fill(color).frame(width: 5, height: 5)
                        Capsule().fill(Theme.secondary).frame(width: 34, height: 4)
                    }
                }
            }
            .padding(.top, 3)
        }
    }

    private var fingers: some View {
        HStack(spacing: 7) {
            Circle().fill(.white.opacity(0.85)).frame(width: 10, height: 10)
            Circle().fill(.white.opacity(0.85)).frame(width: 10, height: 10)
        }
        .shadow(color: .black.opacity(0.4), radius: 2)
        .offset(y: fingersDown ? 46 : 18)
        .opacity(fingersVisible ? 1 : 0)
    }

    private func loop() async {
        if reduceMotion {
            isOpen = true
            pointerVisible = false
            return
        }
        while !Task.isCancelled {
            // Hover.
            activeTip = 0
            pointer = .away
            withAnimation(.easeOut(duration: 0.3)) { pointerVisible = true }
            guard await pause(0.7) else { return }
            withAnimation(.easeInOut(duration: 0.9)) { pointer = .notch }
            guard await pause(1.3) else { return }
            withAnimation(Theme.open) { isOpen = true }
            guard await pause(2.0) else { return }
            withAnimation(.easeInOut(duration: 0.8)) { pointer = .leaving }
            guard await pause(0.25) else { return }
            withAnimation(Theme.close) { isOpen = false }
            guard await pause(0.9) else { return }

            // Two-finger swipe.
            activeTip = 1
            withAnimation(.easeOut(duration: 0.25)) { pointerVisible = false }
            fingersDown = false
            withAnimation(.easeOut(duration: 0.2)) { fingersVisible = true }
            guard await pause(0.45) else { return }
            withAnimation(.easeIn(duration: 0.35)) { fingersDown = true }
            guard await pause(0.2) else { return }
            withAnimation(Theme.open) { isOpen = true }
            withAnimation(.easeOut(duration: 0.25)) { fingersVisible = false }
            guard await pause(2.0) else { return }
            withAnimation(Theme.close) { isOpen = false }
            guard await pause(1.0) else { return }
        }
    }

    /// Sleeps, returning false once the view has gone (the task is cancelled).
    private func pause(_ seconds: Double) async -> Bool {
        try? await Task.sleep(for: .seconds(seconds))
        return !Task.isCancelled
    }
}
