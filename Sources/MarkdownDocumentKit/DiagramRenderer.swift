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
    /// `palette` is the active `DocumentTheme`'s `diagramPalette` — map its colors onto whatever
    /// the diagramming library's own theming hook is (Mermaid: a `%%{init: {'theme':'base',
    /// 'themeVariables': {...}}}%%` directive prepended to `source`) so a rendered diagram matches
    /// the rest of the document instead of the library's own stock color scheme. This package
    /// stays Mermaid-unaware either way — it only ever hands across plain color data, the same
    /// "colors injected, don't hardcode a look" shape `DocumentTheme` already uses for every other
    /// block type; turning that into a specific `%%{init}%%` string is entirely this method's own
    /// job. Return `nil` if `source` can't be rendered (invalid Mermaid syntax, the JS context
    /// isn't available) — the caller falls back to the raw source text in a code block rather than
    /// a blank gap.
    func image(forMermaidSource source: String, palette: DiagramPalette) -> PlatformImage?
}

/// The colors a `DiagramRenderer` should use so a rendered diagram matches the rest of the
/// document instead of whatever a diagramming library's own stock theme happens to default to —
/// carries no font-family field, consistent with `DocumentTheme`'s own stance on that (see its
/// top-of-file comment), and no font-*size* field either: unlike `FormulaRenderer`'s `fontSize`
/// (which has to match surrounding body text so an inline formula sits on the same baseline), a
/// diagram is always its own standalone block, so internal node/label sizing is the diagramming
/// library's own concern, not something that needs to match anything around it.
public struct DiagramPalette {
    /// A node's fill — Mermaid's `primaryColor`.
    public var nodeBackground: PlatformColor
    /// A node's outline — Mermaid's `primaryBorderColor`.
    public var nodeBorder: PlatformColor
    /// Connector/arrow strokes — Mermaid's `lineColor`.
    public var lineColor: PlatformColor
    /// Node label text — Mermaid's `primaryTextColor`/`textColor`.
    public var textColor: PlatformColor

    public init(nodeBackground: PlatformColor, nodeBorder: PlatformColor, lineColor: PlatformColor, textColor: PlatformColor) {
        self.nodeBackground = nodeBackground
        self.nodeBorder = nodeBorder
        self.lineColor = lineColor
        self.textColor = textColor
    }
}
#endif
