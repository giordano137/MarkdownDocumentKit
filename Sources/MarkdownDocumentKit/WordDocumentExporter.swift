// WordDocumentExporter
//
// Produces a `.docx` with real, editable Word tables — not the flattened image
// `DocumentRenderer.attributedString(from:...)` embeds, which is what AppKit's own
// `.officeOpenXML` writer (`NSAttributedString.data(from:documentAttributes:)`, see README) turns
// every `.table` block into today, and (verified empirically, not assumed — see
// `OOXMLTableWriter`'s own top comment) *stays* turning into even if the source string carries a
// real `NSTextTable` instead: that writer silently drops `NSTextTableBlock` structure rather than
// serializing it to `<w:tbl>`.
//
// So this builds the `<w:tbl>` XML itself (`OOXMLTableWriter`) and splices it into the `.docx`
// AppKit's writer already produces, in place of a placeholder paragraph left where each table
// belongs: every non-table block renders exactly as `attributedString(from:...)` would (both share
// `DocumentRenderer.blockParagraph`), so this only ever touches the table encoding, not the rest of
// the document.
//
// AppKit-only, like the rest of DOCX support in this package (see README's "AppKit's own OOXML
// writer") — `.data(from:documentAttributes:)` for `.officeOpenXML` isn't available on UIKit at
// all, so there was never a cross-platform DOCX path to preserve here.
//
// Why splice XML into AppKit's own zip rather than write a `.docx` completely from scratch: every
// other part of a `.docx` (styles, theme colors, document properties, the OOXML relationships
// between them) is exactly what AppKit's writer already gets right for the rest of the document —
// reimplementing all of that ourselves to fix one part (tables) would both be far more code and
// risk drifting from what Word actually expects as AppKit's own writer evolves.

#if canImport(AppKit)
import AppKit
import Foundation

public enum WordDocumentExportError: Error {
    /// AppKit's `.officeOpenXML` writer didn't produce a well-formed ZIP, or `word/document.xml`
    /// wasn't in it — would mean that writer's own output shape changed in a way
    /// `MinimalZipArchive` (deliberately scoped to today's shape, see its own top comment) no
    /// longer understands, not a problem with the source document.
    case unreadableOfficeOpenXMLOutput
    /// A table's placeholder paragraph vanished from `word/document.xml` between being written and
    /// being searched for — same "AppKit's writer output shape changed underneath us" cause as
    /// `unreadableOfficeOpenXMLOutput`.
    case placeholderNotFound
}

public enum WordDocumentExporter {
    /// `.docx` bytes, ready to write to disk — mirrors `PDFRenderer.render(_:)`'s shape
    /// (`throws -> Data`) rather than handing back an `NSAttributedString` for the caller to
    /// serialize themselves, because that intermediate string here contains table placeholders,
    /// not real content — feeding it directly to `.data(from:documentAttributes:)` the way the
    /// README's own DOCX snippet does for `attributedString(from:...)` would write those
    /// placeholders straight into the document.
    public static func export(
        _ blocks: [DocumentBlock],
        title: String,
        contentWidth: CGFloat = DocumentRenderer.defaultContentWidth,
        theme: DocumentTheme = .default,
        formulaRenderer: FormulaRenderer? = nil,
        imageRenderer: ImageRenderer? = nil,
        diagramRenderer: DiagramRenderer? = nil
    ) throws -> Data {
        var tables: [(header: [String], alignments: [TableAlignment], rows: [[String]])] = []
        let attributed = NSMutableAttributedString()
        attributed.append(DocumentRenderer.styledTitle(title, theme: theme))
        let footnoteNumbers = DocumentRenderer.footnoteReferenceNumbers(in: blocks)
        for block in blocks {
            switch block {
            case .table(let header, let alignments, let rows):
                attributed.append(placeholderParagraph(index: tables.count))
                tables.append((header, alignments, rows))
            // Every footnote definition renders once, together, in the trailing "Footnotes"
            // section appended below — not inline at its own position in the block sequence —
            // same skip `DocumentRenderer.attributedString(from:...)` applies.
            case .footnoteDefinition:
                continue
            default:
                attributed.append(
                    DocumentRenderer.blockParagraph(
                        block,
                        contentWidth: contentWidth,
                        theme: theme,
                        formulaRenderer: formulaRenderer,
                        imageRenderer: imageRenderer,
                        diagramRenderer: diagramRenderer
                    )
                )
            }
        }
        DocumentRenderer.replaceFootnoteReferences(in: attributed, numbers: footnoteNumbers, theme: theme)
        if let footnotesSection = DocumentRenderer.footnoteDefinitionsSection(
            blocks: blocks,
            numbers: footnoteNumbers,
            theme: theme,
            formulaRenderer: formulaRenderer
        ) {
            attributed.append(footnotesSection)
        }

        let officeOpenXMLData = try attributed.data(
            from: NSRange(location: 0, length: attributed.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML]
        )
        guard !tables.isEmpty || !footnoteNumbers.isEmpty else { return officeOpenXMLData }

        var entries: [ZipEntry]
        do {
            entries = try MinimalZipArchive.read(officeOpenXMLData)
        } catch {
            throw WordDocumentExportError.unreadableOfficeOpenXMLOutput
        }
        guard let documentIndex = entries.firstIndex(where: { $0.name == "word/document.xml" }),
            var documentXML = String(data: entries[documentIndex].uncompressedData, encoding: .utf8)
        else { throw WordDocumentExportError.unreadableOfficeOpenXMLOutput }

        for (index, table) in tables.enumerated() {
            let tableXML =
                OOXMLTableWriter.tableXML(
                    header: table.header,
                    alignments: table.alignments,
                    rows: table.rows,
                    contentWidth: contentWidth,
                    theme: theme
                ) ?? plainTextFallbackXML(header: table.header, rows: table.rows)
            try replacePlaceholderParagraph(index: index, in: &documentXML, with: tableXML)
        }
        replaceRawPositionWithSemanticSuperscript(in: &documentXML)

        let originalEntry = entries[documentIndex]
        entries[documentIndex] = ZipEntry(
            name: originalEntry.name,
            uncompressedData: Data(documentXML.utf8),
            dosTime: originalEntry.dosTime,
            dosDate: originalEntry.dosDate
        )
        return MinimalZipArchive.write(entries)
    }

    /// AppKit's `.officeOpenXML` writer encodes a footnote reference's `.baselineOffset` (see
    /// `DocumentRenderer.replaceFootnoteReferences`, the only place this package ever sets that
    /// attribute) as a raw `<w:position w:val="N"/>` — a geometric "raise this run by N half-points"
    /// instruction, not the semantic "this run is superscript" `<w:vertAlign>` element a real
    /// editor's own superscript command would produce. Both are spec-legal and (confirmed via
    /// `textutil`, an independent OOXML reader) render identically raised in at least one real
    /// reader — but macOS's own Quick Look docx preview renders a raw `<w:position>` *lowered*
    /// instead, confirmed by actually opening a generated `.docx` and looking at it, not by any
    /// string-contains test. Swapping in `<w:vertAlign w:val="superscript"/>` — what Word's own UI
    /// would write — is the more robustly-understood representation, so every footnote reference
    /// gets this instead of AppKit's default encoding. Safe as an unconditional, non-positional
    /// substitution: `.baselineOffset` is exclusively this package's own footnote-superscript
    /// signal (confirmed — nothing else in this codebase sets it), always positive, so every
    /// `<w:position>` a generated `document.xml` could possibly contain came from exactly this and
    /// always means "superscript," never "subscript."
    private static func replaceRawPositionWithSemanticSuperscript(in documentXML: inout String) {
        guard let regex = try? NSRegularExpression(pattern: "<w:position w:val=\"\\d+\"/>") else { return }
        let range = NSRange(location: 0, length: (documentXML as NSString).length)
        documentXML = regex.stringByReplacingMatches(
            in: documentXML,
            range: range,
            withTemplate: "<w:vertAlign w:val=\"superscript\"/>"
        )
    }

    // MARK: - Placeholder paragraphs

    /// Private-Use-Area sentinels (distinct from `DocumentRenderer`'s own formula sentinels, so
    /// the two never collide inside one document) wrapping a table's index — guaranteed not to
    /// collide with real document text for the same reason `DocumentRenderer.extractInlineFormulas`
    /// already relies on this trick: these codepoints carry no meaning any real Markdown source
    /// would plausibly contain.
    private static let sentinelStart: Character = "\u{E030}"
    private static let sentinelEnd: Character = "\u{E031}"

    private static func placeholderText(index: Int) -> String {
        "\(sentinelStart)TABLE\(index)\(sentinelEnd)"
    }

    private static func placeholderParagraph(index: Int) -> NSAttributedString {
        NSAttributedString(string: placeholderText(index: index) + "\n")
    }

    /// Finds the placeholder text, then widens outward to that specific `<w:p>...</w:p>` element
    /// and replaces the whole thing with `replacementXML`. Paragraphs never nest in OOXML, so the
    /// nearest `</w:p>` after the placeholder and nearest `<w:p>` before it are unambiguously its
    /// own boundaries — deliberately searching for the exact literal `<w:p>` (not just `<w:p`,
    /// which `<w:pPr>` — this same paragraph's own properties element, appearing between that open
    /// tag and the placeholder text — would also match) is what keeps this from mis-locating the
    /// paragraph's start.
    private static func replacePlaceholderParagraph(index: Int, in documentXML: inout String, with replacementXML: String) throws {
        let placeholder = placeholderText(index: index)
        guard let placeholderRange = documentXML.range(of: placeholder) else {
            throw WordDocumentExportError.placeholderNotFound
        }
        guard
            let paragraphStart = documentXML.range(
                of: "<w:p>",
                options: .backwards,
                range: documentXML.startIndex..<placeholderRange.lowerBound
            )?.lowerBound,
            let paragraphEnd = documentXML.range(
                of: "</w:p>",
                range: placeholderRange.upperBound..<documentXML.endIndex
            )?.upperBound
        else { throw WordDocumentExportError.placeholderNotFound }

        documentXML.replaceSubrange(paragraphStart..<paragraphEnd, with: replacementXML)
    }

    /// Mirrors `DocumentRenderer.tableParagraph`'s own fallback for a zero-column table — shows
    /// the raw cell text rather than silently dropping the table. One `<w:t>` run per line joined
    /// by `<w:br/>` (an explicit line break element), since `<w:t>`'s own text content collapses a
    /// literal newline the way HTML whitespace does — a plain `\n` inside it would render as a
    /// single space, not a line break.
    private static func plainTextFallbackXML(header: [String], rows: [[String]]) -> String {
        let lines = ([header] + rows).map { $0.joined(separator: " | ") }
        let runs = lines.enumerated().map { index, line -> String in
            let breakTag = index == 0 ? "" : "<w:br/>"
            return "\(breakTag)<w:t xml:space=\"preserve\">\(OOXMLTableWriter.escapeXML(line))</w:t>"
        }.joined()
        return "<w:p><w:r>\(runs)</w:r></w:p>"
    }
}
#endif
