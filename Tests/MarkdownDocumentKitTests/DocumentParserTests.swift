import Testing
@testable import MarkdownDocumentKit

@Test func parsesHeadingLevels() {
    let blocks = DocumentParser.parse("# One\n## Two\n###### Six")
    #expect(
        blocks == [
            .heading(level: 1, text: "One"),
            .heading(level: 2, text: "Two"),
            .heading(level: 6, text: "Six"),
        ]
    )
}

@Test func parsesPlainParagraph() {
    let blocks = DocumentParser.parse("Just a line of text.")
    #expect(blocks == [.paragraph(text: "Just a line of text.")])
}

@Test func skipsBlankLines() {
    let blocks = DocumentParser.parse("# Title\n\n\nBody text.")
    #expect(blocks == [.heading(level: 1, text: "Title"), .paragraph(text: "Body text.")])
}

@Test func parsesUnorderedListMarkers() {
    for marker in ["- ", "* ", "+ "] {
        let blocks = DocumentParser.parse("\(marker)Item")
        #expect(blocks == [.listItem(ordered: false, number: nil, level: 0, text: "Item")])
    }
}

@Test func parsesOrderedListWithNumber() {
    let blocks = DocumentParser.parse("3. Third item")
    #expect(blocks == [.listItem(ordered: true, number: 3, level: 0, text: "Third item")])
}

@Test func parsesNestedListByIndentation() {
    let blocks = DocumentParser.parse("- Top\n  - Nested once\n    - Nested twice")
    #expect(
        blocks == [
            .listItem(ordered: false, number: nil, level: 0, text: "Top"),
            .listItem(ordered: false, number: nil, level: 1, text: "Nested once"),
            .listItem(ordered: false, number: nil, level: 2, text: "Nested twice"),
        ]
    )
}

@Test func parsesFencedCodeBlockAsOneBlock() {
    let markdown = "```\nlet x = 1\nprint(x)\n```"
    let blocks = DocumentParser.parse(markdown)
    #expect(blocks == [.codeBlock(lines: ["let x = 1", "print(x)"])])
}

@Test func codeBlockContentIsNotParsedAsHeadingsOrLists() {
    let markdown = "```\n# not a heading\n- not a list item\n```"
    let blocks = DocumentParser.parse(markdown)
    #expect(blocks == [.codeBlock(lines: ["# not a heading", "- not a list item"])])
}

@Test func unterminatedCodeBlockStillFlushesAtEndOfDocument() {
    let markdown = "```\nleftover line"
    let blocks = DocumentParser.parse(markdown)
    #expect(blocks == [.codeBlock(lines: ["leftover line"])])
}

@Test func parsesMixedDocumentInOrder() {
    let markdown = """
        # Report

        Intro paragraph.

        - First
        - Second

        ```
        code here
        ```
        """
    let blocks = DocumentParser.parse(markdown)
    #expect(
        blocks == [
            .heading(level: 1, text: "Report"),
            .paragraph(text: "Intro paragraph."),
            .listItem(ordered: false, number: nil, level: 0, text: "First"),
            .listItem(ordered: false, number: nil, level: 0, text: "Second"),
            .codeBlock(lines: ["code here"]),
        ]
    )
}
