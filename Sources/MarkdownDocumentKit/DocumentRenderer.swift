// DocumentRenderer
//
// Turns `[DocumentBlock]` into a styled `NSAttributedString` — the macOS half of Phase 1 (see
// README). Deliberately in its own `#if os(macOS)`-gated file: `DocumentBlock`/`DocumentParser`
// stay pure Foundation so a future UIKit renderer is an additive file, not a rewrite of the
// model underneath it.
//
// Two things this improves over a naive Markdown-to-NSAttributedString pass: paragraphs are
// justified and hyphenated rather than ragged-right, and inline formatting goes through the same
// `NSAttributedString(markdown:)` pass consistently across every block type instead of only some.

#if os(macOS)
import AppKit
import Foundation

public enum DocumentRenderer {
    /// US Letter (612pt wide) minus `PDFRenderer`'s own 54pt margins on each side — tables need
    /// to know the eventual page's content width up front, since (unlike text) they're rasterized
    /// once at a fixed pixel size rather than reflowed at layout time. Override if a consumer
    /// renders to a different page size/margins than `PDFRenderer`'s own defaults.
    public static let defaultContentWidth: CGFloat = 504

    public static func attributedString(
        from blocks: [DocumentBlock],
        title: String,
        contentWidth: CGFloat = defaultContentWidth,
        formulaRenderer: FormulaRenderer? = nil,
        imageRenderer: ImageRenderer? = nil
    ) -> NSAttributedString {
        let result = NSMutableAttributedString()
        result.append(styledTitle(title))

        for block in blocks {
            switch block {
            case .heading(let level, let text):
                result.append(headingParagraph(text, level: level, formulaRenderer: formulaRenderer))

            case .paragraph(let text):
                result.append(bodyParagraph(text, formulaRenderer: formulaRenderer))

            case .blockquote(let text):
                result.append(blockquoteParagraph(text, formulaRenderer: formulaRenderer))

            case .callout(let kind, let text):
                result.append(calloutParagraph(kind: kind, text: text, formulaRenderer: formulaRenderer))

            case .listItem(let ordered, let number, let level, let text):
                let bullet = ordered ? "\(number ?? 1).  " : "\(bulletCharacter(forLevel: level))  "
                result.append(listParagraph(bullet + text, level: level, formulaRenderer: formulaRenderer))

            case .codeBlock(let lines):
                result.append(codeParagraph(lines))

            case .table(let header, let alignments, let rows):
                result.append(tableParagraph(header: header, alignments: alignments, rows: rows, contentWidth: contentWidth))

            case .formula(let latex):
                result.append(formulaParagraph(latex: latex, formulaRenderer: formulaRenderer))

            case .image(let altText, let source):
                result.append(imageParagraph(altText: altText, source: source, contentWidth: contentWidth, imageRenderer: imageRenderer))
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

    private static func headingParagraph(_ text: String, level: Int, formulaRenderer: FormulaRenderer?) -> NSAttributedString {
        let size = headingSizeByLevel[min(max(level - 1, 0), headingSizeByLevel.count - 1)]
        return inlineParagraph(
            text,
            baseFont: .boldSystemFont(ofSize: size),
            indent: 0,
            spacingAfter: 10,
            justified: false,
            formulaRenderer: formulaRenderer
        )
    }

    // MARK: - Paragraphs

    /// Justified + hyphenated — the one concrete visual step up from the AppKit renderer this
    /// replaces, and most of what separates "looks like a printed page" from "looks like a
    /// text file". Headings/list items stay ragged-right on purpose: justifying short lines
    /// produces ugly, uneven word-spacing that full paragraphs don't suffer from.
    private static func bodyParagraph(_ text: String, formulaRenderer: FormulaRenderer?) -> NSAttributedString {
        inlineParagraph(
            text,
            baseFont: .systemFont(ofSize: 13),
            indent: 0,
            spacingAfter: 8,
            justified: true,
            formulaRenderer: formulaRenderer
        )
    }

    // MARK: - Blockquotes

    /// Indented + italic + muted, the standard plain-text rendering of a quote — a real left
    /// border bar isn't representable through `NSParagraphStyle` alone the way a browser's CSS
    /// `border-left` is, and isn't worth a custom `NSTextAttachment`/manual-draw detour for a
    /// document converter that never had blockquote support at all before this.
    private static func blockquoteParagraph(_ text: String, formulaRenderer: FormulaRenderer?) -> NSAttributedString {
        let result = inlineParagraph(
            text,
            baseFont: NSFontManager.shared.convert(.systemFont(ofSize: 13), toHaveTrait: .italicFontMask),
            indent: 18,
            spacingAfter: 8,
            justified: false,
            formulaRenderer: formulaRenderer
        )
        let mutable = NSMutableAttributedString(attributedString: result)
        let fullRange = NSRange(location: 0, length: mutable.length)
        mutable.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: fullRange)
        return mutable
    }

    // MARK: - Callouts

    /// Fixed light tint + a matching darker accent for the label text, per GFM alert kind — fixed
    /// rather than dynamic for the same reason `codeBlockBackground` already is (an exported file
    /// has no live theme to resolve dynamic colors against).
    private static func calloutTint(for kind: CalloutKind) -> (background: NSColor, accent: NSColor) {
        switch kind {
        case .note:
            return (NSColor(red: 0.90, green: 0.95, blue: 1.0, alpha: 1), NSColor(red: 0.16, green: 0.40, blue: 0.85, alpha: 1))
        case .tip:
            return (NSColor(red: 0.89, green: 0.97, blue: 0.90, alpha: 1), NSColor(red: 0.16, green: 0.55, blue: 0.28, alpha: 1))
        case .warning:
            return (NSColor(red: 1.0, green: 0.95, blue: 0.82, alpha: 1), NSColor(red: 0.70, green: 0.48, blue: 0.05, alpha: 1))
        case .important:
            return (NSColor(red: 0.95, green: 0.90, blue: 1.0, alpha: 1), NSColor(red: 0.50, green: 0.20, blue: 0.75, alpha: 1))
        }
    }

    /// A GFM alert (`> [!NOTE]` etc.): a bold, accent-colored label line, then the body text
    /// tinted via a `.backgroundColor` attribute — the same mechanism `codeBlockBackground`
    /// already uses, so no new PDF/DOCX-side handling is needed (`PDFRenderer` paints it manually
    /// with rounded corners; DOCX's OOXML writer picks up `.backgroundColor` as text shading
    /// automatically). The label itself carries no background: it's typically much shorter than
    /// the body, and a `.backgroundColor` run only ever paints as wide as its own glyphs (real
    /// here, and already true of `codeBlockBackground`) — tinting just the word "Note" would read
    /// as an odd narrow highlight rather than a label sitting inside a wider box. No icon glyph
    /// either: an emoji/symbol character risks rendering oddly through `PDFRenderer`'s raw
    /// CoreText text-showing operators, which color-glyph fonts don't always cooperate with, so a
    /// plain text label is the robust choice.
    private static func calloutParagraph(kind: CalloutKind, text: String, formulaRenderer: FormulaRenderer?) -> NSAttributedString {
        let (background, accent) = calloutTint(for: kind)
        let result = NSMutableAttributedString()

        let labelStyle = NSMutableParagraphStyle()
        labelStyle.firstLineHeadIndent = 18
        labelStyle.headIndent = 18
        labelStyle.paragraphSpacing = 2
        result.append(
            NSAttributedString(
                string: kind.rawValue + "\n",
                attributes: [
                    .font: NSFont.boldSystemFont(ofSize: 13),
                    .foregroundColor: accent,
                    .paragraphStyle: labelStyle,
                ]
            )
        )

        let body = inlineParagraph(
            text,
            baseFont: .systemFont(ofSize: 13),
            indent: 18,
            spacingAfter: 8,
            justified: true,
            formulaRenderer: formulaRenderer
        )
        let mutableBody = NSMutableAttributedString(attributedString: body)
        mutableBody.addAttribute(.backgroundColor, value: background, range: NSRange(location: 0, length: mutableBody.length))
        result.append(mutableBody)

        return result
    }

    // MARK: - Lists

    private static func bulletCharacter(forLevel level: Int) -> String {
        level % 2 == 0 ? "•" : "◦"
    }

    private static func listParagraph(_ text: String, level: Int, formulaRenderer: FormulaRenderer?) -> NSAttributedString {
        inlineParagraph(
            text,
            baseFont: .systemFont(ofSize: 13),
            indent: CGFloat(level) * 18,
            spacingAfter: 4,
            justified: false,
            formulaRenderer: formulaRenderer
        )
    }

    // MARK: - Code blocks

    /// Light gray, matching `TableRenderer.headerBackground`'s fixed (non-dynamic) shading —
    /// these are exported files read outside the app's own theme, so a fixed tone reads
    /// correctly regardless of the viewer's system appearance, unlike `NSColor.textBackgroundColor`.
    /// DOCX picks this up for free via `.backgroundColor` (AppKit's OOXML writer maps it to Word's
    /// own text shading); PDF needs `PDFRenderer` to paint it manually, since raw `CTFrameDraw`
    /// never honors this attribute on its own (see that file's `drawBackgroundColors`).
    public static let codeBlockBackground = NSColor(white: 0.95, alpha: 1)

    private static func codeParagraph(_ lines: [String]) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.paragraphSpacingBefore = 4
        style.paragraphSpacing = 12
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
            .foregroundColor: NSColor.textColor,
            .backgroundColor: codeBlockBackground,
            .paragraphStyle: style,
        ]
        return NSAttributedString(string: lines.joined(separator: "\n") + "\n", attributes: attributes)
    }

    // MARK: - Tables

    /// Wraps the table as a single `TableAttachment` on its own line — carries the raw table
    /// data + computed layout (not just a picture), so `PDFRenderer` can draw real, selectable
    /// text instead of embedding the attachment's fallback bitmap image the way a generic
    /// consumer (DOCX export) does. Same "can't flow as text, needs its own attachment" placement
    /// as an inline formula's rendered image, just block-level (full paragraph width,
    /// top-aligned) instead of inline/baseline-aligned.
    private static func tableParagraph(
        header: [String],
        alignments: [TableAlignment],
        rows: [[String]],
        contentWidth: CGFloat
    ) -> NSAttributedString {
        guard let attachment = TableAttachment(header: header, alignments: alignments, rows: rows, maxWidth: contentWidth)
        else {
            // Falls back to a plain-text rendering of the table rather than silently dropping
            // it — mirrors the fallback for a formula that can't be rendered (show the raw
            // source, don't just disappear).
            let plain = ([header] + rows).map { $0.joined(separator: " | ") }.joined(separator: "\n")
            return codeParagraph(plain.components(separatedBy: "\n"))
        }

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
    /// links first (that call only ever parses inline runs, never block structure), then layers
    /// the block-level font/indent/spacing/justification on top, since inline Markdown parsing
    /// doesn't touch any of those.
    ///
    /// Inline math (`$...$`/`\(...\)`/a stray `$$...$$` not on its own line) is pulled out
    /// *before* the Markdown pass via `extractInlineFormulas` — not just so it can be replaced
    /// with a rendered image afterward, but because leaving raw LaTeX in place would let its own
    /// syntax get misread as Markdown (`$a_b$`'s underscore, `$x*y$`'s asterisk) by the very same
    /// parser. A hand-rolled chat-message renderer that instead lifts a matched formula onto its
    /// own line (a natural first instinct — it's the simplest way to give it room) risks a
    /// related but different bug: a `**`/`*` markdown pair that used to sit tight around the
    /// formula ends up split across the new line break and no longer recognized as a pair. This
    /// sidesteps that whole class of problem by never lifting a formula onto its own line in the
    /// first place; everything here stays inline, on one line, from source text through to the
    /// final attributed string.
    private static func inlineParagraph(
        _ text: String,
        baseFont: NSFont,
        indent: CGFloat,
        spacingAfter: CGFloat,
        justified: Bool,
        formulaRenderer: FormulaRenderer?
    ) -> NSAttributedString {
        let (sanitizedText, formulas) = extractInlineFormulas(from: text)
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        let inline =
            (try? NSAttributedString(markdown: sanitizedText, options: options)) ?? NSAttributedString(string: sanitizedText)

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

        guard !formulas.isEmpty else { return mutable }
        replaceFormulaSentinels(in: mutable, formulas: formulas, fontSize: baseFont.pointSize, formulaRenderer: formulaRenderer)
        return mutable
    }

    // MARK: - Formulas

    /// Sentinel pair from the Unicode Private Use Area — guaranteed to carry no Markdown meaning
    /// of its own, so `NSAttributedString(markdown:)` passes a `\u{E000}0\u{E001}` placeholder
    /// straight through as literal text.
    private static let sentinelStart: Character = "\u{E000}"
    private static let sentinelEnd: Character = "\u{E001}"

    /// Finds `$$...$$`, `\(...\)`, and `$...$` spans in `text` and replaces each with a numbered
    /// sentinel placeholder, returning the rewritten text plus the extracted `(latex, displayMode)`
    /// pairs in encounter order (the number inside each placeholder is that pair's index).
    /// `$...$` specifically is skipped (left as literal text) when it looks like plain-prose
    /// dollar signs rather than math — empty, starting with a digit ("$5"), or spanning multiple
    /// sentences (". ") — cheap guards against the false-positive shape a document generator
    /// routinely hits: two currency mentions in one paragraph ("$5 or $10").
    private static func extractInlineFormulas(from text: String) -> (text: String, formulas: [(latex: String, displayMode: Bool)]) {
        var formulas: [(latex: String, displayMode: Bool)] = []
        var result = text

        func replaceMatches(pattern: String, displayMode: Bool, skip: ((String) -> Bool)? = nil) {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
            var output = ""
            var cursor = result.startIndex
            let nsRange = NSRange(location: 0, length: (result as NSString).length)
            regex.enumerateMatches(in: result, range: nsRange) { match, _, _ in
                guard let match,
                    let wholeRange = Range(match.range, in: result),
                    let contentRange = Range(match.range(at: 1), in: result),
                    wholeRange.lowerBound >= cursor
                else { return }
                let content = String(result[contentRange])
                if let skip, skip(content) { return }
                output += result[cursor..<wholeRange.lowerBound]
                output += "\(sentinelStart)\(formulas.count)\(sentinelEnd)"
                formulas.append((latex: content, displayMode: displayMode))
                cursor = wholeRange.upperBound
            }
            output += result[cursor...]
            result = output
        }

        // `\[...\]`/`$$...$$` here means one landed mid-sentence rather than alone on its own
        // line (the case `DocumentParser`'s `parseDisplayFormula` already turns into a `.formula`
        // block) — still real display math by LaTeX convention, so `displayMode: true`, just
        // flowing inline since there's prose sharing its line. Handled before the Markdown pass
        // for the same reason as everything else here: left alone, `\[`/`\]` are themselves valid
        // Markdown backslash-escapes and `NSAttributedString(markdown:)` would silently eat the
        // backslash, leaving bare "[...]" behind — caught by opening an actual generated PDF.
        replaceMatches(pattern: "\\\\\\[([\\s\\S]+?)\\\\\\]", displayMode: true)
        replaceMatches(pattern: "\\$\\$([\\s\\S]+?)\\$\\$", displayMode: true)
        replaceMatches(pattern: "\\\\\\(([\\s\\S]+?)\\\\\\)", displayMode: false)
        replaceMatches(pattern: "\\$([^$\\n]+?)\\$", displayMode: false) { content in
            let trimmed = content.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty || (trimmed.first?.isNumber ?? false) || trimmed.contains(". ")
        }

        return (result, formulas)
    }

    /// Walks the already-Markdown-parsed attributed string for the sentinel placeholders
    /// `extractInlineFormulas` left behind and swaps each for a rendered formula image (or, with
    /// no renderer supplied or one that fails to parse this LaTeX, the raw source text back in
    /// its original delimiter) — replaced back-to-front so earlier matches' ranges stay valid as
    /// later ones are replaced.
    private static func replaceFormulaSentinels(
        in attributed: NSMutableAttributedString,
        formulas: [(latex: String, displayMode: Bool)],
        fontSize: CGFloat,
        formulaRenderer: FormulaRenderer?
    ) {
        guard let regex = try? NSRegularExpression(pattern: "\(sentinelStart)(\\d+)\(sentinelEnd)") else { return }
        let string = attributed.string
        let matches = regex.matches(in: string, range: NSRange(location: 0, length: (string as NSString).length))

        for match in matches.reversed() {
            guard let indexRange = Range(match.range(at: 1), in: string),
                let formulaIndex = Int(string[indexRange]),
                formulas.indices.contains(formulaIndex)
            else { continue }
            let formula = formulas[formulaIndex]
            if let attachment = renderedFormulaAttachment(
                latex: formula.latex,
                displayMode: formula.displayMode,
                fontSize: fontSize,
                formulaRenderer: formulaRenderer,
                baselineAligned: true
            ) {
                attributed.replaceCharacters(in: match.range, with: attachment)
            } else {
                let fallback = formula.displayMode ? "$$\(formula.latex)$$" : "$\(formula.latex)$"
                attributed.replaceCharacters(in: match.range, with: fallback)
            }
        }
    }

    /// `nil` when no renderer was supplied, or the supplied one couldn't parse this LaTeX —
    /// callers fall back to the raw source text in either case, never a blank gap.
    ///
    /// `baselineAligned` controls whether the image's bottom edge hangs `rendered.descent` below
    /// the attachment run's baseline (true — needed so an inline symbol sits level with the
    /// surrounding word's baseline instead of its top) or sits flush with `y: 0` (false — a
    /// standalone `.formula` block has no surrounding text to align with, and this keeps its
    /// whole height reported as ascent, same convention `TableAttachment.bounds` already uses).
    /// Not just cosmetic: a raw-CoreText PDF page's own `CTRunDelegate` (see `PDFRenderer`)
    /// derives the run's ascent/descent split straight from this rect, so getting it wrong for a
    /// block formula previously under/over-reserved line height and made it visibly overlap the
    /// paragraph drawn right after it — caught by opening an actual generated PDF, not by a
    /// passing `extractedText.contains(...)` unit test, which can't see a layout overlap at all.
    private static func renderedFormulaAttachment(
        latex: String,
        displayMode: Bool,
        fontSize: CGFloat,
        formulaRenderer: FormulaRenderer?,
        baselineAligned: Bool
    ) -> NSAttributedString? {
        guard let rendered = formulaRenderer?.image(forLaTeX: latex, displayMode: displayMode, fontSize: fontSize) else {
            return nil
        }
        let attachment = NSTextAttachment()
        attachment.image = rendered.image
        attachment.bounds = CGRect(
            x: 0,
            y: baselineAligned ? -rendered.descent : 0,
            width: rendered.image.size.width,
            height: rendered.image.size.height
        )
        return NSAttributedString(attachment: attachment)
    }

    /// A `.formula` block's own centered line — same "own-line `NSTextAttachment` plus a
    /// blank-line pagination-gap workaround" shape as `tableParagraph` below (see its comment for
    /// why the workaround is a plain extra line rather than `NSParagraphStyle.paragraphSpacing`).
    /// Falls back to a code-styled block (not a plain paragraph) when unrendered, so raw LaTeX at
    /// least reads as "this was meant to be a formula" rather than garbled prose.
    private static func formulaParagraph(latex: String, formulaRenderer: FormulaRenderer?) -> NSAttributedString {
        let displayFontSize: CGFloat = 16
        guard
            let attachment = renderedFormulaAttachment(
                latex: latex,
                displayMode: true,
                fontSize: displayFontSize,
                formulaRenderer: formulaRenderer,
                baselineAligned: false
            )
        else {
            return codeParagraph(["\\[\(latex)\\]"])
        }
        let result = NSMutableAttributedString(attributedString: attachment)
        result.append(NSAttributedString(string: "\n"))
        result.append(NSAttributedString(string: "\n", attributes: [.font: NSFont.systemFont(ofSize: 40)]))
        return result
    }

    // MARK: - Images

    /// Decodes a `data:image/...;base64,...` source directly — the one image source this package
    /// can resolve without any consumer-supplied I/O, since the bytes are already embedded right
    /// in the Markdown itself. Anything else (a local path, a remote URL) goes to the injected
    /// `ImageRenderer` instead, same "consumer supplies the capability that needs I/O" shape as
    /// `FormulaRenderer`.
    private static func decodeDataURIImage(_ source: String) -> NSImage? {
        guard source.hasPrefix("data:"), let commaIndex = source.firstIndex(of: ",") else { return nil }
        let meta = source[source.index(source.startIndex, offsetBy: 5)..<commaIndex]
        guard meta.contains(";base64") else { return nil }
        let base64 = String(source[source.index(after: commaIndex)...])
        guard let data = Data(base64Encoded: base64) else { return nil }
        return NSImage(data: data)
    }

    /// An `.image` block's own line — scaled down (preserving aspect ratio) if it's wider than
    /// the page's content width, never scaled up (a small image stays small rather than
    /// pixelating). Falls back to the alt text, not a blank gap, when the source can't be
    /// resolved at all (no renderer supplied, a `data:` URI that fails to decode, or the renderer
    /// itself returning `nil`) — same "show something, don't just disappear" philosophy every
    /// other block-level fallback in this file already follows.
    private static func imageParagraph(
        altText: String,
        source: String,
        contentWidth: CGFloat,
        imageRenderer: ImageRenderer?
    ) -> NSAttributedString {
        guard let image = decodeDataURIImage(source) ?? imageRenderer?.image(forSource: source, altText: altText) else {
            return missingImageParagraph(altText: altText)
        }

        let naturalSize = image.size
        let scale = naturalSize.width > contentWidth ? contentWidth / naturalSize.width : 1
        let displaySize = CGSize(width: naturalSize.width * scale, height: naturalSize.height * scale)

        let attachment = NSTextAttachment()
        attachment.image = image
        attachment.bounds = CGRect(origin: .zero, size: displaySize)

        let result = NSMutableAttributedString(attributedString: NSAttributedString(attachment: attachment))
        result.append(NSAttributedString(string: "\n"))
        result.append(NSAttributedString(string: "\n", attributes: [.font: NSFont.systemFont(ofSize: 40)]))
        return result
    }

    private static func missingImageParagraph(altText: String) -> NSAttributedString {
        let text = altText.isEmpty ? "[image]" : "[image: \(altText)]"
        let style = NSMutableParagraphStyle()
        style.paragraphSpacing = 8
        return NSAttributedString(
            string: text + "\n",
            attributes: [
                .font: NSFontManager.shared.convert(.systemFont(ofSize: 13), toHaveTrait: .italicFontMask),
                .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: style,
            ]
        )
    }
}
#endif
