// DocumentBlock
//
// The block-level model a Markdown source is parsed into, before any rendering happens.
// Deliberately a plain, platform-agnostic data model (no NSAttributedString/NSFont/UIFont
// anywhere in this file) — a renderer (AppKit today, UIKit later, or something else entirely)
// turns these into whatever final form it needs, but the parse step itself never has to know.

import Foundation

/// Per-column alignment from a table's delimiter row (`:---`/`:---:`/`---:`/`---`).
public enum TableAlignment: Equatable {
    case none, left, center, right
}

/// GFM's "alert" convention: a blockquote whose first line is one of these four markers on its
/// own (`> [!NOTE]`, then the body on following `>` lines). `rawValue` is the label a renderer
/// shows verbatim (title-cased, not the all-caps marker spelling).
public enum CalloutKind: String, Hashable, CaseIterable {
    case note = "Note"
    case tip = "Tip"
    case warning = "Warning"
    case important = "Important"
}

/// One block-level element of a parsed document. Inline formatting (bold/italic/links) is
/// *not* broken out here — it stays as literal Markdown inside each block's `text`/cell string,
/// applied by whichever renderer consumes the block (see `DocumentRenderer.inlineAttributedString`
/// on macOS). Splitting inline runs out at the model layer would just mean redoing the same work
/// a renderer already needs to do to turn text into platform-specific styled runs.
public enum DocumentBlock: Equatable {
    case heading(level: Int, text: String)
    case paragraph(text: String)
    case blockquote(text: String)
    /// A GFM alert (`> [!NOTE]` etc.) — a blockquote whose marker line identified it as one of
    /// the four known kinds. A plain blockquote whose first line merely *contains* `[!NOTE]`-like
    /// text but isn't formatted as the marker convention stays `.blockquote` instead; see
    /// `DocumentParser`'s blockquote branch for the exact check.
    case callout(kind: CalloutKind, text: String)
    case listItem(ordered: Bool, number: Int?, level: Int, text: String)
    /// A GFM task list item (`- [ ] ...`/`- [x] ...`) — a separate case rather than an added
    /// field on `.listItem`, same "specialized variant gets its own case" shape `.callout` already
    /// uses relative to `.blockquote`: adding a parameter to `.listItem` instead would source-break
    /// every existing exhaustive `switch` over it, in this package and in any consumer's, for a
    /// distinction that GFM itself treats as a different list-item kind, not a `.listItem` flag
    /// (task list markers are only ever unordered — GFM has no numbered task list syntax — so this
    /// carries no `ordered`/`number` fields `.listItem` has).
    case taskListItem(checked: Bool, level: Int, text: String)
    /// A footnote's definition (`[^id]: text`, its own whole line) — GFM convention lets these
    /// sit anywhere in the source (traditionally grouped at the end), so `DocumentRenderer`
    /// collects every one into a single "Footnotes" section it appends after the rest of the
    /// document, numbered by the order each identifier is first *referenced* (a `[^id]` inline in
    /// some other block's `text`) rather than by where its definition happens to sit in the
    /// source — matching how GFM itself numbers footnotes. A definition with no matching
    /// reference anywhere is dropped, not shown, since there'd be no footnote number to give it.
    /// The reference itself (`[^id]`) is deliberately *not* its own case here, same reasoning as
    /// inline math: it stays literal inside whichever block's `text` it's written in, resolved by
    /// `DocumentRenderer` at render time, not decomposed at the model layer.
    case footnoteDefinition(identifier: String, text: String)
    /// `language` is the fence's info string verbatim (` ```swift ` → `"swift"`), `nil` for a bare
    /// ` ``` ` fence with nothing after it — this package renders every code block identically
    /// regardless (no syntax highlighting; see README's "zero dependencies" reasoning), but
    /// carrying the tag through rather than discarding it lets a consumer that *does* want
    /// highlighting build one on top instead of losing the information at parse time with no way
    /// to get it back. A change to this case's shape (not a new sibling case, unlike `.callout`/
    /// `.taskListItem`) since this is the same block gaining an extra piece of metadata, not GFM
    /// treating a tagged code block as a semantically different construct the way a task list item
    /// is a different list-item kind — a second, near-duplicate case would just mean every consumer
    /// switch (and `DocumentRenderer`'s own) handling two cases that render identically.
    case codeBlock(language: String?, lines: [String])
    /// `alignments.count == header.count`; every row in `rows` is padded/truncated to that same
    /// width by the parser, so a renderer never has to guard against ragged input. A cell left
    /// empty (GFM's usual "same as the row above" authoring convention) stays an empty string
    /// here — there's no real colspan/rowspan concept to model, GFM tables don't have one either.
    case table(header: [String], alignments: [TableAlignment], rows: [[String]])
    /// A standalone display equation — the whole content of a `\[...\]` or `$$...$$` block (own
    /// line(s), not mixed with surrounding prose). `latex` excludes the delimiters. Inline math
    /// (`$...$`/`\(...\)` mid-sentence) is *not* a block of its own — see `DocumentRenderer`,
    /// which extracts it from a `.paragraph`/`.listItem`/`.blockquote`'s text at render time so it
    /// keeps flowing with the surrounding words instead of breaking the paragraph apart.
    case formula(latex: String)
    /// A standalone `![alt](source)` image, recognized only when it's the *entire* line — like
    /// `.formula`, this package doesn't attempt inline image flow mid-sentence (bounded,
    /// block-level scope, not full CommonMark inline parsing; see README). `source` is whatever
    /// the Markdown wrote verbatim: a `data:image/...;base64,...` URI (which `DocumentRenderer`
    /// decodes directly, no consumer code needed), a local file path, or a remote URL (both of
    /// which need an injected `ImageRenderer`, since this package does no disk/network I/O of
    /// its own).
    case image(altText: String, source: String)
    /// A fenced ` ```mermaid ` code block — recognized specifically (the parser checks the fence's
    /// language tag) because it needs to become a rendered diagram image via an injected
    /// `DiagramRenderer`, not a monospaced text dump the way every other fenced language stays a
    /// plain `.codeBlock`. `source` is the fence's raw content, unmodified.
    case diagram(source: String)
}

/// Turns Markdown source into `[DocumentBlock]`. Line-oriented, not a full CommonMark
/// implementation — see README for why a bounded, known set of constructs is the point rather
/// than a limitation to fix.
public enum DocumentParser {
    public static func parse(_ markdown: String) -> [DocumentBlock] {
        var blocks: [DocumentBlock] = []
        let lines = markdown.components(separatedBy: "\n")

        var isCodeBlockOpen = false
        var codeLines: [String] = []
        var codeBlockLanguage = ""

        func flushCodeBlock() {
            guard !codeLines.isEmpty else { return }
            if codeBlockLanguage.lowercased() == "mermaid" {
                blocks.append(.diagram(source: codeLines.joined(separator: "\n")))
            } else {
                let language = codeBlockLanguage.isEmpty ? nil : codeBlockLanguage
                blocks.append(.codeBlock(language: language, lines: codeLines))
            }
            codeLines = []
            codeBlockLanguage = ""
        }

        // Index-based rather than `for rawLine in lines` — a table block needs to look ahead
        // at the delimiter row before committing to "this is a table" and then consume however
        // many body rows follow, which a single-line-at-a-time loop can't express.
        var index = 0
        while index < lines.count {
            let rawLine = lines[index]
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") {
                if isCodeBlockOpen {
                    flushCodeBlock()
                    isCodeBlockOpen = false
                } else {
                    codeBlockLanguage = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                    isCodeBlockOpen = true
                }
                index += 1
                continue
            }
            if isCodeBlockOpen {
                codeLines.append(rawLine)
                index += 1
                continue
            }
            if trimmed.isEmpty {
                index += 1
                continue
            }

            if let heading = parseHeading(trimmed) {
                blocks.append(heading)
                index += 1
                continue
            }

            if let image = parseImageLine(trimmed) {
                blocks.append(image)
                index += 1
                continue
            }

            if let footnote = parseFootnoteDefinition(trimmed) {
                blocks.append(footnote)
                index += 1
                continue
            }

            // Checked before the table branch below: a formula containing "|" (e.g. absolute-value
            // bars, `|x|`) would otherwise risk being mistaken for a table row.
            if let formula = parseDisplayFormula(trimmed, lines: lines, index: &index) {
                blocks.append(formula)
                continue
            }

            // Checked before the table branch below: a quoted line containing "|" (a quoted
            // table row, or just a literal pipe) would otherwise risk being mistaken for one.
            if trimmed.hasPrefix(">") {
                var quotedLines: [String] = []
                while index < lines.count {
                    let quotedTrimmed = lines[index].trimmingCharacters(in: .whitespaces)
                    guard quotedTrimmed.hasPrefix(">") else { break }
                    var stripped = String(quotedTrimmed.dropFirst())
                    if stripped.hasPrefix(" ") { stripped.removeFirst() }
                    quotedLines.append(stripped)
                    index += 1
                }
                // GFM alert convention: the marker has to be the *entire* first line, not just
                // text that happens to contain it — a real quote like "> He said [!NOTE] once."
                // must stay a plain blockquote.
                if let first = quotedLines.first, let kind = calloutKind(forMarkerLine: first) {
                    blocks.append(.callout(kind: kind, text: quotedLines.dropFirst().joined(separator: " ")))
                } else {
                    blocks.append(.blockquote(text: quotedLines.joined(separator: " ")))
                }
                continue
            }

            if trimmed.contains("|"), index + 1 < lines.count,
                let alignments = parseDelimiterRow(lines[index + 1])
            {
                let header = parseTableRow(trimmed)
                var rowIndex = index + 2
                var rows: [[String]] = []
                while rowIndex < lines.count {
                    let rowLine = lines[rowIndex]
                    let rowTrimmed = rowLine.trimmingCharacters(in: .whitespaces)
                    guard !rowTrimmed.isEmpty, rowTrimmed.contains("|") else { break }
                    rows.append(normalizedRow(parseTableRow(rowTrimmed), toWidth: header.count))
                    rowIndex += 1
                }
                blocks.append(.table(header: normalizedRow(header, toWidth: header.count), alignments: alignments, rows: rows))
                index = rowIndex
                continue
            }

            if let listItem = parseListLine(rawLine) {
                blocks.append(listItem)
                index += 1
                continue
            }

            blocks.append(.paragraph(text: trimmed))
            index += 1
        }
        flushCodeBlock()
        return blocks
    }

    private static func parseHeading(_ trimmed: String) -> DocumentBlock? {
        guard let range = trimmed.range(of: "^#{1,6}\\s+", options: .regularExpression) else { return nil }
        let level = trimmed.distance(from: trimmed.startIndex, to: range.upperBound) - 1
        let text = String(trimmed[range.upperBound...])
        return .heading(level: level, text: text)
    }

    /// Leading-whitespace-based nesting (2 spaces per level, tabs counted as 2 spaces) — a plain,
    /// self-contained implementation, since this package has zero dependencies (see
    /// README/Package.swift) and pulling in a consumer app's own list parser would mean depending
    /// on the app, backwards.
    private static func parseListLine(_ rawLine: String) -> DocumentBlock? {
        var indent = 0
        var index = rawLine.startIndex
        while index < rawLine.endIndex {
            if rawLine[index] == " " {
                indent += 1
            } else if rawLine[index] == "\t" {
                indent += 2
            } else {
                break
            }
            index = rawLine.index(after: index)
        }
        let content = String(rawLine[index...])
        let level = indent / 2

        if content.hasPrefix("- ") || content.hasPrefix("* ") || content.hasPrefix("+ ") {
            let rest = String(content.dropFirst(2))
            if let checked = taskListChecked(rest) {
                return .taskListItem(checked: checked, level: level, text: String(rest.dropFirst(4)))
            }
            return .listItem(ordered: false, number: nil, level: level, text: rest)
        }

        if let match = content.range(of: "^\\d+\\.\\s+", options: .regularExpression) {
            let numberString = content[content.startIndex..<match.upperBound]
                .trimmingCharacters(in: CharacterSet(charactersIn: ". \t"))
            let text = String(content[match.upperBound...])
            return .listItem(ordered: true, number: Int(numberString), level: level, text: text)
        }

        return nil
    }

    /// `nil` for a plain (non-task) list item's content — GFM requires the checkbox marker
    /// (`[ ]`/`[x]`/`[X]`, exactly one space inside the brackets, then a space before the item's
    /// text) to sit immediately after the bullet with nothing else between them.
    private static func taskListChecked(_ content: String) -> Bool? {
        if content.hasPrefix("[ ] ") { return false }
        if content.hasPrefix("[x] ") || content.hasPrefix("[X] ") { return true }
        return nil
    }

    // MARK: - Tables

    /// Splits a `| a | b |` (leading/trailing pipes optional, GFM allows both) row on
    /// unescaped `|`, trimming whitespace and un-escaping `\|` back to a literal pipe.
    private static func parseTableRow(_ line: String) -> [String] {
        var cells: [String] = []
        var current = ""
        var previousWasBackslash = false
        var body = line.trimmingCharacters(in: .whitespaces)
        if body.hasPrefix("|") { body.removeFirst() }
        if body.hasSuffix("|") { body.removeLast() }

        for character in body {
            if character == "|" && !previousWasBackslash {
                cells.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(character)
            }
            previousWasBackslash = (character == "\\") && !previousWasBackslash
        }
        cells.append(current.trimmingCharacters(in: .whitespaces))
        return cells.map { $0.replacingOccurrences(of: "\\|", with: "|") }
    }

    /// `nil` when `line` isn't a valid delimiter row at all — the caller uses that to decide
    /// "this wasn't actually a table", not just "this table has no alignment hints".
    private static func parseDelimiterRow(_ line: String) -> [TableAlignment]? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("-") else { return nil }
        let cells = parseTableRow(trimmed)
        guard !cells.isEmpty else { return nil }

        var alignments: [TableAlignment] = []
        for cell in cells {
            guard cell.range(of: "^:?-+:?$", options: .regularExpression) != nil else { return nil }
            switch (cell.hasPrefix(":"), cell.hasSuffix(":")) {
            case (true, true): alignments.append(.center)
            case (true, false): alignments.append(.left)
            case (false, true): alignments.append(.right)
            case (false, false): alignments.append(.none)
            }
        }
        return alignments
    }

    // MARK: - Display formulas

    /// Recognizes a `\[...\]`/`$$...$$` display equation, either written on one line
    /// (`\[E = mc^2\]`) or as its own fenced block spanning several lines (opening `\[`/`$$` alone
    /// on a line, content, then a matching closing `\]`/`$$` alone on a line). Advances `index`
    /// itself (like the table branch above, which also consumes a variable number of lines) and
    /// returns `nil` without touching `index` if `trimmed` isn't a formula opener at all.
    private static func parseDisplayFormula(_ trimmed: String, lines: [String], index: inout Int) -> DocumentBlock? {
        if let range = trimmed.range(of: "^\\\\\\[(.*)\\\\\\]$", options: .regularExpression) {
            let inner = trimmed[range]
            let latex = String(inner.dropFirst(2).dropLast(2))
            index += 1
            return .formula(latex: latex)
        }
        if let range = trimmed.range(of: "^\\$\\$(.*)\\$\\$$", options: .regularExpression) {
            let inner = trimmed[range]
            let latex = String(inner.dropFirst(2).dropLast(2))
            index += 1
            return .formula(latex: latex)
        }

        let opensFencedBlock = trimmed == "\\[" || trimmed == "$$"
        guard opensFencedBlock else { return nil }
        let closingMarker = trimmed == "\\[" ? "\\]" : "$$"

        var formulaLines: [String] = []
        var cursor = index + 1
        while cursor < lines.count {
            let candidate = lines[cursor].trimmingCharacters(in: .whitespaces)
            if candidate == closingMarker { break }
            formulaLines.append(lines[cursor])
            cursor += 1
        }
        index = min(cursor + 1, lines.count)
        return .formula(latex: formulaLines.joined(separator: "\n"))
    }

    // MARK: - Callouts

    /// Matches a line that is *exactly* `[!NOTE]`/`[!TIP]`/`[!WARNING]`/`[!IMPORTANT]` (case
    /// insensitive — a model writing `[!Note]` shouldn't fall back to a plain, unstyled
    /// blockquote just for that), with no other content on the line.
    private static func calloutKind(forMarkerLine line: String) -> CalloutKind? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("[!"), trimmed.hasSuffix("]") else { return nil }
        let name = trimmed.dropFirst(2).dropLast(1).uppercased()
        switch name {
        case "NOTE": return .note
        case "TIP": return .tip
        case "WARNING": return .warning
        case "IMPORTANT": return .important
        default: return nil
        }
    }

    // MARK: - Images

    /// Recognizes a whole-line `![alt](source)`. Deliberately simple, not full CommonMark link
    /// syntax: alt text can't contain `]`, source can't contain `)` — a fine trade for a bounded
    /// implementation (see README) that covers what a model actually writes for an image link.
    private static func parseImageLine(_ trimmed: String) -> DocumentBlock? {
        guard let regex = try? NSRegularExpression(pattern: "^!\\[([^\\]]*)\\]\\(([^)]*)\\)$") else { return nil }
        let nsRange = NSRange(location: 0, length: (trimmed as NSString).length)
        guard let match = regex.firstMatch(in: trimmed, range: nsRange),
            let altRange = Range(match.range(at: 1), in: trimmed),
            let sourceRange = Range(match.range(at: 2), in: trimmed)
        else { return nil }
        return .image(altText: String(trimmed[altRange]), source: String(trimmed[sourceRange]))
    }

    // MARK: - Footnotes

    /// Recognizes a whole-line `[^id]: definition text` — the identifier can't contain `]`, same
    /// bounded-syntax trade-off `parseImageLine` already makes for its own bracketed pieces.
    private static func parseFootnoteDefinition(_ trimmed: String) -> DocumentBlock? {
        guard let regex = try? NSRegularExpression(pattern: "^\\[\\^([^\\]]+)\\]:\\s+(.+)$") else { return nil }
        let nsRange = NSRange(location: 0, length: (trimmed as NSString).length)
        guard let match = regex.firstMatch(in: trimmed, range: nsRange),
            let idRange = Range(match.range(at: 1), in: trimmed),
            let textRange = Range(match.range(at: 2), in: trimmed)
        else { return nil }
        return .footnoteDefinition(identifier: String(trimmed[idRange]), text: String(trimmed[textRange]))
    }

    private static func normalizedRow(_ row: [String], toWidth width: Int) -> [String] {
        if row.count == width { return row }
        if row.count > width { return Array(row.prefix(width)) }
        return row + Array(repeating: "", count: width - row.count)
    }
}
