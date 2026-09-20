// ImageRenderer
//
// Consumer-supplied hook for resolving an `.image` block's `source` to an actual image — this
// package does no disk or network I/O of its own (same zero-dependency reasoning as
// FormulaRenderer), so a local file path or remote URL only renders as a real picture when the
// consumer supplies one. A `data:image/...;base64,...` source never reaches this protocol at
// all: `DocumentRenderer` decodes those directly, since the bytes are already embedded right in
// the Markdown and need no I/O to resolve.

#if canImport(AppKit) || canImport(UIKit)

public protocol ImageRenderer {
    /// Return `nil` if `source` can't be resolved (file not found, request failed, unsupported
    /// scheme) — the caller falls back to showing the alt text instead of a blank gap.
    func image(forSource source: String, altText: String) -> PlatformImage?
}
#endif
