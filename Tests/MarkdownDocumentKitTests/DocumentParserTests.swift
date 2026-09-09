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

@Test func parsesSimpleTableWithAlignments() {
    let markdown = """
        | Left | Center | Right |
        | :--- | :---: | ---: |
        | a | b | c |
        | d | e | f |
        """
    let blocks = DocumentParser.parse(markdown)
    #expect(
        blocks == [
            .table(
                header: ["Left", "Center", "Right"],
                alignments: [.left, .center, .right],
                rows: [["a", "b", "c"], ["d", "e", "f"]]
            )
        ]
    )
}

@Test func tableWithoutAlignmentColonsUsesNoneAlignment() {
    let markdown = "| A | B |\n| --- | --- |\n| 1 | 2 |"
    let blocks = DocumentParser.parse(markdown)
    #expect(blocks == [.table(header: ["A", "B"], alignments: [.none, .none], rows: [["1", "2"]])])
}

@Test func lineWithPipeButNoDelimiterRowIsNotATable() {
    // A stray "|" in a normal sentence shouldn't be mistaken for a table just because the
    // line contains a pipe — the very next line has to actually be a valid delimiter row.
    let blocks = DocumentParser.parse("Speed | Velocity, same thing.\nNext paragraph.")
    #expect(
        blocks == [
            .paragraph(text: "Speed | Velocity, same thing."),
            .paragraph(text: "Next paragraph."),
        ]
    )
}

@Test func raggedTableRowsAreNormalizedToHeaderWidth() {
    let markdown = "| A | B | C |\n| --- | --- | --- |\n| short |\n| way | too | many | cells |"
    let blocks = DocumentParser.parse(markdown)
    #expect(
        blocks == [
            .table(
                header: ["A", "B", "C"],
                alignments: [.none, .none, .none],
                rows: [["short", "", ""], ["way", "too", "many"]]
            )
        ]
    )
}

@Test func tableStopsAtBlankLine() {
    let markdown = "| A | B |\n| --- | --- |\n| 1 | 2 |\n\nAfter the table."
    let blocks = DocumentParser.parse(markdown)
    #expect(
        blocks == [
            .table(header: ["A", "B"], alignments: [.none, .none], rows: [["1", "2"]]),
            .paragraph(text: "After the table."),
        ]
    )
}

@Test func emptyCellSurvivesAsEmptyString() {
    // GFM's usual convention for "same value as the row above" — no real rowspan concept,
    // just an empty cell (see DocumentBlock.table's doc comment).
    let markdown = "| A | B |\n| --- | --- |\n| x | y |\n|  | z |"
    let blocks = DocumentParser.parse(markdown)
    #expect(
        blocks == [
            .table(header: ["A", "B"], alignments: [.none, .none], rows: [["x", "y"], ["", "z"]])
        ]
    )
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
