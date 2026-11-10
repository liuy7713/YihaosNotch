import AVFoundation
import ImageIO
import UniformTypeIdentifiers

/// What a dropped file is, as far as converting goes.
enum ConvertKind: String, Sendable, CaseIterable {
    case image, pdf, document, markdown, movie, audio
}

/// A format the notch can make. Each is offered only for the kinds that can become it
/// (see `ConvertCatalog.targets`).
enum ConvertTarget: String, Sendable, CaseIterable, Identifiable {
    case jpeg, png, heic, pdf, smallerPDF, text, word, html, mp4, m4a, wav

    var id: String { rawValue }

    var fileExtension: String {
        switch self {
        case .jpeg: "jpg"
        case .png: "png"
        case .heic: "heic"
        case .pdf, .smallerPDF: "pdf"
        case .text: "txt"
        case .word: "docx"
        case .html: "html"
        case .mp4: "mp4"
        case .m4a: "m4a"
        case .wav: "wav"
        }
    }

    /// The button's label. `combining` is several files becoming one PDF.
    /// The button's name. A video's sound alone says what it is; for audio files
    /// "M4A" is enough.
    func label(combining: Bool = false, fromVideo: Bool = false) -> String {
        switch self {
        case .jpeg: "JPEG"
        case .png: "PNG"
        case .heic: "HEIC"
        case .pdf: combining ? "One PDF" : "PDF"
        case .smallerPDF: "Smaller PDF"
        case .text: "Text"
        case .word: "Word"
        case .html: "HTML"
        case .mp4: "MP4"
        case .m4a: fromVideo ? "Sound only (M4A)" : "M4A"
        case .wav: "WAV"
        }
    }

    /// The type a file already in this format has, so it isn't offered again.
    var type: UTType? {
        switch self {
        case .jpeg: .jpeg
        case .png: .png
        case .heic: .heic
        case .pdf: .pdf
        case .text: .plainText
        case .word: UTType("org.openxmlformats.wordprocessingml.document")
        case .html: .html
        case .mp4: .mpeg4Movie
        case .m4a: .mpeg4Audio
        case .wav: .wav
        case .smallerPDF: nil
        }
    }
}

enum ConvertCatalog {
    static let wordTypes: [UTType] = [
        "org.openxmlformats.wordprocessingml.document", "com.microsoft.word.doc",
        "org.oasis-open.opendocument.text", "com.microsoft.word.wordml",
    ].compactMap { UTType($0) }

    static let markdownExtensions: Set<String> = ["md", "markdown", "mdown", "mkd"]

    static func kind(of url: URL) -> ConvertKind? {
        let ext = url.pathExtension.lowercased()
        if markdownExtensions.contains(ext) { return .markdown }
        // macOS can't play MKV; MatroskaConverter copies what's inside into an MP4.
        if ext == "mkv" { return .movie }
        guard let type = UTType(filenameExtension: ext) else { return nil }
        return kind(of: type)
    }

    static func kind(of type: UTType) -> ConvertKind? {
        if type.conforms(to: .pdf) { return .pdf }
        if let markdown = UTType("net.daringfireball.markdown"), type.conforms(to: markdown) { return .markdown }
        // Images ImageIO can read: not SVG, which is an image to UTType but not to ImageIO.
        if type.conforms(to: .image) { return imageTypes.contains(type.identifier) ? .image : nil }
        if wordTypes.contains(where: type.conforms(to:)) || type.conforms(to: .rtf) || type.conforms(to: .rtfd)
            || type.conforms(to: .html) || type.conforms(to: .plainText) {
            return .document
        }
        let playable = audiovisualTypes.contains(type.identifier)
        if type.conforms(to: .movie), playable { return .movie }
        if type.conforms(to: .audio), playable { return .audio }
        return nil
    }

    /// Everything the files can all become, in the order of the first file's kind.
    /// A format every file is already in is left out, except that several files can
    /// still become one PDF.
    static func targets(for urls: [URL]) -> [ConvertTarget] {
        let kinds = urls.map(kind(of:))
        guard !kinds.isEmpty, kinds.allSatisfy({ $0 != nil }) else { return [] }
        let several = urls.count > 1
        var result = targets(for: kinds[0]!, several: several)
        for kind in kinds.dropFirst() {
            let allowed = Set(targets(for: kind!, several: several))
            result = result.filter(allowed.contains)
        }
        let types = urls.map { UTType(filenameExtension: $0.pathExtension.lowercased()) }
        return result.filter { target in
            if target == .pdf, several { return true }
            guard let targetType = target.type else { return true }
            return !types.allSatisfy { $0?.conforms(to: targetType) == true }
        }
    }

    static func targets(for kind: ConvertKind, several: Bool) -> [ConvertTarget] {
        switch kind {
        case .image: [.jpeg, .png, .heic, .pdf]
        case .pdf: several ? [.pdf, .png, .jpeg, .text] : [.png, .jpeg, .text, .smallerPDF]
        case .document: [.pdf, .word, .text]
        case .markdown: [.pdf, .word, .html]
        case .movie: [.mp4, .m4a]
        case .audio: [.m4a, .wav]
        }
    }

    /// Whether `target` turns all of `urls` into a single file.
    static func combines(_ urls: [URL], into target: ConvertTarget) -> Bool {
        target == .pdf && urls.count > 1 && urls.allSatisfy { [.image, .pdf].contains(kind(of: $0)) }
    }

    /// "3 photos", "2 PDFs", "4 files".
    static func describe(_ urls: [URL]) -> String {
        let kinds = Set(urls.compactMap(kind(of:)))
        guard urls.count > 1 else { return urls.first?.lastPathComponent ?? "" }
        let noun = kinds.count == 1 ? kinds.first.map(noun) ?? "files" : "files"
        return "\(urls.count) \(noun)"
    }

    /// Why a drop can't be converted, when it's worth saying: some of the files can be
    /// converted but not all, or they can't become any one format together. A drag
    /// where nothing can be converted gets nil, so it passes over the notch unnoticed.
    struct Refusal: Equatable, Sendable {
        let title: String
        let detail: String
    }

    static func refusal(for urls: [URL]) -> Refusal? {
        let kinds = urls.map(kind(of:))
        let unknown = zip(urls, kinds).filter { $0.1 == nil }.map(\.0)
        guard !urls.isEmpty, unknown.count < urls.count else { return nil }
        if !unknown.isEmpty {
            let known = kinds.compactMap { $0 }
            let nouns = Set(known.map(noun))
            let others: String = switch (known.count, nouns.count == 1 ? nouns.first : nil) {
            case (1, let plural?): "the \(singular(plural))"
            case (let count, let plural?): "the \(count) \(plural)"
            case (1, nil): "the other file"
            default: "the other files"
            }
            let detail = known.count == 1 ? "Drop \(others) on its own." : "Drop \(others) without \(unknown.count == 1 ? "it" : "them")."
            return Refusal(title: unknown.count == 1 ? "Can't convert \(unknown[0].lastPathComponent)"
                               : "Can't convert \(unknown.count) of these files",
                           detail: detail)
        }
        guard targets(for: urls).isEmpty else { return nil }
        var nouns: [String] = []
        for kind in kinds.compactMap({ $0 }) where !nouns.contains(noun(kind)) { nouns.append(noun(kind)) }
        guard nouns.count == 2 else {
            return Refusal(title: "Can't convert these together",
                           detail: "They need different formats. Drop each kind separately.")
        }
        return Refusal(title: "Can't convert these together",
                       detail: "\(nouns[0].prefix(1).uppercased() + nouns[0].dropFirst()) and \(nouns[1]) need different formats. Drop them separately.")
    }

    /// Where a big batch goes, so it doesn't spill across Downloads: "Converted to JPEG".
    static func folderName(for target: ConvertTarget) -> String {
        "Converted to \(target.label())"
    }

    private static func singular(_ plural: String) -> String {
        switch plural {
        case "audio files": "audio file"
        default: String(plural.dropLast())
        }
    }

    private static func noun(_ kind: ConvertKind) -> String {
        switch kind {
        case .image: "photos"
        case .pdf: "PDFs"
        case .document, .markdown: "documents"
        case .movie: "videos"
        case .audio: "audio files"
        }
    }

    private static let imageTypes = Set((CGImageSourceCopyTypeIdentifiers() as? [String]) ?? [])
    private static let audiovisualTypes = Set(AVURLAsset.audiovisualTypes().map(\.rawValue))
}

/// Finder-style names that never replace an existing file: "Photo.jpg", then
/// "Photo 2.jpg", "Photo 3.jpg"…
enum OutputNaming {
    static func available(base: String, ext: String, in folder: URL,
                          exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) -> URL {
        let name = base.isEmpty ? "Converted" : base
        for index in 1... {
            let stem = index == 1 ? name : "\(name) \(index)"
            let candidate = folder.appendingPathComponent(ext.isEmpty ? stem : "\(stem).\(ext)")
            if !exists(candidate) { return candidate }
        }
        fatalError("unreachable")
    }
}
