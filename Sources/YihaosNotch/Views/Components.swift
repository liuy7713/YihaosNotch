import SwiftUI

/// A small battery outline that fills to `level`.
struct BatteryGlyph: View {
    let level: Int
    let charging: Bool

    private var fillColor: Color {
        if charging { return Theme.charge }
        if level <= 20 { return Theme.low }
        return Theme.primary
    }

    var body: some View {
        HStack(spacing: 1) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                    .strokeBorder(Theme.tertiary, lineWidth: 1)
                RoundedRectangle(cornerRadius: 1.8, style: .continuous)
                    .fill(fillColor)
                    .frame(width: max(2, 18 * CGFloat(min(level, 100)) / 100))
                    .padding(2)
            }
            .frame(width: 24, height: 12)
            RoundedRectangle(cornerRadius: 1, style: .continuous)
                .fill(Theme.tertiary)
                .frame(width: 1.5, height: 4.5)
        }
    }
}

/// Four bars that move while music plays and rest, still and dimmed, while paused.
/// Purely decorative: reading real audio levels would need a system-audio capture
/// permission, which isn't worth it here.
struct AudioBars: View {
    let color: Color
    let isPlaying: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        AudioBarsLayerView(color: NSColor(color), animating: isPlaying && !reduceMotion)
            .frame(width: AudioBarsNSView.contentWidth, height: AudioBarsNSView.contentHeight)
            .opacity(isPlaying ? 1 : 0.55)
            .animation(.easeOut(duration: 0.35), value: isPlaying)
            .accessibilityHidden(true)
    }
}

private struct AudioBarsLayerView: NSViewRepresentable {
    let color: NSColor
    let animating: Bool

    func makeNSView(context: Context) -> AudioBarsNSView { AudioBarsNSView() }

    func updateNSView(_ view: AudioBarsNSView, context: Context) {
        view.update(color: color, animating: animating)
    }
}

/// The bars are Core Animation layers with repeating keyframe animations. The render
/// server plays them, so the app does no per-frame work at all while music plays
/// (a SwiftUI timeline would re-run view code ~30 times a second, all day).
final class AudioBarsNSView: NSView {
    static let barWidth: CGFloat = 2.5
    static let spacing: CGFloat = 2
    static let contentWidth = barWidth * 4 + spacing * 3
    static let contentHeight: CGFloat = 14

    /// Still shape shown while paused.
    private static let restHeights: [CGFloat] = [4, 6, 5, 3.5]
    /// One loop per bar. Each starts and ends at that bar's rest height, so resuming
    /// from pause doesn't jump and each loop is seamless.
    private static let keyframes: [[CGFloat]] = [
        [4, 11, 6, 13, 5, 9, 4],
        [6, 4, 12, 7, 14, 5, 6],
        [5, 13, 4, 10, 7, 12, 5],
        [3.5, 9, 13, 5, 10, 6, 3.5],
    ]
    /// Different, non-multiple durations so the bars never visibly sync up.
    private static let durations: [Double] = [1.9, 1.5, 1.7, 1.35]
    private static let animationKey = "dance"

    private let bars: [CALayer] = (0..<4).map { _ in CALayer() }
    private var isAnimating = false

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: Self.contentWidth, height: Self.contentHeight))
        // Layer-hosting: we own the layer tree.
        layer = CALayer()
        wantsLayer = true
        for (i, bar) in bars.enumerated() {
            bar.cornerRadius = Self.barWidth / 2
            bar.bounds = CGRect(x: 0, y: 0, width: Self.barWidth, height: Self.restHeights[i])
            layer?.addSublayer(bar)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (i, bar) in bars.enumerated() {
            bar.position = CGPoint(x: CGFloat(i) * (Self.barWidth + Self.spacing) + Self.barWidth / 2,
                                   y: bounds.midY)
        }
        CATransaction.commit()
    }

    func update(color: NSColor, animating: Bool) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.3)
        bars.forEach { $0.backgroundColor = color.cgColor }
        CATransaction.commit()

        guard animating != isAnimating else { return }
        isAnimating = animating
        animating ? startDancing() : settle()
    }

    private func startDancing() {
        for (i, bar) in bars.enumerated() {
            let animation = CAKeyframeAnimation(keyPath: "bounds.size.height")
            animation.values = Self.keyframes[i]
            animation.duration = Self.durations[i]
            animation.calculationMode = .cubic
            animation.repeatCount = .infinity
            // Slow, soft movement doesn't need ProMotion's 120 Hz: 30 frames a second
            // looks the same and lets the compositor redraw this corner a quarter as often.
            animation.preferredFrameRateRange = CAFrameRateRange(minimum: 20, maximum: 30, preferred: 30)
            bar.add(animation, forKey: Self.animationKey)
        }
    }

    /// Eases each bar from wherever it is on screen down to its rest height.
    private func settle() {
        for (i, bar) in bars.enumerated() {
            let current = bar.presentation()?.bounds.height ?? Self.restHeights[i]
            bar.removeAnimation(forKey: Self.animationKey)
            let ease = CABasicAnimation(keyPath: "bounds.size.height")
            ease.fromValue = current
            ease.toValue = Self.restHeights[i]
            ease.duration = 0.35
            ease.timingFunction = CAMediaTimingFunction(name: .easeOut)
            bar.add(ease, forKey: "settle")
        }
    }
}

/// Album artwork, or a quiet placeholder.
struct ArtworkView: View {
    let image: NSImage?
    let size: CGFloat
    let cornerRadius: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Theme.fill)
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .transition(.opacity)
            } else {
                Image(systemName: "music.note")
                    .font(.system(size: size * 0.32, weight: .medium))
                    .foregroundStyle(Theme.tertiary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(Theme.hairline, lineWidth: 0.5)
        )
        .animation(.easeOut(duration: 0.25), value: image)
    }
}

/// Round icon button used in the panel header.
struct HeaderIconButton: View {
    let systemName: String
    /// Spoken by VoiceOver and shown as the tooltip.
    let label: String
    var active = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(active ? Color.black : Theme.secondary)
                .frame(width: 26, height: 26)
                .background(Circle().fill(active ? Theme.primary : .clear))
                .contentShape(Circle())
                .animation(.easeOut(duration: 0.2), value: active)
        }
        .buttonStyle(PressableStyle())
        .hoverHighlight(cornerRadius: 13)
        .help(label)
        .accessibilityLabel(label)
        .accessibilityAddTraits(active ? .isSelected : [])
    }
}

extension Date {
    /// Always 24-hour ("13:50"), whatever the system's 12/24-hour setting.
    var time24: String {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: self)
        return String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
    }
}

extension Double {
    /// 75 → "1:15"
    var playbackTime: String {
        // Bounded before converting: Int(_:) traps on huge values.
        guard isFinite, self >= 0, self < 1e7 else { return "0:00" }
        let total = Int(self)
        let hours = total / 3600, minutes = (total % 3600) / 60, seconds = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%d:%02d", minutes, seconds)
    }
}
