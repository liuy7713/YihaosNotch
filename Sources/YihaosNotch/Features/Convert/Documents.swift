import AppKit
import os

private let log = Logger(subsystem: "com.yihao.YihaosNotch", category: "Convert")

/// Word, RTF, OpenDocument, HTML, plain text and Markdown to PDF, Word, text or HTML.
/// Microsoft Word does it when it's installed and the setting allows (it lays the
/// document out exactly as Word would print it); otherwise macOS's text system does,
/// which keeps text, fonts and tables but not Word's exact layout.
enum Documents {
    /// Converts `input` to `out`. Returns a note when Word was wanted but couldn't help.
    static func convert(_ input: URL, to target: ConvertTarget, useWord: Bool, out: URL) async throws -> String? {
        let name = input.lastPathComponent
        let isMarkdown = ConvertCatalog.kind(of: input) == .markdown
        var markdown: String?
        if isMarkdown {
            guard let data = try? Data(contentsOf: input) else { throw ConvertError.unreadable(name) }
            markdown = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        }
        let title = input.deletingPathExtension().lastPathComponent
        let folder = input.deletingLastPathComponent()

        if target == .html, let markdown {
            // Image paths stay as written, relative to the page: no full paths (with
            // the user's name in them) end up in a file that gets shared.
            let html = MarkdownHTML.document(markdown, title: title, base: nil)
            try html.write(to: out, atomically: true, encoding: .utf8)
            return nil
        }

        var note: String?
        if useWord, target == .pdf || target == .word, WordAutomation.isInstalled {
            if let markdown {
                // Word reads HTML well; images beside the Markdown file are copied
                // along so Word can reach them.
                if await WordAutomation.convertMarkdown(markdown, title: title, folder: folder, to: target, out: out) {
                    return nil
                }
            } else if await WordAutomation.convert(input, to: target, out: out) {
                return nil
            }
            // Stop pressed while Word was busy: nothing is saved.
            try Task.checkCancellation()
            note = "Made without Word, which didn't respond."
        }

        // The text system lays out on the main thread; a huge log or CSV would freeze
        // the notch for minutes.
        let size = (try? input.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        // Word and OpenDocument files are zipped and often big with pictures; the
        // limit is for text that has to be laid out.
        let zipped = ["docx", "odt", "rtfd"].contains(input.pathExtension.lowercased())
        if size > TextSystem.sizeLimit, !zipped { throw ConvertError.tooLarge(name) }

        try await MainActor.run {
            let text: NSAttributedString
            if let markdown {
                text = try TextSystem.read(html: MarkdownHTML.document(markdown, title: title, base: folder,
                                                                         remoteImages: false),
                                           name: name)
            } else {
                text = try TextSystem.read(input)
            }
            switch target {
            case .pdf: try TextSystem.printPDF(text, to: out, name: name)
            case .word: try TextSystem.writeWord(text, to: out, name: name)
            default: try TextSystem.writeText(text, to: out)
            }
        }
        return note
    }
}

/// macOS's own text system: reads what TextEdit reads, writes PDF by "printing" and
/// Word by its .docx writer.
@MainActor
enum TextSystem {
    /// Bigger documents are refused rather than laid out on the main thread.
    nonisolated static let sizeLimit = 25_000_000

    static func read(_ url: URL) throws -> NSAttributedString {
        let name = url.lastPathComponent
        if ConvertCatalog.kind(of: url) == .document, url.pathExtension.lowercased().hasPrefix("htm") {
            guard let data = try? Data(contentsOf: url) else { throw ConvertError.unreadable(name) }
            return try read(html: String(decoding: data, as: UTF8.self), name: name, base: url)
        }
        do {
            return try NSAttributedString(url: url, options: [:], documentAttributes: nil)
        } catch {
            throw ConvertError.unreadable(name)
        }
    }

    /// HTML with anything that would load from the web taken out first: converting
    /// never goes online.
    static func read(html: String, name: String, base: URL? = nil) throws -> NSAttributedString {
        let offline = offline(html)
        var options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: NSAttributedString.DocumentType.html,
            .characterEncoding: String.Encoding.utf8.rawValue,
            .timeout: 10,
        ]
        if let base { options[.baseURL] = base }
        guard let text = try? NSAttributedString(data: Data(offline.utf8), options: options, documentAttributes: nil)
        else { throw ConvertError.unreadable(name) }
        return text
    }

    /// Removes scripts, frames, linked stylesheets and web images or backgrounds.
    nonisolated static func offline(_ html: String) -> String {
        let patterns = [
            #"<script\b[^>]*>[\s\S]*?</script>"#,
            #"<(iframe|frame|object|embed)\b[^>]*>([\s\S]*?</\1>)?"#,
            #"<link\b[^>]*>"#,
            #"<img\b[^>]*\bsrc\s*=\s*["']?\s*(https?:)?//[^>]*>"#,
            #"url\(\s*["']?\s*(https?:)?//[^)]*\)"#,
            #"@import[^;]*;"#,
        ]
        var result = html
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            result = regex.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result),
                                                    withTemplate: "")
        }
        return result
    }

    /// Paginates onto the default paper size (A4 or Letter, as the region has it).
    static func printPDF(_ text: NSAttributedString, to url: URL, name: String) throws {
        let info = NSPrintInfo(dictionary: [
            .jobDisposition: NSPrintInfo.JobDisposition.save,
            .jobSavingURL: url,
        ])
        info.paperSize = NSPrintInfo.shared.paperSize
        for edge in [\NSPrintInfo.topMargin, \.bottomMargin, \.leftMargin, \.rightMargin] {
            info[keyPath: edge] = 56
        }
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isHorizontallyCentered = false
        // Otherwise a short document lands in the middle of the page.
        info.isVerticallyCentered = false

        let width = info.paperSize.width - info.leftMargin - info.rightMargin
        // TextKit 1: only its layout draws table borders when printing.
        let view = NSTextView(usingTextLayoutManager: false)
        // Dark mode would print default-coloured text white.
        view.appearance = NSAppearance(named: .aqua)
        view.frame = NSRect(x: 0, y: 0, width: width, height: 100)
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        view.isVerticallyResizable = true
        view.drawsBackground = false
        view.textStorage?.setAttributedString(text)
        if let layout = view.layoutManager, let container = view.textContainer {
            layout.ensureLayout(for: container)
            view.setFrameSize(NSSize(width: width, height: max(layout.usedRect(for: container).height, 20)))
        }
        let operation = NSPrintOperation(view: view, printInfo: info)
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        guard operation.run(), FileManager.default.fileExists(atPath: url.path) else {
            throw ConvertError.failed(name)
        }
    }

    static func writeWord(_ text: NSAttributedString, to url: URL, name: String) throws {
        do {
            let data = try text.data(from: NSRange(location: 0, length: text.length),
                                     documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML])
            try data.write(to: url)
        } catch {
            throw ConvertError.failed(name)
        }
    }

    static func writeText(_ text: NSAttributedString, to url: URL) throws {
        try text.string.write(to: url, atomically: true, encoding: .utf8)
    }
}

/// Converts with Microsoft Word over AppleScript. Word is sandboxed, so it only works
/// in one folder of ours (~/Library/Caches/com.yihao.YihaosNotch/Word): the first time,
/// Word asks once for access to it, and macOS asks once whether this app may control
/// Word. Anything going wrong (Word missing, declined, too slow) returns false, and
/// the text system takes over.
enum WordAutomation {
    static let bundleID = "com.microsoft.Word"

    static var isInstalled: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
    }

    static var folder: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.yihao.YihaosNotch/Word", isDirectory: true)
    }

    /// Set after Word first converts something: from then on it isn't brought to the
    /// front (the first time it may need to show its access dialog).
    private static let workedKey = "wordConversionWorked"

    static func convert(_ input: URL, to target: ConvertTarget, out: URL) async -> Bool {
        let work = folder
        let id = UUID().uuidString
        let source = work.appendingPathComponent("\(id).\(input.pathExtension)")
        do {
            try prepare(work)
            if input.pathExtension.lowercased().hasPrefix("htm") {
                // Word would load the page's web images and stylesheets: give it a copy
                // without them, so converting never goes online.
                let data = try Data(contentsOf: input)
                try TextSystem.offline(String(decoding: data, as: UTF8.self)).write(to: source, atomically: true,
                                                                                     encoding: .utf8)
            } else {
                try FileManager.default.copyItem(at: input, to: source)
            }
        } catch {
            try? FileManager.default.removeItem(at: source)
            return false
        }
        defer { try? FileManager.default.removeItem(at: source) }
        return await run(source, id: id, to: target, out: out)
    }

    static func convertMarkdown(_ markdown: String, title: String, folder base: URL, to target: ConvertTarget,
                                out: URL) async -> Bool {
        let work = folder
        let id = UUID().uuidString
        let source = work.appendingPathComponent("\(id).html")
        var copied: [URL] = []
        defer {
            try? FileManager.default.removeItem(at: source)
            for url in copied { try? FileManager.default.removeItem(at: url) }
        }
        do {
            try prepare(work)
            // No web images: Word would fetch them.
            var html = MarkdownHTML.document(markdown, title: title, base: base, remoteImages: false)
            // Local images, by their full file URLs, become copies next to the page. Only
            // image files of a sensible size: a path to a folder or anything else is
            // left for Word to show as missing.
            let pattern = try NSRegularExpression(pattern: #"src="(file://[^"]+)""#)
            for match in pattern.matches(in: html, range: NSRange(html.startIndex..., in: html)).reversed() {
                guard let range = Range(match.range(at: 1), in: html),
                      let url = URL(string: String(html[range])), isCopyableImage(url)
                else { continue }
                let copy = work.appendingPathComponent("\(id)-\(copied.count).\(url.pathExtension)")
                copied.append(copy)
                try FileManager.default.copyItem(at: url, to: copy)
                html.replaceSubrange(range, with: copy.lastPathComponent)
            }
            try html.write(to: source, atomically: true, encoding: .utf8)
        } catch {
            return false
        }
        return await run(source, id: id, to: target, out: out)
    }

    private static func isCopyableImage(_ url: URL) -> Bool {
        guard url.isFileURL,
              let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentTypeKey]),
              values.isRegularFile == true, (values.fileSize ?? .max) <= 50_000_000,
              values.contentType?.conforms(to: .image) == true
        else { return false }
        return true
    }

    /// Makes the folder, and clears out anything an earlier conversion left behind
    /// (Word finishing after a Stop or a timeout, or the app quitting mid-way).
    private static func prepare(_ work: URL) throws {
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let old = Date.now.addingTimeInterval(-600)
        let items = (try? FileManager.default.contentsOfDirectory(at: work, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for item in items {
            let modified = (try? item.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if modified < old { try? FileManager.default.removeItem(at: item) }
        }
    }

    private static func run(_ source: URL, id: String, to target: ConvertTarget, out: URL) async -> Bool {
        let result = folder.appendingPathComponent("\(id)-out.\(target.fileExtension)")
        defer { try? FileManager.default.removeItem(at: result) }
        let wasRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
        let firstTime = !UserDefaults.standard.bool(forKey: workedKey)
        let script = """
            on run argv
                set inFile to POSIX file (item 1 of argv)
                set outPath to item 2 of argv
                tell application id "\(bundleID)"
                    with timeout of 150 seconds
                        if item 4 of argv is "front" then activate
                        set theDoc to open inFile read only true add to recent files false confirm conversions false
                        if item 3 of argv is "pdf" then
                            save as theDoc file name outPath file format format PDF add to recent files false
                        else
                            save as theDoc file name outPath file format format document default add to recent files false
                        end if
                        close theDoc saving no
                        if item 5 of argv is "quit" and (count of documents) is 0 then quit saving no
                    end timeout
                end tell
                return "ok"
            end run
            """
        let output = await Osascript.run(script, arguments: [
            source.path, result.path, target == .pdf ? "pdf" : "docx",
            firstTime ? "front" : "back", wasRunning ? "stay" : "quit",
        ], deadline: 160)
        guard output == "ok", FileManager.default.fileExists(atPath: result.path) else {
            log.error("Word conversion failed")
            return false
        }
        do {
            try FileManager.default.moveItem(at: result, to: out)
        } catch {
            return false
        }
        UserDefaults.standard.set(true, forKey: workedKey)
        return true
    }
}
