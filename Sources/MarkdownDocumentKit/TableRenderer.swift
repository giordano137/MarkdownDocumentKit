// TableRenderer
//
// Computes a `.table` block's layout (column widths, row heights, styled per-cell content) and
// can draw it to a bitmap image — used as the DOCX-facing fallback (`render`, embedded as a
// plain image attachment there) and by anyone who just wants a table as a picture.
//
// The PDF path does *not* use the bitmap: real, selectable/searchable table text needs the
// cells actually drawn as text in the PDF's own content stream, not flattened to pixels first
// (a `CGImage` has no concept of "this pixel used to be a letter"). `computeLayout` is the
// piece that split out for that — same column-width/row-height math, but returning the styled
// `NSAttributedString`s and geometry for a caller (the 137 app's `PDFRenderer`) to draw for
// real, instead of only ever handing back a finished image. See `TableAttachment`.

#if os(macOS)
import AppKit
import Foundation

/// Everything needed to draw a table for real: styled (aligned, bold/italic-preserving) cell
/// content plus the geometry `computeLayout` settled on. `headerCells`/`bodyCells` are already
/// run through the same inline-Markdown-then-style pass `DocumentRenderer`'s own paragraphs use.
public struct TableLayout {
    public let columnWidths: [CGFloat]
    public let headerHeight: CGFloat
    public let rowHeights: [CGFloat]
    public let totalSize: CGSize
    public let headerCells: [NSAttributedString]
    public let bodyCells: [[NSAttributedString]]
}

public enum TableRenderer {
    public static let cellFont = NSFont.systemFont(ofSize: 12)
    public static let headerFont = NSFont.boldSystemFont(ofSize: 12)
    public static let horizontalPadding: CGFloat = 8
    public static let verticalPadding: CGFloat = 5
    public static let minRowHeight: CGFloat = 22
    public static let minColumnWidth: CGFloat = 36
    public static let borderColor = NSColor(white: 0.75, alpha: 1)
    public static let headerBackground = NSColor(white: 0.91, alpha: 1)
    private static let bitmapScale: CGFloat = 2  // crisp at typical PDF/print viewing sizes

    /// `maxWidth` is the available content width (e.g. a page's width minus margins) the table
    /// must fit inside — columns are measured at their natural width first, then scaled down
    /// proportionally only if that natural total would overflow it. Returns `nil` only for a
    /// zero-column table (never for "didn't fit" — it always fits, just narrower).
    public static func computeLayout(
        header: [String],
        alignments: [TableAlignment],
        rows: [[String]],
        maxWidth: CGFloat
    ) -> TableLayout? {
        let columnCount = header.count
        guard columnCount > 0 else { return nil }

        let measuringHeaderCells = header.map { cellAttributedString($0, font: headerFont, alignment: .none) }
        let measuringBodyGrid = rows.map { row in row.map { cellAttributedString($0, font: cellFont, alignment: .none) } }

        var columnWidths = (0..<columnCount).map { column -> CGFloat in
            var natural = measuringHeaderCells[column].size().width
            for row in measuringBodyGrid {
                natural = max(natural, row[column].size().width)
            }
            return max(natural + horizontalPadding * 2, minColumnWidth)
        }
        let naturalTotal = columnWidths.reduce(0, +)
        if naturalTotal > maxWidth {
            let scale = maxWidth / naturalTotal
            columnWidths = columnWidths.map { $0 * scale }
        }

        func rowHeight(_ cells: [NSAttributedString]) -> CGFloat {
            var tallest: CGFloat = 0
            for (column, cell) in cells.enumerated() {
                let constrainedWidth = columnWidths[column] - horizontalPadding * 2
                let bounds = cell.boundingRect(
                    with: CGSize(width: max(constrainedWidth, 1), height: .greatestFiniteMagnitude),
                    options: [.usesLineFragmentOrigin, .usesFontLeading]
                )
                tallest = max(tallest, bounds.height)
            }
            return max(tallest + verticalPadding * 2, minRowHeight)
        }

        // Re-styled with each column's real alignment now that column widths (and therefore
        // whether a cell's paragraph style should be left/center/right) are settled — the
        // measuring pass above used `.none` because alignment doesn't affect natural size.
        let headerCells = header.enumerated().map { column, text in
            cellAttributedString(text, font: headerFont, alignment: alignments[column])
        }
        let bodyCells = rows.map { row in
            row.enumerated().map { column, text in
                cellAttributedString(text, font: cellFont, alignment: alignments[column])
            }
        }

        let headerHeight = rowHeight(headerCells)
        let rowHeights = bodyCells.map(rowHeight)
        let totalSize = CGSize(width: columnWidths.reduce(0, +), height: headerHeight + rowHeights.reduce(0, +))

        return TableLayout(
            columnWidths: columnWidths,
            headerHeight: headerHeight,
            rowHeights: rowHeights,
            totalSize: totalSize,
            headerCells: headerCells,
            bodyCells: bodyCells
        )
    }

    /// Bitmap fallback — used for DOCX embedding (a plain image attachment there, see
    /// `TableAttachment`) and by any consumer that just wants a picture of the table. Draws the
    /// exact same `computeLayout` geometry `drawTable(_:in:origin:)` draws for real, just onto
    /// an offscreen bitmap instead of a live PDF context.
    public static func render(
        header: [String],
        alignments: [TableAlignment],
        rows: [[String]],
        maxWidth: CGFloat
    ) -> (image: NSImage, size: CGSize)? {
        guard let layout = computeLayout(header: header, alignments: alignments, rows: rows, maxWidth: maxWidth)
        else { return nil }

        guard
            let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: Int(layout.totalSize.width * bitmapScale),
                pixelsHigh: Int(layout.totalSize.height * bitmapScale),
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            )
        else { return nil }
        rep.size = layout.totalSize

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.current = context
        // No manual `scaleBy` here — `NSGraphicsContext(bitmapImageRep:)` already maps its
        // drawing coordinate space to `rep.size` (the point size set above) regardless of the
        // rep's actual pixel dimensions, so the `bitmapScale`-many extra pixels allocated for
        // Retina crispness are already accounted for automatically. Scaling again on top of that
        // halved (in each axis) the space drawing calls actually had to work with — everything
        // past the resulting midpoint landed outside the pixel buffer and never made it into the
        // image, which read as "top and right of the table missing" rather than a scale bug.
        drawTable(layout, in: context.cgContext, origin: .zero)

        let image = NSImage(size: layout.totalSize)
        image.addRepresentation(rep)
        return (image, layout.totalSize)
    }

    /// Draws borders, header shading, and every cell's real text directly into `context` at
    /// `origin` (bottom-left of the table, same non-flipped bottom-left-origin convention as a
    /// fresh bitmap context or a PDF page) — the piece that makes PDF export's table text
    /// genuinely selectable: `context` here is the PDF page's own content stream, so this ends
    /// up as real text-showing operators, not a flattened image.
    public static func drawTable(_ layout: TableLayout, in context: CGContext, origin: CGPoint) {
        let nsContext = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = nsContext
        defer { NSGraphicsContext.restoreGraphicsState() }

        // Top-down drawing: track the top edge of the row about to be drawn and subtract, rather
        // than accumulate from y=0, so row 0 (the header) ends up visually on top without
        // needing a flipped coordinate space.
        var rowTop = origin.y + layout.totalSize.height
        drawRow(
            cells: layout.headerCells,
            columnWidths: layout.columnWidths,
            originX: origin.x,
            top: rowTop,
            height: layout.headerHeight,
            background: headerBackground
        )
        rowTop -= layout.headerHeight
        for (rowIndex, cells) in layout.bodyCells.enumerated() {
            let height = layout.rowHeights[rowIndex]
            drawRow(cells: cells, columnWidths: layout.columnWidths, originX: origin.x, top: rowTop, height: height, background: nil)
            rowTop -= height
        }
        drawGrid(layout, origin: origin)
    }

    private static func drawRow(
        cells: [NSAttributedString],
        columnWidths: [CGFloat],
        originX: CGFloat,
        top: CGFloat,
        height: CGFloat,
        background: NSColor?
    ) {
        var x: CGFloat = originX
        for (column, cell) in cells.enumerated() {
            let width = columnWidths[column]
            let cellRect = CGRect(x: x, y: top - height, width: width, height: height)
            if let background {
                background.setFill()
                cellRect.fill()
            }
            let textRect = cellRect.insetBy(dx: horizontalPadding, dy: verticalPadding)
            cell.draw(with: textRect, options: [.usesLineFragmentOrigin, .usesFontLeading])
            x += width
        }
    }

    private static func drawGrid(_ layout: TableLayout, origin: CGPoint) {
        borderColor.setStroke()
        let path = NSBezierPath()
        path.lineWidth = 1
        let rowHeights = [layout.headerHeight] + layout.rowHeights

        var y: CGFloat = origin.y + layout.totalSize.height
        path.move(to: CGPoint(x: origin.x, y: y))
        path.line(to: CGPoint(x: origin.x + layout.totalSize.width, y: y))
        for height in rowHeights {
            y -= height
            path.move(to: CGPoint(x: origin.x, y: y))
            path.line(to: CGPoint(x: origin.x + layout.totalSize.width, y: y))
        }

        var x: CGFloat = origin.x
        path.move(to: CGPoint(x: x, y: origin.y))
        path.line(to: CGPoint(x: x, y: origin.y + layout.totalSize.height))
        for width in layout.columnWidths {
            x += width
            path.move(to: CGPoint(x: x, y: origin.y))
            path.line(to: CGPoint(x: x, y: origin.y + layout.totalSize.height))
        }
        path.stroke()
    }

    /// Same inline-Markdown-then-style approach as `DocumentRenderer`'s own paragraphs, so a
    /// **bold** table cell renders bold instead of showing literal asterisks.
    private static func cellAttributedString(_ text: String, font: NSFont, alignment: TableAlignment) -> NSAttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        let inline = (try? NSAttributedString(markdown: text, options: options)) ?? NSAttributedString(string: text)
        let mutable = NSMutableAttributedString(attributedString: inline)
        let fullRange = NSRange(location: 0, length: mutable.length)

        let style = NSMutableParagraphStyle()
        switch alignment {
        case .none, .left: style.alignment = .left
        case .center: style.alignment = .center
        case .right: style.alignment = .right
        }
        mutable.addAttribute(.paragraphStyle, value: style, range: fullRange)
        // Fixed black, not the dynamic `.textColor` — this text gets drawn straight into a raw
        // `CGContext`/PDF content stream (`drawTable`, called by 137's `PDFRenderer` outside any
        // live window), where a dynamic semantic color can resolve to something else entirely; in
        // practice it resolved to a color barely distinguishable from the page background,
        // confirmed by opening an actual generated PDF, not just by a passing unit test (a text
        // color attribute existing and a color being visible are different assertions). Matches
        // `DocumentRenderer.codeBlockBackground`'s already-established reasoning for the same
        // "exported file, no live theme to resolve against" situation.
        mutable.addAttribute(.foregroundColor, value: NSColor.black, range: fullRange)

        mutable.enumerateAttribute(.font, in: fullRange, options: []) { value, range, _ in
            let traits = (value as? NSFont)?.fontDescriptor.symbolicTraits ?? []
            var descriptor = font.fontDescriptor
            if !traits.isDisjoint(with: [.bold, .italic]) {
                descriptor = descriptor.withSymbolicTraits(traits.intersection([.bold, .italic]))
            }
            mutable.addAttribute(.font, value: NSFont(descriptor: descriptor, size: font.pointSize) ?? font, range: range)
        }
        return mutable
    }
}
#endif
