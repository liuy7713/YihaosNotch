import SwiftUI

struct NowPlayingCard: View {
    @Environment(NowPlayingService.self) private var nowPlaying

    var body: some View {
        if let track = nowPlaying.track {
            playing(track)
        } else {
            idle
        }
    }

    private func playing(_ track: Track) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                Button { nowPlaying.openPlayer() } label: {
                    ArtworkView(image: nowPlaying.artwork, size: 92, cornerRadius: 13)
                }
                .buttonStyle(PressableStyle())
                .help("Open \(nowPlaying.source?.appName ?? "player")")
                .accessibilityLabel("Open \(nowPlaying.source?.appName ?? "player")")

                VStack(alignment: .leading, spacing: 0) {
                    Text(track.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.primary)
                        .lineLimit(1)
                    Text(track.artist)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondary)
                        .lineLimit(1)
                        .padding(.top, 2)
                    if let lyrics = nowPlaying.lyrics {
                        LyricLine(lyrics: lyrics, color: nowPlaying.accent, isPlaying: nowPlaying.isPlaying,
                                  position: { nowPlaying.position(at: $0) })
                            .padding(.top, 6)
                    }
                    Spacer(minLength: 0)
                    controls
                }
                .frame(height: 92)
            }
            Scrubber(duration: track.duration, isPlaying: nowPlaying.isPlaying,
                     position: { nowPlaying.position(at: $0) },
                     onSeek: { nowPlaying.seek(to: $0) })
        }
        .frame(maxHeight: .infinity, alignment: .center)
    }

    private var controls: some View {
        HStack(spacing: 6) {
            control("backward.fill", size: 13, label: "Previous track") { nowPlaying.previousTrack() }
            control(nowPlaying.isPlaying ? "pause.fill" : "play.fill", size: 19,
                    label: nowPlaying.isPlaying ? "Pause" : "Play") { nowPlaying.playPause() }
                .contentTransition(.symbolEffect(.replace))
            control("forward.fill", size: 13, label: "Next track") { nowPlaying.nextTrack() }
        }
        .padding(.leading, -8)
    }

    private func control(_ symbol: String, size: CGFloat, label: String,
                         action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(Theme.primary)
                .frame(width: 34, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .hoverHighlight(cornerRadius: 9)
        .accessibilityLabel(label)
    }

    private var idle: some View {
        HStack(alignment: .top, spacing: 14) {
            ArtworkView(image: nil, size: 92, cornerRadius: 13)
            VStack(alignment: .leading, spacing: 2) {
                Text("Not playing")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.primary)
                Text("Start something in")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.tertiary)
                Spacer(minLength: 0)
                HStack(spacing: 6) {
                    ForEach(MusicSource.allCases.filter { $0.appURL != nil }, id: \.self) { source in
                        PlayerChip(source: source) { nowPlaying.openPlayer(source) }
                    }
                }
            }
            .frame(height: 92)
        }
        .frame(maxHeight: .infinity, alignment: .center)
    }
}

private struct PlayerChip: View {
    let source: MusicSource
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let url = source.appURL {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                        .resizable()
                        .frame(width: 14, height: 14)
                }
                Text(source.appName)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.primary)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(Capsule().fill(Theme.fill))
            .contentShape(Capsule())
        }
        .buttonStyle(PressableStyle())
    }
}

/// The current lyric line. Each new line slides up into place (or fades, with
/// Reduce Motion). The timeline stops while paused.
private struct LyricLine: View {
    let lyrics: Lyrics
    let color: Color
    let isPlaying: Bool
    let position: (Date) -> Double

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.2, paused: !isPlaying)) { context in
            // Small lead so the line appears as it's sung, not just after.
            let line = lyrics.line(at: position(context.date) + 0.3) ?? ""
            ZStack(alignment: .leading) {
                Text(line.isEmpty ? "♪" : line)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(color.opacity(line.isEmpty ? 0.5 : 0.95))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .id(line)
                    .transition(reduceMotion
                        ? .opacity
                        : .asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity),
                                      removal: .move(edge: .top).combined(with: .opacity)))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 15)
            .clipped()
            .animation(.easeOut(duration: 0.28), value: line)
        }
        .accessibilityHidden(true)
    }
}

/// Thin progress bar you can drag to seek; it thickens while dragging. Streams with no
/// fixed length (radio, live) show only the elapsed time. The timeline stops while paused.
private struct Scrubber: View {
    let duration: Double
    let isPlaying: Bool
    let position: (Date) -> Double
    let onSeek: (Double) -> Void

    @State private var dragFraction: Double?

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.5, paused: !isPlaying)) { context in
            let current = dragFraction.map { $0 * duration } ?? position(context.date)
            if duration > 0 {
                bar(current: current)
            } else {
                Text(current.playbackTime)
                    .font(.system(size: 10, weight: .medium).monospacedDigit())
                    .foregroundStyle(Theme.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func bar(current: Double) -> some View {
        let fraction = min(max(current / duration, 0), 1)
        return VStack(spacing: 5) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.fillStrong)
                    Capsule()
                        .fill(Theme.primary)
                        .frame(width: max(dragFraction == nil ? 4 : 6, geo.size.width * fraction))
                }
                .frame(height: dragFraction == nil ? 4 : 6)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            dragFraction = min(max(value.location.x / geo.size.width, 0), 1)
                        }
                        .onEnded { _ in
                            if let dragFraction { onSeek(dragFraction * duration) }
                            dragFraction = nil
                        }
                )
                .animation(.easeOut(duration: 0.15), value: dragFraction == nil)
            }
            .frame(height: 10)

            HStack {
                Text(current.playbackTime)
                Spacer()
                // U+2212 minus sign, which lines up with the digits.
                Text("\u{2212}" + max(duration - current, 0).playbackTime)
            }
            .font(.system(size: 10, weight: .medium).monospacedDigit())
            .foregroundStyle(Theme.tertiary)
        }
        .accessibilityElement()
        .accessibilityLabel("Playback position")
        .accessibilityValue("\(current.playbackTime) of \(duration.playbackTime)")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: onSeek(min(current + 10, duration))
            case .decrement: onSeek(max(current - 10, 0))
            @unknown default: break
            }
        }
    }
}
