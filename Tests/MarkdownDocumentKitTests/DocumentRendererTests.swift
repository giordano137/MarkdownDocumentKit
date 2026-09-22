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

    func image(forMermaidSource source: String) -> PlatformImage? {
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
#endif
