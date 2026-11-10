import AppKit
import AVFoundation
import Foundation
import ImageIO
import PDFKit
import Testing
import UniformTypeIdentifiers
@testable import YihaosNotch

/// Which formats a drop offers, and how results are named.
struct ConvertCatalogTests {
    private func urls(_ names: String...) -> [URL] { names.map { URL(fileURLWithPath: "/tmp/\($0)") } }

    @Test func kinds() {
        #expect(ConvertCatalog.kind(of: URL(fileURLWithPath: "/a/IMG_1.HEIC")) == .image)
        #expect(ConvertCatalog.kind(of: URL(fileURLWithPath: "/a/scan.pdf")) == .pdf)
        #expect(ConvertCatalog.kind(of: URL(fileURLWithPath: "/a/essay.docx")) == .document)
        #expect(ConvertCatalog.kind(of: URL(fileURLWithPath: "/a/notes.rtf")) == .document)
        #expect(ConvertCatalog.kind(of: URL(fileURLWithPath: "/a/README.md")) == .markdown)
        #expect(ConvertCatalog.kind(of: URL(fileURLWithPath: "/a/clip.mov")) == .movie)
        #expect(ConvertCatalog.kind(of: URL(fileURLWithPath: "/a/Recording.MKV")) == .movie)
        #expect(ConvertCatalog.kind(of: URL(fileURLWithPath: "/a/song.mp3")) == .audio)
        #expect(ConvertCatalog.kind(of: URL(fileURLWithPath: "/a/archive.zip")) == nil)
        // An image to UTType, but not one ImageIO reads.
        #expect(ConvertCatalog.kind(of: URL(fileURLWithPath: "/a/logo.svg")) == nil)
    }

    @Test func targetsLeaveOutTheFormatItsAlreadyIn() {
        #expect(ConvertCatalog.targets(for: urls("a.heic")) == [.jpeg, .png, .pdf])
        #expect(ConvertCatalog.targets(for: urls("a.jpg")) == [.png, .heic, .pdf])
        #expect(ConvertCatalog.targets(for: urls("a.docx")) == [.pdf, .text])
        #expect(ConvertCatalog.targets(for: urls("a.md")) == [.pdf, .word, .html])
        #expect(ConvertCatalog.targets(for: urls("a.mov")) == [.mp4, .m4a])
        #expect(ConvertCatalog.targets(for: urls("a.mp4")) == [.m4a])
        #expect(ConvertCatalog.targets(for: urls("a.mp3")) == [.m4a, .wav])
        #expect(ConvertCatalog.targets(for: urls("a.pdf")) == [.png, .jpeg, .text, .smallerPDF])
    }

    @Test func mixedDropsOfferWhatAllCanBecome() {
        // Several images and PDFs can become one PDF.
        #expect(ConvertCatalog.targets(for: urls("a.jpg", "b.pdf")) == [.jpeg, .png, .pdf])
        #expect(ConvertCatalog.targets(for: urls("a.pdf", "b.pdf")).first == .pdf)
        #expect(ConvertCatalog.combines(urls("a.jpg", "b.heic"), into: .pdf))
        #expect(!ConvertCatalog.combines(urls("a.docx", "b.docx"), into: .pdf))
        #expect(ConvertCatalog.targets(for: urls("a.jpg", "b.mov")).isEmpty)
        #expect(ConvertCatalog.targets(for: urls("a.jpg", "b.zip")).isEmpty)
    }

    @Test func knowsFilesKeptByOtherApps() {
        #expect(ConvertService.isInAnotherApp(URL(fileURLWithPath:
            "/Users/a/Library/Containers/com.tencent.xinWeChat/Data/Documents/photo.heic")))
        #expect(ConvertService.isInAnotherApp(URL(fileURLWithPath: "/Users/a/Library/Group Containers/x/y.pdf")))
        #expect(!ConvertService.isInAnotherApp(URL(fileURLWithPath: "/Users/a/Downloads/photo.heic")))
    }

    @Test func describesDrops() {
        #expect(ConvertCatalog.describe(urls("a.jpg", "b.heic", "c.png")) == "3 photos")
        #expect(ConvertCatalog.describe(urls("a.jpg", "b.pdf")) == "2 files")
        #expect(ConvertCatalog.describe(urls("Report.pdf")) == "Report.pdf")
    }

    @Test func explainsDropsThatCantGoTogether() {
        // Nothing convertible at all: the drag passes by without a word.
        #expect(ConvertCatalog.refusal(for: urls("Archive.zip")) == nil)
        #expect(ConvertCatalog.refusal(for: urls("a.zip", "b.dmg")) == nil)
        // Fine together: no refusal.
        #expect(ConvertCatalog.refusal(for: urls("a.jpg", "b.pdf")) == nil)
        let mixed = ConvertCatalog.refusal(for: urls("a.jpg", "b.heic", "clip.mov"))
        #expect(mixed?.title == "Can't convert these together")
        #expect(mixed?.detail == "Photos and videos need different formats. Drop them separately.")
        let three = ConvertCatalog.refusal(for: urls("a.jpg", "clip.mov", "song.wav"))
        #expect(three?.detail == "They need different formats. Drop each kind separately.")
        let stray = ConvertCatalog.refusal(for: urls("a.jpg", "Archive.zip"))
        #expect(stray == .init(title: "Can't convert Archive.zip", detail: "Drop the photo on its own."))
        let strays = ConvertCatalog.refusal(for: urls("a.jpg", "b.jpg", "x.zip", "y.zip"))
        #expect(strays == .init(title: "Can't convert 2 of these files", detail: "Drop the 2 photos without them."))
        let mixedStray = ConvertCatalog.refusal(for: urls("a.jpg", "clip.mov", "x.zip"))
        #expect(mixedStray?.detail == "Drop the other files without it.")
    }

    @Test func namesBatchFoldersByTheNewFormat() {
        #expect(ConvertCatalog.folderName(for: .jpeg) == "Converted to JPEG")
        #expect(ConvertCatalog.folderName(for: .m4a) == "Converted to M4A")
    }

    @Test func soundFromAVideoSaysWhatItIs() {
        #expect(ConvertTarget.m4a.label(fromVideo: true) == "Sound only (M4A)")
        #expect(ConvertTarget.m4a.label() == "M4A")
    }

    @Test func savesNextToOriginalsOnlyWhereItMakesSense() {
        #expect(!ConvertService.isUnsuitableFolder(URL(fileURLWithPath: "/Users/a/Documents")))
        #expect(ConvertService.isUnsuitableFolder(
            URL(fileURLWithPath: "/Users/a/Library/Containers/com.tencent.xinWeChat/Data/Files")))
        #expect(ConvertService.isUnsuitableFolder(FileManager.default.temporaryDirectory))
        #expect(ConvertService.isUnsuitableFolder(URL(fileURLWithPath: "/Applications/Some.app/Contents/Resources")))
    }

    @Test func namesNeverReplaceAFile() {
        let folder = URL(fileURLWithPath: "/out")
        var taken: Set<String> = []
        let exists: (URL) -> Bool = { taken.contains($0.lastPathComponent) }
        #expect(OutputNaming.available(base: "Photo", ext: "jpg", in: folder, exists: exists).lastPathComponent == "Photo.jpg")
        taken = ["Photo.jpg", "Photo 2.jpg"]
        #expect(OutputNaming.available(base: "Photo", ext: "jpg", in: folder, exists: exists).lastPathComponent == "Photo 3.jpg")
        taken = ["Pages"]
        #expect(OutputNaming.available(base: "Pages", ext: "", in: folder, exists: exists).lastPathComponent == "Pages 2")
        #expect(OutputNaming.available(base: "v1.2 notes", ext: "pdf", in: folder, exists: { _ in false })
            .lastPathComponent == "v1.2 notes.pdf")
    }
}

struct MarkdownHTMLTests {
    @Test func blocksNestAsWritten() {
        let html = MarkdownHTML.body("""
            # Title
            Some **bold** and *it*.

            - one
            - two
              1. nested

            > quote

            ```swift
            let x = 1 < 2
            ```
            """, base: nil)
        #expect(html.contains("<h1>Title</h1>"))
        #expect(html.contains("<strong>bold</strong>"))
        #expect(html.contains("<em>it</em>"))
        #expect(html.contains("<li><p>two</p>\n<ol>\n<li><p>nested</p>\n</li>\n</ol>\n</li>"))
        #expect(html.contains("<blockquote>\n<p>quote</p>"))
        #expect(html.contains("<pre><code class=\"language-swift\">let x = 1 &lt; 2\n</code></pre>"))
    }

    @Test func tablesKeepHeadersAndAlignment() {
        let html = MarkdownHTML.body("""
            | Name | Count |
            |:-----|------:|
            | a    | 1     |
            """, base: nil)
        #expect(html.contains("<th>Name</th>"))
        #expect(html.contains("<th style=\"text-align: right\">Count</th>"))
        #expect(html.contains("<td style=\"text-align: right\">1</td>"))
    }

    @Test func webImagesCanBeLeftOut() {
        let markdown = "![chart](https://example.com/c.png) ![local](pic.png)"
        let base = URL(fileURLWithPath: "/tmp/")
        let offline = MarkdownHTML.body(markdown, base: base, remoteImages: false)
        #expect(!offline.contains("example.com"))
        #expect(offline.contains("chart"))
        #expect(offline.contains("src=\"file:///tmp/pic.png\""))
        #expect(MarkdownHTML.body(markdown, base: base).contains("src=\"https://example.com/c.png\""))
    }

    @Test func escapesText() {
        #expect(MarkdownHTML.body("a <script> & \"b\"", base: nil).contains("a &lt;script&gt; &amp; &quot;b&quot;"))
    }

    @Test func offlineHTMLLosesWhatWouldLoad() {
        let html = """
            <link rel="stylesheet" href="https://x.com/a.css"><script>alert(1)</script>
            <img src="https://x.com/a.png"><img src="local.png"><div style="background: url('https://x.com/b.png')">t</div>
            """
        let offline = TextSystem.offline(html)
        #expect(!offline.contains("x.com"))
        #expect(!offline.contains("alert"))
        #expect(offline.contains("local.png"))
    }
}

/// Real conversions on small files made on the spot.
struct ConversionTests {
    private let folder: URL = {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ConvertTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    /// A 60×40 PNG, transparent on the right half, rotated by its orientation tag.
    private func makePNG(_ name: String, orientation: Int = 1) throws -> URL {
        let context = CGContext(data: nil, width: 60, height: 40, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 30, height: 40))
        let url = folder.appendingPathComponent(name)
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, context.makeImage()!,
                                   [kCGImagePropertyOrientation: orientation] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        return url
    }

    private func pixelSize(_ url: URL) -> CGSize? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return CGSize(width: width, height: height)
    }

    @Test func imageToJPEGTurnsUprightAndFillsTransparency() async throws {
        let input = try makePNG("turned.png", orientation: 6)
        let out = folder.appendingPathComponent("turned.jpg")
        try await Converters.image(input, to: .jpeg, stripLocation: true, out: out)
        #expect(pixelSize(out) == CGSize(width: 40, height: 60))
        let source = try #require(CGImageSourceCreateWithURL(out as CFURL, nil))
        #expect(CGImageSourceGetType(source) as String? == UTType.jpeg.identifier)
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let data = try #require(image.dataProvider?.data as Data?)
        // Where it was transparent is now white, not black.
        #expect(data.prefix(3).allSatisfy { $0 > 200 } || data.suffix(4).prefix(3).allSatisfy { $0 > 200 })
    }

    @Test func bigBatchesGoInOneFolder() async throws {
        let destination = folder.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        func convert(_ count: Int, prefix: String) async throws -> ConvertService.Outcome {
            let files = try (1...count).map { try makePNG("\(prefix)\($0).png") }
            return await ConvertService.run(files, to: .jpeg, combining: false, options: .init(),
                                            destination: .folder, folder: destination.path) { _, _ in }
        }
        let few = try await convert(ConvertService.looseLimit, prefix: "few")
        #expect(few.converted == ConvertService.looseLimit)
        #expect(few.made.count == ConvertService.looseLimit)
        #expect(few.made.allSatisfy { $0.pathExtension == "jpg" && $0.deletingLastPathComponent().path == destination.path })

        let many = try await convert(ConvertService.looseLimit + 1, prefix: "many")
        #expect(many.converted == ConvertService.looseLimit + 1)
        let saved = try #require(many.made.first)
        #expect(many.made.count == 1)
        #expect(saved.lastPathComponent == "Converted to JPEG")
        let inside = try FileManager.default.contentsOfDirectory(atPath: saved.path)
        #expect(inside.count == ConvertService.looseLimit + 1)
        #expect(inside.allSatisfy { $0.hasPrefix("many") && $0.hasSuffix(".jpg") })

        // A second batch doesn't merge into the first.
        let again = try await convert(ConvertService.looseLimit + 1, prefix: "again")
        #expect(again.made.first?.lastPathComponent == "Converted to JPEG 2")
        #expect(again.batch)
        #expect(!few.batch)
    }

    @Test func imagesAndPDFsBecomeOnePDF() async throws {
        let first = try makePNG("one.png")
        let second = try makePNG("two.png")
        let combined = folder.appendingPathComponent("both.pdf")
        try await Converters.combinedPDF([first, second], out: combined, stripLocation: true)
        #expect(PDFDocument(url: combined)?.pageCount == 2)
        let again = folder.appendingPathComponent("three.pdf")
        try await Converters.combinedPDF([combined, first], out: again, stripLocation: true)
        #expect(PDFDocument(url: again)?.pageCount == 3)
    }

    @Test func pdfPagesBecomeImages() async throws {
        let png = try makePNG("page.png")
        let pdf = folder.appendingPathComponent("doc.pdf")
        try await Converters.combinedPDF([png, png, png], out: pdf, stripLocation: true)
        let made = try await Converters.pdfPages(pdf, to: .png, folder: folder, base: "doc") { _ in }
        let pages = try FileManager.default.contentsOfDirectory(atPath: made.path).sorted()
        #expect(pages == ["doc 1.png", "doc 2.png", "doc 3.png"])

        let single = folder.appendingPathComponent("single.pdf")
        try await Converters.combinedPDF([png], out: single, stripLocation: true)
        let one = try await Converters.pdfPages(single, to: .jpeg, folder: folder, base: "single") { _ in }
        #expect(one.lastPathComponent == "single.jpg")
        // 842 pt on the long side, at twice the size.
        #expect(pixelSize(one) == CGSize(width: 1684, height: 1123))
    }

    @Test func aPDFWithoutTextSaysSo() async throws {
        let pdf = folder.appendingPathComponent("picture.pdf")
        try await Converters.combinedPDF([try makePNG("p.png")], out: pdf, stripLocation: true)
        await #expect(throws: ConvertError.noText("picture.pdf")) {
            try await Converters.pdfText(pdf, out: folder.appendingPathComponent("picture.txt"))
        }
    }

    @Test @MainActor func documentsPrintToPDFAndWord() throws {
        let text = NSAttributedString(string: String(repeating: "A line of text.\n", count: 120))
        let pdf = folder.appendingPathComponent("text.pdf")
        try TextSystem.printPDF(text, to: pdf, name: "text")
        #expect((PDFDocument(url: pdf)?.pageCount ?? 0) >= 2)
        #expect(PDFDocument(url: pdf)?.string?.contains("A line of text.") == true)
        let docx = folder.appendingPathComponent("text.docx")
        try TextSystem.writeWord(text, to: docx, name: "text")
        let back = try NSAttributedString(url: docx, options: [:], documentAttributes: nil)
        #expect(back.string.contains("A line of text."))
    }

    @Test func markdownBecomesHTML() async throws {
        let md = folder.appendingPathComponent("notes.md")
        try "# Notes\n\n- a\n- b\n".write(to: md, atomically: true, encoding: .utf8)
        let out = folder.appendingPathComponent("notes.html")
        let note = try await Documents.convert(md, to: .html, useWord: false, out: out)
        #expect(note == nil)
        let html = try String(contentsOf: out, encoding: .utf8)
        #expect(html.contains("<title>notes</title>"))
        #expect(html.contains("<h1>Notes</h1>"))
    }

    @Test func audioBecomesWAV() async throws {
        // Half a second of silence as AIFF, written without any devices.
        let input = folder.appendingPathComponent("tone.aiff")
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
        do {
            let file = try AVAudioFile(forWriting: input, settings: format.settings)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 22_050)!
            buffer.frameLength = 22_050
            try file.write(from: buffer)
        }
        let out = folder.appendingPathComponent("tone.wav")
        try await Converters.wav(input, out: out) { _ in }
        let result = try AVAudioFile(forReading: out)
        #expect(result.length == 22_050)
        #expect(result.fileFormat.channelCount == 2)
    }
}
