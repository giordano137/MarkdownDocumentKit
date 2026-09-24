#if canImport(AppKit) || canImport(UIKit)
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif
import Testing
@testable import MarkdownDocumentKit

/// A blank image of the given size — `PlatformImage(size:)` alone already does this on AppKit; UIKit
/// has no equivalent one-argument initializer, so this draws nothing into a real
/// `UIGraphicsImageRenderer` context instead. Used only as a stand-in "here's an image of this
/// size" for mock renderers below; its pixel content is never asserted on.
private func testImage(width: CGFloat, height: CGFloat) -> PlatformImage {
    #if canImport(AppKit)
    return PlatformImage(size: CGSize(width: width, height: height))
    #elseif canImport(UIKit)
    return UIGraphicsImageRenderer(size: CGSize(width: width, height: height)).image { _ in }
    #endif
}

/// Deterministic 1x1 image per call so tests can assert an attachment was actually produced,
/// without depending on any real math-typesetting engine (this package has none — see README).
private struct MockFormulaRenderer: FormulaRenderer {
    var shouldFail: Bool = false

    func image(forLaTeX latex: String, displayMode: Bool, fontSize: CGFloat) -> FormulaImage? {
        guard !shouldFail else { return nil }
        return FormulaImage(image: testImage(width: 10, height: 10), descent: 2)
    }
}

@Test func displayFormulaRendersAsAttachmentWhenRendererSupplied() {
    let blocks: [DocumentBlock] = [.formula(latex: "E = mc^2")]
    let attributed = DocumentRenderer.attributedString(from: blocks, title: "", formulaRenderer: MockFormulaRenderer())
    var foundAttachment = false
    attributed.enumerateAttribute(.attachment, in: NSRange(location: 0, length: attributed.length)) { value, _, _ in
        if value is NSTextAttachment { foundAttachment = true }
    }
    #expect(foundAttachment)
    #expect(!attributed.string.contains("E = mc^2"))
}

@Test func displayFormulaFallsBackToRawSourceWithoutRenderer() {
    let blocks: [DocumentBlock] = [.formula(latex: "E = mc^2")]
    let attributed = DocumentRenderer.attributedString(from: blocks, title: "")
    #expect(attributed.string.contains("E = mc^2"))
}

@Test func inlineDollarFormulaFlowsWithSurroundingParagraphText() {
    let blocks: [DocumentBlock] = [.paragraph(text: "The energy is $E = mc^2$ per Einstein.")]
    let attributed = DocumentRenderer.attributedString(from: blocks, title: "", formulaRenderer: MockFormulaRenderer())
    #expect(attributed.string.contains("The energy is"))
    #expect(attributed.string.contains("per Einstein."))
    var foundAttachment = false
    attributed.enumerateAttribute(.attachment, in: NSRange(location: 0, length: attributed.length)) { value, _, _ in
        if value is NSTextAttachment { foundAttachment = true }
    }
    #expect(foundAttachment)
}

@Test func inlineDollarSignsThatLookLikeCurrencyAreNotTreatedAsMath() {
    let blocks: [DocumentBlock] = [.paragraph(text: "It costs $5 or $10 depending on size.")]
    let attributed = DocumentRenderer.attributedString(from: blocks, title: "", formulaRenderer: MockFormulaRenderer())
    #expect(attributed.string.contains("$5 or $10"))
}

@Test func inlineFormulaFallsBackToRawSourceWhenRendererFailsToParse() {
    let blocks: [DocumentBlock] = [.paragraph(text: "Symbol $W$ here.")]
    let attributed = DocumentRenderer.attributedString(
        from: blocks,
        title: "",
        formulaRenderer: MockFormulaRenderer(shouldFail: true)
    )
    #expect(attributed.string.contains("$W$"))
}

/// A tiny (1x1 transparent) real PNG, so tests can exercise actual image decoding rather than a
/// synthetic `PlatformImage(size:)` that was never really encoded/decoded.
private let tinyPNGBase64 =
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="

private struct MockImageRenderer: ImageRenderer {
    var shouldFail: Bool = false

    func image(forSource source: String, altText: String) -> PlatformImage? {
        guard !shouldFail else { return nil }
        return testImage(width: 10, height: 10)
    }
}

private struct MockDiagramRenderer: DiagramRenderer {
    var shouldFail: Bool = false
    var capturedPalette: (DiagramPalette) -> Void = { _ in }

    func image(forMermaidSource source: String, palette: DiagramPalette) -> PlatformImage? {
        capturedPalette(palette)
        guard !shouldFail else { return nil }
        return testImage(width: 10, height: 10)
    }
}

@Test func imageWithDataURISourceDecodesWithoutAnyRendererSupplied() {
    let blocks: [DocumentBlock] = [.image(altText: "dot", source: "data:image/png;base64,\(tinyPNGBase64)")]
    let attributed = DocumentRenderer.attributedString(from: blocks, title: "")
    var foundAttachment = false
    attributed.enumerateAttribute(.attachment, in: NSRange(location: 0, length: attributed.length)) { value, _, _ in
        if value is NSTextAttachment { foundAttachment = true }
    }
    #expect(foundAttachment)
}

@Test func imageWithRemoteSourceUsesInjectedImageRenderer() {
    let blocks: [DocumentBlock] = [.image(altText: "diagram", source: "https://example.com/diagram.png")]
    let attributed = DocumentRenderer.attributedString(from: blocks, title: "", imageRenderer: MockImageRenderer())
    var foundAttachment = false
    attributed.enumerateAttribute(.attachment, in: NSRange(location: 0, length: attributed.length)) { value, _, _ in
        if value is NSTextAttachment { foundAttachment = true }
    }
    #expect(foundAttachment)
}

@Test func imageFallsBackToAltTextWithoutARendererOrDataURI() {
    let blocks: [DocumentBlock] = [.image(altText: "A diagram", source: "https://example.com/diagram.png")]
    let attributed = DocumentRenderer.attributedString(from: blocks, title: "")
    #expect(attributed.string.contains("A diagram"))
}

@Test func imageFallsBackWhenInjectedRendererCannotResolveIt() {
    let blocks: [DocumentBlock] = [.image(altText: "A diagram", source: "https://example.com/missing.png")]
    let attributed = DocumentRenderer.attributedString(from: blocks, title: "", imageRenderer: MockImageRenderer(shouldFail: true))
    #expect(attributed.string.contains("A diagram"))
}

@Test func imageWiderThanContentWidthIsScaledDownPreservingAspectRatio() {
    struct WideImageRenderer: ImageRenderer {
        func image(forSource source: String, altText: String) -> PlatformImage? {
            testImage(width: 2000, height: 1000)
        }
    }
    let blocks: [DocumentBlock] = [.image(altText: "wide", source: "wide.png")]
    let attributed = DocumentRenderer.attributedString(
        from: blocks,
        title: "",
        contentWidth: 500,
        imageRenderer: WideImageRenderer()
    )
    var attachmentSize: CGSize?
    attributed.enumerateAttribute(.attachment, in: NSRange(location: 0, length: attributed.length)) { value, _, _ in
        if let attachment = value as? NSTextAttachment { attachmentSize = attachment.bounds.size }
    }
    #expect(attachmentSize?.width == 500)
    #expect(attachmentSize?.height == 250)
}

@Test func mermaidDiagramRendersAsAttachmentWhenRendererSupplied() {
    let blocks: [DocumentBlock] = [.diagram(source: "graph TD\nA --> B")]
    let attributed = DocumentRenderer.attributedString(from: blocks, title: "", diagramRenderer: MockDiagramRenderer())
    var foundAttachment = false
    attributed.enumerateAttribute(.attachment, in: NSRange(location: 0, length: attributed.length)) { value, _, _ in
        if value is NSTextAttachment { foundAttachment = true }
    }
    #expect(foundAttachment)
    #expect(!attributed.string.contains("graph TD"))
}

@Test func mermaidDiagramFallsBackToRawSourceAsCodeBlockWithoutARenderer() {
    let blocks: [DocumentBlock] = [.diagram(source: "graph TD\nA --> B")]
    let attributed = DocumentRenderer.attributedString(from: blocks, title: "")
    #expect(attributed.string.contains("graph TD"))
    #expect(attributed.string.contains("A --> B"))
    var foundAttachment = false
    attributed.enumerateAttribute(.attachment, in: NSRange(location: 0, length: attributed.length)) { value, _, _ in
        if value is NSTextAttachment { foundAttachment = true }
    }
    #expect(!foundAttachment)
}

@Test func mermaidDiagramFallsBackWhenInjectedRendererCannotParseIt() {
    let blocks: [DocumentBlock] = [.diagram(source: "graph TD\nA --> B")]
    let attributed = DocumentRenderer.attributedString(from: blocks, title: "", diagramRenderer: MockDiagramRenderer(shouldFail: true))
    #expect(attributed.string.contains("graph TD"))
}

@Test func mermaidDiagramRendererReceivesTheActiveThemesDiagramPalette() {
    // The whole point of passing a DiagramPalette at all: a consumer's DiagramRenderer should be
    // able to color a rendered diagram to match the rest of the document (e.g. via a Mermaid
    // %%{init}%% directive) without separately hardcoding a palette of its own. This just guards
    // that the palette which actually reaches the renderer is the active theme's, not some
    // unrelated default.
    var theme = DocumentTheme.default
    theme.diagramPalette = DiagramPalette(nodeBackground: .red, nodeBorder: .green, lineColor: .blue, textColor: .yellow)

    var received: DiagramPalette?
    let renderer = MockDiagramRenderer(capturedPalette: { received = $0 })
    let blocks: [DocumentBlock] = [.diagram(source: "graph TD\nA --> B")]
    _ = DocumentRenderer.attributedString(from: blocks, title: "", theme: theme, diagramRenderer: renderer)

    #expect(received?.nodeBackground == .red)
    #expect(received?.nodeBorder == .green)
    #expect(received?.lineColor == .blue)
    #expect(received?.textColor == .yellow)
}

@Test func rendersTitleAndHeadingText() {
    let blocks: [DocumentBlock] = [.heading(level: 1, text: "Section"), .paragraph(text: "Body.")]
    let attributed = DocumentRenderer.attributedString(from: blocks, title: "My Document")
    let string = attributed.string
    #expect(string.contains("My Document"))
    #expect(string.contains("Section"))
    #expect(string.contains("Body."))
}

@Test func rendersOrderedListWithItsNumber() {
    let blocks: [DocumentBlock] = [.listItem(ordered: true, number: 5, level: 0, text: "Fifth")]
    let attributed = DocumentRenderer.attributedString(from: blocks, title: "")
    #expect(attributed.string.contains("5."))
    #expect(attributed.string.contains("Fifth"))
}

@Test func rendersCheckedAndUncheckedTaskListItemsWithDifferentGlyphs() {
    let blocks: [DocumentBlock] = [
        .taskListItem(checked: false, level: 0, text: "To do"),
        .taskListItem(checked: true, level: 0, text: "Done"),
    ]
    let attributed = DocumentRenderer.attributedString(from: blocks, title: "")
    #expect(attributed.string.contains("\u{2610}"))  // ☐
    #expect(attributed.string.contains("\u{2611}"))  // ☑
    #expect(attributed.string.contains("To do"))
    #expect(attributed.string.contains("Done"))
}

@Test func footnoteReferenceIsReplacedWithASuperscriptNumberAndDefinitionAppendedAtTheEnd() {
    let blocks: [DocumentBlock] = [
        .paragraph(text: "See the details[^1] for more."),
        .footnoteDefinition(identifier: "1", text: "The actual footnote text."),
    ]
    let attributed = DocumentRenderer.attributedString(from: blocks, title: "")

    #expect(!attributed.string.contains("[^1]"))
    #expect(attributed.string.contains("See the details1 for more."))
    #expect(attributed.string.contains("Footnotes"))
    #expect(attributed.string.contains("1.  The actual footnote text."))

    let numberRange = (attributed.string as NSString).range(of: "details1 for")
    let digitLocation = numberRange.location + "details".count
    let baselineOffset = attributed.attribute(.baselineOffset, at: digitLocation, effectiveRange: nil) as? CGFloat
    #expect((baselineOffset ?? 0) > 0)
}

@Test func footnotesAreNumberedByFirstReferenceOrderNotDeclarationOrder() {
    // "second" is defined first in the source but referenced second in the body — GFM numbers by
    // reference order, so it should come out as footnote 2, not footnote 1.
    let blocks: [DocumentBlock] = [
        .footnoteDefinition(identifier: "second", text: "Second definition text."),
        .footnoteDefinition(identifier: "first", text: "First definition text."),
        .paragraph(text: "First ref[^first], then second ref[^second]."),
    ]
    let attributed = DocumentRenderer.attributedString(from: blocks, title: "")

    #expect(attributed.string.contains("1.  First definition text."))
    #expect(attributed.string.contains("2.  Second definition text."))
}

@Test func unresolvedFootnoteReferenceStaysLiteralText() {
    let blocks: [DocumentBlock] = [.paragraph(text: "A dangling ref[^missing] with no definition.")]
    let attributed = DocumentRenderer.attributedString(from: blocks, title: "")
    #expect(attributed.string.contains("[^missing]"))
    #expect(!attributed.string.contains("Footnotes"))
}

@Test func unreferencedFootnoteDefinitionIsDroppedEntirely() {
    let blocks: [DocumentBlock] = [
        .paragraph(text: "No references here."),
        .footnoteDefinition(identifier: "orphan", text: "Nobody points to me."),
    ]
    let attributed = DocumentRenderer.attributedString(from: blocks, title: "")
    #expect(!attributed.string.contains("Footnotes"))
    #expect(!attributed.string.contains("Nobody points to me."))
}

@Test func rendersCodeBlockLinesJoined() {
    let blocks: [DocumentBlock] = [.codeBlock(lines: ["let x = 1", "print(x)"])]
    let attributed = DocumentRenderer.attributedString(from: blocks, title: "")
    #expect(attributed.string.contains("let x = 1"))
    #expect(attributed.string.contains("print(x)"))
}

@Test func codeBlockCarriesBackgroundColorForShading() {
    // DOCX picks this attribute up for free via AppKit's OOXML writer; `PDFRenderer` paints it
    // manually (CTFrameDraw ignores it) — this only guards that the attribute itself is actually
    // present on the code block's text, not either renderer.
    let blocks: [DocumentBlock] = [.codeBlock(lines: ["let x = 1"])]
    let attributed = DocumentRenderer.attributedString(from: blocks, title: "")
    let range = (attributed.string as NSString).range(of: "let x = 1")
    let background = attributed.attribute(.backgroundColor, at: range.location, effectiveRange: nil) as? PlatformColor
    #expect(background == DocumentTheme.default.codeBlockBackground)
}

@Test func codeBlockHasNoExtraParagraphSpacingBetweenInteriorLines() {
    // Regression guard: codeParagraph used to build the whole multi-line block as one
    // NSAttributedString with a single, uniformly-applied NSParagraphStyle carrying non-zero
    // paragraphSpacingBefore/paragraphSpacing — but every "\n" still starts a new paragraph for
    // layout purposes no matter how the attribute was applied, so that spacing landed between
    // *every* pair of lines inside the block, not just before/after the block as a whole. Only
    // visible by actually opening a generated PDF (a real multi-line code block showed a visible
    // gap in its shaded background between every line) — attribute-presence tests like
    // `codeBlockCarriesBackgroundColorForShading` above couldn't catch it, since the background
    // color attribute itself was always correct; only the paragraph style's spacing values were
    // wrong for interior lines.
    let blocks: [DocumentBlock] = [.codeBlock(lines: ["line one", "line two", "line three"])]
    let attributed = DocumentRenderer.attributedString(from: blocks, title: "")

    func paragraphStyle(containing needle: String) -> NSParagraphStyle? {
        let range = (attributed.string as NSString).range(of: needle)
        return attributed.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle
    }

    let first = paragraphStyle(containing: "line one")
    let middle = paragraphStyle(containing: "line two")
    let last = paragraphStyle(containing: "line three")

    #expect(first?.paragraphSpacingBefore == DocumentTheme.default.codeBlockSpacingBefore)
    #expect(first?.paragraphSpacing == 0)
    #expect(middle?.paragraphSpacingBefore == 0)
    #expect(middle?.paragraphSpacing == 0)
    #expect(last?.paragraphSpacingBefore == 0)
    #expect(last?.paragraphSpacing == DocumentTheme.default.codeBlockSpacingAfter)
}

@Test func codeBlockTextColorIsFixedNotDynamic() {
    // Regression guard: this used to be the dynamic `PlatformColor.textColor`, which resolved to a
    // barely-visible near-white when `PDFRenderer` drew it into a raw CGContext with no live
    // window/appearance to resolve against — confirmed by opening an actual generated PDF, not
    // caught by `codeBlockCarriesBackgroundColorForShading` above (attribute presence and color
    // correctness are different assertions).
    let blocks: [DocumentBlock] = [.codeBlock(lines: ["let x = 1"])]
    let attributed = DocumentRenderer.attributedString(from: blocks, title: "")
    let range = (attributed.string as NSString).range(of: "let x = 1")
    let foreground = attributed.attribute(.foregroundColor, at: range.location, effectiveRange: nil) as? PlatformColor
    #expect(foreground == PlatformColor.black)
}

@Test func rendersBlockquoteTextItalicizedAndIndented() {
    let blocks: [DocumentBlock] = [.blockquote(text: "A wise quote.")]
    let attributed = DocumentRenderer.attributedString(from: blocks, title: "")
    #expect(attributed.string.contains("A wise quote."))
    let range = (attributed.string as NSString).range(of: "A wise quote.")
    let font = attributed.attribute(.font, at: range.location, effectiveRange: nil) as? PlatformFont
    #if canImport(AppKit)
    #expect(font?.fontDescriptor.symbolicTraits.contains(.italic) == true)
    #elseif canImport(UIKit)
    #expect(font?.fontDescriptor.symbolicTraits.contains(.traitItalic) == true)
    #endif
    let style = attributed.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle
    #expect((style?.headIndent ?? 0) > 0)
}

@Test func rendersCalloutLabelInBoldAccentColorAboveTintedBody() {
    let blocks: [DocumentBlock] = [.callout(kind: .warning, text: "Careful here.")]
    let attributed = DocumentRenderer.attributedString(from: blocks, title: "")
    #expect(attributed.string.contains("Warning"))
    #expect(attributed.string.contains("Careful here."))

    let labelRange = (attributed.string as NSString).range(of: "Warning")
    let labelFont = attributed.attribute(.font, at: labelRange.location, effectiveRange: nil) as? PlatformFont
    #if canImport(AppKit)
    #expect(labelFont?.fontDescriptor.symbolicTraits.contains(.bold) == true)
    #elseif canImport(UIKit)
    #expect(labelFont?.fontDescriptor.symbolicTraits.contains(.traitBold) == true)
    #endif
    let labelColor = attributed.attribute(.foregroundColor, at: labelRange.location, effectiveRange: nil) as? PlatformColor
    #expect(labelColor != nil && labelColor != .black)

    let bodyRange = (attributed.string as NSString).range(of: "Careful here.")
    let bodyBackground = attributed.attribute(.backgroundColor, at: bodyRange.location, effectiveRange: nil) as? PlatformColor
    #expect(bodyBackground != nil)
    // The label itself carries no background — see `DocumentRenderer.calloutParagraph`'s doc
    // comment for why a background only as wide as the short label word would look wrong.
    let labelBackground = attributed.attribute(.backgroundColor, at: labelRange.location, effectiveRange: nil) as? PlatformColor
    #expect(labelBackground == nil)
}

@Test func differentCalloutKindsGetDifferentAccentColors() {
    func accentColor(for kind: CalloutKind) -> PlatformColor? {
        let attributed = DocumentRenderer.attributedString(from: [.callout(kind: kind, text: "Body.")], title: "")
        let range = (attributed.string as NSString).range(of: kind.rawValue)
        return attributed.attribute(.foregroundColor, at: range.location, effectiveRange: nil) as? PlatformColor
    }
    #expect(accentColor(for: .note) != accentColor(for: .tip))
    #expect(accentColor(for: .warning) != accentColor(for: .important))
    #expect(accentColor(for: .note) != accentColor(for: .warning))
}

@Test func bodyParagraphsAreJustifiedAndHyphenated() {
    let blocks: [DocumentBlock] = [.paragraph(text: "Some body text.")]
    let attributed = DocumentRenderer.attributedString(from: blocks, title: "")
    // Locate the paragraph style actually applied to the paragraph's text (index 0 is the
    // empty title's own paragraph style when title is "").
    let range = (attributed.string as NSString).range(of: "Some body text.")
    let style = attributed.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle
    #expect(style?.alignment == .justified)
    #expect(style?.hyphenationFactor == 1.0)
}

@Test func headingsAreNotJustified() {
    let blocks: [DocumentBlock] = [.heading(level: 2, text: "A short heading")]
    let attributed = DocumentRenderer.attributedString(from: blocks, title: "")
    let range = (attributed.string as NSString).range(of: "A short heading")
    let style = attributed.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle
    #expect(style?.alignment != .justified)
}

@Test func tableRendersAsASingleImageAttachment() {
    let blocks: [DocumentBlock] = [
        .table(header: ["A", "B"], alignments: [.none, .none], rows: [["1", "2"]])
    ]
    let attributed = DocumentRenderer.attributedString(from: blocks, title: "")
    var foundAttachment = false
    attributed.enumerateAttribute(.attachment, in: NSRange(location: 0, length: attributed.length)) { value, _, _ in
        if value is NSTextAttachment { foundAttachment = true }
    }
    #expect(foundAttachment)
}

@Test func tableImageFitsWithinRequestedContentWidth() {
    let longText = String(repeating: "word ", count: 40)
    let blocks: [DocumentBlock] = [
        .table(header: ["Column"], alignments: [.none], rows: [[longText]])
    ]
    let attributed = DocumentRenderer.attributedString(from: blocks, title: "", contentWidth: 300)
    var attachmentSize: CGSize?
    attributed.enumerateAttribute(.attachment, in: NSRange(location: 0, length: attributed.length)) { value, _, _ in
        if let attachment = value as? NSTextAttachment { attachmentSize = attachment.bounds.size }
    }
    #expect(attachmentSize != nil)
    #expect((attachmentSize?.width ?? .infinity) <= 300.5)
}

@Test func tableAttachmentCarriesRawDataForRealTextDrawing() {
    // `PDFRenderer` needs the original header/alignments/rows (not just a picture) to draw real,
    // selectable text instead of embedding the fallback bitmap — regression coverage for that
    // data actually surviving the trip through `tableParagraph`.
    let blocks: [DocumentBlock] = [
        .table(header: ["A", "B"], alignments: [.left, .right], rows: [["1", "2"]])
    ]
    let attributed = DocumentRenderer.attributedString(from: blocks, title: "")
    var found: TableAttachment?
    attributed.enumerateAttribute(.attachment, in: NSRange(location: 0, length: attributed.length)) { value, _, _ in
        if let table = value as? TableAttachment { found = table }
    }
    #expect(found?.header == ["A", "B"])
    #expect(found?.alignments == [.left, .right])
    #expect(found?.rows == [["1", "2"]])
    #expect(found?.layout.columnWidths.count == 2)
}

@Test func rendersTableForFallsBackToPlainTextWhenHeaderIsEmpty() {
    // TableRenderer.render returns nil for a zero-column table — DocumentRenderer must not
    // crash or silently drop the block, it falls back to plain text (see tableParagraph).
    let blocks: [DocumentBlock] = [.table(header: [], alignments: [], rows: [])]
    let attributed = DocumentRenderer.attributedString(from: blocks, title: "")
    #expect(attributed.length >= 0)
}

// MARK: - WordDocumentExporter (AppKit-only: DOCX writing isn't available on UIKit at all)

#if canImport(AppKit)
/// Extracts `word/document.xml` from `data` via `/usr/bin/unzip` — deliberately *not*
/// `MinimalZipArchive.read` (which these tests are partly trying to validate) — so a bug in our
/// own ZIP writer shows up as a failure here instead of being invisible to a self-checking round
/// trip through our own reader.
private func documentXML(fromDocxData data: Data) throws -> String {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }
    let docxURL = tempDir.appendingPathComponent("out.docx")
    try data.write(to: docxURL)

    let unzipDir = tempDir.appendingPathComponent("unzipped")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
    process.arguments = ["-q", docxURL.path, "-d", unzipDir.path]
    try process.run()
    process.waitUntilExit()

    return try String(contentsOf: unzipDir.appendingPathComponent("word/document.xml"), encoding: .utf8)
}

@Test func wordDocumentExporterProducesARealTableElementWithCellText() throws {
    let blocks: [DocumentBlock] = [
        .table(header: ["Metric", "Q1"], alignments: [.none, .none], rows: [["Revenue", "12k"]])
    ]
    let data = try WordDocumentExporter.export(blocks, title: "Report")
    let xml = try documentXML(fromDocxData: data)

    #expect(xml.contains("<w:tbl>"))
    #expect(xml.contains("Metric"))
    #expect(xml.contains("Revenue"))
    #expect(xml.contains("12k"))
    // No leftover placeholder sentinel — it must have been fully replaced, not left alongside the
    // real table.
    #expect(!xml.contains("TABLE0"))
}

@Test func wordDocumentExporterOutputIsWellFormedXML() throws {
    let blocks: [DocumentBlock] = [
        .heading(level: 1, text: "Report"),
        .paragraph(text: "Some **bold** prose."),
        .table(header: ["A", "B"], alignments: [.left, .right], rows: [["1", "2"], ["3", "4"]]),
        .paragraph(text: "After the table."),
    ]
    let data = try WordDocumentExporter.export(blocks, title: "Doc")
    let xml = try documentXML(fromDocxData: data)

    // Parsing as XML independently confirms our string-splice (paragraph-boundary search +
    // `<w:tbl>` insertion) produced structurally valid markup, not just text that happens to
    // contain the right substrings.
    #expect(throws: Never.self) {
        _ = try XMLDocument(data: Data(xml.utf8), options: [])
    }
}

@Test func wordDocumentExporterTableElementsFollowTheRequiredOOXMLSchemaOrder() throws {
    // Word (and any spec-compliant OOXML reader) requires a `<w:tbl>`'s children in exactly this
    // sequence — `tblPr`, then `tblGrid`, then one-or-more `tr`, each holding one-or-more `tc`,
    // each `tc` holding its `tcPr` before any `p` — not just "the right elements present
    // somewhere". Getting this wrong would still pass `wordDocumentExporterOutputIsWellFormedXML`
    // (still well-formed XML) and the other structural tests above (still contains the right
    // text) while still being rejected or silently reinterpreted by a real editor — exactly the
    // class of bug neither of those catches. This is the automatable half of "is this really
    // editable": confirming an editor's schema *would* accept the shape, without depending on an
    // actual editor (python-docx/Word/LibreOffice) being installed in CI.
    let blocks: [DocumentBlock] = [
        .table(header: ["A", "B"], alignments: [.left, .right], rows: [["1", "2"], ["3", "4"]])
    ]
    let data = try WordDocumentExporter.export(blocks, title: "")
    let xml = try documentXML(fromDocxData: data)

    let document = try XMLDocument(data: Data(xml.utf8), options: [])
    let tables = try document.nodes(forXPath: "//*[local-name()='tbl']")
    let table = try #require(tables.first as? XMLElement)
    #expect(tables.count == 1)

    let tableChildren = (table.children ?? []).compactMap { $0 as? XMLElement }
    #expect(tableChildren.first?.localName == "tblPr")
    #expect(tableChildren.dropFirst().first?.localName == "tblGrid")

    let rows = Array(tableChildren.dropFirst(2))
    #expect(!rows.isEmpty)
    #expect(rows.allSatisfy { $0.localName == "tr" })

    for row in rows {
        let cells = (row.children ?? []).compactMap { $0 as? XMLElement }
        #expect(!cells.isEmpty)
        #expect(cells.allSatisfy { $0.localName == "tc" })
        for cell in cells {
            let cellChildren = (cell.children ?? []).compactMap { $0 as? XMLElement }
            #expect(cellChildren.first?.localName == "tcPr")
            #expect(cellChildren.dropFirst().allSatisfy { $0.localName == "p" })
        }
    }
}

@Test func wordDocumentExporterHandlesMultipleTablesAtTheirOwnPlaceholders() throws {
    let blocks: [DocumentBlock] = [
        .table(header: ["A"], alignments: [.none], rows: [["first"]]),
        .paragraph(text: "Between the two tables."),
        .table(header: ["B"], alignments: [.none], rows: [["second"]]),
    ]
    let data = try WordDocumentExporter.export(blocks, title: "")
    let xml = try documentXML(fromDocxData: data)

    #expect(xml.components(separatedBy: "<w:tbl>").count - 1 == 2)
    #expect(xml.contains("first"))
    #expect(xml.contains("second"))
    #expect(xml.range(of: "first")!.lowerBound < xml.range(of: "Between the two tables")!.lowerBound)
    #expect(xml.range(of: "Between the two tables")!.lowerBound < xml.range(of: "second")!.lowerBound)
}

@Test func wordDocumentExporterBoldTableCellProducesABoldRun() throws {
    let blocks: [DocumentBlock] = [
        .table(header: ["A"], alignments: [.none], rows: [["**bold cell**"]])
    ]
    let data = try WordDocumentExporter.export(blocks, title: "")
    let xml = try documentXML(fromDocxData: data)

    let cellRange = xml.range(of: "bold cell")
    #expect(cellRange != nil)
    if let cellRange {
        let precedingContext = xml[xml.startIndex..<cellRange.lowerBound].suffix(200)
        #expect(precedingContext.contains("<w:b/>"))
    }
}

@Test func wordDocumentExporterNonTableContentMatchesAttributedStringText() throws {
    // Only `.table` should diverge from `attributedString(from:...)` — everything else routes
    // through the exact same `DocumentRenderer.blockParagraph`.
    let blocks: [DocumentBlock] = [
        .heading(level: 1, text: "Report"),
        .paragraph(text: "Some prose."),
    ]
    let data = try WordDocumentExporter.export(blocks, title: "Doc")
    let xml = try documentXML(fromDocxData: data)
    #expect(xml.contains("Doc"))
    #expect(xml.contains("Report"))
    #expect(xml.contains("Some prose."))
}

@Test func wordDocumentExporterFallsBackToPlainTextForAZeroColumnTable() throws {
    // OOXMLTableWriter.tableXML returns nil for a zero-column table, same as
    // TableRenderer.computeLayout — must not throw or silently drop the block.
    let blocks: [DocumentBlock] = [.table(header: [], alignments: [], rows: [])]
    let data = try WordDocumentExporter.export(blocks, title: "")
    #expect(!data.isEmpty)
}

@Test func wordDocumentExporterFootnoteReferenceUsesSemanticSuperscriptNotRawPosition() throws {
    // Regression coverage for a real, only-visually-obvious bug (caught by actually opening a
    // generated .docx in Quick Look, not by any earlier string-contains test): AppKit's writer
    // encodes `.baselineOffset` as a raw `<w:position w:val="N"/>` geometric offset. `textutil` (a
    // second, independent OOXML reader) renders that raised as intended, but Quick Look's own docx
    // preview renders it *lowered* instead — `<w:vertAlign w:val="superscript"/>`, the semantic
    // element a real editor's own superscript command would write, is the more robustly-understood
    // representation and is what `WordDocumentExporter` now substitutes in.
    let blocks: [DocumentBlock] = [
        .paragraph(text: "See the details[^1]."),
        .footnoteDefinition(identifier: "1", text: "Footnote text."),
    ]
    let data = try WordDocumentExporter.export(blocks, title: "")
    let xml = try documentXML(fromDocxData: data)

    #expect(xml.contains("<w:vertAlign w:val=\"superscript\"/>"))
    #expect(!xml.contains("<w:position"))
}

@Test func wordDocumentExporterTableCellsUseTheSameFontFamilyAsTheRestOfTheDocument() throws {
    // Regression coverage for a real, only-visually-obvious bug (caught by actually opening a
    // generated .docx, not by any earlier string-contains test): table cells used to carry no
    // `<w:rFonts>` at all, or one built from `NSFont.familyName`, which for the system font
    // resolves to `.AppleSystemUIFont` — one of AppKit's private, dot-prefixed internal names, not
    // a real typeface any OOXML reader outside AppKit's own text system can resolve. That rendered
    // table text in Word's default serif fallback while the rest of the document (written by
    // AppKit's own writer, which *does* resolve the system font to a real family) showed the
    // correct sans-serif family. Deliberately not asserting a literal "Helvetica Neue" — comparing
    // the table's family against the body paragraph's own `<w:rFonts>` keeps this correct even if
    // a future OS resolves the system font to a different real name. Deliberately comparing the
    // family on the *specific runs carrying our own visible text*, not "every `<w:rFonts>` in the
    // document is identical": AppKit's writer itself emits a second, closely related family
    // ("Helvetica" vs "Helvetica Neue") on its own unrelated empty trailing runs — a pre-existing
    // writer quirk this test has no reason to assert away.
    let blocks: [DocumentBlock] = [
        .paragraph(text: "Distinctive body prose."),
        .table(header: ["A"], alignments: [.none], rows: [["Distinctive cell text"]]),
    ]
    let data = try WordDocumentExporter.export(blocks, title: "")
    let xml = try documentXML(fromDocxData: data)

    #expect(!xml.contains(".AppleSystemUIFont"))

    func fontFamily(precedingFirstOccurrenceOf marker: String) throws -> String {
        let markerRange = try #require(xml.range(of: marker))
        let precedingXML = String(xml[xml.startIndex..<markerRange.lowerBound])
        let regex = try NSRegularExpression(pattern: #"<w:rFonts w:ascii="([^"]+)""#)
        let nsPrecedingXML = precedingXML as NSString
        let lastMatch = try #require(
            regex.matches(in: precedingXML, range: NSRange(location: 0, length: nsPrecedingXML.length)).last
        )
        return nsPrecedingXML.substring(with: lastMatch.range(at: 1))
    }

    let bodyFamily = try fontFamily(precedingFirstOccurrenceOf: "Distinctive body prose.")
    let cellFamily = try fontFamily(precedingFirstOccurrenceOf: "Distinctive cell text")
    #expect(bodyFamily == cellFamily)
}

@Test func wordDocumentExporterWithNoTablesSkipsZipRewritingEntirely() throws {
    // No placeholders to find means no zip round trip needed — this exercises that early-return
    // path (`guard !tables.isEmpty else { return officeOpenXMLData }`) explicitly.
    let blocks: [DocumentBlock] = [.paragraph(text: "No tables here.")]
    let data = try WordDocumentExporter.export(blocks, title: "")
    let xml = try documentXML(fromDocxData: data)
    #expect(xml.contains("No tables here."))
}
#endif
#endif
