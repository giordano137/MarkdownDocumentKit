// DocumentRenderer
//
// Turns `[DocumentBlock]` into a styled `NSAttributedString` — works on both AppKit (macOS) and
// UIKit (iOS) through the `PlatformFont`/`PlatformColor`/`PlatformImage` typealiases and the
// handful of helpers in `PlatformTypes.swift`; only the couple of genuinely divergent operations
// (italic font conversion, bold/italic trait preservation) route through those, everything else
// here is one shared implementation. `DocumentBlock`/`DocumentParser` stay pure Foundation with no
// gating at all, needed by neither platform's UI frameworks.
//
// Every color/font-size/spacing value used below comes from a `DocumentTheme` (default:
// `.default`, reproducing this package's original hardcoded look exactly) — see that file for why
// font *family* stays out of scope.
//
// Two things this improves over a naive Markdown-to-NSAttributedString pass: paragraphs are
// justified and hyphenated rather than ragged-right, and inline formatting goes through the same
// `NSAttributedString(markdown:)` pass consistently across every block type instead of only some.

#if canImport(AppKit) || canImport(UIKit)
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif
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
        theme: DocumentTheme = .default,
        formulaRenderer: FormulaRenderer? = nil,
        imageRenderer: ImageRenderer? = nil,
        diagramRenderer: DiagramRenderer? = nil
    ) -> NSAttributedString {
        let result = NSMutableAttributedString()
        result.append(styledTitle(title, theme: theme))

        // Every footnote definition renders once, together, in the trailing "Footnotes" section
        // built below — not inline at its own position in the block sequence — so it's skipped
        // here rather than passed to `blockParagraph`.
        let footnoteNumbers = footnoteReferenceNumbers(in: blocks)
        for block in blocks {
            if case .footnoteDefinition = block { continue }
            result.append(
                blockParagraph(
                    block,
                    contentWidth: contentWidth,
                    theme: theme,
                    formulaRenderer: formulaRenderer,
                    imageRenderer: imageRenderer,
                    diagramRenderer: diagramRenderer
                )
            )
        }
        replaceFootnoteReferences(in: result, numbers: footnoteNumbers, theme: theme)
        if let footnotesSection = footnoteDefinitionsSection(blocks: blocks, numbers: footnoteNumbers, theme: theme, formulaRenderer: formulaRenderer) {
            result.append(footnotesSection)
        }
        return result
    }

    /// One block's styled paragraph(s) — pulled out of `attributedString(from:...)` so
    /// `WordDocumentExporter.export` (AppKit-only, see that file) can reuse the exact same
    /// rendering for every block *except* `.table`, where it splices in a real `<w:tbl>` instead
    /// of this function's `TableAttachment` image (see `WordDocumentExporter`'s own top-of-file
    /// comment for why that couldn't just be a different `NSAttributedString` built the normal
    /// way, the way this substitution sounds like it should work).
    static func blockParagraph(
        _ block: DocumentBlock,
        contentWidth: CGFloat,
        theme: DocumentTheme,
        formulaRenderer: FormulaRenderer?,
        imageRenderer: ImageRenderer?,
        diagramRenderer: DiagramRenderer?
    ) -> NSAttributedString {
        switch block {
        case .heading(let level, let text):
            return headingParagraph(text, level: level, theme: theme, formulaRenderer: formulaRenderer)

        case .paragraph(let text):
            return bodyParagraph(text, theme: theme, formulaRenderer: formulaRenderer)

        case .blockquote(let text):
            return blockquoteParagraph(text, theme: theme, formulaRenderer: formulaRenderer)

        case .callout(let kind, let text):
            return calloutParagraph(kind: kind, text: text, theme: theme, formulaRenderer: formulaRenderer)

        case .listItem(let ordered, let number, let level, let text):
            let bullet = ordered ? "\(number ?? 1).  " : "\(bulletCharacter(forLevel: level))  "
            return listParagraph(bullet + text, level: level, theme: theme, formulaRenderer: formulaRenderer)

        case .taskListItem(let checked, let level, let text):
            let checkbox = checked ? "\u{2611}" : "\u{2610}"  // ☑ / ☐
            return listParagraph("\(checkbox)  " + text, level: level, theme: theme, formulaRenderer: formulaRenderer)

        case .codeBlock(let lines):
            return codeParagraph(lines, theme: theme)

        case .table(let header, let alignments, let rows):
            return tableParagraph(header: header, alignments: alignments, rows: rows, contentWidth: contentWidth, theme: theme)

        case .formula(let latex):
            return formulaParagraph(latex: latex, theme: theme, formulaRenderer: formulaRenderer)

        case .image(let altText, let source):
            return imageParagraph(altText: altText, source: source, contentWidth: contentWidth, theme: theme, imageRenderer: imageRenderer)

        case .diagram(let source):
            return diagramParagraph(source: source, contentWidth: contentWidth, theme: theme, diagramRenderer: diagramRenderer)

        case .footnoteDefinition:
            // Never actually reached: both `attributedString(from:...)` and
            // `WordDocumentExporter.export` filter `.footnoteDefinition` out before calling
            // `blockParagraph` — every definition renders once, together, in the trailing
            // "Footnotes" section (`footnoteDefinitionsSection`), not inline at its original
            // position in the block sequence. An empty result (not a `fatalError`/non-exhaustive
            // switch) keeps a stray direct call harmless rather than crashing.
            return NSAttributedString()
        }
    }

    // MARK: - Footnotes

    /// Assigns each footnote identifier a number by the order it's first *referenced* (a `[^id]`
    /// inside some other block's prose text), not by where its `.footnoteDefinition` happens to
    /// sit in the source — matching GFM's own numbering. Only identifiers that actually have a
    /// matching definition get a number; an unresolved `[^id]` is left as literal text by
    /// `replaceFootnoteReferences` below, the same "show something honest, not a blank gap" choice
    /// every other unresolvable reference in this package already makes.
    static func footnoteReferenceNumbers(in blocks: [DocumentBlock]) -> [String: Int] {
        let definedIdentifiers = Set(
            blocks.compactMap { block -> String? in
                guard case .footnoteDefinition(let identifier, _) = block else { return nil }
                return identifier
            }
        )
        guard !definedIdentifiers.isEmpty, let regex = try? NSRegularExpression(pattern: "\\[\\^([^\\]]+)\\]") else { return [:] }

        var numbers: [String: Int] = [:]
        var nextNumber = 1
        for block in blocks {
            guard let text = proseText(of: block) else { continue }
            let nsRange = NSRange(location: 0, length: (text as NSString).length)
            for match in regex.matches(in: text, range: nsRange) {
                guard let idRange = Range(match.range(at: 1), in: text) else { continue }
                let identifier = String(text[idRange])
                guard definedIdentifiers.contains(identifier), numbers[identifier] == nil else { continue }
                numbers[identifier] = nextNumber
                nextNumber += 1
            }
        }
        return numbers
    }

    /// The prose text a block's `[^id]` references (if any) live in — `nil` for block types where
    /// a bracket pair means something else entirely (a table cell, image alt text, code/formula/
    /// diagram source) rather than prose a footnote reference could sensibly sit in; footnote
    /// reference support is deliberately bounded to the same text-bearing blocks
    /// `extractInlineFormulas` already covers via `inlineParagraph`.
    private static func proseText(of block: DocumentBlock) -> String? {
        switch block {
        case .heading(_, let text): return text
        case .paragraph(let text): return text
        case .blockquote(let text): return text
        case .callout(_, let text): return text
        case .listItem(_, _, _, let text): return text
        case .taskListItem(_, _, let text): return text
        case .codeBlock, .table, .formula, .image, .diagram, .footnoteDefinition: return nil
        }
    }

    /// Replaces every resolvable `[^id]` left in `attributed`'s already-rendered text with a
    /// small superscript number — done as a pass over the *finished* string (not a sentinel
    /// swapped in before the Markdown pass, the way `extractInlineFormulas` protects LaTeX syntax)
    /// because `[^id]` isn't valid CommonMark link/emphasis syntax to begin with, so
    /// `NSAttributedString(markdown:)` already passes it through unchanged — nothing to protect it
    /// from. Reads the surrounding run's own font/color at each match (rather than a single theme
    /// value) so the superscript's relative size is correct whether the reference sits in body
    /// text, a heading, or a list item, each a different font size.
    static func replaceFootnoteReferences(in attributed: NSMutableAttributedString, numbers: [String: Int], theme: DocumentTheme) {
        guard !numbers.isEmpty, let regex = try? NSRegularExpression(pattern: "\\[\\^([^\\]]+)\\]") else { return }
        let string = attributed.string
        let matches = regex.matches(in: string, range: NSRange(location: 0, length: (string as NSString).length))

        for match in matches.reversed() {
            guard let idRange = Range(match.range(at: 1), in: string) else { continue }
            let identifier = String(string[idRange])
            guard let number = numbers[identifier] else { continue }

            var runAttributes = attributed.attributes(at: match.range.location, effectiveRange: nil)
            let baseFont = (runAttributes[.font] as? PlatformFont) ?? PlatformFont.systemFont(ofSize: theme.bodyFontSize)
            runAttributes[.font] = PlatformFont.systemFont(ofSize: baseFont.pointSize * 0.7)
            runAttributes[.baselineOffset] = baseFont.pointSize * 0.35
            attributed.replaceCharacters(in: match.range, with: NSAttributedString(string: "\(number)", attributes: runAttributes))
        }
    }

    /// The trailing "Footnotes" section every resolved definition renders in, together, once —
    /// reuses `listParagraph`'s own numbered-list styling for each entry (`"1.  text"`) rather
    /// than inventing a separate visual style for what's already, structurally, a numbered list.
    /// `nil` when there's nothing to show, so a document with no (resolvable) footnotes gets no
    /// empty "Footnotes" heading tacked onto the end.
    static func footnoteDefinitionsSection(
        blocks: [DocumentBlock],
        numbers: [String: Int],
        theme: DocumentTheme,
        formulaRenderer: FormulaRenderer?
    ) -> NSAttributedString? {
        var seenIdentifiers = Set<String>()
        let definitions = blocks.compactMap { block -> (number: Int, text: String)? in
            guard case .footnoteDefinition(let identifier, let text) = block,
                let number = numbers[identifier],
                !seenIdentifiers.contains(identifier)
            else { return nil }
            seenIdentifiers.insert(identifier)
            return (number, text)
        }.sorted { $0.number < $1.number }
        guard !definitions.isEmpty else { return nil }

        let result = NSMutableAttributedString()
        result.append(headingParagraph("Footnotes", level: 2, theme: theme, formulaRenderer: nil))
        for definition in definitions {
            result.append(
                listParagraph("\(definition.number).  " + definition.text, level: 0, theme: theme, formulaRenderer: formulaRenderer)
            )
        }
        return result
    }

    // MARK: - Title

    /// Not `private`: also used by `wordAttributedString(from:...)` (AppKit-only, see
    /// `DocumentRenderer+Word.swift`) to give the Word export the exact same title styling.
    static func styledTitle(_ text: String, theme: DocumentTheme) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.paragraphSpacing = theme.titleSpacing
        return NSAttributedString(
            string: text + "\n",
            attributes: [.font: PlatformFont.boldSystemFont(ofSize: theme.titleFontSize), .paragraphStyle: style]
        )
    }

    // MARK: - Headings

    private static func headingParagraph(
        _ text: String,
        level: Int,
        theme: DocumentTheme,
        formulaRenderer: FormulaRenderer?
    ) -> NSAttributedString {
        let sizes = theme.headingFontSizes
        let size = sizes[min(max(level - 1, 0), sizes.count - 1)]
        return inlineParagraph(
            text,
            baseFont: .boldSystemFont(ofSize: size),
            indent: 0,
            spacingAfter: theme.headingSpacing,
            justified: false,
            formulaRenderer: formulaRenderer
        )
    }

    // MARK: - Paragraphs

    /// Justified + hyphenated — the one concrete visual step up from the AppKit renderer this
    /// replaces, and most of what separates "looks like a printed page" from "looks like a
    /// text file". Headings/list items stay ragged-right on purpose: justifying short lines
    /// produces ugly, uneven word-spacing that full paragraphs don't suffer from.
    private static func bodyParagraph(_ text: String, theme: DocumentTheme, formulaRenderer: FormulaRenderer?) -> NSAttributedString {
        inlineParagraph(
            text,
            baseFont: .systemFont(ofSize: theme.bodyFontSize),
            indent: 0,
            spacingAfter: theme.bodySpacing,
            justified: true,
            formulaRenderer: formulaRenderer
        )
    }

    // MARK: - Blockquotes

    /// Indented + italic + muted, the standard plain-text rendering of a quote — a real left
    /// border bar isn't representable through `NSParagraphStyle` alone the way a browser's CSS
    /// `border-left` is, and isn't worth a custom `NSTextAttachment`/manual-draw detour for a
    /// document converter that never had blockquote support at all before this.
    private static func blockquoteParagraph(
        _ text: String,
        theme: DocumentTheme,
        formulaRenderer: FormulaRenderer?
    ) -> NSAttributedString {
        let result = inlineParagraph(
            text,
            baseFont: italicSystemFont(ofSize: theme.bodyFontSize),
            indent: theme.indentUnit,
            spacingAfter: theme.bodySpacing,
            justified: false,
            formulaRenderer: formulaRenderer
        )
        let mutable = NSMutableAttributedString(attributedString: result)
        let fullRange = NSRange(location: 0, length: mutable.length)
        mutable.addAttribute(.foregroundColor, value: theme.secondaryText, range: fullRange)
        return mutable
    }

    // MARK: - Callouts

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
    private static func calloutParagraph(
        kind: CalloutKind,
        text: String,
        theme: DocumentTheme,
        formulaRenderer: FormulaRenderer?
    ) -> NSAttributedString {
        let tint = theme.calloutTint(for: kind)
        let result = NSMutableAttributedString()

        let labelStyle = NSMutableParagraphStyle()
        labelStyle.firstLineHeadIndent = theme.indentUnit
        labelStyle.headIndent = theme.indentUnit
        labelStyle.paragraphSpacing = theme.calloutLabelSpacing
        result.append(
            NSAttributedString(
                string: kind.rawValue + "\n",
                attributes: [
                    .font: PlatformFont.boldSystemFont(ofSize: theme.calloutLabelFontSize),
                    .foregroundColor: tint.accent,
                    .paragraphStyle: labelStyle,
                ]
            )
        )

        let body = inlineParagraph(
            text,
            baseFont: .systemFont(ofSize: theme.bodyFontSize),
            indent: theme.indentUnit,
            spacingAfter: theme.bodySpacing,
            justified: true,
            formulaRenderer: formulaRenderer
        )
        let mutableBody = NSMutableAttributedString(attributedString: body)
        mutableBody.addAttribute(.backgroundColor, value: tint.background, range: NSRange(location: 0, length: mutableBody.length))
        result.append(mutableBody)

        return result
    }

    // MARK: - Lists

    private static func bulletCharacter(forLevel level: Int) -> String {
        level % 2 == 0 ? "•" : "◦"
    }

    private static func listParagraph(
        _ text: String,
        level: Int,
        theme: DocumentTheme,
        formulaRenderer: FormulaRenderer?
    ) -> NSAttributedString {
        inlineParagraph(
            text,
            baseFont: .systemFont(ofSize: theme.bodyFontSize),
            indent: CGFloat(level) * theme.indentUnit,
            spacingAfter: theme.listItemSpacing,
            justified: false,
            formulaRenderer: formulaRenderer
        )
    }

    // MARK: - Code blocks

    /// Builds one `NSAttributedString` run *per line*, each with its own `NSParagraphStyle`,
    /// rather than a single attributes dictionary applied uniformly across
    /// `lines.joined(separator: "\n")` (this function's original version). That uniform version
    /// looked identical in a debugger/`.string` inspection, but every `\n` still starts a new
    /// "paragraph" for layout purposes regardless of how the attribute was applied — so a *shared*
    /// `paragraphSpacingBefore`/`paragraphSpacing` landed between every pair of lines inside the
    /// block, not just before/after the block as a whole, opening a visible gap in the shaded
    /// background between every two lines of a multi-line code block. Caught only by opening an
    /// actual generated PDF (no test asserted on inter-line spacing, only on text/attribute
    /// presence) — putting the before-spacing on just the first line and the after-spacing on just
    /// the last one closes those gaps while leaving the block's own outer spacing unchanged.
    private static func codeParagraph(_ lines: [String], theme: DocumentTheme) -> NSAttributedString {
        let font = PlatformFont.monospacedSystemFont(ofSize: theme.codeFontSize, weight: .regular)
        let result = NSMutableAttributedString()
        for (index, line) in lines.enumerated() {
            let style = NSMutableParagraphStyle()
            style.paragraphSpacingBefore = index == 0 ? theme.codeBlockSpacingBefore : 0
            style.paragraphSpacing = index == lines.count - 1 ? theme.codeBlockSpacingAfter : 0
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                // Fixed by default (`theme.codeText`), not a dynamic system color — a dynamic
                // semantic color resolves to something barely visible when drawn into a raw
                // `CGContext` outside any live window (`PDFRenderer`'s PDF page). Confirmed by
                // opening an actual generated PDF with a code block — the text was there (present
                // in the text layer) but rendered nearly invisible, not caught by any passing unit
                // test since none of them assert on the *color*, only on the text's
                // presence/attributes.
                .foregroundColor: theme.codeText,
                .backgroundColor: theme.codeBlockBackground,
                .paragraphStyle: style,
            ]
            result.append(NSAttributedString(string: line + "\n", attributes: attributes))
        }
        return result
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
        contentWidth: CGFloat,
        theme: DocumentTheme
    ) -> NSAttributedString {
        guard
            let attachment = TableAttachment(
                header: header,
                alignments: alignments,
                rows: rows,
                maxWidth: contentWidth,
                theme: theme
            )
        else {
            // Falls back to a plain-text rendering of the table rather than silently dropping
            // it — mirrors the fallback for a formula that can't be rendered (show the raw
            // source, don't just disappear).
            let plain = ([header] + rows).map { $0.joined(separator: " | ") }.joined(separator: "\n")
            return codeParagraph(plain.components(separatedBy: "\n"), theme: theme)
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
        // already renders correctly), so that's what creates the gap here. Not theme-controlled:
        // this is an internal pagination workaround, not a visible style choice.
        result.append(NSAttributedString(string: "\n", attributes: [.font: PlatformFont.systemFont(ofSize: 40)]))
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
        baseFont: PlatformFont,
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
        mutable.enumerateAttributes(in: fullRange, options: []) { attrs, range, _ in
            let traits = emphasisTraits(in: attrs)
            let font = applyingTraits(bold: traits.bold, italic: traits.italic, to: baseFont)
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
    private static func formulaParagraph(latex: String, theme: DocumentTheme, formulaRenderer: FormulaRenderer?) -> NSAttributedString {
        guard
            let attachment = renderedFormulaAttachment(
                latex: latex,
                displayMode: true,
                fontSize: theme.formulaDisplayFontSize,
                formulaRenderer: formulaRenderer,
                baselineAligned: false
            )
        else {
            return codeParagraph(["\\[\(latex)\\]"], theme: theme)
        }
        let result = NSMutableAttributedString(attributedString: attachment)
        result.append(NSAttributedString(string: "\n"))
        result.append(NSAttributedString(string: "\n", attributes: [.font: PlatformFont.systemFont(ofSize: 40)]))
        return result
    }

    // MARK: - Images

    /// Decodes a `data:image/...;base64,...` source directly — the one image source this package
    /// can resolve without any consumer-supplied I/O, since the bytes are already embedded right
    /// in the Markdown itself. Anything else (a local path, a remote URL) goes to the injected
    /// `ImageRenderer` instead, same "consumer supplies the capability that needs I/O" shape as
    /// `FormulaRenderer`.
    private static func decodeDataURIImage(_ source: String) -> PlatformImage? {
        guard source.hasPrefix("data:"), let commaIndex = source.firstIndex(of: ",") else { return nil }
        let meta = source[source.index(source.startIndex, offsetBy: 5)..<commaIndex]
        guard meta.contains(";base64") else { return nil }
        let base64 = String(source[source.index(after: commaIndex)...])
        guard let data = Data(base64Encoded: base64) else { return nil }
        return PlatformImage(data: data)
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
        theme: DocumentTheme,
        imageRenderer: ImageRenderer?
    ) -> NSAttributedString {
        guard let image = decodeDataURIImage(source) ?? imageRenderer?.image(forSource: source, altText: altText) else {
            return missingImageParagraph(altText: altText, theme: theme)
        }
        return scaledImageAttachmentParagraph(image, contentWidth: contentWidth)
    }

    private static func missingImageParagraph(altText: String, theme: DocumentTheme) -> NSAttributedString {
        let text = altText.isEmpty ? "[image]" : "[image: \(altText)]"
        let style = NSMutableParagraphStyle()
        style.paragraphSpacing = theme.bodySpacing
        return NSAttributedString(
            string: text + "\n",
            attributes: [
                .font: italicSystemFont(ofSize: theme.bodyFontSize),
                .foregroundColor: theme.secondaryText,
                .paragraphStyle: style,
            ]
        )
    }

    /// Scales `image` down (preserving aspect ratio) if it's wider than the page's content width,
    /// never scaled up, and wraps it as a standalone-paragraph `NSTextAttachment` — the shared tail
    /// end of both `imageParagraph` and `diagramParagraph`, since a rendered diagram is laid out on
    /// the page exactly like any other block-level image once it exists as a `PlatformImage`.
    private static func scaledImageAttachmentParagraph(_ image: PlatformImage, contentWidth: CGFloat) -> NSAttributedString {
        let naturalSize = image.size
        let scale = naturalSize.width > contentWidth ? contentWidth / naturalSize.width : 1
        let displaySize = CGSize(width: naturalSize.width * scale, height: naturalSize.height * scale)

        let attachment = NSTextAttachment()
        attachment.image = image
        attachment.bounds = CGRect(origin: .zero, size: displaySize)

        let result = NSMutableAttributedString(attributedString: NSAttributedString(attachment: attachment))
        result.append(NSAttributedString(string: "\n"))
        result.append(NSAttributedString(string: "\n", attributes: [.font: PlatformFont.systemFont(ofSize: 40)]))
        return result
    }

    // MARK: - Diagrams

    /// A fenced ` ```mermaid ` block: rendered as an image via the injected `DiagramRenderer`
    /// exactly like `.image` is via `ImageRenderer` (see `scaledImageAttachmentParagraph`). Without
    /// a renderer, or one that can't parse this particular Mermaid source, falls back to the raw
    /// source shown as a code block — reusing `codeParagraph`'s own styling rather than attempting
    /// any kind of ASCII-art approximation of the diagram, which would risk looking like a real
    /// (but wrong) rendering rather than an honest "this needs a renderer" fallback.
    private static func diagramParagraph(
        source: String,
        contentWidth: CGFloat,
        theme: DocumentTheme,
        diagramRenderer: DiagramRenderer?
    ) -> NSAttributedString {
        guard let image = diagramRenderer?.image(forMermaidSource: source, palette: theme.diagramPalette) else {
            return codeParagraph(source.components(separatedBy: "\n"), theme: theme)
        }
        return scaledImageAttachmentParagraph(image, contentWidth: contentWidth)
    }
}
#endif
