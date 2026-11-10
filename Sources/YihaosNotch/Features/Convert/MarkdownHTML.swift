import Foundation

/// Markdown to HTML with Foundation's own parser (GitHub-flavoured: tables,
/// strikethrough, task lists), so no Markdown library ships with the app. The parser
/// marks each run of text with the blocks it sits in, innermost first; this rebuilds
/// the nesting from those.
enum MarkdownHTML {
    /// A complete page with a plain, readable style. `remoteImages` false replaces
    /// images on the web with their description, so converting fetches nothing.
    static func document(_ markdown: String, title: String, base: URL?, remoteImages: Bool = true) -> String {
        """
        <!DOCTYPE html>
        <html><head><meta charset="utf-8"><title>\(escape(title))</title>
        <style>
        body { font: 11pt -apple-system, "Helvetica Neue", Helvetica, Arial, sans-serif; line-height: 1.5; color: #1d1d1f; max-width: 46em; margin: 2em auto; padding: 0 1em; }
        h1, h2, h3, h4 { line-height: 1.25; margin: 1.2em 0 0.5em; }
        h1 { font-size: 22pt; } h2 { font-size: 17pt; } h3 { font-size: 14pt; }
        code { font: 10pt Menlo, Consolas, monospace; background: #f2f2f4; padding: 0 3px; }
        pre { background: #f2f2f4; padding: 10px 12px; }
        pre code { background: none; padding: 0; }
        blockquote { margin-left: 0; padding-left: 1em; border-left: 3px solid #d2d2d7; color: #555; }
        table { border-collapse: collapse; }
        th, td { border: 1px solid #d2d2d7; padding: 4px 10px; }
        th { background: #f5f5f7; }
        img { max-width: 100%; }
        </style></head>
        <body>
        \(body(markdown, base: base, remoteImages: remoteImages))
        </body></html>
        """
    }

    static func body(_ markdown: String, base: URL?, remoteImages: Bool = true) -> String {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .full, failurePolicy: .returnPartiallyParsedIfPossible)
        guard let parsed = try? AttributedString(markdown: markdown, options: options, baseURL: base) else {
            return "<pre>\(escape(markdown))</pre>"
        }
        var html = ""
        /// Blocks currently open, outermost first, with the tag that closes each.
        var open: [(block: PresentationIntent.IntentType, close: String)] = []

        for run in parsed.runs {
            let path = Array((run.presentationIntent?.components ?? []).reversed())
            var shared = 0
            while shared < open.count, shared < path.count, open[shared].block.identity == path[shared].identity {
                shared += 1
            }
            for entry in open[shared...].reversed() { html += entry.close }
            open.removeSubrange(shared...)
            for index in path.indices.dropFirst(shared) {
                let tags = tags(for: path[index], in: path[..<index])
                html += tags.open
                open.append((path[index], tags.close))
            }
            let text = String(parsed[run.range].characters)
            let innermost = open.last?.block.kind
            if case .codeBlock? = innermost {
                html += escape(text)
            } else if case .thematicBreak? = innermost {
                continue
            } else {
                html += inline(text, run: run, remoteImages: remoteImages)
            }
        }
        for entry in open.reversed() { html += entry.close }
        return html
    }

    private static func inline(_ text: String, run: AttributedString.Runs.Run, remoteImages: Bool) -> String {
        if let image = run.imageURL {
            if image.isFileURL || remoteImages {
                return "<img src=\"\(escape(image.absoluteString))\" alt=\"\(escape(text))\">"
            }
            return escape(text)
        }
        let intent = run.inlinePresentationIntent ?? []
        if intent.contains(.lineBreak) { return "<br>\n" }
        if intent.contains(.softBreak) { return "\n" }
        var html = escape(text)
        if intent.contains(.code) { html = "<code>\(html)</code>" }
        if intent.contains(.emphasized) { html = "<em>\(html)</em>" }
        if intent.contains(.stronglyEmphasized) { html = "<strong>\(html)</strong>" }
        if intent.contains(.strikethrough) { html = "<del>\(html)</del>" }
        if let link = run.link { html = "<a href=\"\(escape(link.absoluteString))\">\(html)</a>" }
        return html
    }

    /// Opening and closing tags for `block`, given the blocks around it (outermost
    /// first): a table cell needs its row (header or not) and its table (alignment).
    private static func tags(for block: PresentationIntent.IntentType,
                             in outer: ArraySlice<PresentationIntent.IntentType>) -> (open: String, close: String) {
        switch block.kind {
        case .paragraph: return ("<p>", "</p>\n")
        case .header(let level):
            let level = min(max(level, 1), 6)
            return ("<h\(level)>", "</h\(level)>\n")
        case .orderedList: return ("<ol>\n", "</ol>\n")
        case .unorderedList: return ("<ul>\n", "</ul>\n")
        case .listItem: return ("<li>", "</li>\n")
        case .codeBlock(let language):
            let open = language.map { "<pre><code class=\"language-\(escape($0))\">" } ?? "<pre><code>"
            return (open, "</code></pre>\n")
        case .blockQuote: return ("<blockquote>\n", "</blockquote>\n")
        case .thematicBreak: return ("<hr>\n", "")
        case .table: return ("<table>\n", "</table>\n")
        case .tableHeaderRow, .tableRow: return ("<tr>", "</tr>\n")
        case .tableCell(let column):
            let isHeader = outer.last.map { if case .tableHeaderRow = $0.kind { true } else { false } } ?? false
            let tag = isHeader ? "th" : "td"
            var style = ""
            if let table = outer.dropLast().last, case .table(let columns) = table.kind, columns.indices.contains(column) {
                switch columns[column].alignment {
                case .center: style = " style=\"text-align: center\""
                case .right: style = " style=\"text-align: right\""
                default: break
                }
            }
            return ("<\(tag)\(style)>", "</\(tag)>")
        @unknown default: return ("", "")
        }
    }

    static func escape(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        for character in text {
            switch character {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\"": result += "&quot;"
            default: result.append(character)
            }
        }
        return result
    }
}
