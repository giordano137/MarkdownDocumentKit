# MarkdownDocumentKit

A native Swift package that lays out Markdown as an actual structured
document — tables, callout boxes (`> [!NOTE]`-style), headings, lists, and
embedded images — and renders the result to PDF, DOCX, or a plain
`NSAttributedString`, without a browser engine or an external typesetting
binary.

## Why this exists

Turning "Markdown a model wrote" into a document worth saving as a file
means handling more than headings and bold text: real study notes and
reports have tables, callout/warning boxes, and diagrams. The two usual
routes to get there both cost more than the problem is actually worth:

- A full **LaTeX engine** (even a modernized, self-contained one) needs a
  large package/font universe — its default bundle is multiple GB, and
  building your own trimmed-down offline bundle is real, ongoing
  maintenance, not a one-time step.
- A **browser engine + JS libraries** (Mermaid, KaTeX, a Markdown-to-HTML
  pipeline) works, but is a lot of moving parts for content that's actually
  a bounded, well-known set of block-level constructs.

MarkdownDocumentKit takes the same middle path
[TeXEnvironments](https://github.com/mgriebling/SwiftMath) took for
formulas: implement the specific handful of constructs that matter
(tables, callouts, headings/lists, images) as real layout code on top of
CoreText/CoreGraphics, instead of reaching for something built to handle
*any* document.

## Math rendering is injected, not bundled

This package has **zero dependencies** — on purpose. It doesn't know what
SwiftMath or TeXEnvironments are. A formula in the source Markdown is
handed to a `FormulaRenderer` protocol the *consumer* implements (typically
backed by SwiftMath for single equations and
[TeXEnvironments](../TeXEnvironments) for multi-line environments/matrices/
chemistry notation) — so a consumer that doesn't care about math isn't
forced to pull in a math-typesetting stack just to lay out a table.

Diagrams (Mermaid) work the same way: a `DiagramRenderer` protocol hook,
because turning Mermaid syntax into an image inherently needs a small JS
context (no native Swift port of Mermaid exists) — that's the one piece
this package can't avoid delegating out, but it stays an injected,
optional capability rather than a hard dependency.

## Status

Phases 1–2 done and wired into the 137 app (`DocumentFormatConverters.swift`
uses this package's `DocumentRenderer`/`DocumentParser` for its PDF/DOCX
export, replacing the app's own former `MarkdownDocumentRenderer`).

- [x] Phase 1: block layout core — headings, paragraphs (justified,
      hyphenated), lists, fenced code blocks. `DocumentBlock`/`DocumentParser`
      (platform-agnostic) + `DocumentRenderer` (macOS/AppKit; UIKit renderer
      not implemented yet, model doesn't block it).
- [x] Phase 2: table layout — column widths (measured, then scaled to fit),
      wrapped row heights, borders, header shading, alignment, inline
      Markdown per cell (`TableRenderer.computeLayout`/`TableLayout`).
      Two ways to render that layout: a bitmap image (`TableRenderer.render`,
      the DOCX-facing fallback — DOCX export doesn't know about tables
      specifically, so it just gets a picture of one via a plain
      `NSTextAttachment`), and drawing it for real (`TableRenderer.drawTable`,
      real per-cell text via CGContext text-showing operators, not pixels).
      `TableAttachment` (an `NSTextAttachment` subclass) carries both — the
      raw table data + layout for a consumer that knows what to do with it,
      and the fallback bitmap for one that doesn't. The 137 app's
      `PDFRenderer` recognizes `TableAttachment` specifically and calls
      `drawTable` directly on the PDF page's content stream, confirmed (via
      PDFKit's own text-extraction layer in a test) to produce genuinely
      selectable/searchable table text — not the DOCX path's embedded
      picture. That recognition step lives in the app, not here, since it's
      specific to *that* PDF pagination method (raw `CTFramesetter`/
      `CTFrameDraw`, which needs a `CTRunDelegate` to reserve the right
      layout space for any attachment at all — see `PDFRenderer` for why).
- [ ] Phase 3: callout boxes (`> [!NOTE]` / `[!TIP]` / `[!WARNING]` /
      `[!IMPORTANT]`) as tinted, icon-labeled rounded boxes.
- [ ] Phase 4: `FormulaRenderer`/`DiagramRenderer` injection points + inline
      and block placement (baseline alignment, sizing).
- [x] Phase 5 (partially — PDF/DOCX export itself is done via the app
      integration above): PDF and DOCX no longer share one identical
      rendering of every block — tables specifically diverge on purpose now
      (real text vs. a fallback picture, since DOCX has no equivalent of
      drawing text directly into arbitrary page coordinates the way a raw
      CoreText PDF page allows). Still shared: everything Phase 1 covers.
      Still open: rounded table corners + centering, and giving DOCX a real
      (not image) table too via `NSTextTable`/`NSTextTableBlock`.

## Requirements

- Swift 5.10+
- iOS 17+ / macOS 14+

## License

MIT — see [LICENSE](LICENSE).
