import AVFoundation
import ImageIO
import UniformTypeIdentifiers

/// What a dropped file is, as far as converting goes.
enum ConvertKind: String, Sendable, CaseIterable {
    case image, pdf, document, markdown, movie, audio, presentation, spreadsheet
}

/// A format the notch can make. Each is offered only for the kinds that can become it
/// (see `ConvertCatalog.targets`).
enum ConvertTarget: String, Sendable, CaseIterable, Identifiable {
    case jpeg, png, heic, pdf, smallerPDF, text, word, html, mp4, m4a, wav, powerPoint, excel, csv

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
        case .powerPoint: "pptx"
        case .excel: "xlsx"
        case .csv: "csv"
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
        case .powerPoint: "PowerPoint"
        case .excel: "Excel"
        case .csv: "CSV"
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
        case .powerPoint: UTType("org.openxmlformats.presentationml.presentation")
        case .excel: UTType("org.openxmlformats.spreadsheetml.sheet")
        case .csv: .commaSeparatedText
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

    /// Opened by PowerPoint. Slide shows (.pps, .ppsx) and files with macros are left
    /// out: PowerPoint starts the show or asks about the macros.
    static let presentationTypes: [UTType] = [
        "org.openxmlformats.presentationml.presentation", "com.microsoft.powerpoint.ppt",
        "org.oasis-open.opendocument.presentation",
    ].compactMap { UTType($0) }

    /// Opened by Excel (CSV only when Excel is there; otherwise it's text).
    static let spreadsheetTypes: [UTType] = [
        "org.openxmlformats.spreadsheetml.sheet", "com.microsoft.excel.xls",
        "org.oasis-open.opendocument.spreadsheet",
    ].compactMap { UTType($0) }

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
        if presentationTypes.contains(where: type.conforms(to:)) { return .presentation }
        if spreadsheetTypes.contains(where: type.conforms(to:)) { return .spreadsheet }
        if type.conforms(to: .commaSeparatedText), Office.isInstalled(.excel) { return .spreadsheet }
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
        var result = available(targets(for: kinds[0]!, several: several), for: urls[0])
        for (url, kind) in zip(urls, kinds).dropFirst() {
            let allowed = Set(available(targets(for: kind!, several: several), for: url))
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
        case .presentation: [.pdf, .png, .jpeg, .powerPoint]
        case .spreadsheet: [.pdf, .excel, .csv]
        }
    }

    /// Leaves out what needs an Office app that isn't installed. An .xlsx becomes CSV
    /// without Excel; everything else about slides and spreadsheets needs the app.
    static func available(_ targets: [ConvertTarget], for url: URL) -> [ConvertTarget] {
        switch kind(of: url) {
        case .presentation:
            return Office.isInstalled(.powerPoint) ? targets : []
        case .spreadsheet:
            if Office.isInstalled(.excel) { return targets }
            return XLSX.canRead(url) ? targets.filter { $0 == .csv } : []
        default:
            return targets
        }
    }

    /// The Office app a file needs and doesn't have, if that's why nothing is offered.
    static func missingApp(for url: URL) -> Office.App? {
        switch kind(of: url) {
        case .presentation where !Office.isInstalled(.powerPoint): .powerPoint
        case .spreadsheet where available(targets(for: .spreadsheet, several: false), for: url).isEmpty: .excel
        default: nil
        }
    }

    /// Whether `target` turns all of `urls` into a single file.
    static func combines(_ urls: [URL], into target: ConvertTarget) -> Bool {
        target == .pdf && urls.count > 1 && urls.allSatisfy { [.image, .pdf].contains(kind(of: $0)) }
    }

    /// "3 photos", "2 PDFs", "4 files".
    static func describe(_ urls: [URL]) -> String {
        guard urls.count > 1 else { return urls.first?.lastPathComponent ?? "" }
        let kinds = urls.map(kind(of:))
        let noun = Set(kinds).count == 1 ? kinds[0].map(noun) ?? "files" : "files"
        return "\(urls.count) \(noun)"
    }

    /// Why a drop can't be converted: the kind of file isn't supported (yet), some of
    /// the files can't be converted, it needs an Office app that isn't installed, or the
    /// files can't become any one format together. Nil when they can be converted.
    struct Refusal: Equatable, Sendable {
        let title: String
        let detail: String
    }

    static func refusal(for urls: [URL]) -> Refusal? {
        guard !urls.isEmpty, targets(for: urls).isEmpty else { return nil }
        let kinds = urls.map(kind(of:))
        let unknown = zip(urls, kinds).filter { $0.1 == nil }.map(\.0)
        if unknown.count == urls.count { return unsupported(urls) }
        // Files that need PowerPoint or Excel come first: dropping them on their own
        // wouldn't help.
        let needing = urls.filter { missingApp(for: $0) != nil }
        if let first = needing.first {
            let title = needing.count == 1 ? "Can't convert \(first.lastPathComponent)"
                : needing.count == urls.count ? "Can't convert these files"
                : "Can't convert \(needing.count) of these files"
            let apps = Set(needing.compactMap(missingApp(for:)))
            let extensions = Set(needing.map { $0.pathExtension.uppercased() })
            let detail: String = if apps.count > 1 {
                "Converting them needs Microsoft PowerPoint and Excel."
            } else if apps.first == .powerPoint {
                "Converting slides needs Microsoft PowerPoint."
            } else if extensions.count == 1, let ext = extensions.first {
                "Converting \(ext) files needs Microsoft Excel."
            } else {
                "Converting these spreadsheets needs Microsoft Excel."
            }
            return Refusal(title: title, detail: detail)
        }
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
        var nouns: [String] = []
        for kind in kinds.compactMap({ $0 }) where !nouns.contains(noun(kind)) { nouns.append(noun(kind)) }
        guard nouns.count == 2 else {
            return Refusal(title: "Can't convert these together",
                           detail: "They need different formats. Drop each kind separately.")
        }
        return Refusal(title: "Can't convert these together",
                       detail: "\(nouns[0].prefix(1).uppercased() + nouns[0].dropFirst()) and \(nouns[1]) need different formats. Drop them separately.")
    }

    /// Nothing in the drop is a kind of file the notch converts.
    private static func unsupported(_ urls: [URL]) -> Refusal {
        if urls.allSatisfy(isFolder) {
            return Refusal(title: "Folders can't be converted",
                           detail: "Open \(urls.count == 1 ? "it" : "them") and drop the files inside.")
        }
        if urls.allSatisfy({ $0.pathExtension.lowercased() == "app" }) {
            return Refusal(title: "Apps can't be converted",
                           detail: "The notch converts photos, PDFs, documents, slides, spreadsheets, videos and audio.")
        }
        let extensions = Set(urls.map { isFolder($0) ? "/" : $0.pathExtension.lowercased() })
        let title: String
        var detail = "The notch converts photos, PDFs, documents, slides, spreadsheets, videos and audio."
        if extensions.count == 1, let ext = extensions.first, ext != "/", !ext.isEmpty {
            title = "\(ext.uppercased()) files aren't supported yet"
            if let hint = hints[ext] { detail = hint }
        } else {
            title = urls.count == 1 ? "This file isn't supported yet" : "These files aren't supported yet"
        }
        return Refusal(title: title, detail: detail)
    }

    /// What to do instead, for files people often have.
    private static let hints: [String: String] = [
        "key": "Export it from Keynote as PowerPoint or PDF, then drop that.",
        "numbers": "Export it from Numbers as Excel or CSV, then drop that.",
        "pages": "Export it from Pages as Word or PDF, then drop that.",
        "pps": "Open it in PowerPoint and save it as a presentation (.pptx) first.",
        "ppsx": "Open it in PowerPoint and save it as a presentation (.pptx) first.",
        "pptm": "It has macros. Save a copy without them (.pptx) first.",
        "xlsm": "It has macros. Save a copy without them (.xlsx) first.",
        "zip": "Unzip it and drop the files inside.",
    ]

    /// A folder, not a package such as an app or an RTFD document.
    static func isFolder(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey]) else { return false }
        return values.isDirectory == true && values.isPackage != true
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
        case .presentation: "presentations"
        case .spreadsheet: "spreadsheets"
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
