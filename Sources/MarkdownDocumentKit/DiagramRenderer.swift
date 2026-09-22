// DiagramRenderer
//
// Consumer-supplied hook for turning a fenced ```mermaid block's source into an image — this
// package has zero dependencies (see README), and turning Mermaid syntax into a real rendered
// diagram inherently needs a small JS context (no native Swift port of Mermaid exists), so a
// `.diagram` block only renders as an actual picture when the consumer supplies one (typically a
// hidden WKWebView running mermaid.js, screenshotted once layout settles). Without one,
// `DocumentRenderer` falls back to showing the raw Mermaid source as a code block — same "show
// the source, don't just disappear" philosophy `FormulaRenderer`/`ImageRenderer` already use,
// deliberately *not* an attempt at a hand-rolled ASCII approximation of the diagram: a wrong or
// ugly best-effort render would be worse than admitting this package can't draw it without help.

#if canImport(AppKit) || canImport(UIKit)

public protocol DiagramRenderer {
    /// Return `nil` if `source` can't be rendered (invalid Mermaid syntax, the JS context isn't
    /// available) — the caller falls back to the raw source text in a code block rather than a
    /// blank gap.
    func image(forMermaidSource source: String) -> PlatformImage?
}
#endif
