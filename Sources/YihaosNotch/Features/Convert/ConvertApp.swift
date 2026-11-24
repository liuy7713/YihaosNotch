import AppKit
import os

/// The apps that convert what macOS can't: Microsoft Office when it's installed, and
/// Apple's Keynote, Numbers and Pages otherwise (and always for their own files).
/// Each works on a copy in its own folder of ours under
/// ~/Library/Caches/com.yihao.YihaosNotch, and macOS asks once whether this app may
/// control it.
enum ConvertApp: String, CaseIterable, Sendable {
    case word, powerPoint, excel, keynote, numbers, pages

    /// Keynote, Numbers and Pages have had two identifiers: the newer first.
    var bundleIDs: [String] {
        switch self {
        case .word: ["com.microsoft.Word"]
        case .powerPoint: ["com.microsoft.Powerpoint"]
        case .excel: ["com.microsoft.Excel"]
        case .keynote: ["com.apple.Keynote", "com.apple.iWork.Keynote"]
        case .numbers: ["com.apple.Numbers", "com.apple.iWork.Numbers"]
        case .pages: ["com.apple.Pages", "com.apple.iWork.Pages"]
        }
    }

    /// The one installed, or the usual one.
    var bundleID: String {
        Self.installed()[self] ?? bundleIDs[0]
    }

    /// Short, for folders and the notch: "PowerPoint", "Keynote".
    var name: String {
        switch self {
        case .word: "Word"
        case .powerPoint: "PowerPoint"
        case .excel: "Excel"
        case .keynote: "Keynote"
        case .numbers: "Numbers"
        case .pages: "Pages"
        }
    }

    /// For sentences: "Microsoft PowerPoint", "Keynote".
    var fullName: String {
        isOffice ? "Microsoft \(name)" : name
    }

    var isOffice: Bool {
        [.word, .powerPoint, .excel].contains(self)
    }

    /// Where the app reads our copy of a file and writes what it makes.
    var folder: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.yihao.YihaosNotch/\(name)", isDirectory: true)
    }

    var isRunning: Bool {
        bundleIDs.contains { !NSRunningApplication.runningApplications(withBundleIdentifier: $0).isEmpty }
    }

    /// Set after the app first converts something: from then on the notch stops
    /// saying it may ask for permission, and Office apps aren't brought to the front
    /// (the first time they may need to show their access dialog).
    var hasWorked: Bool {
        get { UserDefaults.standard.bool(forKey: "\(rawValue)ConversionWorked") }
        nonmutating set { UserDefaults.standard.set(newValue, forKey: "\(rawValue)ConversionWorked") }
    }

    // MARK: Installed apps

    /// Which apps tests pretend are installed.
    @TaskLocal static var installedForTesting: Set<ConvertApp>?

    /// Looked up at most every few seconds: the formats offered are worked out on
    /// every redraw, and someone may install an app while this one is running.
    private static let cache = OSAllocatedUnfairLock<(date: Date, apps: [ConvertApp: String])?>(initialState: nil)

    /// `--without-office` converts as if Microsoft Office weren't installed, to try
    /// Keynote, Numbers and Pages on a Mac that has both.
    private static let withoutOffice = CommandLine.arguments.contains("--without-office")

    static func isInstalled(_ app: ConvertApp) -> Bool {
        if let installedForTesting { return installedForTesting.contains(app) }
        return installed()[app] != nil
    }

    /// Each installed app and the identifier it has.
    private static func installed() -> [ConvertApp: String] {
        if let installedForTesting {
            return Dictionary(uniqueKeysWithValues: installedForTesting.map { ($0, $0.bundleIDs[0]) })
        }
        return cache.withLock { cached in
            if let cached, cached.date.timeIntervalSinceNow > -5 { return cached.apps }
            var apps: [ConvertApp: String] = [:]
            for app in allCases where !(withoutOffice && app.isOffice) {
                apps[app] = app.bundleIDs.first {
                    NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil
                }
            }
            cached = (Date.now, apps)
            return apps
        }
    }

    // MARK: Working copies

    /// Makes the folder, and clears out anything an earlier conversion left behind
    /// (the app finishing after a Stop or a timeout, or this app quitting mid-way).
    static func prepare(_ work: URL) throws {
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let old = Date.now.addingTimeInterval(-600)
        let items = (try? FileManager.default.contentsOfDirectory(at: work, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for item in items {
            let modified = (try? item.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if modified < old { try? FileManager.default.removeItem(at: item) }
        }
    }

    /// Copies `input` into the app's folder under a name of its own, so the original is
    /// never opened (or locked, or changed) by the app. CSV gets a byte-order mark if
    /// it's UTF-8 without one, or Excel reads accented and Asian text as gibberish.
    static func stage(_ input: URL, for app: ConvertApp, id: String) throws -> URL {
        let work = app.folder
        try prepare(work)
        let copy = work.appendingPathComponent("\(id).\(input.pathExtension.lowercased())")
        if input.pathExtension.lowercased() == "csv" {
            let data = try Data(contentsOf: input)
            let bom = Data([0xEF, 0xBB, 0xBF])
            if !data.starts(with: bom), String(data: data, encoding: .utf8) != nil {
                try (bom + data).write(to: copy)
                return copy
            }
        }
        try FileManager.default.copyItem(at: input, to: copy)
        // The copy keeps the original's date; the sweep in `prepare` goes by it.
        try? FileManager.default.setAttributes([.modificationDate: Date.now], ofItemAtPath: copy.path)
        return copy
    }

    /// After a failure or Stop: runs the app's `tidy` handler with `arguments`, which
    /// closes whatever this conversion opened and quits the app if it launched it and
    /// nothing else is open, then deletes `files`. Runs on its own: the conversion's
    /// task is cancelled and can't run scripts, and the app may still be busy with
    /// the request that was cut off.
    static func tidy(handler: String, arguments: [String], removing files: [URL]) {
        let call = arguments.indices.map { "item \($0 + 1) of argv" }.joined(separator: ", ")
        Task.detached {
            _ = await Osascript.run(handler + """

                on run argv
                    my tidy(\(call))
                end run
                """, arguments: arguments, deadline: 130)
            for file in files { try? FileManager.default.removeItem(at: file) }
        }
    }

    /// After a conversion quit the app it launched: waits a few seconds for it to go,
    /// so the next file in a batch doesn't find it still running (and leave it open).
    static func waitUntilQuit(_ app: ConvertApp) async {
        for _ in 0..<25 where app.isRunning {
            try? await Task.sleep(for: .milliseconds(200))
        }
    }

    // MARK: Password-protected files

    /// Whether `url` is a password-protected Office or iWork file. The apps would ask
    /// for the password in a window of their own and never open it for converting.
    /// Older Office files (.doc, .xls, .ppt) can't be told apart this cheaply: those
    /// fail when the app doesn't open them in time.
    static func isPasswordProtected(_ url: URL) -> Bool {
        switch url.pathExtension.lowercased() {
        case "docx", "xlsx", "pptx":
            // An encrypted Office Open XML file isn't a zip but an older-style
            // compound file holding the encrypted zip.
            guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
            defer { try? handle.close() }
            let head = (try? handle.read(upToCount: 8)) ?? Data()
            return head == Data([0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1])
        case "key", "numbers", "pages":
            // Keynote, Numbers and Pages keep a password verifier at the top of the
            // document: a file in a package, an entry in a single-file document.
            let names = [".iwpv2", ".iwpv"]
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                return names.contains { FileManager.default.fileExists(atPath: url.appendingPathComponent($0).path) }
            }
            return names.contains { (try? XLSX.part($0, in: url, name: url.lastPathComponent)) != nil }
        default:
            return false
        }
    }
}
