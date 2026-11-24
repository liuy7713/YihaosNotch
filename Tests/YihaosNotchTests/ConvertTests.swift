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
        // Nothing convertible at all: held anyway, and it says so.
        #expect(ConvertCatalog.refusal(for: urls("Archive.zip"))
            == .init(title: "ZIP files aren't supported yet", detail: "Unzip it and drop the files inside."))
        #expect(ConvertCatalog.refusal(for: urls("a.zip", "b.dmg"))?.title == "These files aren't supported yet")
        #expect(ConvertCatalog.refusal(for: urls("a.dmg", "b.dmg"))?.title == "DMG files aren't supported yet")
        #expect(ConvertCatalog.refusal(for: urls("Show.ppsx"))?.detail
            == "It's a slide show. Open it in PowerPoint or Keynote and save a presentation (.pptx) first.")
        #expect(ConvertCatalog.refusal(for: urls("LICENSE"))?.title == "This file isn't supported yet")
        #expect(ConvertCatalog.refusal(for: urls("Safari.app"))?.title == "Apps can't be converted")
        #expect(ConvertCatalog.refusal(for: urls("LICENSE"))?.detail.hasPrefix("The notch converts photos") == true)
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

    @Test func saysFoldersCantBeConverted() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(ConvertCatalog.refusal(for: [folder])
            == .init(title: "Folders can't be converted", detail: "Open it and drop the files inside."))
        #expect(ConvertCatalog.isFolder(folder))
        #expect(!ConvertCatalog.isFolder(URL(fileURLWithPath: "/tmp/missing-\(UUID().uuidString)")))
    }

    @Test func slidesAndSpreadsheetsNeedOffice() {
        ConvertApp.$installedForTesting.withValue([.powerPoint, .excel]) {
            #expect(ConvertCatalog.kind(of: URL(fileURLWithPath: "/a/Deck.PPTX")) == .presentation)
            #expect(ConvertCatalog.kind(of: URL(fileURLWithPath: "/a/old.ppt")) == .presentation)
            #expect(ConvertCatalog.kind(of: URL(fileURLWithPath: "/a/Budget.xlsx")) == .spreadsheet)
            #expect(ConvertCatalog.kind(of: URL(fileURLWithPath: "/a/old.xls")) == .spreadsheet)
            #expect(ConvertCatalog.kind(of: URL(fileURLWithPath: "/a/data.csv")) == .spreadsheet)
            #expect(ConvertCatalog.kind(of: URL(fileURLWithPath: "/a/show.ppsx")) == nil)
            #expect(ConvertCatalog.targets(for: urls("Deck.pptx")) == [.pdf, .png, .jpeg])
            #expect(ConvertCatalog.targets(for: urls("old.ppt")) == [.pdf, .png, .jpeg, .powerPoint])
            #expect(ConvertCatalog.targets(for: urls("Budget.xlsx")) == [.pdf, .csv])
            #expect(ConvertCatalog.targets(for: urls("old.xls")) == [.pdf, .excel, .csv])
            #expect(ConvertCatalog.targets(for: urls("data.csv")) == [.pdf, .excel])
            #expect(ConvertCatalog.targets(for: urls("a.pptx", "b.pptx")) == [.pdf, .png, .jpeg])
            #expect(ConvertCatalog.describe(urls("a.pptx", "b.ppt")) == "2 presentations")
            // Both can become PDF.
            #expect(ConvertCatalog.targets(for: urls("Deck.pptx", "Budget.xlsx")) == [.pdf])
            #expect(ConvertCatalog.refusal(for: urls("Deck.pptx", "clip.mov"))?.detail
                == "Presentations and videos need different formats. Drop them separately.")
            // Keynote and Numbers files need their own apps.
            #expect(ConvertCatalog.targets(for: urls("Talk.key")).isEmpty)
            #expect(ConvertCatalog.refusal(for: urls("Talk.key"))
                == .init(title: "Can't convert Talk.key", detail: "Converting Keynote files needs Keynote."))
            #expect(ConvertCatalog.refusal(for: urls("Budget.numbers"))?.detail == "Converting Numbers files needs Numbers.")
        }
        ConvertApp.$installedForTesting.withValue([]) {
            // An .xlsx still becomes CSV; the rest needs an app. CSV is text then.
            #expect(ConvertCatalog.targets(for: urls("Budget.xlsx")) == [.csv])
            #expect(ConvertCatalog.targets(for: urls("old.xls")).isEmpty)
            #expect(ConvertCatalog.targets(for: urls("Deck.pptx")).isEmpty)
            #expect(ConvertCatalog.kind(of: URL(fileURLWithPath: "/a/data.csv")) == .document)
            #expect(ConvertCatalog.refusal(for: urls("Deck.pptx"))
                == .init(title: "Can't convert Deck.pptx", detail: "Converting slides needs Microsoft PowerPoint or Keynote."))
            #expect(ConvertCatalog.refusal(for: urls("old.xls"))
                == .init(title: "Can't convert old.xls", detail: "Converting XLS files needs Microsoft Excel or Numbers."))
            #expect(ConvertCatalog.refusal(for: urls("a.ppt", "b.ppt"))?.title == "Can't convert these files")
            #expect(ConvertCatalog.refusal(for: urls("Deck.pptx", "a.zip"))
                == .init(title: "Can't convert Deck.pptx", detail: "Converting slides needs Microsoft PowerPoint or Keynote."))
            // Only Excel opens .ods: that's what both need.
            #expect(ConvertCatalog.refusal(for: urls("a.ods", "b.xls"))?.detail
                == "Converting these spreadsheets needs Microsoft Excel.")
            #expect(ConvertCatalog.refusal(for: urls("a.odp"))?.detail == "Converting ODP files needs Microsoft PowerPoint.")
            #expect(ConvertCatalog.refusal(for: urls("a.pptx", "b.xls"))?.detail
                == "Converting them needs Microsoft PowerPoint or Keynote, and Microsoft Excel or Numbers.")
            #expect(ConvertCatalog.refusal(for: urls("a.jpg", "b.ppt"))?.title == "Can't convert b.ppt")
            #expect(ConvertCatalog.refusal(for: urls("Budget.xlsx")) == nil)
            #expect(ConvertCatalog.refusal(for: urls("Letter.pages"))?.detail == "Converting Pages files needs Pages.")
            #expect(ConvertCatalog.refusal(for: urls("a.key", "b.key"))?.detail == "Converting Keynote files needs Keynote.")
            // Word files fall back to macOS's text system.
            #expect(ConvertCatalog.targets(for: urls("Letter.docx")) == [.pdf, .text])
        }
    }

    @Test func keynoteNumbersAndPagesStandInForOffice() {
        ConvertApp.$installedForTesting.withValue([.keynote, .numbers, .pages]) {
            let file = { (name: String) in URL(fileURLWithPath: "/tmp/\(name)") }
            #expect(ConvertCatalog.kind(of: file("Talk.key")) == .presentation)
            #expect(ConvertCatalog.kind(of: file("Budget.numbers")) == .spreadsheet)
            #expect(ConvertCatalog.kind(of: file("Letter.pages")) == .document)
            #expect(ConvertCatalog.kind(of: file("data.csv")) == .spreadsheet)
            #expect(ConvertCatalog.targets(for: urls("Talk.key")) == [.pdf, .png, .jpeg, .powerPoint])
            #expect(ConvertCatalog.targets(for: urls("Deck.pptx")) == [.pdf, .png, .jpeg])
            #expect(ConvertCatalog.targets(for: urls("Budget.numbers")) == [.pdf, .excel, .csv])
            #expect(ConvertCatalog.targets(for: urls("Budget.xlsx")) == [.pdf, .csv])
            #expect(ConvertCatalog.targets(for: urls("Letter.pages")) == [.pdf, .word, .text])
            #expect(ConvertCatalog.targets(for: urls("Talk.key", "Deck.pptx")) == [.pdf, .png, .jpeg, .powerPoint])
            #expect(ConvertCatalog.describe(urls("Talk.key", "Deck.ppt")) == "2 presentations")
            // Keynote can't open OpenDocument slides, nor Numbers OpenDocument sheets.
            #expect(ConvertCatalog.targets(for: urls("a.odp")).isEmpty)
            #expect(ConvertCatalog.targets(for: urls("a.ods")).isEmpty)
            #expect(ConvertCatalog.refusal(for: urls("a.ods"))?.detail == "Converting ODS files needs Microsoft Excel.")

            #expect(ConvertCatalog.app(for: file("Deck.pptx"), to: .pdf, useWord: true) == .keynote)
            #expect(ConvertCatalog.app(for: file("Talk.key"), to: .powerPoint, useWord: false) == .keynote)
            #expect(ConvertCatalog.app(for: file("old.xls"), to: .csv, useWord: true) == .numbers)
            #expect(ConvertCatalog.app(for: file("Budget.xlsx"), to: .csv, useWord: true) == nil)
            #expect(ConvertCatalog.app(for: file("Budget.numbers"), to: .csv, useWord: true) == .numbers)
            // Pages for Word files when the setting allows; the text system otherwise.
            #expect(ConvertCatalog.app(for: file("Letter.docx"), to: .pdf, useWord: true) == .pages)
            #expect(ConvertCatalog.app(for: file("Letter.doc"), to: .word, useWord: true) == .pages)
            #expect(ConvertCatalog.app(for: file("Letter.docx"), to: .pdf, useWord: false) == nil)
            #expect(ConvertCatalog.app(for: file("Letter.docx"), to: .text, useWord: true) == nil)
            #expect(ConvertCatalog.app(for: file("notes.rtf"), to: .pdf, useWord: true) == nil)
            #expect(ConvertCatalog.app(for: file("README.md"), to: .pdf, useWord: true) == nil)
            // Its own files always go through Pages, setting or not.
            #expect(ConvertCatalog.app(for: file("Letter.pages"), to: .text, useWord: false) == .pages)
        }
        // Office first, when both are there.
        ConvertApp.$installedForTesting.withValue(Set(ConvertApp.allCases)) {
            let file = { (name: String) in URL(fileURLWithPath: "/tmp/\(name)") }
            #expect(ConvertCatalog.app(for: file("Deck.pptx"), to: .pdf, useWord: true) == .powerPoint)
            #expect(ConvertCatalog.app(for: file("old.xls"), to: .pdf, useWord: true) == .excel)
            #expect(ConvertCatalog.app(for: file("Letter.docx"), to: .pdf, useWord: true) == .word)
            #expect(ConvertCatalog.app(for: file("Talk.key"), to: .pdf, useWord: true) == .keynote)
            #expect(ConvertCatalog.app(for: file("Budget.numbers"), to: .excel, useWord: true) == .numbers)
            #expect(ConvertCatalog.targets(for: urls("a.odp")) == [.pdf, .png, .jpeg, .powerPoint])
        }
    }

    @Test func aPrivateKeyIsntAPresentation() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let key = folder.appendingPathComponent("server.key")
        try "-----BEGIN PRIVATE KEY-----\n".write(to: key, atomically: true, encoding: .utf8)
        let deck = folder.appendingPathComponent("Talk.key")
        try Data("PK\u{3}\u{4}".utf8).write(to: deck)
        let package = folder.appendingPathComponent("Old.key")
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        #expect(ConvertCatalog.kind(of: key) == nil)
        #expect(ConvertCatalog.kind(of: deck) == .presentation)
        #expect(ConvertCatalog.kind(of: package) == .presentation)
    }

    @Test func spotsPasswordProtectedFiles() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        // An encrypted .docx is a compound file, not a zip.
        let locked = folder.appendingPathComponent("Locked.docx")
        try Data([0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1, 0, 0]).write(to: locked)
        #expect(ConvertApp.isPasswordProtected(locked))
        let open = folder.appendingPathComponent("Open.pptx")
        try Data("PK\u{3}\u{4}rest".utf8).write(to: open)
        #expect(!ConvertApp.isPasswordProtected(open))
        // A Keynote package with a password verifier inside.
        let package = folder.appendingPathComponent("Locked.key")
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        #expect(!ConvertApp.isPasswordProtected(package))
        try Data().write(to: package.appendingPathComponent(".iwpv2"))
        #expect(ConvertApp.isPasswordProtected(package))
        // Single-file documents are zips: the verifier is an entry.
        let zipped = folder.appendingPathComponent("Locked.numbers")
        let plain = folder.appendingPathComponent("Plain.pages")
        try zip([".iwpv2": "x", "Index/Document.iwa": "y"], to: zipped)
        try zip(["Index/Document.iwa": "y"], to: plain)
        #expect(ConvertApp.isPasswordProtected(zipped))
        #expect(!ConvertApp.isPasswordProtected(plain))
        #expect(!ConvertApp.isPasswordProtected(folder.appendingPathComponent("Missing.key")))
    }

    /// A zip of these files, made with the system's `zip`.
    private func zip(_ files: [String: String], to url: URL) throws {
        let source = url.deletingPathExtension().appendingPathExtension("parts")
        for (name, text) in files {
            let file = source.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: file, atomically: true, encoding: .utf8)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = source
        process.arguments = ["-qr", url.path, "."]
        try process.run()
        process.waitUntilExit()
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

/// Reading .xlsx files for CSV, without Excel.
struct XLSXTests {
    /// Zips the parts into an .xlsx with the system's `zip`.
    private func workbook(_ parts: [String: String]) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        for (path, xml) in parts {
            let url = folder.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try xml.write(to: url, atomically: true, encoding: .utf8)
        }
        let out = folder.appendingPathExtension("xlsx")
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.currentDirectoryURL = folder
        zip.arguments = ["-qr", out.path, "."]
        try zip.run()
        zip.waitUntilExit()
        try FileManager.default.removeItem(at: folder)
        return out
    }

    private let main = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
    private let rel = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"

    private func sample() throws -> URL {
        try workbook([
            "xl/workbook.xml": """
                <workbook xmlns="\(main)" xmlns:r="\(rel)"><workbookPr/><sheets>
                <sheet name="Sales" sheetId="1" r:id="rId1"/>
                <sheet name="Secret" sheetId="2" state="hidden" r:id="rId2"/>
                <sheet name="Q1/Q2" sheetId="3" r:id="rId3"/>
                </sheets></workbook>
                """,
            "xl/_rels/workbook.xml.rels": """
                <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
                <Relationship Id="rId1" Type="\(rel)/worksheet" Target="worksheets/sheet1.xml"/>
                <Relationship Id="rId2" Type="\(rel)/worksheet" Target="worksheets/sheet2.xml"/>
                <Relationship Id="rId3" Type="\(rel)/worksheet" Target="/xl/worksheets/sheet3.xml"/>
                </Relationships>
                """,
            "xl/sharedStrings.xml": """
                <sst xmlns="\(main)"><si><t>名前</t></si><si><r><t>Hello, </t></r><r><t>"world"</t></r></si>
                <si><t>東京</t><rPh sb="0" eb="2"><t>トウキョウ</t></rPh></si></sst>
                """,
            "xl/styles.xml": """
                <styleSheet xmlns="\(main)"><numFmts><numFmt numFmtId="164" formatCode="yyyy/mm/dd;@"/>
                <numFmt numFmtId="165" formatCode="#,##0 &quot;days&quot;"/></numFmts>
                <cellStyleXfs><xf numFmtId="14"/></cellStyleXfs>
                <cellXfs><xf numFmtId="0"/><xf numFmtId="164"/><xf numFmtId="165"/><xf numFmtId="22"/></cellXfs></styleSheet>
                """,
            "xl/worksheets/sheet1.xml": """
                <worksheet xmlns="\(main)"><sheetData>
                <row r="1"><c r="A1" t="s"><v>0</v></c><c r="C1" t="s"><v>1</v></c></row>
                <row r="2"><c r="A2" t="s"><v>2</v></c><c r="B2" s="1"><v>46343</v></c><c r="C2" s="2"><v>12</v></c></row>
                <row r="4"><c r="A4" t="b"><v>1</v></c><c r="B4" s="3"><v>46343.5</v></c><c r="C4"><f>1/3</f><v>0.33333333333333331</v></c></row>
                <row r="5"><c r="A5" t="inlineStr"><is><t>line
                two</t></is></c><c r="B5" s="1"/></row>
                </sheetData></worksheet>
                """,
            "xl/worksheets/sheet2.xml": """
                <worksheet xmlns="\(main)"><sheetData><row r="1"><c r="A1"><v>1</v></c></row></sheetData></worksheet>
                """,
            "xl/worksheets/sheet3.xml": """
                <x:worksheet xmlns:x="\(main)"><x:sheetData><x:row><x:c><x:v>7</x:v></x:c><x:c t="str"><x:v>ok</x:v></x:c></x:row></x:sheetData></x:worksheet>
                """,
        ])
    }

    @Test func readsVisibleSheetsAsText() throws {
        let url = try sample()
        defer { try? FileManager.default.removeItem(at: url) }
        let sheets = try XLSX.read(url, name: "Book.xlsx")
        #expect(sheets.map(\.name) == ["Sales", "Q1/Q2"])
        #expect(sheets[0].rows == [
            ["名前", "", "Hello, \"world\""],
            ["東京", "2026-11-17", "12"],
            [],
            ["TRUE", "2026-11-17 12:00:00", "0.333333333333333"],
            ["line\ntwo"],
        ])
        #expect(sheets[1].rows == [["7", "ok"]])
    }

    @Test func writesOneCSVOrAFolderOfThem() async throws {
        let url = try sample()
        let out = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: out)
        }
        let made = try await XLSX.csv(url, name: "Book.xlsx", folder: out, base: "Book")
        #expect(made.lastPathComponent == "Book")
        let names = try FileManager.default.contentsOfDirectory(atPath: made.path).sorted()
        #expect(names == ["Q1-Q2.csv", "Sales.csv"])
        let data = try Data(contentsOf: made.appendingPathComponent("Sales.csv"))
        #expect(data.starts(with: [0xEF, 0xBB, 0xBF]))
        let text = String(decoding: data.dropFirst(3), as: UTF8.self)
        #expect(text.hasPrefix("名前,,\"Hello, \"\"world\"\"\"\r\n東京,2026-11-17,12\r\n,,\r\n"))
    }

    @Test func hostileFilesDontCrashOrBalloon() throws {
        let url = try workbook([
            "xl/workbook.xml": """
                <workbook xmlns="\(main)" xmlns:r="\(rel)"><sheets><sheet name="S" sheetId="1" r:id="rId1"/></sheets></workbook>
                """,
            "xl/_rels/workbook.xml.rels": """
                <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
                <Relationship Id="rId1" Type="\(rel)/worksheet" Target="worksheets/sheet1.xml"/></Relationships>
                """,
            "xl/worksheets/sheet1.xml": """
                <worksheet xmlns="\(main)"><sheetData>
                <row r="-9223372036854775808"><c><v>1</v></c></row>
                <row r="9223372036854775807"/><row/><row/>
                <row r="1"><c r="XFD1"><v>1</v></c></row><row r="1048576"><c r="A1048576"><v>1</v></c></row>
                </sheetData></worksheet>
                """,
        ])
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(throws: ConvertError.tooLarge("Big.xlsx")) { try XLSX.read(url, name: "Big.xlsx") }
    }

    @Test func notAWorkbook() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).xlsx")
        try Data("not a zip".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(throws: ConvertError.unreadable("Fake.xlsx")) { try XLSX.read(url, name: "Fake.xlsx") }
    }

    @Test func cellsAndDates() {
        #expect(XLSX.column("A1") == 0)
        #expect(XLSX.column("AB12") == 27)
        #expect(XLSX.column("XFD1") == 16_383)
        #expect(XLSX.column("12") == nil)
        #expect(XLSX.date(1, date1904: false) == "1900-01-01")
        #expect(XLSX.date(61, date1904: false) == "1900-03-01")
        #expect(XLSX.date(1, date1904: true) == "1904-01-02")
        #expect(XLSX.date(0.75, date1904: false) == "18:00:00")
        #expect(XLSX.date(-1, date1904: false) == nil)
        #expect(XLSX.numberStyle(id: 14, code: nil) == .date)
        #expect(XLSX.numberStyle(id: 170, code: "[$-409]mmm d, yyyy") == .date)
        #expect(XLSX.numberStyle(id: 171, code: "#,##0.00 \"days\"") == nil)
        #expect(XLSX.numberStyle(id: 172, code: "[Red]0.0") == nil)
        #expect(XLSX.numberStyle(id: 173, code: "0.0 _s") == nil)
        #expect(XLSX.numberStyle(id: 174, code: "h:mm AM/PM") == .time)
        #expect(XLSX.numberStyle(id: 175, code: "[h]:mm") == .elapsed)
        #expect(XLSX.numberStyle(id: 0, code: nil) == nil)
        #expect(XLSX.dateTime(1.25, style: .elapsed, date1904: false) == "30:00:00")
        #expect(XLSX.dateTime(46343.75, style: .time, date1904: false) == "18:00:00")
        #expect(XLSX.format(1e15) == "1000000000000000")
        #expect(XLSX.format(0.1 + 0.2) == "0.3")
        #expect(XLSX.unescape("a_x000D_b_x005F_x") == "a\rb_x")
        #expect(XLSX.resolve("../xl/worksheets/sheet1.xml") == "xl/worksheets/sheet1.xml")
        #expect(XLSX.resolve("/xl/a.xml") == "xl/a.xml")
        #expect(XLSX.cell("B12")! == (1, 11))
        #expect(XLSX.cell("A0")?.row == nil)
        #expect(XLSX.csv([["a", "b c", " x"], ["1"]]) == "a,b c,\" x\"\r\n1,,\r\n")
        #expect(XLSX.fileName(".hidden/one:two") == "_hidden-one-two")
    }
}

/// The AppleScript sent to Keynote, Numbers and Pages, as text: nothing is run.
struct IWorkScriptTests {
    /// One-word terms of the three apps' dictionaries (from `sdef`) that read like
    /// variable names. A variable with one of these names silently means the app's
    /// property instead.
    private let terms: Set<String> = [
        "address", "alignment", "author", "automatic", "borders", "bottom", "cell", "center", "character",
        "chart", "color", "column", "cover", "data", "date", "description", "direction", "duration", "export",
        "file", "files", "filtered", "font", "format", "formula", "frozen", "genre", "group", "height", "hint",
        "id", "image", "language", "left", "line", "locked", "name", "number", "page", "paragraph", "parent",
        "password", "position", "presentation", "range", "rating", "right", "row", "scale", "section",
        "selection", "shape", "sheet", "size", "skipped", "slide", "spreadsheet", "start", "table", "tag",
        "template", "text", "theme", "title", "top", "type", "value", "width", "word", "saved", "document",
        "documents", "window", "result", "version", "modified",
    ]

    private func variables(in script: String) -> Set<String> {
        let pattern = try! NSRegularExpression(pattern: #"\bset (\w+) to\b|\brepeat with (\w+) in\b|\bon \w+\(([^)]*)\)"#)
        var names: Set<String> = []
        for match in pattern.matches(in: script, range: NSRange(script.startIndex..., in: script)) {
            for group in 1...3 {
                guard let range = Range(match.range(at: group), in: script) else { continue }
                for name in script[range].split(separator: ",") {
                    names.insert(name.trimmingCharacters(in: .whitespaces))
                }
            }
        }
        return names
    }

    @Test(arguments: [ConvertApp.keynote, .numbers, .pages])
    func variablesAreNotDictionaryTerms(app: ConvertApp) {
        let scripts = [IWorkAutomation.script(for: app, bundleID: app.bundleIDs[0]),
                       IWorkAutomation.readyScript(bundleID: app.bundleIDs[0])]
        for script in scripts {
            let names = variables(in: script)
            #expect(!names.isEmpty)
            #expect(names.isDisjoint(with: terms), "\(names.intersection(terms))")
        }
    }

    @Test func eachAppExportsItsOwnFormats() {
        let keynote = IWorkAutomation.script(for: .keynote, bundleID: "com.apple.Keynote")
        #expect(keynote.contains(#"tell application id "com.apple.Keynote""#))
        #expect(keynote.contains(#"if exportKind is "pdf" then"#))
        #expect(keynote.contains("export theDoc to outFile as PDF with properties {PDF image quality:Best}"))
        #expect(keynote.contains(#"else if exportKind is "powerPoint" then"#))
        #expect(keynote.contains("export theDoc to outFile as Microsoft PowerPoint"))
        #expect(!keynote.contains("Microsoft Excel"))

        let numbers = IWorkAutomation.script(for: .numbers, bundleID: "com.apple.iWork.Numbers")
        #expect(numbers.contains(#"tell application id "com.apple.iWork.Numbers""#))
        #expect(numbers.contains("as Microsoft Excel with properties {exclude summary worksheet:true}"))
        #expect(numbers.contains("as PDF with properties {image quality:Best}"))

        let pages = IWorkAutomation.script(for: .pages, bundleID: "com.apple.Pages")
        #expect(pages.contains("as Microsoft Word"))
        #expect(pages.contains(#"else if exportKind is "text" then"#))
        #expect(pages.contains("as unformatted text"))
        // An unknown format is an error, not a silent success.
        #expect(pages.contains(#"error "unknown format""#))
        #expect(IWorkAutomation.exports(for: .word).isEmpty)
    }

    @Test func closesOnlyWhatItOpenedAndNeverSaves() {
        let script = IWorkAutomation.script(for: .pages, bundleID: "com.apple.Pages")
        // New since the app was asked, and in the job's folder or imported under the
        // copy's name.
        #expect(script.contains("if knownIds does not contain docId then"))
        #expect(script.contains(#"docPath contains jobId or (docPath is "" and (docName is importName or docName is copyName))"#))
        #expect(script.contains("saving no"))
        #expect(!script.contains("save theDoc"))
        #expect(script.contains(#"if quitting is "quit" and (count of documents) is 0 then quit"#))
        // macOS refusing to let the notch control the app is told apart.
        #expect(script.contains("-1743"))
        #expect(IWorkAutomation.readyScript(bundleID: "com.apple.Pages").contains(#"if errorNumber is -1743 then return "denied""#))
        // The tidy handler takes the arguments the conversion passes after the format.
        #expect(IWorkAutomation.tidyHandler(bundleID: "com.apple.Pages")
            .contains("on tidy(jobId, knownIds, importName, copyName, quitting)"))
    }

    @Test func readsCSVAsNumbersWritesIt() {
        #expect(IWorkAutomation.csvRows("a,b\r\n\"x, \"\"y\"\"\",2\r\n") == [["a", "b"], ["x, \"y\"", "2"]])
        #expect(IWorkAutomation.csvRows("\"line\nbreak\",z\n,") == [["line\nbreak", "z"], ["", ""]])
        #expect(IWorkAutomation.csvRows("") == [])
    }

    @Test func tidiesNumbersCSV() {
        // Numbers pads rows to the table's width and keeps its empty rows.
        let padded = "Item,Cost,,,\r\nCafé,12.5,,,\r\n\"北京, \"\"trip\"\"\",300,,,\r\n,,,,\r\n"
        let tidied = IWorkAutomation.tidiedCSV(Data(padded.utf8))
        #expect(tidied.starts(with: [0xEF, 0xBB, 0xBF]))
        #expect(String(decoding: tidied.dropFirst(3), as: UTF8.self)
            == "Item,Cost\r\nCafé,12.5\r\n\"北京, \"\"trip\"\"\",300\r\n")
        // A byte-order mark already there isn't doubled.
        let marked = IWorkAutomation.tidiedCSV(Data([0xEF, 0xBB, 0xBF]) + Data("a,b\n".utf8))
        #expect(String(decoding: marked.dropFirst(3), as: UTF8.self) == "a,b\r\n")
    }

    @Test func textGetsLineFeeds() {
        let data = IWorkAutomation.normalizedText(Data("Café\r北京\r\nend".utf8))
        #expect(String(decoding: data, as: UTF8.self) == "Café\n北京\nend\n")
    }
}
