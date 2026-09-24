# Contributing

PRs welcome. For anything bigger than a bugfix — a new block type, a
change to the public API, a new injection point — open an issue first and
say what you're after. That isn't a gate, it's so you don't spend two
evenings on something that turns out to be out of scope or already
half-solved elsewhere in the package.

- **`swift test` must be green** before you open a PR.
- **New behavior needs new tests** — not just the happy path, the edge
  cases too (an empty/zero-column table, a missing renderer, a ragged
  table row, that kind of thing). A PR that changes behavior with no test
  covering it is the one case "tests pass" is trivially true and means
  nothing.
- **Cross-platform code needs both platforms.** If you touch
  `DocumentRenderer`/`TableRenderer`/`PDFRenderer`, run the macOS tests
  *and* the Simulator ones:

  ```
  swift test
  xcodebuild test -scheme MarkdownDocumentKit \
    -destination "platform=iOS Simulator,name=iPhone 16"
  ```

  This package runs on both from one shared implementation, and a
  coordinate-space or font-availability bug can pass on one platform and
  silently break the other (see [ARCHITECTURE.md](ARCHITECTURE.md) for
  real examples of exactly that). CI runs both jobs too, but catching it
  locally is faster than catching it in review.
- **Visual changes want a real look.** For spacing, colors or pagination,
  open the generated PDF rather than only asserting on attributes — see
  "Green isn't the same as right" below for why that catches what tests
  don't.
- **Keep the zero-dependency policy:** no new Swift package dependencies.
  Math typesetting, image I/O, and diagram rendering are injected via
  `FormulaRenderer`/`ImageRenderer`/`DiagramRenderer` on purpose — see the
  README's "Injecting math, images, and diagrams" section before adding a
  new capability that needs I/O or a third-party library.

## Working with AI

Using AI to help write a PR — including the actual code — is fine here.
Plenty of this codebase was built exactly that way (see
[ARCHITECTURE.md](ARCHITECTURE.md) for the honest history, real bugs
included). No disclosure required, no "explain every line" gate, and
nobody gets a hard time for using the tools they have.

So what follows isn't a warning — it's just what I actually look at in a
review, written down so you know it before you spend the effort.

- **You're the director, the AI is the worker.** It executes; the design is
  yours. That's not a dig at the tools, it follows from the one thing a
  model structurally can't do: it has no need of its own. Architecture is
  the answer to a problem somebody actually *has* — "I needed this, it was
  missing, so it had to look like this" — and that problem is yours. A
  model can build a shape; it can't tell you why that shape is right for a
  requirement it never had. So the question about a PR is never "did you
  type this yourself", it's "what does this make possible, and why in this
  form".
- **Syntax isn't the bar; architecture is.** Swift syntax is deterministic
  and lookup-able — it has a correct answer, and you don't need to be able
  to produce it from memory to contribute here. Architecture has no
  lookup-able answer: it's a decision, and decisions need someone who
  wants something. Concretely, know what *capability* changed — not the
  diff line by line: does a new field source-break existing exhaustive
  switches where a new case wouldn't have, does a new capability belong
  behind an injection point (`FormulaRenderer`-style) instead of baked in,
  does it touch `DocumentBlock`/`DocumentTheme`'s public shape at all. If
  it changes the public API, be ready to say why this shape and not one
  already established elsewhere.
- **Green isn't the same as right.** When you're fixing a bug, a test that
  would pass with or without the fix hasn't tested anything — put the bug
  back, confirm the test goes red, then fix it again and confirm it's
  green. Nobody expects a perfect test; there's always a case left
  uncovered. But do cover the case you wrote the fix for — that one isn't
  optional. And where the output is a file, open the
  file: several real bugs here passed every test and were only ever
  visible in the generated PDF or DOCX. Checking with something that isn't
  this codebase (`unzip`, `python-docx`, an actual reader) beats our own
  writer being validated against our own reader.

Letting a second model review the diff is a decent way to catch a missed
edge case or a correctness slip, and worth doing. It won't answer the
*fit* question though — a second model has the same blind spot as the
first: no stake in this package, no idea what it's for. That part stays
with you.

And if a contribution doesn't fit as-is, that's a conversation, not a wall
— say what you were after, I'll say what doesn't fit and why (see
ARCHITECTURE.md for how that reasoning tends to go here), and there's
usually another way to help or a version that does fit.

## Releasing

Bump `MarkdownDocumentKit.version` in `MarkdownDocumentKit.swift`, then
commit and push that bump **before** tagging:

```
git commit -am "Bump version to X.Y.Z"
git push origin main

git tag -a vX.Y.Z -m "vX.Y.Z — one-line summary

Longer description: what changed, why, how it was verified."
git push origin vX.Y.Z
```

Pushing the tag does carry its commit's objects along, so skipping
`push origin main` wouldn't break the release itself — but `main` on
GitHub would then be missing the version bump, and the branch would
disagree with the tag until someone pushes again. Push the branch first
and it never happens.

Pushing the `vX.Y.Z` tag is what triggers everything else — `release.yml`
picks it up and creates the matching GitHub Release automatically, using
the tag's own annotation as the release notes. Don't run
`gh release create` by hand; if the tag's message is wrong, fix the tag
and re-push rather than editing the release separately, so the two never
drift apart.

Follows [SemVer](https://semver.org); see the README's "Versioning"
section for what that means pre-1.0.
