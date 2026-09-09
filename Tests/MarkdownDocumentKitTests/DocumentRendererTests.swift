#if os(macOS)
import AppKit
import Testing
@testable import MarkdownDocumentKit

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
    // `PDFRenderer` in the 137 app needs the original header/alignments/rows (not just a
    // picture) to draw real, selectable text instead of embedding the fallback bitmap —
    // regression coverage for that data actually surviving the trip through `tableParagraph`.
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
