// PDFRenderer
//
// Paginates a `DocumentRenderer`-produced `NSAttributedString` into a real multi-page PDF using
// CoreText directly — no `NSPrintOperation`/print-panel round trip, no dependency. Lives here
// (not just in a consuming app) because "renders to PDF" is this package's own stated job (see
// README) — a table/formula's `NSTextAttachment` needs the exact same `CTRunDelegate`/margin
// handling this file works out regardless of which app is calling it, so a consumer shouldn't
// have to reimplement this raw-CoreText dance themselves to get a real PDF out.

#if canImport(AppKit) || canImport(UIKit)
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif
import CoreText
import Foundation

public enum PDFRenderingError: Error {
    case renderingFailed
}

public enum PDFRenderer {
    /// US Letter (612x792pt) with a 0.75" (54pt) margin by default.
    public static func render(
        _ attributedString: NSAttributedString,
        pageSize: CGSize = CGSize(width: 612, height: 792),
        margin: CGFloat = 54
    ) throws -> Data {
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData) else {
            throw PDFRenderingError.renderingFailed
        }
        var mediaBox = CGRect(origin: .zero, size: pageSize)
        guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw PDFRenderingError.renderingFailed
        }

        let textRect = CGRect(
            x: margin,
            y: margin,
            width: pageSize.width - margin * 2,
            height: pageSize.height - margin * 2
        )
        let path = CGPath(rect: textRect, transform: nil)

        // A table (or formula) rides in this attributed string as an `NSTextAttachment` — same
        // "render the thing that can't flow as text, embed as an image" trick as an app's own
        // inline-math rendering might use. Two extra steps that technique needs here specifically,
        // neither of which a live `NSTextView` requires (TextKit handles both automatically):
        // CoreText only reserves layout space matching an attachment's real size if a
        // `CTRunDelegate` explicitly reports it (bare `.attachment` sizing is silently ignored by
        // raw `CTFramesetter`/`CTFrameDraw`, collapsing the run to near-zero and leaving every
        // attachment overlapping whatever comes right after it) — and `CTFrameDraw` itself only
        // draws glyphs, never attachment images, regardless.
        let attributedStringWithAttachmentSizing = withAttachmentSizingDelegates(attributedString)
        let framesetter = CTFramesetterCreateWithAttributedString(attributedStringWithAttachmentSizing as CFAttributedString)
        let totalLength = attributedStringWithAttachmentSizing.length

        var location = 0
        repeat {
            context.beginPDFPage(nil)
            let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: location, length: 0), path, nil)
            context.textMatrix = .identity
            // Backgrounds first (e.g. a code block's shading, see DocumentRenderer.codeBlockBackground)
            // — `CTFrameDraw` below only ever draws glyphs, never `.backgroundColor`, unlike a live
            // NSTextView/TextKit stack which paints it automatically.
            drawBackgroundColors(in: frame, context: context, frameOrigin: textRect.origin)
            CTFrameDraw(frame, context)
            drawAttachmentImages(in: frame, context: context, frameOrigin: textRect.origin)
            context.endPDFPage()

            let visibleRange = CTFrameGetVisibleStringRange(frame)
            // Guard against a frame that can't fit even a single glyph in the text rect, which
            // would otherwise spin forever re-drawing the same empty page.
            guard visibleRange.length > 0 else { break }
            location += visibleRange.length
        } while location < totalLength

        context.closePDF()
        return data as Data
    }

    /// Holds one attachment's run metrics for the `CTRunDelegate` callbacks below — a plain
    /// reference type so it can round-trip through `Unmanaged` (required: the callbacks are
    /// `@convention(c)` function pointers and can't capture context directly).
    private final class AttachmentRunMetrics {
        let width: CGFloat
        let ascent: CGFloat
        let descent: CGFloat
        init(width: CGFloat, ascent: CGFloat, descent: CGFloat) {
            self.width = width
            self.ascent = ascent
            self.descent = descent
        }
    }

    /// Attaches a `CTRunDelegate` to every `.attachment` range reporting its real width/ascent/
    /// descent as the run's own. Returns a copy; never mutates the original, since DOCX export
    /// consumes the same `NSAttributedString` through AppKit's own OOXML writer, which needs no
    /// such delegate and shouldn't carry one.
    ///
    /// Ascent/descent are derived from `attachment.bounds`, not just its height, because a table
    /// (`bounds.origin.y == 0`, drawn entirely above the baseline — "a block image on its own
    /// line") and an inline formula (`bounds.origin.y == -descent`, so its bottom hangs below the
    /// baseline like a real glyph does) need different splits of the same total height. Reporting
    /// descent as always 0 (this function's original, table-only version) under-reserved line
    /// height for a formula and made it overlap the line drawn right after it — caught by actually
    /// opening a generated PDF, not just by a passing unit test (`extractedText.contains(...)`
    /// can't see a visual overlap at all).
    private static func withAttachmentSizingDelegates(_ attributedString: NSAttributedString) -> NSAttributedString {
        let mutable = NSMutableAttributedString(attributedString: attributedString)
        let fullRange = NSRange(location: 0, length: mutable.length)
        mutable.enumerateAttribute(.attachment, in: fullRange, options: []) { value, range, _ in
            guard let attachment = value as? NSTextAttachment else { return }
            var callbacks = CTRunDelegateCallbacks(
                version: kCTRunDelegateVersion1,
                dealloc: { pointer in
                    Unmanaged<AttachmentRunMetrics>.fromOpaque(pointer).release()
                },
                getAscent: { pointer in
                    Unmanaged<AttachmentRunMetrics>.fromOpaque(pointer).takeUnretainedValue().ascent
                },
                getDescent: { pointer in
                    Unmanaged<AttachmentRunMetrics>.fromOpaque(pointer).takeUnretainedValue().descent
                },
                getWidth: { pointer in
                    Unmanaged<AttachmentRunMetrics>.fromOpaque(pointer).takeUnretainedValue().width
                }
            )
            let bounds = attachment.bounds
            let metrics = AttachmentRunMetrics(
                width: bounds.width,
                ascent: bounds.height + bounds.origin.y,
                descent: -bounds.origin.y
            )
            let refCon = Unmanaged.passRetained(metrics).toOpaque()
            guard let delegate = CTRunDelegateCreate(&callbacks, refCon) else { return }
            mutable.addAttribute(kCTRunDelegateAttributeName as NSAttributedString.Key, value: delegate, range: range)
        }
        return mutable
    }

    /// Paints a filled rect behind every run carrying a `.backgroundColor` attribute (currently
    /// just `DocumentRenderer.codeBlockBackground` on code blocks) — the PDF-specific half of a
    /// pair with `withAttachmentSizingDelegates`/`drawAttachmentImages` above: raw CoreText only
    /// draws what it's explicitly told to, so anything a live NSTextView/TextKit stack would paint
    /// automatically (attachment images, background shading) needs its own manual pass here. Spans
    /// the run's full line height (ascent+descent), not just its own glyph bounds, so adjacent runs
    /// on the same line produce a continuous band rather than a jagged one.
    ///
    /// `frameOrigin` (the text rect's own origin, i.e. the page margin) has to be added to every
    /// line origin by hand: `CTFrameGetLineOrigins` reports points relative to the frame's own path
    /// bounding box, with the box's bottom-left corner as (0, 0) — not already-absolute page
    /// coordinates. `CTFrameDraw` never shows this because it positions glyphs from its own
    /// internal knowledge of the path, never through these external line origins at all — only
    /// code that (like this one) reads `CTFrameGetLineOrigins` itself needs the margin added back
    /// manually. Caught by actually opening a generated PDF with a code block near the page's
    /// edge, not a passing unit test.
    private static func drawBackgroundColors(in frame: CTFrame, context: CGContext, frameOrigin: CGPoint) {
        guard let lines = CTFrameGetLines(frame) as? [CTLine] else { return }
        var lineOrigins = [CGPoint](repeating: .zero, count: lines.count)
        CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &lineOrigins)

        for (lineIndex, line) in lines.enumerated() {
            guard let runs = CTLineGetGlyphRuns(line) as? [CTRun] else { continue }
            var ascent: CGFloat = 0
            var descent: CGFloat = 0
            CTLineGetTypographicBounds(line, &ascent, &descent, nil)
            let lineOrigin = CGPoint(x: lineOrigins[lineIndex].x + frameOrigin.x, y: lineOrigins[lineIndex].y + frameOrigin.y)

            for run in runs {
                guard let attributes = CTRunGetAttributes(run) as? [NSAttributedString.Key: Any],
                    let color = attributes[.backgroundColor] as? PlatformColor
                else { continue }

                let runRange = CTRunGetStringRange(run)
                let startOffset = CTLineGetOffsetForStringIndex(line, runRange.location, nil)
                let endOffset = CTLineGetOffsetForStringIndex(line, runRange.location + runRange.length, nil)
                let rect = CGRect(
                    x: lineOrigin.x + startOffset,
                    y: lineOrigin.y - descent,
                    width: endOffset - startOffset,
                    height: ascent + descent
                )
                // Rounded, not a plain fill: reads as a genuine "tinted box" for a callout
                // (README's original Phase 3 goal) rather than a flat highlight; a small enough
                // radius that it doesn't visibly change a code block's existing rectangular look.
                let cornerRadius: CGFloat = min(4, rect.height / 2)
                let path = CGPath(roundedRect: rect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
                context.setFillColor(color.cgColor)
                context.addPath(path)
                context.fillPath()
            }
        }
    }

    /// `CTFrameDraw` draws glyphs only — an `.attachment` run's actual image still has to be drawn
    /// by hand afterward, at the position/size CoreText reserved for it via the `CTRunDelegate`
    /// above. See `drawBackgroundColors` above for why `frameOrigin` (the page margin) has to be
    /// added to `CTFrameGetLineOrigins`' values by hand — without it, every table/formula image
    /// drew flush with the page's bottom-left corner instead of inside the margin, confirmed by
    /// opening a real generated PDF (no unit test catches a visual mis-position like this).
    private static func drawAttachmentImages(in frame: CTFrame, context: CGContext, frameOrigin: CGPoint) {
        guard let lines = CTFrameGetLines(frame) as? [CTLine] else { return }
        var lineOrigins = [CGPoint](repeating: .zero, count: lines.count)
        CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &lineOrigins)

        for (lineIndex, line) in lines.enumerated() {
            guard let runs = CTLineGetGlyphRuns(line) as? [CTRun] else { continue }
            for run in runs {
                guard let attributes = CTRunGetAttributes(run) as? [NSAttributedString.Key: Any],
                    let attachment = attributes[.attachment] as? NSTextAttachment
                else { continue }

                let runRange = CTRunGetStringRange(run)
                let xOffset = CTLineGetOffsetForStringIndex(line, runRange.location, nil)
                let lineOrigin = CGPoint(x: lineOrigins[lineIndex].x + frameOrigin.x, y: lineOrigins[lineIndex].y + frameOrigin.y)
                let bounds = attachment.bounds
                let origin = CGPoint(x: lineOrigin.x + xOffset + bounds.origin.x, y: lineOrigin.y + bounds.origin.y)

                // A `TableAttachment` gets drawn for real — actual text-showing operators in the
                // PDF content stream, genuinely selectable/searchable, not a flattened picture of
                // text. Every other attachment (a formula image, say) still goes through the plain
                // "draw the fallback bitmap" path, same as before.
                if let table = attachment as? TableAttachment {
                    TableRenderer.drawTable(table.layout, in: context, origin: origin)
                } else if let image = attachment.image,
                    let cgImageValue = cgImage(from: image)
                {
                    let imageRect = CGRect(x: origin.x, y: origin.y, width: bounds.width, height: bounds.height)
                    context.draw(cgImageValue, in: imageRect)
                }
            }
        }
    }
}
#endif
