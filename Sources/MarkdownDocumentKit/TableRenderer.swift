// TableRenderer
//
// Draws a `.table` block into a bitmap image, which `DocumentRenderer` then embeds as a single
// `NSTextAttachment` — the same "render the thing that can't flow as text, embed it as an
// image" trick `InlineMathImageRenderer` uses in the 137 app for formulas. Not a limitation
// worked around here: CoreText/NSAttributedString have no grid-layout primitive at all, a table
// genuinely has to be drawn, not flowed.
//
// Rendering to an image rather than real inline flow also means PDF and DOCX export (both just
// embed whatever `NSTextAttachment`s the shared `NSAttributedString` carries) get an identical
// table for free, instead of two separate table-drawing implementations that could drift apart.

#if os(macOS)
import AppKit
import Foundation

public enum TableRenderer {
    private static let cellFont = NSFont.systemFont(ofSize: 12)
    private static let headerFont = NSFont.boldSystemFont(ofSize: 12)
    private static let horizontalPadding: CGFloat = 8
    private static let verticalPadding: CGFloat = 5
    private static let minRowHeight: CGFloat = 22
    private static let minColumnWidth: CGFloat = 36
    private static let borderColor = NSColor(white: 0.75, alpha: 1)
    private static let headerBackground = NSColor(white: 0.91, alpha: 1)
    private static let bitmapScale: CGFloat = 2  // crisp at typical PDF/print viewing sizes

    /// `maxWidth` is the available content width (e.g. a page's width minus margins) the table
    /// must fit inside — columns are measured at their natural width first, then scaled down
    /// proportionally only if that natural total would overflow it. Returns `nil` only if the
    /// bitmap itself couldn't be allocated (never for "the table didn't fit" — it always fits,
    /// just narrower).
    public static func render(
        header: [String],
        alignments: [TableAlignment],
        rows: [[String]],
        maxWidth: CGFloat
    ) -> (image: NSImage, size: CGSize)? {
        let columnCount = header.count
        guard columnCount > 0 else { return nil }

        let headerCells = header.map { cellAttributedString($0, font: headerFont, alignment: .none) }
        let bodyCellGrid = rows.map { row in row.map { cellAttributedString($0, font: cellFont, alignment: .none) } }

        var columnWidths = (0..<columnCount).map { column -> CGFloat in
            var natural = headerCells[column].size().width
            for row in bodyCellGrid {
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

        // Re-applies each column's real alignment now that column widths (and therefore
        // whether a cell's paragraph style should be left/center/right) are settled — the
        // measuring pass above used `.none` because alignment doesn't affect natural size.
        let alignedHeaderCells = header.enumerated().map { column, text in
            cellAttributedString(text, font: headerFont, alignment: alignments[column])
        }
        let alignedBodyGrid = rows.map { row in
            row.enumerated().map { column, text in
                cellAttributedString(text, font: cellFont, alignment: alignments[column])
            }
        }

        let headerHeight = rowHeight(alignedHeaderCells)
        let bodyHeights = alignedBodyGrid.map(rowHeight)
        let totalWidth = columnWidths.reduce(0, +)
        let totalHeight = headerHeight + bodyHeights.reduce(0, +)

        guard
            let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: Int(totalWidth * bitmapScale),
                pixelsHigh: Int(totalHeight * bitmapScale),
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            )
        else { return nil }
        let pointSize = CGSize(width: totalWidth, height: totalHeight)
        rep.size = pointSize

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.current = context
        // No manual `scaleBy` here — `NSGraphicsContext(bitmapImageRep:)` already maps its
        // drawing coordinate space to `rep.size` (the point size set above) regardless of the
        // rep's actual pixel dimensions, so the `bitmapScale`-many extra pixels we allocated
        // for Retina crispness are already accounted for automatically. Scaling again on top of
        // that halved (in each axis) the space our drawing calls actually had to work with —
        // everything past the resulting midpoint landed outside the pixel buffer and never
        // made it into the image at all, which read as "top and right of the table missing"
        // rather than as a scaling artifact.

        // Top-down drawing in a *non-flipped* context (origin bottom-left, the default for a
        // freshly created bitmap context): track the top edge of the row about to be drawn and
        // subtract, rather than accumulate from y=0, so row 0 (the header) ends up visually on
        // top without needing a flipped coordinate space.
        var rowTop = totalHeight
        drawRow(
            cells: alignedHeaderCells,
            columnWidths: columnWidths,
            top: rowTop,
            height: headerHeight,
            background: headerBackground
        )
        rowTop -= headerHeight
        for (rowIndex, cells) in alignedBodyGrid.enumerated() {
            let height = bodyHeights[rowIndex]
            drawRow(cells: cells, columnWidths: columnWidths, top: rowTop, height: height, background: nil)
            rowTop -= height
        }
        drawGrid(columnWidths: columnWidths, rowHeights: [headerHeight] + bodyHeights, totalSize: pointSize)

        let image = NSImage(size: pointSize)
        image.addRepresentation(rep)
        return (image, pointSize)
    }

    private static func drawRow(
        cells: [NSAttributedString],
        columnWidths: [CGFloat],
        top: CGFloat,
        height: CGFloat,
        background: NSColor?
    ) {
        var x: CGFloat = 0
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

    private static func drawGrid(columnWidths: [CGFloat], rowHeights: [CGFloat], totalSize: CGSize) {
        borderColor.setStroke()
        let path = NSBezierPath()
        path.lineWidth = 1

        var y: CGFloat = totalSize.height
        path.move(to: CGPoint(x: 0, y: y))
        path.line(to: CGPoint(x: totalSize.width, y: y))
        for height in rowHeights {
            y -= height
            path.move(to: CGPoint(x: 0, y: y))
            path.line(to: CGPoint(x: totalSize.width, y: y))
        }

        var x: CGFloat = 0
        path.move(to: CGPoint(x: x, y: 0))
        path.line(to: CGPoint(x: x, y: totalSize.height))
        for width in columnWidths {
            x += width
            path.move(to: CGPoint(x: x, y: 0))
            path.line(to: CGPoint(x: x, y: totalSize.height))
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
        mutable.addAttribute(.foregroundColor, value: NSColor.textColor, range: fullRange)

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
