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
// `NSAttributedString`s and geometry for `PDFRenderer` to draw for real, instead of only ever
// handing back a finished image. See `TableAttachment`.
//
// All actual drawing (`drawTable`/`drawRow`/`drawGrid`) goes through raw CoreText/CoreGraphics —
// `CTFramesetter`+`CTFrameDraw` for cell text, `CGContext` fill/stroke for backgrounds and grid
// lines — deliberately not `NSAttributedString.draw(with:)`/`NSBezierPath`/`UIBezierPath`. Those
// convenience APIs draw into whatever the platform's own "current graphics context" is and, on
// UIKit, assume that context uses UIKit's own top-left/y-down coordinate convention; a PDF page's
// CGContext is natively bottom-left/y-up (the PDF spec's own convention, not an OS choice), so
// text drawn that way through UIKit's convenience layer would come out flipped. Raw CoreText draws
// into whatever explicit CGContext you hand it, respecting that context's actual coordinate
// system — the same approach `PDFRenderer` already uses for the whole document, extended here to
// table cells specifically. This also means `drawTable`/`drawRow`/`drawGrid` need no
// platform-specific branch at all: they're identical on macOS and iOS.
//
// Every color/font-size/padding value comes from the `DocumentTheme` passed to `computeLayout` —
// carried inside the returned `TableLayout` so `drawTable(_:in:origin:)` (called later, often from
// `PDFRenderer`, which never sees a theme itself) doesn't need it threaded through separately.

#if canImport(AppKit) || canImport(UIKit)
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif
import CoreText
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
    public let theme: DocumentTheme
}

public enum TableRenderer {
    private static let bitmapScale: CGFloat = 2  // crisp at typical PDF/print viewing sizes

    /// `maxWidth` is the available content width (e.g. a page's width minus margins) the table
    /// must fit inside — columns are measured at their natural width first, then scaled down
    /// proportionally only if that natural total would overflow it. Returns `nil` only for a
    /// zero-column table (never for "didn't fit" — it always fits, just narrower).
    public static func computeLayout(
        header: [String],
        alignments: [TableAlignment],
        rows: [[String]],
        maxWidth: CGFloat,
        theme: DocumentTheme = .default
    ) -> TableLayout? {
        let columnCount = header.count
        guard columnCount > 0 else { return nil }

        let headerFont = PlatformFont.boldSystemFont(ofSize: theme.tableHeaderFontSize)
        let cellFont = PlatformFont.systemFont(ofSize: theme.tableCellFontSize)
        let horizontalPadding = theme.tableHorizontalPadding
        let verticalPadding = theme.tableVerticalPadding

        let measuringHeaderCells = header.map { cellAttributedString($0, font: headerFont, alignment: .none, theme: theme) }
        let measuringBodyGrid = rows.map { row in
            row.map { cellAttributedString($0, font: cellFont, alignment: .none, theme: theme) }
        }

        var columnWidths = (0..<columnCount).map { column -> CGFloat in
            var natural = measuringHeaderCells[column].size().width
            for row in measuringBodyGrid {
                natural = max(natural, row[column].size().width)
            }
            return max(natural + horizontalPadding * 2, theme.tableMinColumnWidth)
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
                // `context:` has a default value on AppKit's overload but is a required
                // parameter on UIKit's — passing it explicitly (nil is fine on both; it's only
                // used to report actual vs. requested scale factor, irrelevant here) keeps this
                // call source-compatible with both.
                let bounds = cell.boundingRect(
                    with: CGSize(width: max(constrainedWidth, 1), height: .greatestFiniteMagnitude),
                    options: [.usesLineFragmentOrigin, .usesFontLeading],
                    context: nil
                )
                tallest = max(tallest, bounds.height)
            }
            return max(tallest + verticalPadding * 2, theme.tableMinRowHeight)
        }

        // Re-styled with each column's real alignment now that column widths (and therefore
        // whether a cell's paragraph style should be left/center/right) are settled — the
        // measuring pass above used `.none` because alignment doesn't affect natural size.
        let headerCells = header.enumerated().map { column, text in
            cellAttributedString(text, font: headerFont, alignment: alignments[column], theme: theme)
        }
        let bodyCells = rows.map { row in
            row.enumerated().map { column, text in
                cellAttributedString(text, font: cellFont, alignment: alignments[column], theme: theme)
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
            bodyCells: bodyCells,
            theme: theme
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
        maxWidth: CGFloat,
        theme: DocumentTheme = .default
    ) -> (image: PlatformImage, size: CGSize)? {
        guard let layout = computeLayout(header: header, alignments: alignments, rows: rows, maxWidth: maxWidth, theme: theme)
        else { return nil }

        return renderToImage(size: layout.totalSize, scale: bitmapScale) { context in
            drawTable(layout, in: context, origin: .zero)
        }.map { ($0, layout.totalSize) }
    }

    /// Draws borders, header shading, and every cell's real text directly into `context` at
    /// `origin` (bottom-left of the table, matching a PDF page's own bottom-left-origin
    /// convention) — the piece that makes PDF export's table text genuinely selectable: `context`
    /// here is the PDF page's own content stream, so this ends up as real text-showing operators,
    /// not a flattened image. `renderToImage` (used by `render` above) pre-flips its own offscreen
    /// context to this same bottom-left convention before calling in here, so this function itself
    /// never needs to know or care which of the two callers it's being used from. Reads its colors
    /// from `layout.theme` rather than taking a separate theme parameter, so a caller that only
    /// has the layout (`PDFRenderer`, via `TableAttachment.layout`) doesn't need one threaded in.
    public static func drawTable(_ layout: TableLayout, in context: CGContext, origin: CGPoint) {
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
            background: layout.theme.tableHeaderBackground,
            horizontalPadding: layout.theme.tableHorizontalPadding,
            verticalPadding: layout.theme.tableVerticalPadding,
            context: context
        )
        rowTop -= layout.headerHeight
        for (rowIndex, cells) in layout.bodyCells.enumerated() {
            let height = layout.rowHeights[rowIndex]
            drawRow(
                cells: cells,
                columnWidths: layout.columnWidths,
                originX: origin.x,
                top: rowTop,
                height: height,
                background: nil,
                horizontalPadding: layout.theme.tableHorizontalPadding,
                verticalPadding: layout.theme.tableVerticalPadding,
                context: context
            )
            rowTop -= height
        }
        drawGrid(layout, origin: origin, context: context)
    }

    private static func drawRow(
        cells: [NSAttributedString],
        columnWidths: [CGFloat],
        originX: CGFloat,
        top: CGFloat,
        height: CGFloat,
        background: PlatformColor?,
        horizontalPadding: CGFloat,
        verticalPadding: CGFloat,
        context: CGContext
    ) {
        var x: CGFloat = originX
        for (column, cell) in cells.enumerated() {
            let width = columnWidths[column]
            let cellRect = CGRect(x: x, y: top - height, width: width, height: height)
            if let background {
                context.setFillColor(background.cgColor)
                context.fill(cellRect)
            }
            let textRect = cellRect.insetBy(dx: horizontalPadding, dy: verticalPadding)
            drawText(cell, in: textRect, context: context)
            x += width
        }
    }

    /// Draws `attributedString` into `rect` of `context` via CoreText directly — see this file's
    /// top-of-file comment for why not `NSAttributedString.draw(with:)`.
    private static func drawText(_ attributedString: NSAttributedString, in rect: CGRect, context: CGContext) {
        let framesetter = CTFramesetterCreateWithAttributedString(attributedString)
        let path = CGPath(rect: rect, transform: nil)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), path, nil)
        CTFrameDraw(frame, context)
    }

    private static func drawGrid(_ layout: TableLayout, origin: CGPoint, context: CGContext) {
        context.setStrokeColor(layout.theme.tableBorder.cgColor)
        context.setLineWidth(1)
        let rowHeights = [layout.headerHeight] + layout.rowHeights

        context.beginPath()
        var y: CGFloat = origin.y + layout.totalSize.height
        context.move(to: CGPoint(x: origin.x, y: y))
        context.addLine(to: CGPoint(x: origin.x + layout.totalSize.width, y: y))
        for height in rowHeights {
            y -= height
            context.move(to: CGPoint(x: origin.x, y: y))
            context.addLine(to: CGPoint(x: origin.x + layout.totalSize.width, y: y))
        }

        var x: CGFloat = origin.x
        context.move(to: CGPoint(x: x, y: origin.y))
        context.addLine(to: CGPoint(x: x, y: origin.y + layout.totalSize.height))
        for width in layout.columnWidths {
            x += width
            context.move(to: CGPoint(x: x, y: origin.y))
            context.addLine(to: CGPoint(x: x, y: origin.y + layout.totalSize.height))
        }
        context.strokePath()
    }

    /// Same inline-Markdown-then-style approach as `DocumentRenderer`'s own paragraphs, so a
    /// **bold** table cell renders bold instead of showing literal asterisks.
    private static func cellAttributedString(
        _ text: String,
        font: PlatformFont,
        alignment: TableAlignment,
        theme: DocumentTheme
    ) -> NSAttributedString {
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
        // Fixed by default (`theme.tableText`), not a dynamic system color — this text gets
        // drawn straight into a raw `CGContext`/PDF content stream (`drawTable`, called by
        // `PDFRenderer` outside any live window), where a dynamic semantic color can resolve to
        // something else entirely; in practice it resolved to a color barely distinguishable from
        // the page background, confirmed by opening an actual generated PDF, not just by a
        // passing unit test (a text color attribute existing and a color being visible are
        // different assertions). Matches `DocumentRenderer`'s `codeText` theme default, same
        // "exported file, no live theme to resolve against" reasoning.
        mutable.addAttribute(.foregroundColor, value: theme.tableText, range: fullRange)

        mutable.enumerateAttribute(.font, in: fullRange, options: []) { value, range, _ in
            let resolvedFont = applyingPreservedBoldItalic(from: value as? PlatformFont, to: font)
            mutable.addAttribute(.font, value: resolvedFont, range: range)
        }
        return mutable
    }
}
#endif
