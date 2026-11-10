import AppKit
import AVFoundation
import ImageIO
import PDFKit
import Quartz
import UniformTypeIdentifiers

enum ConvertError: Error, CustomStringConvertible, Equatable {
    case unreadable(String)
    case locked(String)
    case noText(String)
    case notSmaller(String)
    case failed(String)
    /// Kept by another app (dragged out of WeChat, Mail…): macOS asks once before
    /// letting this app read other apps' files, and refuses the read that asked.
    case otherApp(String)
    case unsupportedVideo(String, codec: String)
    case unsupportedAudio(String, codec: String)
    case tooLarge(String)
    case noSound(String)

    var description: String {
        switch self {
        case .unreadable(let name): "Couldn't read \(name)."
        case .locked(let name): "\(name) is password-protected."
        case .noText(let name): "\(name) has no text to copy out; it may be a scan."
        case .notSmaller(let name): "\(name) is already about as small as it gets."
        case .failed(let name): "Couldn't convert \(name)."
        case .tooLarge(let name): "\(name) is too large to convert here."
        case .noSound(let name): "\(name) has no sound to save."
        case .unsupportedVideo(let name, let codec):
            "\(name) has \(codec) video, which macOS can't convert. H.264 and HEVC videos work."
        case .unsupportedAudio(let name, let codec):
            "\(name) has \(codec) sound, which macOS can't convert."
        case .otherApp(let name):
            "macOS asked whether this app may open \(name) from another app. If you allowed it, choose the format again."
        }
    }
}

/// The conversions themselves, all with macOS's own frameworks (and Word, when the
/// user has it and wants it). Each writes into a private temporary folder; the
/// service moves the result to where it's saved.
enum Converters {
    struct Options: Sendable {
        var stripLocation = true
        var useWord = true
    }

    typealias Progress = @Sendable (Double) -> Void

    /// Converts `input`, writing `<base>.<ext>` (or a folder of pages) into `folder`.
    /// Returns what it made and, when it's worth saying, a note.
    static func convert(_ input: URL, to target: ConvertTarget, options: Options, into folder: URL,
                        progress: @escaping Progress) async throws -> (url: URL, note: String?) {
        let name = input.lastPathComponent
        let base = input.deletingPathExtension().lastPathComponent
        let out = folder.appendingPathComponent(base).appendingPathExtension(target.fileExtension)
        switch (ConvertCatalog.kind(of: input), target) {
        case (.image, .jpeg), (.image, .png), (.image, .heic):
            try await image(input, to: target, stripLocation: options.stripLocation, out: out)
        case (.image, .pdf), (.pdf, .pdf):
            try await combinedPDF([input], out: out, stripLocation: options.stripLocation)
        case (.pdf, .png), (.pdf, .jpeg):
            return (try await pdfPages(input, to: target, folder: folder, base: base, progress: progress), nil)
        case (.pdf, .text):
            try await pdfText(input, out: out)
        case (.pdf, .smallerPDF):
            let smaller = folder.appendingPathComponent("\(base) (smaller).pdf")
            try await smallerPDF(input, out: smaller)
            return (smaller, nil)
        case (.movie, _) where input.pathExtension.lowercased() == "mkv":
            return (out, try await MatroskaConverter.convert(input, to: target, out: out, progress: progress))
        case (.movie, _), (.audio, .m4a):
            try await export(input, to: target, out: out, progress: progress)
        case (.audio, .wav):
            try await wav(input, out: out, progress: progress)
        case (.document, _), (.markdown, _):
            let note = try await Documents.convert(input, to: target, useWord: options.useWord, out: out)
            return (out, note)
        default:
            throw ConvertError.failed(name)
        }
        return (out, nil)
    }

    // MARK: Images

    @concurrent
    static func image(_ input: URL, to target: ConvertTarget, stripLocation: Bool, out: URL) async throws {
        let name = input.lastPathComponent
        guard let source = CGImageSourceCreateWithURL(input as CFURL, nil), CGImageSourceGetCount(source) > 0,
              var image = orientedImage(source)
        else { throw ConvertError.unreadable(name) }
        let index = CGImageSourceGetPrimaryImageIndex(source)
        var properties = (CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]) ?? [:]
        // The pixels are already turned upright.
        properties[kCGImagePropertyOrientation] = 1
        if var tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            tiff[kCGImagePropertyTIFFOrientation] = 1
            properties[kCGImagePropertyTIFFDictionary] = tiff
        }
        if stripLocation { properties.removeValue(forKey: kCGImagePropertyGPSDictionary) }
        properties[kCGImageDestinationLossyCompressionQuality] = 0.9
        // JPEG has no transparency; without this, transparent areas turn black.
        if target == .jpeg, hasAlpha(image), let flat = flattened(image) { image = flat }

        let type: UTType = switch target {
        case .png: .png
        case .heic: .heic
        default: .jpeg
        }
        guard let destination = CGImageDestinationCreateWithURL(out as CFURL, type.identifier as CFString, 1, nil)
        else { throw ConvertError.failed(name) }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ConvertError.failed(name) }
    }

    /// The primary image at full size, turned the way the camera says it was held.
    static func orientedImage(_ source: CGImageSource) -> CGImage? {
        let index = CGImageSourceGetPrimaryImageIndex(source)
        let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] ?? [:]
        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        guard orientation != 1,
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return CGImageSourceCreateImageAtIndex(source, index, nil) }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(width, height),
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary)
    }

    private static func hasAlpha(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: false
        default: true
        }
    }

    /// On white, for formats without transparency.
    private static func flattened(_ image: CGImage) -> CGImage? {
        guard let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                      bytesPerRow: 0,
                                      // Always RGB: a grey or indexed image's own space can't
                                      // take this layout, and transparency would turn black.
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.setFillColor(.white)
        context.fill(rect)
        context.draw(image, in: rect)
        return context.makeImage()
    }

    // MARK: PDF

    /// Photos and PDFs, in order, as the pages of one PDF. Each photo gets a page of
    /// its own shape, A4-sized along its longer side.
    @concurrent
    static func combinedPDF(_ inputs: [URL], out: URL, stripLocation: Bool) async throws {
        let document = PDFDocument()
        for input in inputs {
            try Task.checkCancellation()
            let name = input.lastPathComponent
            if ConvertCatalog.kind(of: input) == .pdf {
                guard let pdf = PDFDocument(url: input) else { throw ConvertError.unreadable(name) }
                guard !pdf.isLocked else { throw ConvertError.locked(name) }
                for index in 0..<pdf.pageCount {
                    if let page = pdf.page(at: index)?.copy() as? PDFPage {
                        document.insert(page, at: document.pageCount)
                    }
                }
            } else {
                guard let source = CGImageSourceCreateWithURL(input as CFURL, nil), let image = orientedImage(source)
                else { throw ConvertError.unreadable(name) }
                let scale = 842 / CGFloat(max(image.width, image.height))
                let size = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
                let picture = NSImage(cgImage: image, size: size)
                guard let page = PDFPage(image: picture, options: [
                    .mediaBox: NSValue(rect: CGRect(origin: .zero, size: size)),
                    .compressionQuality: 0.85,
                ]) else { throw ConvertError.failed(name) }
                document.insert(page, at: document.pageCount)
            }
        }
        guard document.pageCount > 0, document.write(to: out) else {
            throw ConvertError.failed(inputs.first?.lastPathComponent ?? "the files")
        }
    }

    /// One image per page at 144 dpi (twice screen size): a single page as a file, more
    /// as a folder of numbered images.
    @concurrent
    static func pdfPages(_ input: URL, to target: ConvertTarget, folder: URL, base: String,
                         progress: @escaping Progress) async throws -> URL {
        let name = input.lastPathComponent
        guard let pdf = PDFDocument(url: input), pdf.pageCount > 0 else { throw ConvertError.unreadable(name) }
        guard !pdf.isLocked else { throw ConvertError.locked(name) }
        let ext = target.fileExtension
        let type: UTType = target == .png ? .png : .jpeg
        let single = pdf.pageCount == 1
        let pagesFolder = folder.appendingPathComponent(base)
        if !single { try FileManager.default.createDirectory(at: pagesFolder, withIntermediateDirectories: true) }

        for index in 0..<pdf.pageCount {
            try Task.checkCancellation()
            guard let page = pdf.page(at: index), let image = render(page, scale: 2) else {
                throw ConvertError.failed(name)
            }
            let url = single
                ? folder.appendingPathComponent("\(base).\(ext)")
                : pagesFolder.appendingPathComponent("\(base) \(index + 1).\(ext)")
            guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil)
            else { throw ConvertError.failed(name) }
            CGImageDestinationAddImage(destination, image,
                                       [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { throw ConvertError.failed(name) }
            progress(Double(index + 1) / Double(pdf.pageCount))
        }
        return single ? folder.appendingPathComponent("\(base).\(ext)") : pagesFolder
    }

    /// A page on white, upright whatever its rotation.
    static func render(_ page: PDFPage, scale: CGFloat) -> CGImage? {
        let bounds = page.bounds(for: .mediaBox)
        let turned = abs(page.rotation) % 180 == 90
        let size = turned ? CGSize(width: bounds.height, height: bounds.width) : bounds.size
        // A damaged PDF can claim any page size.
        let scaled = CGSize(width: size.width * scale, height: size.height * scale)
        guard scaled.width.isFinite, scaled.height.isFinite, (1...30_000).contains(scaled.width),
              (1...30_000).contains(scaled.height) else { return nil }
        let width = Int(scaled.width.rounded()), height = Int(scaled.height.rounded())
        guard width * height < 400_000_000,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        context.setFillColor(.white)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        page.draw(with: .mediaBox, to: context)
        return context.makeImage()
    }

    @concurrent
    static func pdfText(_ input: URL, out: URL) async throws {
        let name = input.lastPathComponent
        guard let pdf = PDFDocument(url: input) else { throw ConvertError.unreadable(name) }
        guard !pdf.isLocked else { throw ConvertError.locked(name) }
        let text = (pdf.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ConvertError.noText(name) }
        try (text + "\n").write(to: out, atomically: true, encoding: .utf8)
    }

    /// macOS's own "Reduce File Size" filter (as in Preview's Export): images are
    /// recompressed and scaled down; text and drawings stay sharp.
    @concurrent
    static func smallerPDF(_ input: URL, out: URL) async throws {
        let name = input.lastPathComponent
        guard let pdf = PDFDocument(url: input) else { throw ConvertError.unreadable(name) }
        guard !pdf.isLocked else { throw ConvertError.locked(name) }
        guard let filter = QuartzFilter(url: URL(fileURLWithPath: "/System/Library/Filters/Reduce File Size.qfilter")),
              pdf.write(to: out, withOptions: [PDFDocumentWriteOption(rawValue: "QuartzFilter"): filter])
        else { throw ConvertError.failed(name) }
        let before = (try? input.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let after = (try? out.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? .max
        if Double(after) > Double(before) * 0.95 {
            try? FileManager.default.removeItem(at: out)
            throw ConvertError.notSmaller(name)
        }
    }

    // MARK: Video and audio

    /// MP4 (copied without re-encoding when it can be) or the soundtrack as M4A.
    static func export(_ input: URL, to target: ConvertTarget, out: URL, progress: @escaping Progress) async throws {
        let name = input.lastPathComponent
        let asset = AVURLAsset(url: input)
        let type: AVFileType = target == .mp4 ? .mp4 : .m4a
        var preset = target == .mp4 ? AVAssetExportPresetHighestQuality : AVAssetExportPresetAppleM4A
        if target == .mp4,
           await AVAssetExportSession.compatibility(ofExportPreset: AVAssetExportPresetPassthrough,
                                                    with: asset, outputFileType: .mp4) {
            preset = AVAssetExportPresetPassthrough
        }
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw ConvertError.unreadable(name)
        }
        let states = session.states(updateInterval: 0.25)
        let watcher = Task {
            for await state in states {
                if case .exporting(let exporting) = state { progress(exporting.fractionCompleted) }
            }
        }
        defer { watcher.cancel() }
        do {
            try await session.export(to: out, as: type)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw ConvertError.failed(name)
        }
    }

    /// 16-bit WAV, at the source's own sample rate and channels.
    @concurrent
    static func wav(_ input: URL, out: URL, progress: @escaping Progress) async throws {
        let name = input.lastPathComponent
        let file: AVAudioFile
        do { file = try AVAudioFile(forReading: input) } catch { throw ConvertError.unreadable(name) }
        let format = file.processingFormat
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        do {
            let output = try AVAudioFile(forWriting: out, settings: settings,
                                         commonFormat: format.commonFormat, interleaved: format.isInterleaved)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1 << 16) else {
                throw ConvertError.failed(name)
            }
            while file.framePosition < file.length {
                try Task.checkCancellation()
                try file.read(into: buffer)
                guard buffer.frameLength > 0 else { break }
                try output.write(from: buffer)
                progress(Double(file.framePosition) / Double(max(file.length, 1)))
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ConvertError.failed(name)
        }
    }
}
