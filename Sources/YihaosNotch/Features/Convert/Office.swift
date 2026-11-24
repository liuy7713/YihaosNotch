import AppKit
import os

private let log = Logger(subsystem: "com.yihao.YihaosNotch", category: "Convert")

/// Slides to PDF or PowerPoint (.pptx) with Microsoft PowerPoint. Pictures of the
/// slides are drawn from the PDF.
enum PowerPointAutomation {
    private static let bundleID = ConvertApp.powerPoint.bundleID

    /// Closes every presentation with the id in its name (it keeps it after a save as
    /// .pptx: "<id>-out.pptx"), then quits if asked and nothing else is open.
    private static let tidyHandler = """
        on tidy(theId, quitting)
            tell application id "\(bundleID)"
                with timeout of 120 seconds
                    try
                        set presNames to name of every presentation
                        repeat with i from (count of presNames) to 1 by -1
                            if (item i of presNames as text) contains theId then close presentation i saving no
                        end repeat
                    end try
                    try
                        if quitting is "quit" and (count of presentations) is 0 then quit
                    end try
                end timeout
            end tell
        end tidy
        """

    // Variable names must not be PowerPoint terms ("saved" is one, and silently means
    // the presentation's property instead).
    // PowerPoint is asked for the presentation by the id in its file name (other
    // presentations may be open). Just after opening it lists none for a moment, so
    // it's asked again each second. Saving tries the path text PowerPoint's own
    // examples use, then a file. Whatever happens, `tidy` closes it afterwards.
    private static let script = tidyHandler + """

        on run argv
            set outFile to POSIX file (item 1 of argv)
            set outText to outFile as text
            set theId to item 4 of argv
            set didSave to false
            set failure to "not open"
            tell application id "\(bundleID)"
                with timeout of 200 seconds
                    try
                        set thePres to missing value
                        repeat 30 times
                            set presNames to name of every presentation
                            repeat with i from 1 to count of presNames
                                if (item i of presNames as text) contains theId then
                                    set thePres to presentation i
                                    exit repeat
                                end if
                            end repeat
                            if thePres is not missing value then exit repeat
                            delay 1
                        end repeat
                        if thePres is missing value then error "not open"
                        if item 2 of argv is "pdf" then
                            set fileType to save as PDF
                        else
                            set fileType to save as Open XML presentation
                        end if
                        -- The first time, PowerPoint may ask for access to the folder.
                        if item 3 of argv is "front" then activate
                        try
                            save thePres in outText as fileType
                        on error
                            save thePres in outFile as fileType
                        end try
                        set didSave to true
                    on error errorText
                        set failure to errorText
                    end try
                end timeout
            end tell
            my tidy(theId, item 5 of argv)
            if didSave then return "ok"
            error failure
        end run
        """

    static func convert(_ input: URL, to target: ConvertTarget, out: URL) async throws {
        let name = input.lastPathComponent
        let app = ConvertApp.powerPoint
        let id = UUID().uuidString
        let source: URL
        do {
            source = try ConvertApp.stage(input, for: app, id: id)
        } catch {
            throw ConvertError.unreadable(name)
        }
        let result = app.folder.appendingPathComponent("\(id)-out.\(target == .powerPoint ? "pptx" : "pdf")")
        var tidied = false
        defer {
            if !tidied {
                try? FileManager.default.removeItem(at: source)
                try? FileManager.default.removeItem(at: result)
            }
        }
        try Task.checkCancellation()

        let wasRunning = app.isRunning
        // PowerPoint's AppleScript `open` hangs, so the copy is opened the way a
        // double-click in Finder opens it, which also gives PowerPoint access to it.
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleID) else {
            throw ConvertError.appFailed(name, app: app.fullName)
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = !app.hasWorked
        configuration.addsToRecentItems = false
        do {
            _ = try await NSWorkspace.shared.open([source], withApplicationAt: appURL, configuration: configuration)
        } catch {
            log.error("PowerPoint didn't open the file")
            throw ConvertError.appFailed(name, app: app.fullName)
        }
        let output = await Osascript.run(script, arguments: [
            result.path, target == .powerPoint ? "pptx" : "pdf", app.hasWorked ? "back" : "front", id,
            wasRunning ? "stay" : "quit",
        ], deadline: 290)
        guard !Task.isCancelled, output == "ok", FileManager.default.fileExists(atPath: result.path) else {
            // Stopped or failed part-way: PowerPoint may still have it open.
            tidied = true
            ConvertApp.tidy(handler: tidyHandler, arguments: [id, wasRunning ? "stay" : "quit"], removing: [source, result])
            try Task.checkCancellation()
            log.error("PowerPoint conversion failed")
            throw ConvertError.appFailed(name, app: app.fullName)
        }
        do {
            try FileManager.default.moveItem(at: result, to: out)
        } catch {
            throw ConvertError.failed(name)
        }
        app.hasWorked = true
        if !wasRunning { await ConvertApp.waitUntilQuit(app) }
    }
}

/// Spreadsheets to PDF or Excel (.xlsx) with Microsoft Excel. CSV is read from the
/// .xlsx by `XLSX`, so it comes out as UTF-8 (Excel's own CSV isn't).
enum ExcelAutomation {
    private static let bundleID = ConvertApp.excel.bundleID

    /// Closes every workbook with the id in its path (its own copy, or the .xlsx it
    /// was saved as in the job folder), then quits if asked and nothing else is open
    /// (a Personal Macro Workbook doesn't count).
    private static let tidyHandler = """
        on tidy(theId, quitting)
            tell application id "\(bundleID)"
                with timeout of 120 seconds
                    try
                        set paths to full name of every workbook
                        repeat with i from (count of paths) to 1 by -1
                            if (item i of paths as text) contains theId then close workbook i saving no
                        end repeat
                    end try
                    try
                        if quitting is "quit" then
                            set others to 0
                            repeat with bookName in (name of every workbook)
                                if (bookName as text) does not start with "PERSONAL" then set others to others + 1
                            end repeat
                            if others is 0 then quit saving no
                        end if
                    end try
                end timeout
            end tell
        end tidy
        """

    private static let script = tidyHandler + """

        on run argv
            set inPath to item 1 of argv
            set outPath to item 2 of argv
            set inText to (POSIX file inPath) as text
            set outText to (POSIX file outPath) as text
            set didSave to false
            set failure to "not open"
            tell application id "\(bundleID)"
                with timeout of 200 seconds
                    try
                        if item 4 of argv is "front" then activate
                        try
                            set theBook to open workbook workbook file name inPath update links do not update links read only true
                        on error
                            set theBook to open workbook workbook file name inText update links do not update links read only true
                        end try
                        if theBook is missing value then error "not open"
                        if item 3 of argv is "pdf" then
                            set fileType to PDF file format
                        else
                            set fileType to workbook normal file format
                        end if
                        try
                            save workbook as theBook filename outPath file format fileType
                        on error
                            save workbook as theBook filename outText file format fileType
                        end try
                        set didSave to true
                    on error errorText
                        set failure to errorText
                    end try
                end timeout
            end tell
            my tidy(item 6 of argv, item 5 of argv)
            if didSave then return "ok"
            error failure
        end run
        """

    static func convert(_ input: URL, to target: ConvertTarget, out: URL) async throws {
        let name = input.lastPathComponent
        let app = ConvertApp.excel
        let id = UUID().uuidString
        // Excel may write a PDF per sheet next to the one asked for: it gets a folder
        // of its own, and every PDF in it is joined in the order they were made.
        let job = app.folder.appendingPathComponent(id, isDirectory: true)
        let source: URL
        do {
            source = try ConvertApp.stage(input, for: app, id: id)
        } catch {
            throw ConvertError.unreadable(name)
        }
        var tidied = false
        defer {
            if !tidied {
                try? FileManager.default.removeItem(at: source)
                try? FileManager.default.removeItem(at: job)
            }
        }
        do {
            try FileManager.default.createDirectory(at: job, withIntermediateDirectories: true)
        } catch {
            throw ConvertError.failed(name)
        }
        try Task.checkCancellation()
        let format = target == .pdf ? "pdf" : "xlsx"
        let result = job.appendingPathComponent("out.\(format)")

        let wasRunning = app.isRunning
        let output = await Osascript.run(script, arguments: [
            source.path, result.path, format, app.hasWorked ? "back" : "front", wasRunning ? "stay" : "quit", id,
        ], deadline: 290)
        let made = format == "pdf" ? madeFiles(in: job, ext: format)
            : FileManager.default.fileExists(atPath: result.path) ? [result] : []
        guard !Task.isCancelled, output == "ok", !made.isEmpty else {
            // Stopped or failed part-way: Excel may still have it open, or be writing.
            tidied = true
            ConvertApp.tidy(handler: tidyHandler, arguments: [id, wasRunning ? "stay" : "quit"], removing: [source, job])
            try Task.checkCancellation()
            log.error("Excel conversion failed")
            throw ConvertError.appFailed(name, app: app.fullName)
        }
        if made.count > 1 {
            try await Converters.renamingErrors(name) {
                try await Converters.combinedPDF(made, out: out, stripLocation: false)
            }
        } else {
            do {
                try FileManager.default.moveItem(at: made[0], to: out)
            } catch {
                throw ConvertError.failed(name)
            }
        }
        app.hasWorked = true
        if !wasRunning { await ConvertApp.waitUntilQuit(app) }
    }

    /// The PDFs Excel wrote, oldest first (not its "~$" lock files).
    private static func madeFiles(in folder: URL, ext: String) -> [URL] {
        let keys: [URLResourceKey] = [.creationDateKey, .isRegularFileKey]
        let items = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys)) ?? []
        var made: [(url: URL, date: Date)] = []
        for item in items where item.pathExtension.lowercased() == ext {
            let fileName = item.lastPathComponent
            guard !fileName.hasPrefix("~$"), !fileName.hasPrefix("."),
                  let values = try? item.resourceValues(forKeys: Set(keys)), values.isRegularFile == true
            else { continue }
            made.append((item, values.creationDate ?? .distantPast))
        }
        made.sort { first, second in
            first.date == second.date
                ? first.url.lastPathComponent.localizedStandardCompare(second.url.lastPathComponent) == .orderedAscending
                : first.date < second.date
        }
        return made.map(\.url)
    }
}
