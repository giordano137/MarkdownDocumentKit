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

/// One block-level element of a parsed document. Inline formatting (bold/italic/links) is
/// *not* broken out here — it stays as literal Markdown inside each block's `text`/cell string,
/// applied by whichever renderer consumes the block (see `DocumentRenderer.inlineAttributedString`
/// on macOS). Splitting inline runs out at the model layer would just mean redoing the same work
/// a renderer already needs to do to turn text into platform-specific styled runs.
public enum DocumentBlock: Equatable {
    case heading(level: Int, text: String)
    case paragraph(text: String)
    case listItem(ordered: Bool, number: Int?, level: Int, text: String)
    case codeBlock(lines: [String])
    /// `alignments.count == header.count`; every row in `rows` is padded/truncated to that same
    /// width by the parser, so a renderer never has to guard against ragged input. A cell left
    /// empty (GFM's usual "same as the row above" authoring convention) stays an empty string
    /// here — there's no real colspan/rowspan concept to model, GFM tables don't have one either.
    case table(header: [String], alignments: [TableAlignment], rows: [[String]])

    // Phase 3+: `.callout`, `.image` land here as they're implemented — every existing renderer
    // only needs a new `case` arm added, not a rewrite, same reasoning
    // `DocumentFormatConverters.all` in the 137 app uses for output formats.
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

        func flushCodeBlock() {
            guard !codeLines.isEmpty else { return }
            blocks.append(.codeBlock(lines: codeLines))
            codeLines = []
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
                }
                isCodeBlockOpen.toggle()
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

    /// Leading-whitespace-based nesting (2 spaces per level, tabs counted as 2 spaces) — the
    /// same convention `MessageParser.parseListLine` uses in the 137 app, reimplemented here
    /// rather than shared, since this package has zero dependencies (see README/Package.swift)
    /// and pulling in the app's own parser would mean depending on the app, backwards.
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
            return .listItem(ordered: false, number: nil, level: level, text: String(content.dropFirst(2)))
        }

        if let match = content.range(of: "^\\d+\\.\\s+", options: .regularExpression) {
            let numberString = content[content.startIndex..<match.upperBound]
                .trimmingCharacters(in: CharacterSet(charactersIn: ". \t"))
            let text = String(content[match.upperBound...])
            return .listItem(ordered: true, number: Int(numberString), level: level, text: text)
        }

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

    private static func normalizedRow(_ row: [String], toWidth width: Int) -> [String] {
        if row.count == width { return row }
        if row.count > width { return Array(row.prefix(width)) }
        return row + Array(repeating: "", count: width - row.count)
    }
}
