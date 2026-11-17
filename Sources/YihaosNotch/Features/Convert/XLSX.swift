import Foundation

/// Reads the cells of an .xlsx workbook to write them as CSV, in UTF-8 (Excel's own CSV
/// on the Mac isn't, so Chinese or accented text would turn into question marks).
/// Values come out as stored: numbers without currency signs or thousands separators,
/// dates as 2026-11-17, times as 14:30:00. Needs no Excel: an .xlsx is a zip of XML
/// files, read with the system's `unzip`, one part at a time and never written to disk.
enum XLSX {
    struct Sheet: Equatable {
        let name: String
        let rows: [[String]]
    }

    /// Parts bigger than this aren't read (a zip can expand enormously).
    static let partLimit = 256 << 20
    /// Cells across the workbook, counting the empty ones that pad rows to the same
    /// width, and shared strings.
    static let cellLimit = 10_000_000

    static func canRead(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "xlsx"
    }

    /// Writes `<base>.csv` for a workbook with one sheet, or a folder `<base>` with a
    /// CSV per sheet. Hidden sheets and empty ones are left out.
    @concurrent
    static func csv(_ input: URL, name: String, folder: URL, base: String) async throws -> URL {
        let sheets = try read(input, name: name).filter { !$0.rows.isEmpty }
        let bom = Data([0xEF, 0xBB, 0xBF])
        if sheets.count <= 1 {
            let out = folder.appendingPathComponent("\(base).csv")
            try write(bom + Data(csv(sheets.first?.rows ?? []).utf8), to: out, name: name)
            return out
        }
        let sheetsFolder = folder.appendingPathComponent(base, isDirectory: true)
        try FileManager.default.createDirectory(at: sheetsFolder, withIntermediateDirectories: true)
        for sheet in sheets {
            try Task.checkCancellation()
            let out = OutputNaming.available(base: fileName(sheet.name), ext: "csv", in: sheetsFolder)
            try write(bom + Data(csv(sheet.rows).utf8), to: out, name: name)
        }
        return sheetsFolder
    }

    private static func write(_ data: Data, to url: URL, name: String) throws {
        do {
            try data.write(to: url)
        } catch {
            throw ConvertError.failed(name)
        }
    }

    /// A sheet's name as a file name: no slashes or colons, not hidden.
    static func fileName(_ sheet: String) -> String {
        var name = sheet.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        if name.hasPrefix(".") { name = "_" + name.dropFirst() }
        return name.trimmingCharacters(in: .whitespaces).isEmpty ? "Sheet" : name
    }

    /// RFC 4180: commas, quotes around fields that need them, CRLF line ends. Every
    /// row is as wide as the widest, as spreadsheets expect.
    static func csv(_ rows: [[String]]) -> String {
        let width = rows.map(\.count).max() ?? 0
        var result = ""
        for row in rows {
            var fields = row.map(field)
            if fields.count < width { fields += Array(repeating: "", count: width - fields.count) }
            result += fields.joined(separator: ",")
            result += "\r\n"
        }
        return result
    }

    private static func field(_ value: String) -> String {
        guard value.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" })
            || value.first == " " || value.last == " "
        else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    // MARK: Reading

    static func read(_ input: URL, name: String) throws -> [Sheet] {
        guard let workbookData = try part("xl/workbook.xml", in: input, name: name),
              let relsData = try part("xl/_rels/workbook.xml.rels", in: input, name: name)
        else { throw ConvertError.unreadable(name) }
        let workbook = Workbook(workbookData)
        guard !workbook.sheets.isEmpty else { throw ConvertError.unreadable(name) }
        let parts = relationships(relsData)
        // The usual places when the relationships don't say.
        let strings = try part(parts.sharedStrings ?? "xl/sharedStrings.xml", in: input, name: name)
            .map { try sharedStrings($0, limit: cellLimit, name: name) } ?? []
        let styles = try part(parts.styles ?? "xl/styles.xml", in: input, name: name).map(numberStyles) ?? [:]

        var sheets: [Sheet] = []
        var cells = strings.count
        for entry in workbook.sheets where !entry.hidden {
            try Task.checkCancellation()
            guard let target = parts.worksheets[entry.relationship], let data = try part(target, in: input, name: name)
            else { continue }
            let rows = try cellRows(data, strings: strings, styles: styles, date1904: workbook.date1904,
                                    budget: cellLimit - cells, name: name)
            // Rows are padded to the widest when written.
            let width = rows.map(\.count).max() ?? 0
            let (padded, overflow) = rows.count.multipliedReportingOverflow(by: max(width, 1))
            cells += padded
            if overflow || cells > cellLimit { throw ConvertError.tooLarge(name) }
            sheets.append(Sheet(name: entry.name, rows: rows))
        }
        return sheets
    }

    /// One part of the zip, or nil if it isn't there. Names match whatever their case,
    /// as in Office files.
    static func part(_ path: String, in archive: URL, name: String) throws -> Data? {
        guard !path.isEmpty, !path.hasPrefix("-") else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        // unzip treats [ ] * ? in names as wildcards.
        let escaped = path.replacingOccurrences(of: #"([\[\]*?\\])"#, with: #"\\$1"#, options: .regularExpression)
        process.arguments = ["-p", "-C", archive.path, escaped]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw ConvertError.unreadable(name)
        }
        let handle = pipe.fileHandleForReading
        var data = Data()
        while true {
            if Task.isCancelled || data.count > partLimit {
                process.terminate()
                process.waitUntilExit()
                if Task.isCancelled { throw CancellationError() }
                throw ConvertError.tooLarge(name)
            }
            guard let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty else { break }
            data.append(chunk)
        }
        process.waitUntilExit()
        switch process.terminationStatus {
        case 0, 1: return data   // 1 is a warning, such as bytes before the zip
        case 11: return nil      // no such part
        default: throw ConvertError.unreadable(name)
        }
    }

    struct Workbook {
        struct Entry {
            let name: String
            let relationship: String
            let hidden: Bool
        }
        var sheets: [Entry] = []
        var date1904 = false

        init(_ data: Data) {
            var sheets: [Entry] = []
            var date1904 = false
            XMLWalker.walk(data, start: { element, attributes in
                switch element {
                case "workbookPr":
                    let value = attributes["date1904"]?.lowercased()
                    date1904 = value == "1" || value == "true"
                case "sheet":
                    guard let id = attributes["id"] else { return }
                    let state = attributes["state"] ?? "visible"
                    sheets.append(Entry(name: attributes["name"] ?? "Sheet", relationship: id,
                                        hidden: state != "visible"))
                default: break
                }
            })
            self.sheets = sheets
            self.date1904 = date1904
        }
    }

    struct Parts {
        /// Relationship id to path, for worksheets (not chart sheets).
        var worksheets: [String: String] = [:]
        var sharedStrings: String?
        var styles: String?
    }

    /// Where the workbook's parts are, from its relationships.
    static func relationships(_ data: Data) -> Parts {
        var parts = Parts()
        XMLWalker.walk(data, start: { element, attributes in
            guard element == "Relationship", let id = attributes["Id"], let target = attributes["Target"],
                  let type = attributes["Type"], attributes["TargetMode"] != "External"
            else { return }
            let path = resolve(target)
            if type.hasSuffix("/worksheet") { parts.worksheets[id] = path }
            if type.hasSuffix("/sharedStrings") { parts.sharedStrings = path }
            if type.hasSuffix("/styles") { parts.styles = path }
        })
        return parts
    }

    /// A relationship's target as a path in the zip: relative to xl/, or from the
    /// root when it starts with a slash, with "." and ".." worked out.
    static func resolve(_ target: String) -> String {
        var components: [Substring] = target.hasPrefix("/") ? [] : ["xl"]
        for component in target.split(separator: "/") {
            switch component {
            case ".": continue
            case "..": if !components.isEmpty { components.removeLast() }
            default: components.append(component)
            }
        }
        return components.joined(separator: "/")
    }

    /// The workbook's text, by index. Phonetic guides (Japanese furigana) are skipped.
    static func sharedStrings(_ data: Data, limit: Int, name: String) throws -> [String] {
        var strings: [String] = []
        var current = ""
        var inText = false
        var inPhonetic = false
        var overLimit = false
        XMLWalker.walk(data, start: { element, _ in
            switch element {
            case "si": current = ""
            case "t": inText = true
            case "rPh": inPhonetic = true
            default: break
            }
            return !overLimit
        }, end: { element in
            switch element {
            case "si":
                strings.append(unescape(current))
                if strings.count > limit { overLimit = true }
            case "t": inText = false
            case "rPh": inPhonetic = false
            default: break
            }
        }, text: { text in
            if inText, !inPhonetic { current += text }
        })
        try Task.checkCancellation()
        if overLimit { throw ConvertError.tooLarge(name) }
        return strings
    }

    /// Excel writes characters XML can't hold, such as a carriage return, as _x000D_
    /// (and a literal "_x" as _x005F_x).
    static func unescape(_ text: String) -> String {
        guard text.contains("_x") else { return text }
        let regex = /_x([0-9A-Fa-f]{4})_/
        return text.replacing(regex) { match in
            guard let value = UInt32(match.1, radix: 16), let scalar = Unicode.Scalar(value) else {
                return String(match.0)
            }
            return String(Character(scalar))
        }
    }

    /// How a number formatted with a style is shown.
    enum NumberStyle: Equatable {
        /// A date, with its time if it has one.
        case date
        /// A time of day: the date part is left out.
        case time
        /// A duration such as [h]:mm, shown as total hours: 30:00:00.
        case elapsed
    }

    /// Which cell styles (by index) show dates and times.
    static func numberStyles(_ data: Data) -> [Int: NumberStyle] {
        var custom: [Int: String] = [:]
        var formats: [Int] = []
        var inCellFormats = false
        XMLWalker.walk(data, start: { element, attributes in
            switch element {
            case "numFmt":
                if let id = attributes["numFmtId"].flatMap(Int.init), let code = attributes["formatCode"] {
                    custom[id] = code
                }
            case "cellXfs": inCellFormats = true
            case "xf" where inCellFormats:
                formats.append(attributes["numFmtId"].flatMap(Int.init) ?? 0)
            default: break
            }
            return true
        }, end: { element in
            if element == "cellXfs" { inCellFormats = false }
        })
        var result: [Int: NumberStyle] = [:]
        for (index, id) in formats.enumerated() {
            if let style = numberStyle(id: id, code: custom[id]) { result[index] = style }
        }
        return result
    }

    /// Excel's built-in date and time formats, or what a custom one shows: a date if it
    /// has a day, month or year, a time if it has only hours, minutes or seconds, a
    /// duration with [h], [m] or [s]. Quoted text, [colour] and [$-locale] codes,
    /// escaped characters and padding (_x, *x) don't count.
    static func numberStyle(id: Int, code: String?) -> NumberStyle? {
        switch id {
        case 14...17, 22, 27...36, 50...58: return .date
        case 18...21, 45, 47: return .time
        case 46: return .elapsed
        default: break
        }
        guard let code else { return nil }
        // The first section is the one for positive numbers.
        let section = code
            .replacingOccurrences(of: #""[^"]*""#, with: "", options: .regularExpression)
            .split(separator: ";", omittingEmptySubsequences: false).first.map(String.init) ?? ""
        let lowered = section.lowercased()
        if lowered.contains("[h") || lowered.contains("[m") || lowered.contains("[s") { return .elapsed }
        let stripped = lowered
            .replacingOccurrences(of: #"\[[^\]]*\]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"[\\_*]."#, with: "", options: .regularExpression)
        if stripped.contains(where: { $0 == "y" || $0 == "d" }) { return .date }
        if stripped.contains(where: { $0 == "h" || $0 == "s" }) { return .time }
        // m alone is a month (mmm, mmmm).
        if stripped.contains("m") { return .date }
        return nil
    }

    /// The cells of one sheet, row by row from A1, as text.
    static func cellRows(_ data: Data, strings: [String], styles: [Int: NumberStyle], date1904: Bool,
                         budget: Int, name: String) throws -> [[String]] {
        let maxRows = 1_048_576
        let maxColumns = 16_384
        var rows: [[String]] = []
        var cells = 0
        var overBudget = false
        var rowIndex = -1
        var columnIndex = -1
        var type = "n"
        var style = 0
        var value = ""
        var inValue = false
        var inPhonetic = false

        XMLWalker.walk(data, start: { element, attributes in
            switch element {
            case "row":
                if let number = attributes["r"].flatMap(Int.init) {
                    rowIndex = (1...maxRows).contains(number) ? number - 1 : maxRows
                } else {
                    rowIndex = min(rowIndex + 1, maxRows)
                }
                columnIndex = -1
            case "c":
                let reference = attributes["r"].flatMap(cell)
                columnIndex = reference?.column ?? min(columnIndex + 1, maxColumns)
                if let row = reference?.row { rowIndex = row }
                type = attributes["t"] ?? "n"
                style = attributes["s"].flatMap(Int.init) ?? 0
                value = ""
            case "v", "t": inValue = true
            case "rPh": inPhonetic = true
            default: break
            }
            return !overBudget
        }, end: { element in
            switch element {
            case "v", "t": inValue = false
            case "rPh": inPhonetic = false
            case "c":
                guard !overBudget, (0..<maxRows).contains(rowIndex), (0..<maxColumns).contains(columnIndex) else {
                    return
                }
                let text = display(value, type: type, style: styles[style], date1904: date1904, strings: strings)
                guard !text.isEmpty else { return }
                let newRows = max(0, rowIndex + 1 - rows.count)
                let newCells = max(0, columnIndex + 1 - (rowIndex < rows.count ? rows[rowIndex].count : 0))
                cells += newRows + newCells
                if cells > budget {
                    overBudget = true
                    return
                }
                if newRows > 0 { rows += Array(repeating: [], count: newRows) }
                if newCells > 0 { rows[rowIndex] += Array(repeating: "", count: newCells) }
                rows[rowIndex][columnIndex] = text
            default: break
            }
        }, text: { text in
            if inValue, !inPhonetic { value += text }
        })
        try Task.checkCancellation()
        if overBudget { throw ConvertError.tooLarge(name) }
        return rows
    }

    /// "B12" → column 1, row 11 (both from zero). The row is nil when it's missing or
    /// out of range.
    static func cell(_ reference: String) -> (column: Int, row: Int?)? {
        var column = 0
        var letters = 0
        var digits = Substring()
        for (offset, scalar) in reference.unicodeScalars.enumerated() {
            let value = scalar.value
            if value >= 65 && value <= 90 {
                column = column * 26 + Int(value - 64)
                letters += 1
                if letters > 3 { return nil }
            } else {
                digits = reference.dropFirst(offset)
                break
            }
        }
        guard letters > 0 else { return nil }
        let row = Int(digits).flatMap { (1...1_048_576).contains($0) ? $0 - 1 : nil }
        return (column - 1, row)
    }

    /// "B12" → 1.
    static func column(_ reference: String) -> Int? {
        cell(reference)?.column
    }

    static func display(_ value: String, type: String, style: NumberStyle?, date1904: Bool,
                        strings: [String]) -> String {
        switch type {
        case "s":
            guard let index = Int(value.trimmingCharacters(in: .whitespaces)), strings.indices.contains(index)
            else { return "" }
            return strings[index]
        case "b":
            return value == "1" ? "TRUE" : value == "0" ? "FALSE" : value
        case "str", "inlineStr":
            return unescape(value)
        case "e", "d":
            return value
        default:
            guard let number = Double(value.trimmingCharacters(in: .whitespaces)), number.isFinite else { return value }
            if let style, let text = dateTime(number, style: style, date1904: date1904) { return text }
            return format(number)
        }
    }

    /// Whole numbers exactly (up to 2^53), others to 15 significant digits as Excel
    /// keeps them.
    static func format(_ number: Double) -> String {
        if number == 0 { return "0" }
        if number.rounded() == number, abs(number) < 9_007_199_254_740_992 { return String(Int64(number)) }
        return String(format: "%.15g", number)
    }

    static func dateTime(_ serial: Double, style: NumberStyle, date1904: Bool) -> String? {
        switch style {
        case .date: return date(serial, date1904: date1904)
        case .time: return serial >= 0 ? clock(Int(((serial - serial.rounded(.down)) * 86_400).rounded()) % 86_400) : nil
        case .elapsed:
            guard abs(serial) < 1e9 else { return nil }
            let seconds = Int((abs(serial) * 86_400).rounded())
            return (serial < 0 ? "-" : "") + String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
        }
    }

    private static func clock(_ seconds: Int) -> String {
        String(format: "%02d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
    }

    /// A serial date as 2026-11-17, 2026-11-17 14:30:00, or 14:30:00 for a time alone.
    static func date(_ serial: Double, date1904: Bool) -> String? {
        guard serial >= 0, serial < 2_958_466 else { return nil }   // up to 9999-12-31
        var days = Int(serial.rounded(.down))
        var seconds = Int(((serial - Double(days)) * 86_400).rounded())
        if seconds >= 86_400 {
            days += 1
            seconds = 0
        }
        // Excel counts a 29 February 1900 that never was; dates before it are a day off.
        if !date1904, days < 60 { days += 1 }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let epoch = date1904 ? DateComponents(year: 1904, month: 1, day: 1) : DateComponents(year: 1899, month: 12, day: 30)
        guard let start = calendar.date(from: epoch),
              let day = calendar.date(byAdding: .day, value: days, to: start)
        else { return nil }
        let parts = calendar.dateComponents([.year, .month, .day], from: day)
        let time = clock(seconds)
        if serial < 1, !date1904 { return time }
        let date = String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
        return seconds == 0 ? date : "\(date) \(time)"
    }
}

/// Calls back for each element's start and end and its text, with namespace
/// prefixes taken off element and attribute names ("x:row" is "row", "r:id" is "id";
/// namespace declarations are left out). `start` returns false to stop, and parsing
/// also stops when the task is cancelled. External entities are never loaded.
final class XMLWalker: NSObject, XMLParserDelegate {
    private let start: (String, [String: String]) -> Bool
    private let end: (String) -> Void
    private let text: (String) -> Void

    private init(start: @escaping (String, [String: String]) -> Bool, end: @escaping (String) -> Void,
                 text: @escaping (String) -> Void) {
        self.start = start
        self.end = end
        self.text = text
    }

    static func walk(_ data: Data, start: @escaping (String, [String: String]) -> Bool,
                     end: @escaping (String) -> Void = { _ in }, text: @escaping (String) -> Void = { _ in }) {
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        let walker = XMLWalker(start: start, end: end, text: text)
        parser.delegate = walker
        parser.parse()
    }

    /// For callers that never stop early.
    static func walk(_ data: Data, start: @escaping (String, [String: String]) -> Void) {
        walk(data, start: { element, attributes in
            start(element, attributes)
            return true
        })
    }

    private static func local(_ name: String) -> String {
        name.firstIndex(of: ":").map { String(name[name.index(after: $0)...]) } ?? name
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        var attributes: [String: String] = [:]
        for (key, value) in attributeDict where key != "xmlns" && !key.hasPrefix("xmlns:") {
            attributes[Self.local(key)] = value
        }
        if !start(Self.local(elementName), attributes) || Task.isCancelled { parser.abortParsing() }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?) {
        end(Self.local(elementName))
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text(string)
    }
}
