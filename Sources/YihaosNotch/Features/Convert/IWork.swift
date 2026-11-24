import AppKit
import os

private let log = Logger(subsystem: "com.yihao.YihaosNotch", category: "Convert")

/// Converts with Apple's Keynote, Numbers and Pages over AppleScript: their own files,
/// and slides, spreadsheets and Word documents when Microsoft Office isn't there.
///
/// The app gets a copy under the original's name (its tables and the PDF's title take
/// that name) in a folder of its own, is launched first if it isn't running (Pages
/// launched by opening a Word file doesn't answer scripts), opens the copy the way
/// Finder would, exports it, and closes it without saving. Documents the user has open
/// are never touched: the one to export is new since the app was asked, and is either
/// in that folder or, for an imported file, has the copy's name and no file yet.
enum IWorkAutomation {
    /// What the app exports.
    enum Export: String, Sendable {
        case pdf, powerPoint, excel, csv, word, text

        var fileExtension: String {
            switch self {
            case .pdf: "pdf"
            case .powerPoint: "pptx"
            case .excel: "xlsx"
            case .csv: "csv"
            case .word: "docx"
            case .text: "txt"
            }
        }
    }

    /// Which exports each app makes.
    static func exports(for app: ConvertApp) -> [Export] {
        switch app {
        case .keynote: [.pdf, .powerPoint]
        case .numbers: [.pdf, .excel, .csv]
        case .pages: [.pdf, .word, .text]
        default: []
        }
    }

    // MARK: Scripts
    // Variable names must not be terms of the app's dictionary: one that is ("saved"
    // in PowerPoint) silently means the app's property instead. `file name` is a
    // Keynote term, so the copy's name is `copyName`.

    /// Launches the app if needed and waits until it answers, then lists the ids of
    /// the documents already open: "ready", then one id per line. "denied" when macOS
    /// was told not to let this app control it. The first time, this is where macOS
    /// asks; the question can wait for an answer for two minutes.
    static func readyScript(bundleID: String) -> String {
        """
        on run argv
            tell application id "\(bundleID)" to launch
            repeat 40 times
                try
                    tell application id "\(bundleID)"
                        with timeout of 120 seconds
                            set idList to id of every document
                        end timeout
                    end tell
                    set AppleScript's text item delimiters to linefeed
                    return "ready" & linefeed & (idList as text)
                on error errorText number errorNumber
                    if errorNumber is -1743 then return "denied"
                end try
                delay 0.5
            end repeat
            return "not ready"
        end run
        """
    }

    /// The ids of the documents this conversion opened: new since `readyScript`, and
    /// either in the job's folder or imported under the copy's name.
    private static func ourDocumentsHandler(bundleID: String) -> String {
        """
        on ourDocs(jobId, knownIds, importName, copyName)
            set found to {}
            tell application id "\(bundleID)"
                repeat with i from 1 to (count of documents)
                    try
                        set docId to (id of document i) as text
                        if knownIds does not contain docId then
                            set docPath to ""
                            try
                                set docPath to POSIX path of (file of document i)
                            end try
                            set docName to (name of document i) as text
                            if docPath contains jobId or (docPath is "" and (docName is importName or docName is copyName)) then
                                set end of found to docId
                            end if
                        end if
                    end try
                end repeat
            end tell
            return found
        end ourDocs
        """
    }

    /// Closes what this conversion opened, then quits if asked and nothing else is open.
    static func tidyHandler(bundleID: String) -> String {
        ourDocumentsHandler(bundleID: bundleID) + """

        on tidy(jobId, knownIds, importName, copyName, quitting)
            tell application id "\(bundleID)"
                with timeout of 120 seconds
                    try
                        repeat with docId in my ourDocs(jobId, knownIds, importName, copyName)
                            close (first document whose id is (docId as text)) saving no
                        end repeat
                    end try
                    try
                        if quitting is "quit" and (count of documents) is 0 then quit
                    end try
                end timeout
            end tell
        end tidy
        """
    }

    /// The export command for each format the app makes, chosen by `exportKind`.
    static func exportCommands(for app: ConvertApp) -> String {
        let commands: [(Export, String)] = exports(for: app).map { export in
            let command = switch (app, export) {
            case (.keynote, .pdf): "export theDoc to outFile as PDF with properties {PDF image quality:Best}"
            case (.keynote, _): "export theDoc to outFile as Microsoft PowerPoint"
            case (.numbers, .pdf): "export theDoc to outFile as PDF with properties {image quality:Best}"
            // Each table becomes a worksheet of its own, without Numbers' list of them.
            case (.numbers, .excel): "export theDoc to outFile as Microsoft Excel with properties {exclude summary worksheet:true}"
            // A file, or a folder with one per table.
            case (.numbers, _): "export theDoc to outFile as CSV"
            case (.pages, .pdf): "export theDoc to outFile as PDF with properties {image quality:Best}"
            case (.pages, .word): "export theDoc to outFile as Microsoft Word"
            default: "export theDoc to outFile as unformatted text"
            }
            return (export, command)
        }
        var lines: [String] = []
        for (index, (export, command)) in commands.enumerated() {
            lines.append("\(index == 0 ? "if" : "else if") exportKind is \"\(export.rawValue)\" then")
            lines.append("    \(command)")
        }
        lines.append("else")
        lines.append("    error \"unknown format\"")
        lines.append("end if")
        return lines.map { String(repeating: " ", count: 16) + $0 }.joined(separator: "\n")
    }

    /// Waits up to 30 seconds for the copy to open, exports it, and closes it. Returns
    /// "ok", "denied", or what went wrong.
    static func script(for app: ConvertApp, bundleID: String) -> String {
        tidyHandler(bundleID: bundleID) + """

        on run argv
            set outFile to POSIX file (item 1 of argv)
            set exportKind to item 2 of argv
            set jobId to item 3 of argv
            set knownIds to item 4 of argv
            set importName to item 5 of argv
            set copyName to item 6 of argv
            set outcome to "not open"
            tell application id "\(bundleID)"
                with timeout of 200 seconds
                    try
                        set theDoc to missing value
                        repeat 60 times
                            set found to my ourDocs(jobId, knownIds, importName, copyName)
                            if found is not {} then
                                set theDoc to first document whose id is (item 1 of found)
                                exit repeat
                            end if
                            delay 0.5
                        end repeat
                        if theDoc is missing value then error "not open"
        \(exportCommands(for: app))
                        set outcome to "ok"
                    on error errorText number errorNumber
                        if errorNumber is -1743 then
                            set outcome to "denied"
                        else
                            set outcome to errorText
                        end if
                    end try
                end timeout
            end tell
            my tidy(jobId, knownIds, importName, copyName, item 7 of argv)
            return outcome
        end run
        """
    }

    // MARK: Converting

    /// Exports `input` with `app` to `out`. Throws `.notAllowed` when macOS was told
    /// not to let this app control it, `.appFailed` for anything else that goes wrong.
    static func convert(_ input: URL, with app: ConvertApp, to export: Export, out: URL) async throws {
        let name = input.lastPathComponent
        guard exports(for: app).contains(export), ConvertApp.isInstalled(app),
              let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleID)
        else { throw ConvertError.appFailed(name, app: app.fullName) }
        let bundleID = app.bundleID
        let id = UUID().uuidString
        let job = app.folder.appendingPathComponent(id, isDirectory: true)
        let copy = job.appendingPathComponent(name)
        let base = input.deletingPathExtension().lastPathComponent
        let result = job.appendingPathComponent("out", isDirectory: true)
            .appendingPathComponent(base.isEmpty ? "Converted" : base)
            .appendingPathExtension(export.fileExtension)
        do {
            try ConvertApp.prepare(app.folder)
            try FileManager.default.createDirectory(at: result.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            // The copy keeps the original's date; the sweep in `prepare` goes by the
            // job folder's, which is new.
            try FileManager.default.copyItem(at: input, to: copy)
        } catch {
            try? FileManager.default.removeItem(at: job)
            throw ConvertError.unreadable(name)
        }
        var tidied = false
        defer { if !tidied { try? FileManager.default.removeItem(at: job) } }
        try Task.checkCancellation()

        let wasRunning = app.isRunning
        let ready = await Osascript.run(readyScript(bundleID: bundleID), deadline: 150) ?? ""
        guard ready.hasPrefix("ready") else {
            try Task.checkCancellation()
            if !wasRunning { quit(app) }
            log.error("\(app.name, privacy: .public) didn't answer: \(ready, privacy: .public)")
            throw ready == "denied" ? ConvertError.notAllowed(name, app: app.fullName)
                : ConvertError.appFailed(name, app: app.fullName)
        }
        let known = String(ready.dropFirst("ready".count))
        let importName = copy.deletingPathExtension().lastPathComponent
        let arguments = [id, known, importName, name, wasRunning ? "stay" : "quit"]

        // Opened the way a double-click in Finder opens it, which also lets the
        // sandboxed app read it. An app that was just quitting (the last file in a
        // batch quit it) refuses: it's given a moment and asked again.
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        var opened = false
        for attempt in 0..<2 where !opened {
            if attempt > 0 { await ConvertApp.waitUntilQuit(app) }
            opened = (try? await NSWorkspace.shared.open([copy], withApplicationAt: appURL,
                                                         configuration: configuration)) != nil
        }
        guard opened else {
            tidied = true
            ConvertApp.tidy(handler: tidyHandler(bundleID: bundleID), arguments: arguments, removing: [job])
            try Task.checkCancellation()
            log.error("\(app.name, privacy: .public) didn't open the file")
            throw ConvertError.appFailed(name, app: app.fullName)
        }

        let outcome = await Osascript.run(script(for: app, bundleID: bundleID),
                                          arguments: [result.path, export.rawValue] + arguments,
                                          deadline: 290)
        guard !Task.isCancelled, outcome == "ok", FileManager.default.fileExists(atPath: result.path) else {
            // Stopped or failed part-way: the app may still have it open.
            tidied = true
            ConvertApp.tidy(handler: tidyHandler(bundleID: bundleID), arguments: arguments, removing: [job])
            try Task.checkCancellation()
            log.error("\(app.name, privacy: .public) conversion failed: \(outcome ?? "timed out", privacy: .public)")
            if outcome == "denied" { throw ConvertError.notAllowed(name, app: app.fullName) }
            throw ConvertError.appFailed(name, app: app.fullName)
        }
        do {
            if export == .text {
                // Pages ends lines the classic Mac way (CR): today's line feeds instead.
                try normalizedText(Data(contentsOf: result)).write(to: out)
            } else {
                try FileManager.default.moveItem(at: result, to: out)
            }
        } catch {
            throw ConvertError.failed(name)
        }
        app.hasWorked = true
        if !wasRunning { await ConvertApp.waitUntilQuit(app) }
    }

    /// A Numbers document's tables as CSV: `<base>.csv`, or a folder `<base>` with
    /// one per table. Numbers' own CSV export (values as Numbers shows them), rather
    /// than reading the .xlsx it saves: that puts each table's title above it as a
    /// row. Each file is tidied to match the CSV made from .xlsx files.
    static func csv(_ input: URL, folder: URL, base: String) async throws -> URL {
        let name = input.lastPathComponent
        let made = folder.appendingPathComponent(".\(UUID().uuidString).csv")
        defer { try? FileManager.default.removeItem(at: made) }
        try await convert(input, with: .numbers, to: .csv, out: made)
        do {
            let isFolder = (try? made.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            guard isFolder else {
                let out = folder.appendingPathComponent("\(base).csv")
                try tidiedCSV(Data(contentsOf: made)).write(to: out)
                return out
            }
            let tables = try FileManager.default.contentsOfDirectory(at: made, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension.lowercased() == "csv" }
                .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            let out = folder.appendingPathComponent(base, isDirectory: true)
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            for table in tables {
                try Task.checkCancellation()
                let file = OutputNaming.available(base: XLSX.fileName(table.deletingPathExtension().lastPathComponent),
                                                  ext: "csv", in: out)
                try tidiedCSV(Data(contentsOf: table)).write(to: file)
            }
            return out
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ConvertError.failed(name)
        }
    }

    /// Numbers pads each row to the table's width, empty columns and rows included.
    /// Those trailing ones go; the rest is written as UTF-8 with a byte-order mark,
    /// as Excel needs to read accents and Asian text right.
    static func tidiedCSV(_ data: Data) -> Data {
        var text = String(decoding: data, as: UTF8.self)
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        var rows = csvRows(text)
        while let last = rows.last, last.allSatisfy(\.isEmpty) { rows.removeLast() }
        let width = rows.map { ($0.lastIndex { !$0.isEmpty } ?? -1) + 1 }.max() ?? 0
        rows = rows.map { Array($0.prefix(width)) }
        return Data([0xEF, 0xBB, 0xBF]) + Data(XLSX.csv(rows).utf8)
    }

    /// RFC 4180: fields split by commas, rows by line ends; quoted fields may hold
    /// commas, line ends and doubled quotes.
    static func csvRows(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = String.UnicodeScalarView()
        var quoted = false
        let scalars = Array(text.unicodeScalars)
        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            let next = index + 1 < scalars.count ? scalars[index + 1] : nil
            if quoted {
                if scalar == "\"" {
                    if next == "\"" {
                        field.append("\"")
                        index += 1
                    } else {
                        quoted = false
                    }
                } else {
                    field.append(scalar)
                }
            } else if scalar == "\"", field.isEmpty {
                quoted = true
            } else if scalar == "," {
                row.append(String(field))
                field = String.UnicodeScalarView()
            } else if scalar == "\r" || scalar == "\n" {
                if scalar == "\r", next == "\n" { index += 1 }
                row.append(String(field))
                rows.append(row)
                row = []
                field = String.UnicodeScalarView()
            } else {
                field.append(scalar)
            }
            index += 1
        }
        if !field.isEmpty || !row.isEmpty {
            row.append(String(field))
            rows.append(row)
        }
        return rows
    }

    /// UTF-8 text with line feeds and a final one.
    static func normalizedText(_ data: Data) -> Data {
        var text = String(decoding: data, as: UTF8.self)
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        if !text.hasSuffix("\n") { text += "\n" }
        return Data(text.utf8)
    }

    /// An app this conversion launched and couldn't use (macOS refused, or it never
    /// answered): quit without Apple events, which may be what's refused.
    private static func quit(_ app: ConvertApp) {
        for bundleID in app.bundleIDs {
            for running in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID) {
                running.terminate()
            }
        }
    }
}
