# Architecture & Design Notes

This is the implementation history and design rationale for each piece of
MarkdownDocumentKit — the "why is it built this way," including the real
bugs that shaped it. For "what is this and how do I use it," see
[README.md](README.md) instead; this file is the deep end, not the front
door.

Phases 1 through 8, plus images, theme injection, and Mermaid diagrams,
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
      corners + centering. Real (not image) DOCX tables — the obvious next
      step from here — turned out not to be the `NSTextTable`/
      `NSTextTableBlock` job this originally assumed; see Phase 6 below for
      why, and what it took instead.
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
- [x] Phase 6: real DOCX tables (`WordDocumentExporter`). The obvious
      approach — build the table out of `NSTextTable`/`NSTextTableBlock`
      instead of `TableAttachment`, since that's the API AppKit's text
      system offers for exactly this — turned out not to work: verified
      empirically (not assumed) by writing an `NSAttributedString`
      containing a real `NSTextTable` structure through AppKit's own
      `.officeOpenXML` writer and inspecting the resulting `document.xml`
      directly. It came out as plain sequential `<w:p>` paragraphs with no
      `<w:tbl>` anywhere — the writer silently drops `NSTextTableBlock`
      structure. (The same source string written to `.rtf` instead *does*
      come out as a real table, confirmed by the `\trowd`/`\cell`/`\row`
      markup in the output — ruling out "wrong way to build the table" and
      narrowing it to "this specific writer doesn't serialize it.")

      So `WordDocumentExporter.export(...)` takes a different path: render
      the document normally (`DocumentRenderer.blockParagraph`, shared with
      `attributedString(from:...)`) except each `.table` block becomes a
      short placeholder paragraph carrying a Private-Use-Area sentinel +
      index (same non-collision trick `DocumentRenderer.extractInlineFormulas`
      already relies on for math sentinels — distinct codepoints, so the two
      never collide in one document). That string still goes through
      AppKit's `.officeOpenXML` writer as normal, producing a `.docx` (a ZIP
      container) with a correct placeholder paragraph sitting exactly where
      each table belongs. Then: unzip it, find `word/document.xml`, replace
      each placeholder paragraph with a hand-written `<w:tbl>` XML fragment
      (`OOXMLTableWriter` — reuses `TableRenderer.computeLayout`'s column
      widths, converted points→twips, and `TableRenderer.cellAttributedString`
      for the same inline-Markdown-then-style pass the PDF/image paths
      already use, so a **bold** cell renders bold here too), re-zip, done.
      A paragraph's boundaries are found by searching for the *exact*
      literal `<w:p>` (not just `<w:p`, which `<w:pPr>` — that same
      paragraph's own properties element, sitting between the open tag and
      the placeholder text — would also match) — paragraphs never nest in
      OOXML, so the nearest `<w:p>`/`</w:p>` around the placeholder are
      unambiguously its own.

      Rewriting the ZIP needed a ZIP reader/writer in the first place —
      `MinimalZipArchive`, deliberately scoped to exactly the shape AppKit's
      writer actually produces (flat entries, plain Deflate or Stored, no
      encryption/Zip64/data-descriptor trailers — confirmed against a real
      generated `.docx` before writing the parser, not assumed) rather than
      attempting a general-purpose ZIP library, which this package's own
      "zero dependencies" stance (see `Package.swift`) would've made a much
      larger ask for a format this package only ever produces itself, never
      reads from a third party. Reading decompresses every entry via
      `Compression`'s `COMPRESSION_ZLIB` decode — verified empirically that
      this is, despite the name, raw deflate (no zlib wrapper), the exact
      framing ZIP's method 8 uses, by decoding a real entry's compressed
      bytes and diffing against `unzip -p`'s output byte-for-byte. Writing
      always re-emits every entry **Stored** (uncompressed) rather than
      re-deflating — this package only ever needs `compression_decode_buffer`
      (decode), never the encode half, since only one small XML entry is
      ever replaced; avoiding a hand-rolled raw-deflate *encoder* sidesteps
      having to separately verify that encoder's framing is byte-correct
      (encoding is materially easier to get subtly wrong than decoding — a
      reader tolerates extra decode slack a writer's framing can't afford).
      Mixing Stored and Deflated entries in one ZIP is completely ordinary
      and every reader already handles it; the only cost is a few extra KB.

      Validated three ways, deliberately not just "our own writer round-trips
      through our own reader" (which would only prove internal consistency,
      not spec-correctness): `unzip -l`/`unzip -q` (a completely independent
      ZIP implementation) on the actual test output; `XMLDocument(data:...)`
      confirming the spliced `document.xml` is well-formed XML, not just
      text containing the right substrings; and `python-docx` (a fully
      independent OOXML reader, unrelated to anything Apple ships) opening a
      real generated `.docx` end-to-end and correctly reporting its table's
      row/column count and per-cell bold runs.

      Building this surfaced an unrelated, pre-existing bug in a much older
      shared code path: `TableRenderer.cellAttributedString`'s and
      `DocumentRenderer.inlineParagraph`'s own bold/italic detection
      (`applyingPreservedBoldItalic`, now replaced) only ever read a run's
      `.font` attribute — correct when `NSAttributedString(markdown:)` used
      to bake **bold**/*italic* into an actual different font object, but
      (confirmed empirically on the SDK this was developed against) current
      `NSAttributedString(markdown:)` output no longer changes `.font` for
      inline emphasis at all — it sets a font-less `.inlinePresentationIntent`
      semantic attribute instead. That means **every** consumer of that
      shared helper — not just this new DOCX-table code, but `PDFRenderer`'s
      raw CoreText drawing and the existing DOCX image-table fallback too —
      was silently rendering `**bold**`/`*italic*` as plain text on that SDK.
      Fixed at the shared root (`emphasisTraits(in:)`/`applyingTraits(bold:
      italic:to:)` in `PlatformTypes.swift`, checking both representations)
      rather than only in the new OOXML-writing code, since the bug lived
      upstream of every consumer, not inside any one of them.

      A second bug only surfaced by actually opening a generated `.docx`
      (Quick Look's own thumbnail renderer — a third independent OOXML
      reader, separate from both `textutil` and `python-docx`) rather than
      trusting green tests: table cells rendered in a serif fallback font
      while the rest of the document showed the correct sans-serif one.
      `OOXMLTableWriter` originally read `(runFont ?? font).familyName` for
      `<w:rFonts>` — for the system font that resolves to
      `.AppleSystemUIFont`, one of AppKit's private, dot-prefixed internal
      names, unresolvable by any OOXML reader outside AppKit's own text
      system. Fixed by hardcoding the real, resolved family
      (`systemFontFamilyName = "Helvetica Neue"`) that AppKit's own writer
      already stamps on every *non*-table paragraph in this exact same
      document (confirmed by inspecting that writer's own XML) — not a
      shortcut, since `DocumentTheme` deliberately never varies font family
      (see its own doc comment), so this is the one family a table's text
      can ever actually be in. Regression-covered by
      `wordDocumentExporterTableCellsUseTheSameFontFamilyAsTheRestOfTheDocument`,
      which compares the table's resolved family against the body
      paragraph's own rather than asserting a literal string, so it stays
      correct even if a future OS resolves the system font to a different
      real name.

      Editability, not just visual correctness, needs its own check:
      whether the table can actually be *changed* afterward, not merely
      displayed. `python-docx` (a spec-faithful third-party OOXML
      implementation, unrelated to Apple's own toolchain) editing a
      generated `.docx` — changing a cell, renaming the header, appending
      a whole new row, saving, then reopening with a fresh instance —
      confirms every edit persists and the file stays valid, direct
      evidence this is a genuine editable table rather than a read-only
      approximation of one.

      TextEdit is not a usable stand-in for that same check. AppKit's own
      `.officeOpenXML` *reader* (TextEdit's underlying text system, the
      read-side counterpart of the writer this whole feature routes
      around) drops `<w:tbl>` structure on an open-then-resave round trip
      for any table, including a plain `python-docx`-generated reference
      table with no relation to this package's own output — the reader has
      no more real table support than the writer does, consistent with
      this phase's opening finding rather than contradicting it. (A stray
      leftover document from an earlier AppleScript check can make a
      broken round trip look like a working one — `document 1` is
      whichever window is frontmost, not necessarily the one just opened —
      so a claim like this needs an explicit document-count/name check
      before it's trusted.) This package has not been validated against an
      actual copy of Microsoft Word or LibreOffice; `python-docx` is the
      practical stand-in. The automatable substitute that *is* in the
      suite for CI, where no editor is installed at all:
      `wordDocumentExporterTableElementsFollowTheRequiredOOXMLSchemaOrder`
      walks the parsed XML tree (`XMLDocument`, not string/regex order
      checks) confirming `<w:tbl>`'s children appear in the exact sequence
      the OOXML schema requires (`tblPr`, `tblGrid`, one-or-more `tr` each
      holding one-or-more `tc`, each `tc`'s `tcPr` before its `p`) — the
      structural precondition every real editor's schema validation
      actually checks, verifiable without depending on one being installed
      in CI.
- [x] Phase 7: task lists and footnotes.

      **Task lists** (`- [ ] ...`/`- [x] ...`) parse into their own
      `.taskListItem(checked:level:text:)` case rather than an added field
      on `.listItem` — adding an associated value to an existing public
      enum case source-breaks every exhaustive `switch` over it, in this
      package and any consumer's, which a new sibling case doesn't (same
      shape `.callout` already uses relative to `.blockquote`). GFM task
      list markers are unordered-only (no numbered task list syntax), so
      this case carries no `ordered`/`number` fields the way `.listItem`
      does. Rendered via the existing `listParagraph` styling with a
      checkbox glyph (`☐`/`☑`) in place of a bullet character — no new
      layout code.

      **Footnotes** (`[^id]` inline, `[^id]: text` as its own line) follow
      the same "block-level construct gets a `DocumentBlock` case, inline
      construct stays literal text resolved at render time" split already
      established for tables and inline math: `.footnoteDefinition
      (identifier:text:)` is a new block case (`DocumentParser` recognizes
      the whole-line `[^id]: text` form), but a `[^id]` reference stays
      literal inside whatever paragraph/list-item/heading/blockquote/
      callout text it's written in, resolved by `DocumentRenderer`.
      Numbering follows GFM's own convention — by the order each
      identifier is first *referenced*, not by where its definition
      happens to sit in the source — which needs a document-wide pass
      (`footnoteReferenceNumbers`) before any individual block renders,
      since a block-local pass (the way inline math's sentinel extraction
      works, self-contained per paragraph) has no way to know a given
      reference is the 1st vs. the 3rd occurrence across the whole
      document. Reference substitution itself (`replaceFootnoteReferences`)
      runs as a second pass over the already-fully-rendered
      `NSAttributedString`, swapping each resolvable `[^id]` for a small
      superscript number — simpler than protecting it with a Private-Use-
      Area sentinel the way inline math needs (`extractInlineFormulas`),
      since `[^id]` isn't valid CommonMark link/emphasis syntax to begin
      with and `NSAttributedString(markdown:)` already passes it through
      as literal text unchanged. All resolved definitions render once,
      together, in a trailing "Footnotes" section built from the same
      `listParagraph` numbered-list styling already used elsewhere, not a
      new visual style. An unresolved reference (no matching definition)
      stays literal text; an unreferenced definition is dropped entirely —
      both match GFM's own behavior, and the "show something honest, not a
      blank gap" choice every other unresolvable reference in this package
      already makes.

      `WordDocumentExporter` needed its own copy of this logic (filtering
      `.footnoteDefinition` before `blockParagraph`, running the same
      reference-number pass, appending the same trailing section) since it
      builds a separate `NSAttributedString`, not `attributedString(from:
      ...)`'s. Building this surfaced the same class of bug Phase 6 already
      hit once: `.baselineOffset` (the superscript's raised-baseline
      attribute) gets encoded by AppKit's `.officeOpenXML` writer as a raw
      `<w:position w:val="N"/>` — a geometric offset, not the semantic
      `<w:vertAlign w:val="superscript"/>` a real editor's own superscript
      command would write. Both are spec-legal, and `textutil` (an
      independent OOXML reader) renders the raw form correctly raised — but
      Quick Look's own docx preview renders it *lowered* instead, caught
      only by actually opening a generated `.docx`, not by any
      string-contains test. `WordDocumentExporter` now substitutes the
      semantic element in as a post-processing step, the same "patch
      AppKit's own writer output" technique Phase 6 already established for
      tables — safe as an unconditional substitution since `.baselineOffset`
      is exclusively this package's own footnote-superscript signal (never
      set anywhere else, never negative), so every `<w:position>` a
      generated `document.xml` could contain came from exactly this and
      always means "superscript."
- [x] Phase 8: lowered the platform floor from iOS 17+/macOS 14+ to iOS
      16+/macOS 13+. Not a code change — verified empirically (not
      assumed) that nothing in this codebase actually needed iOS 17/macOS
      14: lowering `Package.swift`'s `platforms:` and rebuilding/retesting
      on both platforms (`swift test`, and `xcodebuild test` on an iOS
      simulator) passed clean with zero availability errors, meaning
      `.iOS(.v17)`/`.macOS(.v14)` had been a conservative default, not
      something any API in use actually required.

      Confirmed the enforcement mechanism itself, not just its absence of
      complaints: temporarily added a function gated
      `@available(iOS 99, macOS 99, *)` and called it unconditionally —
      `swift build` correctly failed with an availability error even
      though the actual host SDK (far newer than either 99 or 17) could
      easily have satisfied it, and even printed `-target
      arm64-apple-macos13.0` in its own invocation despite building on a
      much newer real OS. This confirms `swift build`/`xcodebuild build`/
      `test` always check availability against `Package.swift`'s declared
      platform minimum specifically, regardless of which SDK or simulator
      is actually present — which in turn means neither existing CI job
      (`macos`, `ios-simulator` in `.github/workflows/swift.yml`) needed
      any changes to start enforcing the new, lower floor: both already
      build via `swift build`/`xcodebuild`, so both already inherited this
      check the moment `Package.swift` changed. No new CI job added.

      What this does *not* cover, and initially was assumed to be gettable
      for free and turned out not to be: an actual iOS 16 simulator run.
      Checked GitHub's own `actions/runner-images` repository directly
      (not assumed from memory) — `macos-13` (whose bundled Xcode 14.x
      would have shipped iOS 16 simulators) has been removed from the
      available runner images entirely; `macos-14`, the oldest one left,
      bundles Xcode 15.0.1 through 16.2, and the *oldest* iOS simulator any
      of those ships is iOS 17.0. A genuine iOS 16 simulator is no longer
      obtainable on GitHub-hosted infrastructure at all, only via a
      self-hosted runner running an old Xcode — disproportionate
      infrastructure for a package this size. The compile-time
      availability check above is therefore the real, current
      verification story for the lowered floor, not a stand-in for a
      simulator run that was simply skipped.
- [ ] Not currently planned: an automatically generated table of contents.
      Deliberately left out of Phase 7 rather than folded in — it's a
      different scale of work from task lists/footnotes, not just another
      block type: `PDFRenderer` only knows which page a heading landed on
      *after* pagination finishes (CoreText lays out one page at a time; a
      `CTFramesetter` frame has no page number of its own), so a TOC up
      front needs a real two-pass pagination — lay out once, record each
      heading's page, render the TOC block, lay out again — not a parser/
      renderer change the way every other Phase 7 entry was. For DOCX,
      computing page numbers this package's own way would be the wrong
      move regardless: Word already has a native `{ TOC }` field that
      computes and updates its own page numbers on open, so a DOCX TOC
      would need its own, different mechanism from the PDF one rather than
      sharing one implementation. Revisit if a real use case shows up.
