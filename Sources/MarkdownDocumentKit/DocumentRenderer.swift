// DocumentRenderer
//
// Turns `[DocumentBlock]` into a styled `NSAttributedString` — the macOS half of Phase 1 (see
// README). Deliberately in its own `#if os(macOS)`-gated file: `DocumentBlock`/`DocumentParser`
// stay pure Foundation so a future UIKit renderer is an additive file, not a rewrite of the
// model underneath it.
//
// Two things this improves over the 137 app's original `MarkdownDocumentRenderer` (which this
// supersedes — see the app-side integration): paragraphs are justified and hyphenated rather
// than ragged-right, and inline formatting goes through the same `NSAttributedString(markdown:)`
// pass consistently across every block type instead of only some.

#if os(macOS)
import AppKit
import Foundation

public enum DocumentRenderer {
    /// US Letter (612pt wide) minus `PDFRenderer`'s own 54pt margins on each side — tables need
    /// to know the eventual page's content width up front, since (unlike text) they're rasterized
    /// once at a fixed pixel size rather than reflowed at layout time. Override if a consumer
    /// renders to a different page size/margins than the 137 app's PDF export does.
    public static let defaultContentWidth: CGFloat = 504

    public static func attributedString(
        from blocks: [DocumentBlock],
        title: String,
        contentWidth: CGFloat = defaultContentWidth
    ) -> NSAttributedString {
        let result = NSMutableAttributedString()
        result.append(styledTitle(title))

        for block in blocks {
            switch block {
            case .heading(let level, let text):
                result.append(headingParagraph(text, level: level))

            case .paragraph(let text):
                result.append(bodyParagraph(text))

            case .listItem(let ordered, let number, let level, let text):
                let bullet = ordered ? "\(number ?? 1).  " : "\(bulletCharacter(forLevel: level))  "
                result.append(listParagraph(bullet + text, level: level))

            case .codeBlock(let lines):
                result.append(codeParagraph(lines))

            case .table(let header, let alignments, let rows):
                result.append(tableParagraph(header: header, alignments: alignments, rows: rows, contentWidth: contentWidth))
            }
        }
        return result
    }

    // MARK: - Title

    private static func styledTitle(_ text: String) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.paragraphSpacing = 16
        return NSAttributedString(
            string: text + "\n",
            attributes: [.font: NSFont.boldSystemFont(ofSize: 22), .paragraphStyle: style]
        )
    }

    // MARK: - Headings

    private static let headingSizeByLevel: [CGFloat] = [20, 18, 16, 14, 13, 12]

    private static func headingParagraph(_ text: String, level: Int) -> NSAttributedString {
        let size = headingSizeByLevel[min(max(level - 1, 0), headingSizeByLevel.count - 1)]
        return inlineParagraph(
            text,
            baseFont: .boldSystemFont(ofSize: size),
            indent: 0,
            spacingAfter: 10,
            justified: false
        )
    }

    // MARK: - Paragraphs

    /// Justified + hyphenated — the one concrete visual step up from the AppKit renderer this
    /// replaces, and most of what separates "looks like a printed page" from "looks like a
    /// text file". Headings/list items stay ragged-right on purpose: justifying short lines
    /// produces ugly, uneven word-spacing that full paragraphs don't suffer from.
    private static func bodyParagraph(_ text: String) -> NSAttributedString {
        inlineParagraph(text, baseFont: .systemFont(ofSize: 13), indent: 0, spacingAfter: 8, justified: true)
    }

    // MARK: - Lists

    private static func bulletCharacter(forLevel level: Int) -> String {
        level % 2 == 0 ? "•" : "◦"
    }

    private static func listParagraph(_ text: String, level: Int) -> NSAttributedString {
        inlineParagraph(
            text,
            baseFont: .systemFont(ofSize: 13),
            indent: CGFloat(level) * 18,
            spacingAfter: 4,
            justified: false
        )
    }

    // MARK: - Code blocks

    private static func codeParagraph(_ lines: [String]) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.paragraphSpacingBefore = 4
        style.paragraphSpacing = 12
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
            .foregroundColor: NSColor.textColor,
            .paragraphStyle: style,
        ]
        return NSAttributedString(string: lines.joined(separator: "\n") + "\n", attributes: attributes)
    }

    // MARK: - Tables

    /// Renders the table to an image (see `TableRenderer`) and wraps it as a single
    /// `NSTextAttachment` on its own line — same "can't flow as text, so embed as an image"
    /// approach the 137 app's `InlineMathImageRenderer` uses for formulas, just block-level
    /// (full paragraph width, top-aligned) instead of inline/baseline-aligned.
    private static func tableParagraph(
        header: [String],
        alignments: [TableAlignment],
        rows: [[String]],
        contentWidth: CGFloat
    ) -> NSAttributedString {
        guard let rendered = TableRenderer.render(header: header, alignments: alignments, rows: rows, maxWidth: contentWidth)
        else {
            // Falls back to a plain-text rendering of the table rather than silently dropping
            // it — mirrors the 137 app's inline-math fallback for a formula SwiftMath can't
            // parse (show the raw source, don't just disappear).
            let plain = ([header] + rows).map { $0.joined(separator: " | ") }.joined(separator: "\n")
            return codeParagraph(plain.components(separatedBy: "\n"))
        }

        let attachment = NSTextAttachment()
        attachment.image = rendered.image
        attachment.bounds = CGRect(origin: .zero, size: rendered.size)

        let result = NSMutableAttributedString(attributedString: NSAttributedString(attachment: attachment))
        result.append(NSAttributedString(string: "\n"))
        // A blank *ordinary* line rather than `NSParagraphStyle.paragraphSpacing` on the
        // attachment's own line — measured empirically (rendering real pages) that a raw
        // CoreText/CTFramesetter pagination pass doesn't respect paragraph spacing around a
        // `CTRunDelegate`-backed attachment run the way it does for normal text lines, and
        // widening the run's own reported descent to fake a trailing gap moved the *next*
        // block's line into the wrong place rather than adding clean space. A real line made of
        // ordinary text has no such issue (confirmed: normal paragraph-to-paragraph spacing
        // already renders correctly), so that's what creates the gap here.
        result.append(NSAttributedString(string: "\n", attributes: [.font: NSFont.systemFont(ofSize: 40)]))
        return result
    }

    // MARK: - Shared inline-Markdown + paragraph-style paragraph builder

    /// Runs `text` through `NSAttributedString(markdown:)` for inline `**bold**`/`*italic*`/
    /// links first (that call only ever parses inline runs, never block structure — same
    /// limitation noted in the 137 app's `MessageContentView`), then layers the block-level
    /// font/indent/spacing/justification on top, since inline Markdown parsing doesn't touch
    /// any of those.
    private static func inlineParagraph(
        _ text: String,
        baseFont: NSFont,
        indent: CGFloat,
        spacingAfter: CGFloat,
        justified: Bool
    ) -> NSAttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        let inline = (try? NSAttributedString(markdown: text, options: options)) ?? NSAttributedString(string: text)

        let mutable = NSMutableAttributedString(attributedString: inline)
        let style = NSMutableParagraphStyle()
        style.paragraphSpacing = spacingAfter
        style.firstLineHeadIndent = indent
        style.headIndent = indent
        if justified {
            style.alignment = .justified
            style.hyphenationFactor = 1.0
        }

        let fullRange = NSRange(location: 0, length: mutable.length)
        mutable.addAttribute(.paragraphStyle, value: style, range: fullRange)
        // Base font applied first, then re-applied preserving bold/italic traits already set by
        // the inline Markdown parse above — a **bold** run's font would otherwise get clobbered
        // back down to the plain base font.
        mutable.enumerateAttribute(.font, in: fullRange, options: []) { value, range, _ in
            let traits = (value as? NSFont)?.fontDescriptor.symbolicTraits ?? []
            var descriptor = baseFont.fontDescriptor
            if !traits.isDisjoint(with: [.bold, .italic]) {
                descriptor = descriptor.withSymbolicTraits(traits.intersection([.bold, .italic]))
            }
            let font = NSFont(descriptor: descriptor, size: baseFont.pointSize) ?? baseFont
            mutable.addAttribute(.font, value: font, range: range)
        }
        mutable.append(NSAttributedString(string: "\n"))
        return mutable
    }
}
#endif
