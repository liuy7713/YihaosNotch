import AppKit
import Observation
import os

private let log = Logger(subsystem: "com.yihao.YihaosNotch", category: "Convert")

/// Where converted files go (Settings › Converting).
enum SaveLocation: String, CaseIterable, Sendable {
    case downloads, original, folder
}

/// Files dropped on the notch, the formats they can become, and the conversion in
/// progress or just finished. Nothing happens until files are dropped.
@MainActor
@Observable
final class ConvertService {
    enum Phase: Equatable {
        case idle
        /// Files are being dragged over the panel.
        case hovering
        case choosing
        case converting(target: ConvertTarget, done: Int, total: Int, fraction: Double)
        case finished
        case failed(String)
        /// Dropped, but these files can't be converted together; says why.
        case refused(ConvertCatalog.Refusal)
    }

    /// More files than this go into one folder rather than loose into Downloads.
    nonisolated static let looseLimit = 5

    private(set) var phase: Phase = .idle
    private(set) var files: [URL] = []
    private(set) var targets: [ConvertTarget] = []
    private(set) var results: [URL] = []
    /// How many files the conversion made: more than `results` when they're in a folder.
    private(set) var convertedCount = 0
    /// While files that can't be converted together are dragged over: why.
    private(set) var refusal: ConvertCatalog.Refusal?
    /// The format offered first: the one last chosen for this kind of file.
    private(set) var preferred: ConvertTarget?
    /// Files were dragged in (or dropped) while a conversion was running.
    private(set) var busyDrop = false
    /// The result went to Downloads because the chosen folder couldn't be written to.
    private(set) var savedToFallback = false
    /// A big batch, saved as one folder.
    private(set) var savedAsFolder = false
    /// Sizes of the dropped files, worked out once rather than on every redraw.
    private(set) var filesSize: Int64 = 0
    /// A line under the result: a fallback location, files that failed, Word.
    private(set) var note: String?
    private(set) var bytesBefore: Int64 = 0
    private(set) var bytesAfter: Int64 = 0
    /// Finished while the panel was closed: shown when it next opens, then cleared.
    private(set) var unseen = false

    /// Called when a conversion ends: how many files it made, out of how many.
    var onFinish: ((_ made: Int, _ total: Int) -> Void)?

    var isConverting: Bool {
        if case .converting = phase { true } else { false }
    }

    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private var job: Task<Void, Never>?
    @ObservationIgnored private var panelIsOpen = false
    /// Counts conversions, so progress from one that ended can't reach the next.
    @ObservationIgnored private var jobNumber = 0
    /// What each result was when it was saved, so Undo never bins a file that has
    /// since been replaced by another of the same name.
    @ObservationIgnored private var resultIdentities: [URL: NSObject] = [:]
    @ObservationIgnored private var beforeHover: (phase: Phase, files: [URL], targets: [ConvertTarget])?

    init(settings: AppSettings) {
        self.settings = settings
    }

    /// Whether dropping these files would convert anything.
    func accepts(_ urls: [URL]) -> Bool {
        settings.convertDropEnabled && !isConverting && !urls.isEmpty && !ConvertCatalog.targets(for: urls).isEmpty
    }

    /// Whether the notch should react to these files: to convert them, or to say why
    /// it can't (including that it's busy). Files none of which can be converted are
    /// left alone.
    func reacts(to urls: [URL]) -> Bool {
        settings.convertDropEnabled && !urls.isEmpty
            && (!ConvertCatalog.targets(for: urls).isEmpty || ConvertCatalog.refusal(for: urls) != nil)
    }

    // MARK: Dragging and dropping

    func hover(_ urls: [URL]) {
        guard reacts(to: urls) else { return }
        if isConverting {
            busyDrop = true
            return
        }
        if phase != .hovering { beforeHover = (phase, files, targets) }
        files = urls
        targets = ConvertCatalog.targets(for: urls)
        refusal = targets.isEmpty ? ConvertCatalog.refusal(for: urls) : nil
        phase = .hovering
    }

    /// The drag left without dropping: back to what was showing.
    func endHover() {
        if isConverting { busyDrop = false }
        guard phase == .hovering else { return }
        refusal = nil
        if let beforeHover {
            phase = beforeHover.phase
            files = beforeHover.files
            targets = beforeHover.targets
        } else {
            phase = .idle
        }
        beforeHover = nil
    }

    func stage(_ urls: [URL]) {
        guard reacts(to: urls) else {
            endHover()
            return
        }
        // Still busy: the message stays until this one finishes.
        if isConverting {
            busyDrop = true
            return
        }
        beforeHover = nil
        refusal = nil
        results = []
        convertedCount = 0
        note = nil
        unseen = false
        if !accepts(urls), let refusal = ConvertCatalog.refusal(for: urls) {
            files = []
            targets = []
            phase = .refused(refusal)
            log.info("refused \(urls.count) file(s)")
            return
        }
        files = urls
        filesSize = Self.size(of: urls)
        targets = ConvertCatalog.targets(for: urls)
        preferred = remembered(in: targets, for: urls)
        phase = .choosing
        log.info("staged \(urls.count) file(s)")
    }

    // MARK: Converting

    func convert(to target: ConvertTarget) {
        guard phase == .choosing || phase.isFailure, !files.isEmpty else { return }
        let files = self.files
        if let kind = files.first.flatMap(ConvertCatalog.kind(of:)) {
            UserDefaults.standard.set(target.rawValue, forKey: Self.lastChoiceKey(kind))
        }
        let options = Converters.Options(stripLocation: settings.convertStripLocation,
                                         useWord: settings.convertUseWord)
        let destination = settings.convertSaveLocation
        let folder = settings.convertFolder
        let combining = ConvertCatalog.combines(files, into: target)
        let total = combining ? 1 : files.count
        results = []
        convertedCount = 0
        savedToFallback = false
        savedAsFolder = false
        note = nil
        phase = .converting(target: target, done: 0, total: total, fraction: 0)
        jobNumber += 1
        let number = jobNumber

        // The service lives as long as the app, so holding it here is fine.
        job = Task {
            let outcome = await Self.run(files, to: target, combining: combining, options: options,
                                         destination: destination, folder: folder) { done, fraction in
                Task { @MainActor in
                    guard number == self.jobNumber, case .converting = self.phase else { return }
                    self.phase = .converting(target: target, done: done, total: total, fraction: fraction)
                }
            }
            self.finish(outcome)
        }
    }

    func stop() {
        job?.cancel()
    }

    /// Moves what was just made to the Bin (originals are never touched) and offers
    /// the formats again.
    func undo() {
        let made = results.filter { url in
            // Only what's still the file this saved: renamed or replaced since, it stays.
            let now = try? url.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier as? NSObject
            return now != nil && now == resultIdentities[url]
        }
        results = []
        resultIdentities = [:]
        convertedCount = 0
        note = nil
        phase = .choosing
        guard !made.isEmpty else { return }
        NSWorkspace.shared.recycle(made) { _, error in
            if let error { log.error("undo failed: \(error.localizedDescription, privacy: .private)") }
        }
    }

    func showInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting(results)
    }

    func dismiss() {
        guard !isConverting else { return }
        reset()
    }

    /// The panel closed: what was on show goes, unless it's still working or just
    /// finished out of sight.
    func panelClosed() {
        panelIsOpen = false
        guard !isConverting, !unseen else { return }
        reset()
    }

    func panelOpened() {
        panelIsOpen = true
        unseen = false
    }

    private func reset() {
        phase = .idle
        files = []
        targets = []
        results = []
        convertedCount = 0
        refusal = nil
        preferred = nil
        busyDrop = false
        savedToFallback = false
        savedAsFolder = false
        filesSize = 0
        resultIdentities = [:]
        note = nil
        beforeHover = nil
    }

    private func finish(_ outcome: Outcome) {
        job = nil
        busyDrop = false
        if outcome.cancelled {
            if !outcome.made.isEmpty { NSWorkspace.shared.recycle(outcome.made) }
            phase = .choosing
            // Stopped, then the panel closed before the last file let go.
            if !panelIsOpen { reset() }
            return
        }
        results = outcome.made
        resultIdentities = Dictionary(uniqueKeysWithValues: outcome.made.compactMap { url in
            (try? url.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier as? NSObject)
                .map { (url, $0) }
        })
        convertedCount = outcome.converted
        savedToFallback = outcome.fellBack
        savedAsFolder = outcome.batch
        bytesBefore = Self.size(of: outcome.sources)
        bytesAfter = Self.size(of: outcome.made)
        if outcome.made.isEmpty {
            phase = .failed(outcome.failures.first?.description ?? "Couldn't convert these.")
            onFinish?(0, max(outcome.failures.count, 1))
            return
        }
        var lines = outcome.notes
        if let first = outcome.failures.first {
            let attempted = outcome.converted + outcome.failures.count
            lines.insert("Converted \(outcome.converted) of \(attempted). \(first)", at: 0)
        }
        note = lines.first
        phase = .finished
        // Seen already if the panel is open; otherwise it waits for the next opening.
        unseen = !panelIsOpen
        onFinish?(outcome.converted, outcome.converted + outcome.failures.count)
    }

    // MARK: Off the main thread

    struct Outcome: Sendable {
        /// What was saved: the files, or the one folder holding them.
        var made: [URL] = []
        /// How many files were made.
        var converted = 0
        var notes: [String] = []
        var failures: [ConvertError] = []
        /// Saved to Downloads because the chosen folder couldn't be written to.
        var fellBack = false
        /// Saved as one folder.
        var batch = false
        /// The originals of what was made, for the "was" size.
        var sources: [URL] = []
        var cancelled = false
    }

    /// Converts each file (or all of them into one PDF) and moves the results to
    /// their place. Runs off the main thread: the first save into Downloads can wait
    /// on macOS's permission prompt.
    @concurrent
    static func run(_ files: [URL], to target: ConvertTarget, combining: Bool, options: Converters.Options,
                            destination: SaveLocation, folder: String,
                            progress: @escaping @Sendable (Int, Double) -> Void) async -> Outcome {
        var outcome = Outcome()
        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("YihaosNotch-Convert-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let groups = combining ? [files] : files.map { [$0] }
        // A big batch is gathered here and saved as one folder at the end.
        let batch: URL? = groups.count > looseLimit
            ? work.appendingPathComponent("batch", isDirectory: true)
                .appendingPathComponent(ConvertCatalog.folderName(for: target), isDirectory: true)
            : nil

        for (index, group) in groups.enumerated() {
            if Task.isCancelled {
                outcome.cancelled = true
                break
            }
            let first = group[0]
            let scratch = work.appendingPathComponent("\(index)", isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
                let made: URL
                var note: String?
                if combining {
                    made = scratch.appendingPathComponent(first.deletingPathExtension().lastPathComponent)
                        .appendingPathExtension("pdf")
                    try await Converters.combinedPDF(group, out: made, stripLocation: options.stripLocation)
                } else {
                    (made, note) = try await Converters.convert(first, to: target, options: options, into: scratch) {
                        progress(index, $0)
                    }
                }
                if let batch {
                    try FileManager.default.createDirectory(at: batch, withIntermediateDirectories: true)
                    _ = try moveUnique(made, into: batch)
                } else {
                    let placed = try place(made, beside: first, destination: destination, folder: folder)
                    outcome.made.append(placed.url)
                    if let fallback = placed.note, !outcome.notes.contains(fallback) {
                        outcome.notes.append(fallback)
                        outcome.fellBack = true
                    }
                }
                outcome.converted += 1
                outcome.sources += group
                if let note, !outcome.notes.contains(note) { outcome.notes.append(note) }
            } catch is CancellationError {
                outcome.cancelled = true
                break
            } catch let error as ConvertError {
                log.error("convert failed: \(error.description, privacy: .private)")
                if case .unreadable(let name) = error, isInAnotherApp(first) {
                    outcome.failures.append(.otherApp(name))
                } else {
                    outcome.failures.append(error)
                }
            } catch {
                log.error("convert failed: \(error.localizedDescription, privacy: .private)")
                outcome.failures.append(.failed(first.lastPathComponent))
            }
            progress(index + 1, 0)
        }
        // Stop pressed during the last file, which didn't notice: still a stop.
        if Task.isCancelled { outcome.cancelled = true }
        if let batch, !outcome.cancelled, outcome.converted > 0 {
            do {
                let placed = try place(batch, beside: files[0], destination: destination, folder: folder)
                outcome.made = [placed.url]
                outcome.batch = true
                if let fallback = placed.note {
                    outcome.notes.append(fallback)
                    outcome.fellBack = true
                }
            } catch {
                log.error("saving the batch failed: \(error.localizedDescription, privacy: .private)")
                outcome.failures = [.failed(batch.lastPathComponent)]
                outcome.converted = 0
            }
        }
        return outcome
    }

    /// Files inside another app's container, which macOS guards with its own prompt.
    nonisolated static func isInAnotherApp(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        return path.contains("/Library/Containers/") || path.contains("/Library/Group Containers/")
    }

    /// Moves `made` into the chosen folder under a name nothing else has. A folder
    /// that can't be written to (a read-only disk, a mail attachment) falls back to
    /// Downloads, and says so.
    nonisolated private static func place(_ made: URL, beside original: URL, destination: SaveLocation,
                                          folder: String) throws -> (url: URL, note: String?) {
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let preferred: URL = switch destination {
        case .downloads: downloads
        case .original: original.deletingLastPathComponent()
        case .folder: folder.isEmpty ? downloads : URL(fileURLWithPath: folder, isDirectory: true)
        }
        // "Next to the original" isn't for originals inside another app's storage, a
        // temporary folder macOS empties, or an app: those results go to Downloads.
        if destination == .original, isUnsuitableFolder(preferred) {
            return (try moveUnique(made, into: downloads), "The original is kept by another app or in a temporary folder.")
        }
        do {
            return (try moveUnique(made, into: preferred), nil)
        } catch where preferred.standardizedFileURL != downloads.standardizedFileURL {
            return (try moveUnique(made, into: downloads), "Your chosen folder couldn't be saved to.")
        }
    }

    nonisolated static func isUnsuitableFolder(_ folder: URL) -> Bool {
        let path = folder.standardizedFileURL.resolvingSymlinksInPath().path + "/"
        let temporary = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path
        return isInAnotherApp(folder) || path.hasPrefix(temporary) || path.hasPrefix("/private/var/folders/")
            || path.hasPrefix("/var/folders/") || path.contains(".app/")
    }

    /// Moves a file or folder into `folder` under a name nothing there has yet.
    nonisolated private static func moveUnique(_ made: URL, into folder: URL) throws -> URL {
        let isFolder = (try? made.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        let base = isFolder ? made.lastPathComponent : made.deletingPathExtension().lastPathComponent
        let url = OutputNaming.available(base: base, ext: isFolder ? "" : made.pathExtension, in: folder)
        try FileManager.default.moveItem(at: made, to: url)
        return url
    }

    // MARK: Helpers

    /// The format last chosen for this kind of file, when it's on offer; otherwise the
    /// first. The buttons keep their places; only the highlight moves.
    private func remembered(in targets: [ConvertTarget], for urls: [URL]) -> ConvertTarget? {
        guard let kind = urls.first.flatMap(ConvertCatalog.kind(of:)),
              let raw = UserDefaults.standard.string(forKey: Self.lastChoiceKey(kind)),
              let last = ConvertTarget(rawValue: raw), targets.contains(last)
        else { return targets.first }
        return last
    }

    private static func lastChoiceKey(_ kind: ConvertKind) -> String { "convertLastTarget.\(kind.rawValue)" }

    nonisolated static func size(of urls: [URL]) -> Int64 {
        urls.reduce(0) { total, url in
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .totalFileAllocatedSizeKey, .fileSizeKey])
            guard values?.isDirectory == true else { return total + Int64(values?.fileSize ?? 0) }
            let contents = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey])?
                .compactMap { ($0 as? URL).flatMap { try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize } } ?? []
            return total + Int64(contents.reduce(0, +))
        }
    }

    /// Where results go, to follow "Saves" or "Saved": "to Downloads", "next to the
    /// original", "to Desktop".
    var destinationDescription: String {
        switch settings.convertSaveLocation {
        case .downloads: "to Downloads"
        case .original: files.count > 1 || convertedCount > 1 ? "next to the originals" : "next to the original"
        case .folder:
            settings.convertFolder.isEmpty ? "to Downloads"
                : "to \(FileManager.default.displayName(atPath: settings.convertFolder))"
        }
    }
}

private extension ConvertService.Phase {
    var isFailure: Bool {
        if case .failed = self { true } else { false }
    }
}
