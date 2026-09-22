# Architecture & Design Notes

This is the implementation history and design rationale for each piece of
MarkdownDocumentKit — the "why is it built this way," including the real
bugs that shaped it. For "what is this and how do I use it," see
[README.md](README.md) instead; this file is the deep end, not the front
door.

Phases 1 through 5, plus images, theme injection, and Mermaid diagrams,
done and in real production use by a consuming app's document-export
feature (parse → render → paginate to PDF/DOCX; a `FormulaRenderer`
and/or `ImageRenderer`/`DiagramRenderer` implementation is the only glue
code a consumer needs to add math/images/diagrams on top, and a
`DocumentTheme` is entirely optional on top of that).

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
      a blank gap. `DiagramRenderer` (Mermaid) followed later, once images
      existed to model it on — see its own entry below.
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
- [x] Theme injection — see README's "Styling is injected too" section.
      `DocumentTheme` covers every color/font-size/spacing constant that
      used to be a `static let`/inline literal across `DocumentRenderer.swift`/
      `TableRenderer.swift`; `TableLayout` carries its own `theme` so
      `PDFRenderer` (which never sees a theme directly) still draws a
      table's borders/header shading in the right colors.
- [x] `DiagramRenderer` (Mermaid) — a fenced ` ```mermaid ` block's language
      tag is checked at parse time (case-insensitively) so it becomes a
      `.diagram(source:)` block instead of a plain `.codeBlock`; every other
      fenced language is untouched. Rendered exactly like `.image` once an
      image exists — same content-width scaling, same "never scaled up"
      rule, same shared `scaledImageAttachmentParagraph` helper — the only
      difference is *getting* that image, via
      `DiagramRenderer.image(forMermaidSource:palette:)` instead of
      `ImageRenderer.image(forSource:altText:)`. No renderer, or one that
      returns `nil` for a given diagram, falls back to the raw Mermaid
      source rendered as a code block (reusing `codeParagraph`'s own
      styling) — deliberately not a hand-rolled ASCII-art attempt at the
      diagram, which would risk looking like a real (but wrong) rendering
      rather than an honest "this needs a renderer" fallback.

      `palette` (the active theme's `diagramPalette`, four colors: node
      background/border, line color, text color) exists because a real
      rendered Mermaid diagram otherwise looks like it was pasted in from a
      different tool — Mermaid's own stock theme has no relationship to
      whatever colors the rest of the document uses (confirmed visually:
      side-by-side renders of the same diagram with Mermaid's default purple
      vs. `%%{init: {'theme':'base', 'themeVariables': {...}}}%%` fed from
      `diagramPalette` were the difference between "looks bolted on" and
      "looks like one document"). This package still knows nothing about
      Mermaid's specific init-directive syntax — `DiagramPalette` is just
      plain color data crossing the protocol boundary, the same shape
      `CalloutTint` already uses; turning that into a `%%{init}%%` string
      (or whatever a different diagramming backend's own theming hook looks
      like) is entirely the consumer's `DiagramRenderer` implementation's
      job. No font field on `DiagramPalette` for the same reason
      `DocumentTheme` itself has none — see its top-of-file comment — and no
      font-*size* field either: unlike `FormulaRenderer`'s `fontSize`, a
      diagram never has to sit on a shared baseline with surrounding text,
      so its internal sizing stays the diagramming library's own concern.
