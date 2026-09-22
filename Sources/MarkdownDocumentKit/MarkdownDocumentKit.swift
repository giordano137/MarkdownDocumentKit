// MarkdownDocumentKit
//
// Lays out Markdown (headings, paragraphs, lists, tables, callout boxes,
// images) as an actual document and renders it to PDF/DOCX/NSAttributedString
// — see README for why this exists instead of a full LaTeX engine or a
// browser-based pipeline.
//
// The real API lives in DocumentParser (parsing), DocumentRenderer/TableRenderer
// (layout), and PDFRenderer (pagination) — see README for current status.

import Foundation

public enum MarkdownDocumentKit {
    public static let version = "0.3.0"
}
