# Contributing

PRs welcome.

- `swift test` must be green before you open a PR.
- If you touch `DocumentRenderer`/`TableRenderer`/`PDFRenderer`, test on
  both macOS and an iOS Simulator — this package runs on both from one
  shared implementation, and a coordinate-space or font-availability bug
  can pass on one platform and silently break the other (see
  [ARCHITECTURE.md](ARCHITECTURE.md) for real examples of exactly that).
- A visual/layout change (spacing, colors, pagination) is worth actually
  opening a generated PDF, not just asserting on attributes — several bugs
  documented in ARCHITECTURE.md were only ever visible that way.
- Keep the zero-dependency policy: no new Swift package dependencies. Math
  typesetting, image I/O, and diagram rendering are injected via
  `FormulaRenderer`/`ImageRenderer`/`DiagramRenderer` on purpose — see the
  README's "Injecting math, images, and diagrams" section before adding a
  new capability that needs I/O or a third-party library.
