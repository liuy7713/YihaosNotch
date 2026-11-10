import QuickLookThumbnailing
import SwiftUI
import UniformTypeIdentifiers

/// Takes the panel's body while files are being converted: the drop target, the
/// formats to choose from, progress, and the result.
struct ConvertPanel: View {
    @Environment(ConvertService.self) private var convert
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .topTrailing) {
            switch convert.phase {
            case .idle, .hovering:
                DropTarget(description: ConvertCatalog.describe(convert.files), refusal: convert.refusal)
            case .refused(let refusal):
                DropTarget(description: "", refusal: refusal)
            case .choosing, .converting, .failed:
                HStack(alignment: .center, spacing: 24) {
                    FileSummary(urls: convert.files, size: convert.filesSize)
                        .frame(width: 220, alignment: .leading)
                    Divider().overlay(Theme.hairline).padding(.vertical, 8)
                    rightSide
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            case .finished:
                HStack(alignment: .center, spacing: 24) {
                    FileSummary(urls: convert.results, size: convert.bytesAfter, draggable: true)
                        .frame(width: 220, alignment: .leading)
                    Divider().overlay(Theme.hairline).padding(.vertical, 8)
                    FinishedView()
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if convert.phase != .hovering, !convert.isConverting {
                CloseButton { convert.dismiss() }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(Theme.swapAnimation(reduceMotion: reduceMotion), value: convert.phase)
    }

    @ViewBuilder
    private var rightSide: some View {
        switch convert.phase {
        case .converting(let target, let done, let total, let fraction):
            VStack(alignment: .leading, spacing: 10) {
                Text("Converting to \(target.label())…")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.primary)
                ProgressBar(value: (Double(done) + min(max(fraction, 0), 1)) / Double(max(total, 1)))
                HStack {
                    Text(convert.busyDrop ? "Still converting. Drop them again when it's done."
                         : total > 1 ? "\(min(done + 1, total)) of \(total)" : " ")
                        .font(.system(size: 11, weight: convert.busyDrop ? .regular : .medium).monospacedDigit())
                        .foregroundStyle(convert.busyDrop ? Theme.secondary : Theme.tertiary)
                        .lineLimit(1)
                    Spacer()
                    Button("Stop") { convert.stop() }
                        .buttonStyle(PillButtonStyle())
                }
            }
            .padding(.trailing, 30)
        case .failed(let message):
            VStack(alignment: .leading, spacing: 10) {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.primary)
                    .symbolRenderingMode(.multicolor)
                    .fixedSize(horizontal: false, vertical: true)
                FormatChoices()
            }
            .padding(.trailing, 30)
        default:
            FormatChoices()
                .padding(.trailing, 30)
        }
    }
}

/// "Convert to" and a button per format; one click converts.
private struct FormatChoices: View {
    @Environment(ConvertService.self) private var convert
    @Environment(AppSettings.self) private var settings

    var body: some View {
        let combining = convert.targets.contains(.pdf) && convert.files.count > 1
            && convert.files.allSatisfy { [.image, .pdf].contains(ConvertCatalog.kind(of: $0)) }
        let fromVideo = convert.files.allSatisfy { ConvertCatalog.kind(of: $0) == .movie }
        VStack(alignment: .leading, spacing: 10) {
            Text("Convert to")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.secondary)
            HStack(spacing: 8) {
                ForEach(convert.targets, id: \.self) { target in
                    Button(target.label(combining: combining && target == .pdf, fromVideo: fromVideo)) {
                        convert.convert(to: target)
                    }
                    .buttonStyle(PillButtonStyle(prominent: target == convert.preferred))
                }
            }
            Text(caption)
                .font(.system(size: 11))
                .foregroundStyle(Theme.tertiary)
                .lineLimit(2)
        }
    }

    private var caption: String {
        var parts = ["Saves \(convert.destinationDescription)."]
        let documents = convert.files.contains { [.document, .markdown].contains(ConvertCatalog.kind(of: $0)) }
        if documents, settings.convertUseWord, WordAutomation.isInstalled,
           convert.targets.contains(where: { $0 == .pdf || $0 == .word }) {
            parts.append("Microsoft Word makes the PDF and Word files.")
        }
        return parts.joined(separator: " ")
    }
}

private struct FinishedView: View {
    @Environment(ConvertService.self) private var convert

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: "checkmark.circle.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.primary)
                .labelStyle(TintedIconLabelStyle(tint: Theme.charge))
            Text(detail)
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(Theme.secondary)
            if let note = convert.note {
                Text(note)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.tertiary)
                    .lineLimit(2)
            }
            HStack(spacing: 8) {
                Button("Show in Finder") { convert.showInFinder() }
                    .buttonStyle(PillButtonStyle(prominent: true))
                Button("Undo") { convert.undo() }
                    .buttonStyle(PillButtonStyle())
                    .help(convert.convertedCount > 1 ? "Moves the new files to the Bin; the originals stay"
                          : "Moves the new file to the Bin; the original stays")
            }
            .padding(.top, 2)
        }
        .padding(.trailing, 30)
    }

    private var title: String {
        "Saved \(convert.savedToFallback ? "to Downloads" : convert.destinationDescription)"
    }

    private var detail: String {
        let after = ByteCountFormatter.string(fromByteCount: convert.bytesAfter, countStyle: .file)
        let before = ByteCountFormatter.string(fromByteCount: convert.bytesBefore, countStyle: .file)
        let count = convert.convertedCount
        if convert.savedAsFolder, let folder = convert.results.first {
            return "\(count) \(count == 1 ? "file" : "files") in “\(folder.lastPathComponent)”, \(after) (was \(before))"
        }
        return count > 1 ? "\(count) files, \(after) (was \(before))" : "\(after) (was \(before))"
    }
}

/// The dashed well shown while files are dragged over the panel, or, for files that
/// can't be converted together, why not.
private struct DropTarget: View {
    let description: String
    var refusal: ConvertCatalog.Refusal?

    var body: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .strokeBorder(Theme.tertiary, style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Theme.fill))
            .overlay {
                VStack(spacing: 6) {
                    Image(systemName: refusal == nil ? "arrow.down.circle.fill" : "exclamationmark.triangle.fill")
                        .font(.system(size: 26, weight: .medium))
                        .foregroundStyle(Theme.primary)
                        .symbolRenderingMode(refusal == nil ? .monochrome : .multicolor)
                    Text(refusal?.title ?? "Drop to convert")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .truncationMode(.middle)
                        .padding(.horizontal, 40)
                    if let detail = refusal?.detail {
                        Text(detail)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.secondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 40)
                    } else if !description.isEmpty {
                        Text(description)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .padding(.horizontal, 40)
                    }
                }
            }
            .accessibilityElement(children: .combine)
    }
}

/// A thumbnail of the first file (with a count for more), its name, and its type and size.
private struct FileSummary: View {
    let urls: [URL]
    let size: Int64
    var draggable = false

    var body: some View {
        HStack(spacing: 14) {
            ZStack(alignment: .bottomTrailing) {
                if let first = urls.first {
                    FileThumbnail(url: first, size: 72)
                        .modifier(DragOut(url: draggable ? first : nil))
                }
                if urls.count > 1 {
                    Text("\(urls.count)")
                        .font(.system(size: 11, weight: .bold).monospacedDigit())
                        .foregroundStyle(Color.black)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Theme.primary))
                        .offset(x: 6, y: 4)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(urls.count > 1 ? ConvertCatalog.describe(urls) : urls.first?.lastPathComponent ?? "")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.primary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.tertiary)
                    .lineLimit(1)
                if draggable, urls.count == 1 {
                    Text("Drag it anywhere")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.tertiary)
                }
            }
        }
    }

    private var detail: String {
        let size = ByteCountFormatter.string(fromByteCount: self.size, countStyle: .file)
        guard urls.count == 1, let url = urls.first,
              let type = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType,
              let name = type.localizedDescription
        else { return size }
        return "\(name) · \(size)"
    }
}

/// Lets a result be dragged straight into Mail, Messages or a browser's upload box.
private struct DragOut: ViewModifier {
    let url: URL?

    func body(content: Content) -> some View {
        if let url {
            content.onDrag { NSItemProvider(contentsOf: url) ?? NSItemProvider() }
        } else {
            content
        }
    }
}

struct FileThumbnail: View {
    let url: URL
    let size: CGFloat

    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            } else {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            }
        }
        .frame(width: size, height: size)
        .task(id: url) {
            let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: size, height: size),
                                                       scale: NSScreen.main?.backingScaleFactor ?? 2,
                                                       representationTypes: .thumbnail)
            image = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).nsImage
        }
        .accessibilityHidden(true)
    }
}

private struct ProgressBar: View {
    let value: Double

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.fillStrong)
                Capsule()
                    .fill(Theme.primary)
                    .frame(width: max(6, geometry.size.width * min(max(value, 0), 1)))
            }
        }
        .frame(height: 5)
        .animation(.easeOut(duration: 0.25), value: value)
        .accessibilityElement()
        .accessibilityLabel("Progress")
        .accessibilityValue("\(Int((min(max(value, 0), 1) * 100).rounded())) percent")
    }
}

private struct CloseButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Theme.secondary)
                .frame(width: 22, height: 22)
                .contentShape(Circle())
        }
        .buttonStyle(PressableStyle())
        .hoverHighlight(cornerRadius: 11)
        .help("Close")
        .accessibilityLabel("Close")
    }
}

/// The panel's text buttons: a soft capsule, brighter for the main choice.
struct PillButtonStyle: ButtonStyle {
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(prominent ? Color.black : Theme.primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Capsule().fill(prominent ? Theme.primary : Theme.fillStrong))
            .contentShape(Capsule())
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .opacity(configuration.isPressed ? 0.75 : 1)
            .animation(.spring(response: 0.2, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

private struct TintedIconLabelStyle: LabelStyle {
    let tint: Color

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon.foregroundStyle(tint)
            configuration.title
        }
    }
}

/// Accepts files dragged onto the open panel. The drag pasteboard can be read while the
/// drag is still in the air, so only files that can be converted light it up.
struct ConvertDropDelegate: DropDelegate {
    let convert: ConvertService

    private var urls: [URL] {
        NSPasteboard(name: .drag).readObjects(forClasses: [NSURL.self],
                                              options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }

    /// A result dragged out of the panel and back over it isn't a new drop.
    private var isOwnResult: Bool {
        let urls = urls
        return !urls.isEmpty && urls.allSatisfy(convert.results.contains)
    }

    func validateDrop(info: DropInfo) -> Bool {
        !isOwnResult && convert.reacts(to: urls)
    }

    func dropEntered(info: DropInfo) {
        guard !isOwnResult else { return }
        convert.hover(urls)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .copy)
    }

    func dropExited(info: DropInfo) {
        convert.endHover()
    }

    func performDrop(info: DropInfo) -> Bool {
        let urls = urls
        guard convert.reacts(to: urls) else { return false }
        convert.stage(urls)
        return true
    }
}
