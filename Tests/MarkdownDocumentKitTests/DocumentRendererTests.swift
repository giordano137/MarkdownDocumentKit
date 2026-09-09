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
#endif
