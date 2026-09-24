// OOXMLTableWriter
//
// Hand-writes the `<w:tbl>` XML fragment `WordDocumentExporter` splices into `word/document.xml` in
// place of a table's placeholder paragraph. Exists because AppKit's own `.officeOpenXML` writer
// turns out not to do this itself: verified empirically (not assumed) that a real `NSTextTable`/
// `NSTextTableBlock` structure in the source `NSAttributedString` — the officially-looking way to
// ask AppKit for a table — gets silently dropped by that writer, producing plain sequential
// `<w:p>` paragraphs with no `<w:tbl>` at all (the same source string written to `.rtf` instead
// *does* come out as a real table — this is specifically an `.officeOpenXML`-writer gap, not a
// wrong way to ask). Reusing `TableRenderer.computeLayout` (same column-width math the PDF path
// already relies on, converted from points to twips — 1pt = 20 twips) and
// `TableRenderer.cellAttributedString` (same inline-Markdown-then-style pass, so a **bold** table
// cell comes out bold here too) keeps this visually consistent with the PDF/image table renderings
// instead of a third, independently-tuned look.

#if canImport(AppKit)
import AppKit
import Foundation

enum OOXMLTableWriter {
    /// The real, resolved font family AppKit's `.officeOpenXML` writer itself stamps on every
    /// non-table paragraph when the source `NSAttributedString` uses the system font — verified by
    /// inspecting that writer's own generated `document.xml` directly, not assumed. Every font this
    /// package's table code ever hands to `NSFont.systemFont(ofSize:)`/`.boldSystemFont(ofSize:)`
    /// resolves to this same family (`DocumentTheme` covers color/size/spacing only, deliberately
    /// not font *family* — see that type's own doc comment), so hardcoding it here isn't a
    /// shortcut around some more-general problem, it's matching the one family this package's
    /// tables can ever actually be in.
    private static let systemFontFamilyName = "Helvetica Neue"

    /// `nil` only when `TableRenderer.computeLayout` itself would be (a zero-column table) —
    /// `WordDocumentExporter` falls back to plain text in that case, same as `DocumentRenderer`'s
    /// own `tableParagraph` does for the image path.
    static func tableXML(
        header: [String],
        alignments: [TableAlignment],
        rows: [[String]],
        contentWidth: CGFloat,
        theme: DocumentTheme
    ) -> String? {
        guard
            let layout = TableRenderer.computeLayout(
                header: header,
                alignments: alignments,
                rows: rows,
                maxWidth: contentWidth,
                theme: theme
            )
        else { return nil }

        let columnWidthsTwips = layout.columnWidths.map { Int(($0 * 20).rounded()) }
        let totalWidthTwips = columnWidthsTwips.reduce(0, +)
        let borderColor = hexString(theme.tableBorder)
        let headerFill = hexString(theme.tableHeaderBackground)

        func borderEdge(_ tag: String) -> String {
            "<w:\(tag) w:val=\"single\" w:sz=\"4\" w:space=\"0\" w:color=\"\(borderColor)\"/>"
        }

        func row(_ values: [String], isHeader: Bool) -> String {
            var xml = "<w:tr>"
            for (columnIndex, text) in values.enumerated() {
                let width = columnIndex < columnWidthsTwips.count ? columnWidthsTwips[columnIndex] : (columnWidthsTwips.last ?? 0)
                let alignment = columnIndex < alignments.count ? alignments[columnIndex] : .none
                xml += "<w:tc><w:tcPr><w:tcW w:w=\"\(width)\" w:type=\"dxa\"/>"
                if isHeader {
                    xml += "<w:shd w:val=\"clear\" w:color=\"auto\" w:fill=\"\(headerFill)\"/>"
                }
                xml += "</w:tcPr>"
                xml += cellParagraphXML(text: text, isHeader: isHeader, alignment: alignment, theme: theme)
                xml += "</w:tc>"
            }
            xml += "</w:tr>"
            return xml
        }

        var xml = "<w:tbl><w:tblPr>"
        xml += "<w:tblW w:w=\"\(totalWidthTwips)\" w:type=\"dxa\"/>"
        xml += "<w:tblBorders>"
        xml += ["top", "left", "bottom", "right", "insideH", "insideV"].map(borderEdge).joined()
        xml += "</w:tblBorders></w:tblPr><w:tblGrid>"
        xml += columnWidthsTwips.map { "<w:gridCol w:w=\"\($0)\"/>" }.joined()
        xml += "</w:tblGrid>"
        xml += row(header, isHeader: true)
        xml += rows.map { row($0, isHeader: false) }.joined()
        xml += "</w:tbl>"
        // A `<w:tbl>` needs at least one ordinary paragraph after it — Word itself always emits
        // one, and some strict readers treat a table with no trailing paragraph (e.g. one that
        // ends the document body) as malformed. `WordDocumentExporter`'s placeholder paragraph
        // already sits right before whatever block follows the table in the source document, or
        // before the closing `<w:sectPr>` if the table is last — either way this empty paragraph
        // safely takes that placeholder's place instead of leaving nothing behind it.
        xml += "<w:p/>"
        return xml
    }

    /// One `<w:p>` per cell: walks the cell's already-Markdown-styled `NSAttributedString` run by
    /// run so a **bold**/*italic* span inside a cell becomes its own `<w:r>` with `<w:b/>`/`<w:i/>`,
    /// instead of collapsing the whole cell to one plain run.
    private static func cellParagraphXML(text: String, isHeader: Bool, alignment: TableAlignment, theme: DocumentTheme) -> String {
        let font = isHeader
            ? PlatformFont.boldSystemFont(ofSize: theme.tableHeaderFontSize)
            : PlatformFont.systemFont(ofSize: theme.tableCellFontSize)
        let styled = TableRenderer.cellAttributedString(text, font: font, alignment: alignment, theme: theme)
        let colorHex = hexString(theme.tableText)
        let jc: String
        switch alignment {
        case .none, .left: jc = "left"
        case .center: jc = "center"
        case .right: jc = "right"
        }

        var runsXML = ""
        styled.enumerateAttribute(.font, in: NSRange(location: 0, length: styled.length)) { value, range, _ in
            guard range.length > 0 else { return }
            let runFont = value as? PlatformFont
            let traits = runFont?.fontDescriptor.symbolicTraits ?? []
            let runText = (styled.string as NSString).substring(with: range)
            var rPr = "<w:rPr>"
            // Without an explicit `<w:rFonts>`, Word (and macOS's own Quick Look docx renderer —
            // confirmed by actually opening a generated `.docx` and looking at it, not just the
            // passing structural tests above) falls back to its own default table font instead of
            // matching the rest of the document — a real, only-visually-obvious inconsistency
            // (table text in a serif font while every surrounding paragraph is sans-serif) no
            // string-contains/XML-well-formedness test would ever catch. Deliberately not reading
            // `(runFont ?? font).familyName` for this: that returns `.AppleSystemUIFont` — one of
            // AppKit's private, dot-prefixed internal names for the dynamic system font, confirmed
            // by inspecting the generated XML directly — which no OOXML reader outside AppKit's own
            // text system can resolve to an actual typeface, so *that* was the direct cause of the
            // serif fallback. `systemFontFamilyName` instead matches the real, resolved family name
            // AppKit's own `.officeOpenXML` writer already stamps on every non-table paragraph in
            // this exact same document — confirmed by inspecting that writer's own XML output.
            rPr += "<w:rFonts w:ascii=\"\(systemFontFamilyName)\" w:hAnsi=\"\(systemFontFamilyName)\" w:cs=\"\(systemFontFamilyName)\"/>"
            if traits.contains(.bold) { rPr += "<w:b/>" }
            if traits.contains(.italic) { rPr += "<w:i/>" }
            rPr += "<w:color w:val=\"\(colorHex)\"/>"
            rPr += "<w:sz w:val=\"\(Int(((runFont?.pointSize ?? font.pointSize) * 2).rounded()))\"/>"
            rPr += "</w:rPr>"
            runsXML += "<w:r>\(rPr)<w:t xml:space=\"preserve\">\(escapeXML(runText))</w:t></w:r>"
        }
        return "<w:p><w:pPr><w:jc w:val=\"\(jc)\"/></w:pPr>\(runsXML)</w:p>"
    }

    /// `usingColorSpace(.deviceRGB)` guards against a color that isn't already RGB-based (a named/
    /// catalog color, say) — calling `.redComponent` directly on one of those throws an
    /// Objective-C exception rather than returning a value, so this converts first and falls back
    /// to black only in the (here, never actually hit — `DocumentTheme`'s colors are always
    /// constructed as plain RGB) case that conversion itself fails.
    private static func hexString(_ color: PlatformColor) -> String {
        guard let rgb = color.usingColorSpace(.deviceRGB) else { return "000000" }
        let r = Int((rgb.redComponent * 255).rounded())
        let g = Int((rgb.greenComponent * 255).rounded())
        let b = Int((rgb.blueComponent * 255).rounded())
        return String(format: "%02X%02X%02X", r, g, b)
    }

    /// Not `private`: also used by `WordDocumentExporter.plainTextFallbackXML` for the same
    /// zero-column-table fallback text `DocumentRenderer.tableParagraph` shows in the image path.
    /// Escapes `"` too, not just the three markup-structural characters — overkill for text
    /// content (where a literal `"` is harmless), but this same function also escapes the
    /// `w:ascii`/`w:hAnsi`/`w:cs` *attribute* values in `<w:rFonts>` below, where an unescaped `"`
    /// in a font family name would terminate the attribute early and corrupt the XML.
    static func escapeXML(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        for character in text {
            switch character {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\"": result += "&quot;"
            default: result.append(character)
            }
        }
        return result
    }
}
#endif
