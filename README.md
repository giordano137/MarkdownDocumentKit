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
[TeXEnvironments](../TeXEnvironments) takes for formulas: implement the
specific handful of constructs that matter (tables, callouts,
headings/lists, images) as real layout code on top of CoreText/CoreGraphics,
instead of reaching for something built to handle *any* document.

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

Phases 1 through 5, plus images, done and in real production use by a
consuming app's document-export feature (parse → render → paginate to
PDF/DOCX; a `FormulaRenderer` and/or `ImageRenderer` implementation is
the only glue code a consumer needs to add math/images on top).

- [x] Phase 1: block layout core — headings, paragraphs (justified,
      hyphenated), lists, fenced code blocks. `DocumentBlock`/`DocumentParser`
      are pure Foundation; `DocumentRenderer`/`TableRenderer`/`PDFRenderer`
      run on **both AppKit (macOS) and UIKit (iOS)** from one shared
      implementation, via the `PlatformFont`/`PlatformColor`/`PlatformImage`
      typealiases and a handful of helpers in `PlatformTypes.swift` for the
      genuine API divergences (italic font conversion, bold/italic trait
      constant names, offscreen bitmap-context creation). Cell/document text
      is drawn with raw CoreText (`CTFramesetter`+`CTFrameDraw`) rather than
      `NSAttributedString.draw(with:)`, specifically so it isn't tied to
      UIKit's own top-left/y-down drawing convention — a PDF page's CGContext
      is natively bottom-left/y-up (the PDF spec's convention, not an OS
      choice), so text drawn through that convenience API would come out
      flipped on iOS. Verified end-to-end on iOS, not just cross-compiled:
      full test suite green on a real iOS Simulator run
      (`xcodebuild test -destination 'platform=iOS Simulator,...'`), plus a
      `TableRenderer.render` bitmap saved from that same simulator run and
      opened directly to confirm it isn't upside down (the specific risk a
      `UIGraphicsImageRenderer`-vs-`NSGraphicsContext` coordinate-space
      mismatch would cause). One test (`attachmentsStayInsideThePageMarginNotFlushWithTheLeftEdge`,
      a pixel-level regression guard) stays AppKit-only — it samples raw
      pixels via `NSBitmapImageRep`, which has no UIKit equivalent short of
      a `CGImage`/`CGDataProvider` byte-offset reimplementation; the margin
      fix it guards lives in unbranched shared code, so this one gap is
      narrow.
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
      and the fallback bitmap for one that doesn't. `PDFRenderer` (below)
      recognizes `TableAttachment` specifically and calls `drawTable`
      directly on the PDF page's content stream, confirmed (via PDFKit's
      own text-extraction layer in a test) to produce genuinely
      selectable/searchable table text — not the DOCX path's embedded
      picture.
- [x] Blockquotes (`> ...`): indented/italic/muted paragraph, joining
      consecutive `>` lines into one block.
- [x] Phase 3: GFM alert callouts — `> [!NOTE]`/`[!TIP]`/`[!WARNING]`/
      `[!IMPORTANT]` (case-insensitive, the marker has to be the blockquote's
      entire first line) parse into `.callout(kind:text:)`, distinct from a
      plain `.blockquote`. Rendered as a bold, accent-colored kind label
      ("Note"/"Tip"/"Warning"/"Important" — a plain text label, not an
      icon/emoji glyph: those risk rendering oddly through `PDFRenderer`'s
      raw CoreText text-showing operators) above the body text, tinted via
      a `.backgroundColor` attribute — the same mechanism
      `codeBlockBackground` already used, now also drawn with rounded
      corners in `PDFRenderer` rather than a flat rect (DOCX's shading stays
      square either way — Word's own text shading has no rounded-corner
      equivalent). Each kind gets its own fixed (not dynamic — an exported
      file has no live theme to resolve against) background/accent color
      pair.
- [x] Phase 4 (formulas): `FormulaRenderer` injection point — a consumer
      implements it on top of its own SwiftMath (or similar) call.
      `\[...\]`/`$$...$$` on their own line (or as their own fenced
      multi-line block) become a `.formula` block, rendered as its own
      centered equation image; `$...$`/`\(...\)`/a stray `\[...\]`/
      `$$...$$` mid-sentence are extracted from a paragraph/list-item/
      blockquote/heading's text and rendered as an inline, baseline-aligned
      image so they keep flowing with surrounding prose instead of breaking
      the paragraph — a formula is never lifted onto its own line to make
      room for it, sidestepping a related-but-different bug class that
      approach invites (a `**`/`*` Markdown pair that used to sit tight
      around the formula ending up split across the new line break and no
      longer recognized as a pair). No renderer supplied, or one that can't
      parse a given LaTeX string, falls back to the raw source text, never
      a blank gap. `DiagramRenderer` (Mermaid) is not started — no native
      Swift port of Mermaid exists, so it would need to delegate to a small
      JS context, unlike everything else here.
- [x] Phase 5: `PDFRenderer` — paginates a `DocumentRenderer`-produced
      `NSAttributedString` into a real multi-page PDF via raw CoreText
      (`CTFramesetter`/`CTFrameDraw`), no `NSPrintOperation` round trip, no
      dependency. Needs a `CTRunDelegate` per `.attachment` run to make raw
      CoreText reserve
      real layout space for a table/formula image at all (bare
      `.attachment` sizing is silently ignored by `CTFramesetter`/
      `CTFrameDraw`) and to draw that image by hand afterward (`CTFrameDraw`
      only ever draws glyphs) — and needs `CTFrameGetLineOrigins`' values
      offset by the page margin by hand, since they're relative to the
      frame's own path bounding box, not already-absolute page coordinates
      (confirmed two real bugs from getting this wrong only by opening an
      actual generated PDF: an attachment's descent under-reported as
      always 0 made it overlap the next line, and the missing margin
      offset drew every table/formula flush with the page's left edge).
      PDF and DOCX no longer share one identical rendering of every block —
      tables specifically diverge on purpose (real text vs. a fallback
      picture, since DOCX has no equivalent of drawing text directly into
      arbitrary page coordinates the way a raw CoreText PDF page allows).
      Still shared: everything Phase 1 covers. Still open: rounded table
      corners + centering, and giving DOCX a real (not image) table too via
      `NSTextTable`/`NSTextTableBlock`.
- [x] Images: a whole-line `![alt](source)` becomes an `.image` block,
      scaled down to fit the page's content width (never scaled up) and
      never mistaken for an inline image mid-sentence — like `.formula`,
      only a whole-line match counts (bounded, block-level scope, not full
      CommonMark inline parsing). A `data:image/...;base64,...` source
      decodes directly with zero consumer code, since the bytes are already
      in the Markdown; a local path or remote URL needs an injected
      `ImageRenderer` (this package does no disk/network I/O of its own,
      same reasoning as `FormulaRenderer`). No renderer, or one that
      returns `nil`, falls back to showing the alt text.
- [ ] `DiagramRenderer` (Mermaid) — not started, see Phase 4's note above.

## Requirements

- Swift 5.10+
- iOS 17+ / macOS 14+

## License

MIT — see [LICENSE](LICENSE).
