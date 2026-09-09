// MarkdownDocumentKit
//
// Lays out Markdown (headings, paragraphs, lists, tables, callout boxes,
// images) as an actual document and renders it to PDF/DOCX/NSAttributedString
// — see README for why this exists instead of a full LaTeX engine or a
// browser-based pipeline.
//
// Phase 1 (block layout core) is not implemented yet — this is scaffolding.

import Foundation

/// Placeholder entry point. Real API (block-model parser + CoreText/CoreGraphics
/// layout + PDF/DOCX renderers) lands with Phase 1.
public enum MarkdownDocumentKit {
    public static let version = "0.0.1"
}
