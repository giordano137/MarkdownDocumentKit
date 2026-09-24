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

@Test func parsesUncheckedTaskListItem() {
    let blocks = DocumentParser.parse("- [ ] Buy milk")
    #expect(blocks == [.taskListItem(checked: false, level: 0, text: "Buy milk")])
}

@Test func parsesCheckedTaskListItemBothCaseVariants() {
    for marker in ["[x]", "[X]"] {
        let blocks = DocumentParser.parse("- \(marker) Done already")
        #expect(blocks == [.taskListItem(checked: true, level: 0, text: "Done already")])
    }
}

@Test func taskListMarkersWorkWithAllThreeBulletCharacters() {
    for marker in ["- ", "* ", "+ "] {
        let blocks = DocumentParser.parse("\(marker)[ ] Item")
        #expect(blocks == [.taskListItem(checked: false, level: 0, text: "Item")])
    }
}

@Test func nestedTaskListItemKeepsItsIndentLevel() {
    let blocks = DocumentParser.parse("  - [x] Nested done")
    #expect(blocks == [.taskListItem(checked: true, level: 1, text: "Nested done")])
}

@Test func bracketsNotShapedLikeATaskMarkerStayAPlainListItem() {
    // "[ ]" needs to be immediately after the bullet with nothing else between them, and needs
    // the trailing space inside the brackets — "[x]" glued straight to text (no space before the
    // content) or a non-checkbox bracket shouldn't be mistaken for one.
    let blocks = DocumentParser.parse("- [Not a checkbox] just text")
    #expect(blocks == [.listItem(ordered: false, number: nil, level: 0, text: "[Not a checkbox] just text")])
}

@Test func parsesFootnoteDefinition() {
    let blocks = DocumentParser.parse("[^1]: This is the footnote text.")
    #expect(blocks == [.footnoteDefinition(identifier: "1", text: "This is the footnote text.")])
}

@Test func parsesFootnoteDefinitionWithANonNumericIdentifier() {
    let blocks = DocumentParser.parse("[^note-a]: Named identifiers work too.")
    #expect(blocks == [.footnoteDefinition(identifier: "note-a", text: "Named identifiers work too.")])
}

@Test func footnoteReferenceInsideAParagraphStaysLiteralAtParseTime() {
    // Resolved by DocumentRenderer at render time, same as inline math — the parser doesn't
    // decompose it.
    let blocks = DocumentParser.parse("See the details[^1].")
    #expect(blocks == [.paragraph(text: "See the details[^1].")])
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

@Test func parsesBlockquoteStrippingMarker() {
    let blocks = DocumentParser.parse("> A quoted line.")
    #expect(blocks == [.blockquote(text: "A quoted line.")])
}

@Test func joinsConsecutiveBlockquoteLinesIntoOneBlock() {
    let blocks = DocumentParser.parse("> Line one.\n> Line two.")
    #expect(blocks == [.blockquote(text: "Line one. Line two.")])
}

@Test func blockquoteWithPipeIsNotMistakenForATable() {
    // A quoted line containing "|" (or a quoted table row) must stay a blockquote, not get
    // reinterpreted by the table branch just because it contains a pipe character.
    let blocks = DocumentParser.parse("> Speed | Velocity, same thing.\nNext paragraph.")
    #expect(
        blocks == [
            .blockquote(text: "Speed | Velocity, same thing."),
            .paragraph(text: "Next paragraph."),
        ]
    )
}

@Test func parsesWholeLineImageMarkdown() {
    let blocks = DocumentParser.parse("![A diagram](https://example.com/diagram.png)")
    #expect(blocks == [.image(altText: "A diagram", source: "https://example.com/diagram.png")])
}

@Test func parsesImageWithEmptyAltText() {
    let blocks = DocumentParser.parse("![](local.png)")
    #expect(blocks == [.image(altText: "", source: "local.png")])
}

@Test func imageMentionedMidSentenceStaysPlainParagraphText() {
    // Bounded, block-level scope (see README) — only a whole-line image is its own block.
    let blocks = DocumentParser.parse("See ![alt](x.png) above.")
    #expect(blocks == [.paragraph(text: "See ![alt](x.png) above.")])
}

@Test func parsesCalloutMarkerAsItsKind() {
    for (marker, kind) in [("NOTE", CalloutKind.note), ("TIP", .tip), ("WARNING", .warning), ("IMPORTANT", .important)] {
        let blocks = DocumentParser.parse("> [!\(marker)]\n> Body text.")
        #expect(blocks == [.callout(kind: kind, text: "Body text.")])
    }
}

@Test func calloutMarkerMatchingIsCaseInsensitive() {
    let blocks = DocumentParser.parse("> [!note]\n> Body text.")
    #expect(blocks == [.callout(kind: .note, text: "Body text.")])
}

@Test func joinsMultipleCalloutBodyLines() {
    let blocks = DocumentParser.parse("> [!TIP]\n> Line one.\n> Line two.")
    #expect(blocks == [.callout(kind: .tip, text: "Line one. Line two.")])
}

@Test func quoteContainingMarkerTextButNotAsWholeLineStaysAPlainBlockquote() {
    // The marker has to be the *entire* first line — a real quote that merely mentions the
    // bracketed text inline must not be reinterpreted as a callout.
    let blocks = DocumentParser.parse("> He said [!NOTE] once, oddly.")
    #expect(blocks == [.blockquote(text: "He said [!NOTE] once, oddly.")])
}

@Test func unknownBracketMarkerStaysAPlainBlockquote() {
    let blocks = DocumentParser.parse("> [!UNKNOWN]\n> Body text.")
    #expect(blocks == [.blockquote(text: "[!UNKNOWN] Body text.")])
}

@Test func parsesSingleLineDisplayFormula() {
    let blocks = DocumentParser.parse("\\[E = mc^2\\]")
    #expect(blocks == [.formula(latex: "E = mc^2")])
}

@Test func parsesSingleLineDollarDollarFormula() {
    let blocks = DocumentParser.parse("$$E = mc^2$$")
    #expect(blocks == [.formula(latex: "E = mc^2")])
}

@Test func parsesFencedMultiLineDisplayFormula() {
    let markdown = "\\[\nx = 1 \\\\\ny = 2\n\\]"
    let blocks = DocumentParser.parse(markdown)
    #expect(blocks == [.formula(latex: "x = 1 \\\\\ny = 2")])
}

@Test func formulaContainingPipeIsNotMistakenForATable() {
    let blocks = DocumentParser.parse("\\[|x| = 1\\]\nNext paragraph.")
    #expect(
        blocks == [
            .formula(latex: "|x| = 1"),
            .paragraph(text: "Next paragraph."),
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

@Test func parsesMermaidFencedBlockAsDiagramNotCodeBlock() {
    let markdown = "```mermaid\ngraph TD\nA --> B\n```"
    let blocks = DocumentParser.parse(markdown)
    #expect(blocks == [.diagram(source: "graph TD\nA --> B")])
}

@Test func mermaidLanguageTagMatchingIsCaseInsensitive() {
    let markdown = "```Mermaid\ngraph TD\nA --> B\n```"
    let blocks = DocumentParser.parse(markdown)
    #expect(blocks == [.diagram(source: "graph TD\nA --> B")])
}

@Test func nonMermaidFencedLanguageStaysAPlainCodeBlock() {
    let markdown = "```swift\nlet x = 1\n```"
    let blocks = DocumentParser.parse(markdown)
    #expect(blocks == [.codeBlock(lines: ["let x = 1"])])
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
