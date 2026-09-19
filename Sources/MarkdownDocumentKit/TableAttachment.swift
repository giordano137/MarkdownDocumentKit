// TableAttachment
//
// An `NSTextAttachment` subclass that carries a table's raw data and computed `TableLayout`
// alongside the usual bitmap `image` — the bitmap is there so a consumer that only knows about
// plain attachments (DOCX's officeOpenXML writer, today) still gets a correct picture of the
// table, but `PDFRenderer` (which recognizes this specific subclass) can instead draw the table
// for real: actual selectable/searchable text in the PDF's content stream, not pixels. See
// `TableRenderer.drawTable` for that path.

#if os(macOS)
import AppKit
import Foundation

public final class TableAttachment: NSTextAttachment {
    public let header: [String]
    public let alignments: [TableAlignment]
    public let rows: [[String]]
    public let layout: TableLayout

    public init?(header: [String], alignments: [TableAlignment], rows: [[String]], maxWidth: CGFloat) {
        guard
            let layout = TableRenderer.computeLayout(header: header, alignments: alignments, rows: rows, maxWidth: maxWidth),
            let rendered = TableRenderer.render(header: header, alignments: alignments, rows: rows, maxWidth: maxWidth)
        else { return nil }

        self.header = header
        self.alignments = alignments
        self.rows = rows
        self.layout = layout
        super.init(data: nil, ofType: nil)
        self.image = rendered.image
        self.bounds = CGRect(origin: .zero, size: rendered.size)
    }

    public required init?(coder: NSCoder) {
        fatalError("TableAttachment does not support NSCoding — it's only ever constructed fresh by DocumentRenderer.")
    }
}
#endif
