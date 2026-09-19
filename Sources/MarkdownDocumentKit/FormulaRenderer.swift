// FormulaRenderer
//
// Consumer-supplied hook for turning LaTeX into an image — this package has zero
// math-typesetting dependencies (see README's "Math rendering is injected, not bundled"), so a
// `.formula` block or an inline `$...$`/`\(...\)` span only renders as real math when the
// consumer supplies one (typically backed by SwiftMath, e.g. via TeXEnvironments). Without one,
// DocumentRenderer falls back to showing the formula's raw LaTeX source as plain text — same
// "show the source, don't just disappear" philosophy TableRenderer already uses when a table
// can't be laid out.

#if os(macOS)
import AppKit

public protocol FormulaRenderer {
    /// `displayMode: true` for a standalone equation (from a `.formula` block, typically
    /// rendered a notch larger), `false` for a symbol appearing inline mid-sentence. Return `nil`
    /// for LaTeX that can't be parsed — the caller falls back to the raw source text rather than
    /// leaving a blank gap.
    func image(forLaTeX latex: String, displayMode: Bool, fontSize: CGFloat) -> FormulaImage?
}

/// An image plus its baseline offset. The offset matters only for an inline formula: it needs to
/// sit on the same baseline as the surrounding text rather than hang from the top of the line —
/// a consumer's own SwiftMath-backed rasterizer typically already computes this (the descent of
/// the rendered `MTMathUILabel`), so this type just carries it across the protocol boundary.
public struct FormulaImage {
    public let image: NSImage
    public let descent: CGFloat

    public init(image: NSImage, descent: CGFloat) {
        self.image = image
        self.descent = descent
    }
}
#endif
