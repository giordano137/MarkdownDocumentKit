// DocumentBlock
//
// The block-level model a Markdown source is parsed into, before any rendering happens.
// Deliberately a plain, platform-agnostic data model (no NSAttributedString/NSFont/UIFont
// anywhere in this file) — a renderer (AppKit today, UIKit later, or something else entirely)
// turns these into whatever final form it needs, but the parse step itself never has to know.

import Foundation

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

    // Phase 2+: `.table`, `.callout`, `.image` land here as they're implemented — every
    // existing renderer only needs a new `case` arm added, not a rewrite, same reasoning
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

        for rawLine in lines {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") {
                if isCodeBlockOpen {
                    flushCodeBlock()
                }
                isCodeBlockOpen.toggle()
                continue
            }
            if isCodeBlockOpen {
                codeLines.append(rawLine)
                continue
            }
            if trimmed.isEmpty {
                continue
            }

            if let heading = parseHeading(trimmed) {
                blocks.append(heading)
                continue
            }

            if let listItem = parseListLine(rawLine) {
                blocks.append(listItem)
                continue
            }

            blocks.append(.paragraph(text: trimmed))
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
}
