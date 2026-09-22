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

## Releasing

Bump `MarkdownDocumentKit.version` in `MarkdownDocumentKit.swift`, then:

```
git tag -a vX.Y.Z -m "vX.Y.Z — one-line summary

Longer description: what changed, why, how it was verified."
git push origin vX.Y.Z
```

Pushing a `vX.Y.Z` tag is all that's needed — `release.yml` picks it up
and creates the matching GitHub Release automatically, using the tag's
own annotation as the release notes. Don't run `gh release create` by
hand; if the tag's message is wrong, fix the tag and re-push rather than
editing the release separately, so the two never drift apart.

Follows [SemVer](https://semver.org); see the README's "Versioning"
section for what that means pre-1.0.
