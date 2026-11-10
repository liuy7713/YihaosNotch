import SwiftUI

/// A small looping animation of the top of a MacBook screen, in three scenes that
/// match the tips beside it (`activeTip` follows along so the right one lights up):
/// 0. the closed notch speaks up on its own: music, a meeting countdown, charging;
/// 1. resting the pointer opens it, then a two-finger swipe does;
/// 2. in the open panel, the clock, camera and gear are clicked in turn;
/// 3. a photo is dragged onto the notch, dropped, and turned into a JPEG.
/// With Reduce Motion it's a still picture of the open panel.
struct NotchDemo: View {
    @Binding var activeTip: Int
    /// For people updating: the newest scene plays first, then the usual loop.
    var startsWithNew = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isOpen = false
    @State private var wing: Wing?
    @State private var highlight: HeaderItem?
    @State private var pointer = Spot.away
    @State private var pointerVisible = false
    @State private var fingersVisible = false
    @State private var fingersDown = false
    @State private var convertStage: ConvertStage?
    @State private var file = Spot.fileStart
    @State private var fileVisible = false
    @State private var chipPressed = false

    private let screenSize = CGSize(width: 280, height: 178)
    private let closedSize = CGSize(width: 62, height: 13)
    private let openSize = CGSize(width: 230, height: 82)
    private let wingWidth: CGFloat = 30

    enum Wing { case music, meeting, charging }

    /// The converting scene's panel: the drop well, the formats, then done.
    enum ConvertStage { case drop, chips, done }

    /// The open panel's header controls, with their centres measured from the middle
    /// of the notch (the clock sits left of the hardware notch, the icons right of it).
    enum HeaderItem: CaseIterable {
        case clock, camera, gear

        var x: CGFloat {
            switch self {
            case .clock: -50
            case .camera: 46
            case .gear: 62
            }
        }
    }

    /// Where the pointer is, as an offset of its centre from the top middle. The arrow's
    /// tip sits about 4 pt left of and 6 pt above that centre.
    enum Spot: Equatable {
        case away, notch, leaving
        case item(HeaderItem)
        /// Where the photo starts, and the JPEG button in the open panel.
        case fileStart, chip

        var offset: CGSize {
            switch self {
            case .away: CGSize(width: 70, height: 118)
            case .notch: CGSize(width: 4, height: 4)
            case .leaving: CGSize(width: -84, height: 128)
            case .item(let item): CGSize(width: item.x + 4, height: 12)
            case .fileStart: CGSize(width: -78, height: 112)
            case .chip: CGSize(width: Self.chipX + 4, height: Self.chipY + 6)
            }
        }

        static let chipX: CGFloat = 8
        static let chipY: CGFloat = 46
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
            DemoFile()
                .offset(CGSize(width: file.offset.width - 2, height: file.offset.height - 8))
                .opacity(fileVisible ? 1 : 0)
                .scaleEffect(fileVisible ? 1 : 0.6)
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

    // MARK: The notch

    private var shapeSize: CGSize {
        if isOpen { return openSize }
        return CGSize(width: closedSize.width + (wing == nil ? 0 : wingWidth * 2), height: closedSize.height)
    }

    private var notch: some View {
        let topRadius: CGFloat = isOpen ? 8 : 4
        return ZStack(alignment: .top) {
            NotchShape(topRadius: topRadius, bottomRadius: isOpen ? 16 : 5)
                .fill(Color.black)
            if isOpen {
                openContent
                    .transition(.opacity.animation(.easeOut(duration: 0.2).delay(0.12)))
            } else if let wing {
                wings(wing)
                    .id(wing)
                    .transition(.opacity.animation(.easeOut(duration: 0.2)))
            }
        }
        .frame(width: shapeSize.width + topRadius * 2, height: shapeSize.height)
    }

    private func wings(_ wing: Wing) -> some View {
        HStack(spacing: 0) {
            Group {
                switch wing {
                case .music:
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(Self.artwork)
                        .frame(width: 9, height: 9)
                case .meeting:
                    Circle().fill(Color.blue).frame(width: 5, height: 5)
                case .charging:
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(Theme.charge)
                }
            }
            .frame(width: wingWidth)
            Spacer(minLength: closedSize.width)
            Group {
                switch wing {
                case .music:
                    DemoBars()
                case .meeting:
                    Text("4 min")
                        .font(.system(size: 7, weight: .semibold))
                        .foregroundStyle(Theme.primary)
                case .charging:
                    Text("65 W")
                        .font(.system(size: 7, weight: .semibold))
                        .foregroundStyle(Theme.primary)
                }
            }
            .frame(width: wingWidth)
        }
        .frame(width: closedSize.width + wingWidth * 2, height: closedSize.height)
    }

    /// The open panel in miniature: the header's clock, camera and gear at their real
    /// places, then placeholder shapes for the music and calendar cards.
    private var openContent: some View {
        ZStack(alignment: .top) {
            Capsule().fill(Theme.tertiary)
                .frame(width: 20, height: 3)
                .frame(height: closedSize.height)
                .offset(x: HeaderItem.clock.x - 26)
            Text("17:43")
                .font(.system(size: 7, weight: .semibold).monospacedDigit())
                .foregroundStyle(Theme.primary)
                .frame(width: 24, height: closedSize.height)
                .offset(x: HeaderItem.clock.x)

            ForEach([(HeaderItem.camera, "video.fill"), (.gear, "gearshape.fill")], id: \.1) { item, symbol in
                Image(systemName: symbol)
                    .font(.system(size: 6.5, weight: .semibold))
                    .foregroundStyle(Theme.secondary)
                    .frame(width: 13, height: closedSize.height)
                    .offset(x: item.x)
            }
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .strokeBorder(Theme.tertiary, lineWidth: 0.8)
                .frame(width: 11, height: 6)
                .frame(height: closedSize.height)
                .offset(x: 82)

            if let highlight {
                Capsule()
                    .strokeBorder(Theme.today, lineWidth: 1.2)
                    .frame(width: highlight == .clock ? 30 : 15, height: 15)
                    .offset(x: highlight.x, y: -1)
                    .transition(.scale(scale: 1.6).combined(with: .opacity))
            }

            if let convertStage {
                convertContent(convertStage)
                    .transition(.opacity.animation(.easeOut(duration: 0.2)))
            } else {
                demoContent
                    .padding(.horizontal, 22)
                    .padding(.top, 25)
                    .transition(.opacity.animation(.easeOut(duration: 0.2)))
            }
        }
    }

    /// The converting panel in miniature, laid out by offsets from the top middle so
    /// the pointer can land on the JPEG button.
    @ViewBuilder
    private func convertContent(_ stage: ConvertStage) -> some View {
        switch stage {
        case .drop:
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(Theme.tertiary, style: StrokeStyle(lineWidth: 0.8, dash: [3, 2.5]))
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.fill))
                .overlay {
                    VStack(spacing: 2) {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.system(size: 9, weight: .medium))
                        Text("Drop to convert")
                            .font(.system(size: 6.5, weight: .semibold))
                    }
                    .foregroundStyle(Theme.primary)
                }
                .frame(width: 186, height: 50)
                .offset(y: 23)
        case .chips, .done:
            ZStack(alignment: .top) {
                RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                    .fill(Self.artwork)
                    .frame(width: 24, height: 24)
                    .offset(x: -78, y: 30)
                VStack(alignment: .leading, spacing: 4) {
                    Capsule().fill(Theme.primary).frame(width: 34, height: 4)
                    Capsule().fill(Theme.tertiary).frame(width: 24, height: 3)
                }
                .frame(width: 40, alignment: .leading)
                .offset(x: -40, y: 36)
                if stage == .chips {
                    Text("Convert to")
                        .font(.system(size: 5.5, weight: .semibold))
                        .foregroundStyle(Theme.secondary)
                        .frame(width: 60, alignment: .leading)
                        .offset(x: Spot.chipX + 14, y: Spot.chipY - 16)
                    HStack(spacing: 3) {
                        ForEach(["JPEG", "PNG", "PDF"], id: \.self) { format in
                            Text(format)
                                .font(.system(size: 5.5, weight: .bold))
                                .foregroundStyle(format == "JPEG" ? Color.black : Theme.primary)
                                .frame(width: 20, height: 9)
                                .background(Capsule().fill(format == "JPEG" ? Theme.primary : Theme.fillStrong))
                                .scaleEffect(format == "JPEG" && chipPressed ? 0.85 : 1)
                        }
                    }
                    .frame(width: 66, alignment: .leading)
                    .offset(x: Spot.chipX + 23, y: Spot.chipY - 4.5)
                } else {
                    HStack(spacing: 3) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(Theme.charge)
                        Text("Saved to Downloads")
                            .foregroundStyle(Theme.primary)
                    }
                    .font(.system(size: 6.5, weight: .semibold))
                    .frame(width: 90, alignment: .leading)
                    .offset(x: Spot.chipX + 37, y: Spot.chipY - 10)
                    .transition(.scale(scale: 0.8).combined(with: .opacity))
                }
            }
        }
    }

    /// Placeholder shapes standing in for the music and calendar cards.
    private var demoContent: some View {
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Self.artwork)
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

    private static let artwork = LinearGradient(
        colors: [Color(red: 1, green: 0.45, blue: 0.38), Color(red: 0.62, green: 0.2, blue: 0.42)],
        startPoint: .topLeading, endPoint: .bottomTrailing)

    private var fingers: some View {
        HStack(spacing: 7) {
            Circle().fill(.white.opacity(0.85)).frame(width: 10, height: 10)
            Circle().fill(.white.opacity(0.85)).frame(width: 10, height: 10)
        }
        .shadow(color: .black.opacity(0.4), radius: 2)
        .offset(y: fingersDown ? 46 : 18)
        .opacity(fingersVisible ? 1 : 0)
    }

    // MARK: Timeline

    private func loop() async {
        if reduceMotion {
            isOpen = true
            return
        }
        if startsWithNew {
            guard await converts() else { return }
        }
        while !Task.isCancelled {
            guard await speaksUp(), await opens(), await panelControls(), await converts() else { return }
        }
    }

    private func speaksUp() async -> Bool {
        activeTip = 0
        guard await pause(0.6) else { return false }
        withAnimation(Theme.open) { wing = .music }
        guard await pause(1.7) else { return false }
        withAnimation(Theme.swap) { wing = .meeting }
        guard await pause(1.7) else { return false }
        withAnimation(Theme.swap) { wing = .charging }
        guard await pause(1.7) else { return false }
        withAnimation(Theme.close) { wing = nil }
        return await pause(0.8)
    }

    private func opens() async -> Bool {
        activeTip = 1
        pointer = .away
        withAnimation(.easeOut(duration: 0.3)) { pointerVisible = true }
        guard await pause(0.5) else { return false }
        withAnimation(.easeInOut(duration: 0.9)) { pointer = .notch }
        guard await pause(1.3) else { return false }
        withAnimation(Theme.open) { isOpen = true }
        guard await pause(1.5) else { return false }
        withAnimation(.easeInOut(duration: 0.8)) { pointer = .leaving }
        guard await pause(0.25) else { return false }
        withAnimation(Theme.close) { isOpen = false }
        guard await pause(0.8) else { return false }

        withAnimation(.easeOut(duration: 0.25)) { pointerVisible = false }
        fingersDown = false
        withAnimation(.easeOut(duration: 0.2)) { fingersVisible = true }
        guard await pause(0.45) else { return false }
        withAnimation(.easeIn(duration: 0.35)) { fingersDown = true }
        guard await pause(0.2) else { return false }
        withAnimation(Theme.open) { isOpen = true }
        withAnimation(.easeOut(duration: 0.25)) { fingersVisible = false }
        guard await pause(1.5) else { return false }
        withAnimation(Theme.close) { isOpen = false }
        return await pause(0.8)
    }

    private func panelControls() async -> Bool {
        activeTip = 2
        pointer = .notch
        withAnimation(Theme.open) { isOpen = true }
        withAnimation(.easeOut(duration: 0.3)) { pointerVisible = true }
        guard await pause(0.6) else { return false }
        for item in HeaderItem.allCases {
            withAnimation(.easeInOut(duration: 0.6)) { pointer = .item(item) }
            guard await pause(0.65) else { return false }
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { highlight = item }
            guard await pause(0.9) else { return false }
            withAnimation(.easeOut(duration: 0.2)) { highlight = nil }
        }
        withAnimation(.easeInOut(duration: 0.8)) { pointer = .leaving }
        guard await pause(0.25) else { return false }
        withAnimation(Theme.close) { isOpen = false }
        withAnimation(.easeOut(duration: 0.4).delay(0.4)) { pointerVisible = false }
        return await pause(1.0)
    }

    private func converts() async -> Bool {
        activeTip = 3
        file = .fileStart
        pointer = .fileStart
        withAnimation(.easeOut(duration: 0.3)) {
            fileVisible = true
            pointerVisible = true
        }
        guard await pause(0.7) else { return false }
        withAnimation(.easeInOut(duration: 1.0)) {
            file = .notch
            pointer = .notch
        }
        guard await pause(0.85) else { return false }
        convertStage = .drop
        withAnimation(Theme.open) { isOpen = true }
        guard await pause(0.9) else { return false }
        // Dropped: the photo goes into the panel.
        withAnimation(.easeIn(duration: 0.2)) { fileVisible = false }
        withAnimation(Theme.swap) { convertStage = .chips }
        guard await pause(0.7) else { return false }
        withAnimation(.easeInOut(duration: 0.6)) { pointer = .chip }
        guard await pause(0.75) else { return false }
        withAnimation(.spring(response: 0.2, dampingFraction: 0.6)) { chipPressed = true }
        guard await pause(0.18) else { return false }
        chipPressed = false
        withAnimation(Theme.swap) { convertStage = .done }
        guard await pause(1.7) else { return false }
        withAnimation(.easeInOut(duration: 0.8)) { pointer = .leaving }
        guard await pause(0.25) else { return false }
        withAnimation(Theme.close) { isOpen = false }
        withAnimation(.easeOut(duration: 0.4).delay(0.4)) { pointerVisible = false }
        guard await pause(0.5) else { return false }
        convertStage = nil
        return await pause(0.5)
    }

    /// Sleeps, returning false once the view has gone (the task is cancelled).
    private func pause(_ seconds: Double) async -> Bool {
        try? await Task.sleep(for: .seconds(seconds))
        return !Task.isCancelled
    }
}

/// A photo being dragged: a little picture with its name.
private struct DemoFile: View {
    var body: some View {
        VStack(spacing: 2) {
            RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                .fill(LinearGradient(colors: [Color(red: 0.36, green: 0.7, blue: 1), Color(red: 0.2, green: 0.36, blue: 0.8)],
                                     startPoint: .top, endPoint: .bottom))
                .overlay(alignment: .bottom) {
                    Image(systemName: "mountain.2.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(.white.opacity(0.85))
                        .padding(.bottom, 1)
                }
                .frame(width: 20, height: 20)
                .overlay(RoundedRectangle(cornerRadius: 2.5, style: .continuous).strokeBorder(.white, lineWidth: 1))
                .shadow(color: .black.opacity(0.5), radius: 2, y: 1)
            Text("IMG.HEIC")
                .font(.system(size: 5.5, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 2)
                .background(RoundedRectangle(cornerRadius: 1.5).fill(Color.blue.opacity(0.8)))
        }
    }
}

/// Three little bars that bob like the real ones while music plays.
private struct DemoBars: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 20)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 1.5) {
                ForEach(0..<3, id: \.self) { index in
                    Capsule()
                        .fill(Color(red: 1, green: 0.55, blue: 0.45))
                        .frame(width: 1.8, height: 3 + 4 * abs(sin(t * 4 + Double(index) * 1.3)))
                }
            }
            .frame(height: 8)
        }
    }
}
