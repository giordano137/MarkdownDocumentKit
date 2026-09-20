// PlatformTypes
//
// AppKit (macOS) and UIKit (iOS) type aliases plus the small set of helpers needed where the two
// frameworks' APIs genuinely diverge (not just differ in name) — this is the seam that lets
// DocumentRenderer/TableRenderer/PDFRenderer share one implementation across both platforms
// instead of two parallel, drift-prone copies. Most of what those files touch (NSAttributedString,
// NSMutableParagraphStyle, NSTextAttachment, NSRegularExpression, CGContext/CoreText) is already
// identical on both platforms and needs nothing here at all.

#if canImport(AppKit)
import AppKit
public typealias PlatformFont = NSFont
public typealias PlatformColor = NSColor
public typealias PlatformImage = NSImage
#elseif canImport(UIKit)
import UIKit
public typealias PlatformFont = UIFont
public typealias PlatformColor = UIColor
public typealias PlatformImage = UIImage
#endif

#if canImport(AppKit) || canImport(UIKit)

/// The system italic variant of a font at the given size — `NSFontManager`'s trait-conversion API
/// has no UIKit equivalent, so this is genuinely two different implementations, not a renamed
/// method.
func italicSystemFont(ofSize size: CGFloat) -> PlatformFont {
    #if canImport(AppKit)
    return NSFontManager.shared.convert(.systemFont(ofSize: size), toHaveTrait: .italicFontMask)
    #elseif canImport(UIKit)
    let base = UIFont.systemFont(ofSize: size)
    guard let descriptor = base.fontDescriptor.withSymbolicTraits(.traitItalic) else { return base }
    return UIFont(descriptor: descriptor, size: size)
    #endif
}

extension PlatformColor {
    /// The muted "secondary text" color used for blockquotes and the missing-image fallback —
    /// `NSColor.secondaryLabelColor` on macOS, `UIColor.secondaryLabel` on iOS. Dynamic (not
    /// fixed) is fine here, unlike the exported-file colors elsewhere in this package: both of
    /// this color's call sites only ever feed into `DOCXDocumentConverter` (AppKit's OOXML writer
    /// reads it before any PDF-specific offscreen-CGContext resolution issue could apply) or an
    /// `NSAttributedString` a consumer displays live, not into `PDFRenderer`'s raw CGContext path.
    static var documentSecondaryText: PlatformColor {
        #if canImport(AppKit)
        return .secondaryLabelColor
        #elseif canImport(UIKit)
        return .secondaryLabel
        #endif
    }
}

/// Re-applies whichever of bold/italic `sourceFont` carries onto `baseFont`, preserving
/// `baseFont`'s family/size — used after `NSAttributedString(markdown:)` parses `**bold**`/
/// `*italic*` into *some* system font, so the result renders in the same family/size as the rest
/// of the paragraph instead of whatever font Markdown parsing happened to pick. Two real
/// implementations, not a renamed method: `NSFontDescriptor.SymbolicTraits` and
/// `UIFontDescriptor.SymbolicTraits` are different types with different case names (`.bold`/
/// `.italic` vs `.traitBold`/`.traitItalic`), and `withSymbolicTraits(_:)` returns non-optional on
/// one platform, optional on the other.
func applyingPreservedBoldItalic(from sourceFont: PlatformFont?, to baseFont: PlatformFont) -> PlatformFont {
    #if canImport(AppKit)
    let traits = sourceFont?.fontDescriptor.symbolicTraits ?? []
    var descriptor = baseFont.fontDescriptor
    if !traits.isDisjoint(with: [.bold, .italic]) {
        descriptor = descriptor.withSymbolicTraits(traits.intersection([.bold, .italic]))
    }
    return NSFont(descriptor: descriptor, size: baseFont.pointSize) ?? baseFont
    #elseif canImport(UIKit)
    let traits = sourceFont?.fontDescriptor.symbolicTraits ?? []
    var descriptor = baseFont.fontDescriptor
    if !traits.isDisjoint(with: [.traitBold, .traitItalic]) {
        if let withTraits = descriptor.withSymbolicTraits(traits.intersection([.traitBold, .traitItalic])) {
            descriptor = withTraits
        }
    }
    return UIFont(descriptor: descriptor, size: baseFont.pointSize)
    #endif
}

/// `NSImage.cgImage(forProposedRect:context:hints:)` has no UIKit equivalent method — `UIImage`
/// exposes the same bitmap directly as a `.cgImage` property instead.
func cgImage(from image: PlatformImage) -> CGImage? {
    #if canImport(AppKit)
    return image.cgImage(forProposedRect: nil, context: nil, hints: nil)
    #elseif canImport(UIKit)
    return image.cgImage
    #endif
}

/// Renders into an offscreen bitmap of `size` (at `scale`), handing `draw` a `CGContext` that
/// behaves as bottom-left-origin/y-up — matching a PDF page's own native coordinate convention
/// (the PDF spec's own bottom-left convention, not an OS choice) — so the same drawing code
/// (`TableRenderer.drawTable`) works unmodified whether it's drawing into this offscreen bitmap or
/// directly into a live PDF page's context. Genuinely two different implementations, not a
/// renamed method: `NSGraphicsContext(bitmapImageRep:)` already gives a bottom-left/y-up context
/// by default, while `UIGraphicsImageRenderer` gives a top-left/y-down one (UIKit's own view
/// convention) that has to be flipped first.
func renderToImage(size: CGSize, scale: CGFloat, draw: (CGContext) -> Void) -> PlatformImage? {
    #if canImport(AppKit)
    guard
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width * scale),
            pixelsHigh: Int(size.height * scale),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )
    else { return nil }
    rep.size = size

    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
    NSGraphicsContext.current = context
    // No manual `scaleBy` here — `NSGraphicsContext(bitmapImageRep:)` already maps its drawing
    // coordinate space to `size` (the point size, not the rep's actual pixel dimensions) — the
    // extra `scale`-many pixels allocated for Retina crispness are already accounted for
    // automatically. Scaling again on top of that halved (in each axis) the space drawing calls
    // actually had to work with, which read as "top and right of the table missing" rather than
    // an obvious scale bug.
    draw(context.cgContext)

    let image = NSImage(size: size)
    image.addRepresentation(rep)
    return image
    #elseif canImport(UIKit)
    let format = UIGraphicsImageRendererFormat()
    format.scale = scale
    let renderer = UIGraphicsImageRenderer(size: size, format: format)
    return renderer.image { rendererContext in
        let context = rendererContext.cgContext
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)
        draw(context)
    }
    #endif
}

#endif
