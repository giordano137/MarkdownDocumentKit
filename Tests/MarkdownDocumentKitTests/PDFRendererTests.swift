#if canImport(AppKit) || canImport(UIKit)
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif
import PDFKit
import Testing
@testable import MarkdownDocumentKit

@Test func rendersAValidSinglePagePDFForATable() throws {
    let markdown = "# Titel\n\nText davor.\n\n| A | B |\n| --- | --- |\n| eins | zwei |\n\nText danach."
    let attributed = DocumentRenderer.attributedString(from: DocumentParser.parse(markdown), title: "Test")
    let data = try PDFRenderer.render(attributed)

    guard let document = PDFDocument(data: data) else {
        Issue.record("PDFRenderer produced data PDFDocument couldn't parse")
        return
    }
    #expect(document.pageCount == 1)
}

// `attachmentsStayInsideThePageMarginNotFlushWithTheLeftEdge` below is AppKit-only: it samples
// individual rasterized pixels via `NSBitmapImageRep`, which has no UIKit equivalent (a raw
// `CGImage`/`CGDataProvider` byte-offset reimplementation would be its own new source of subtle
// bugs — premultiplied alpha, byte order, row padding — that can't be visually debugged the way
// the AppKit version already was). The margin fix this guards lives entirely in `PDFRenderer.swift`,
// which has no platform-specific branches at all — the same CoreText/CGContext code path runs
// unmodified on iOS, so this one test's AppKit-only pixel check still stands in for both platforms
// in practice, even though it can't literally run on an iOS simulator.
#if canImport(AppKit)
@Test func attachmentsStayInsideThePageMarginNotFlushWithTheLeftEdge() throws {
    // Regression guard for a real bug found by actually opening a generated PDF (no
    // text-content assertion can see a visual mis-position like this): `CTFrameGetLineOrigins`
    // reports points relative to the frame's own path bounding box — its horizontal origin is
    // always 0 regardless of the page margin — not already-absolute page coordinates. So a
    // table/formula attachment's *x* position drew flush with the page's left edge instead of
    // inset by the margin, while ordinary `CTFrameDraw`-drawn text (which never reads
    // `CTFrameGetLineOrigins`) stayed correctly inset. Scans a whole vertical strip just left of
    // the margin rather than one guessed point, since the table's row is at whatever y its
    // content happens to land at.
    let markdown = "# Titel\n\nText davor.\n\n| A | B |\n| --- | --- |\n| eins | zwei |\n| drei | vier |"
    let attributed = DocumentRenderer.attributedString(from: DocumentParser.parse(markdown), title: "Test")
    let pageSize = CGSize(width: 612, height: 792)
    let margin: CGFloat = 54
    let data = try PDFRenderer.render(attributed, pageSize: pageSize, margin: margin)

    guard let document = PDFDocument(data: data), let pdfPage = document.page(at: 0) else {
        Issue.record("Could not open generated PDF with PDFKit")
        return
    }
    let pageBounds = pdfPage.bounds(for: .mediaBox)
    let thumbnail = pdfPage.thumbnail(of: pageBounds.size, for: .mediaBox)
    guard let cgImage = thumbnail.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
        Issue.record("Could not rasterize PDF page")
        return
    }
    let bitmap = NSBitmapImageRep(cgImage: cgImage)
    let pixelsPerPoint = CGFloat(bitmap.pixelsWide) / pageBounds.width
    // Halfway into the margin: comfortably left of anything a correctly-margined document ever
    // draws, comfortably right of 0 so antialiasing at the true page edge can't false-pass.
    let x = Int((margin / 2) * pixelsPerPoint)
    var foundInk = false
    for y in stride(from: 0, to: bitmap.pixelsHigh, by: 4) {
        guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceGray) else { continue }
        var white: CGFloat = 0
        color.getWhite(&white, alpha: nil)
        if white < 0.95 {
            foundInk = true
            break
        }
    }
    #expect(!foundInk, "Found drawn content inside the page margin — an attachment lost its horizontal margin offset")
}
#endif

@Test func paginatesLongContentAcrossMultiplePagesWithoutLosingOrDuplicatingText() throws {
    // Regression guard for the actual page-break loop in PDFRenderer.render: `location +=
    // visibleRange.length` advancing by the wrong amount would either re-draw the tail of one
    // page again at the top of the next (duplication) or skip text that fell exactly on the
    // boundary (loss) — neither of which `rendersAValidSinglePagePDFForATable` above can catch,
    // since that test only ever produces one page. Each paragraph is a short, unique, single-word
    // token specifically so line-wrapping/hyphenation can't fracture it across a PDFKit text
    // extraction, which would otherwise look like data loss that isn't really there.
    let markerCount = 200
    let markers = (1...markerCount).map { String(format: "Marker%04d", $0) }
    let markdown = markers.map { "\($0)." }.joined(separator: "\n\n")
    let attributed = DocumentRenderer.attributedString(from: DocumentParser.parse(markdown), title: "Test")
    let data = try PDFRenderer.render(attributed)

    guard let document = PDFDocument(data: data) else {
        Issue.record("PDFRenderer produced data PDFDocument couldn't parse")
        return
    }
    #expect(document.pageCount > 1, "Expected enough content to force a page break, got \(document.pageCount) page(s)")

    var extracted: [String] = []
    for pageIndex in 0..<document.pageCount {
        guard let page = document.page(at: pageIndex), let pageText = page.string else { continue }
        let regex = try NSRegularExpression(pattern: "Marker\\d{4}")
        let nsRange = NSRange(location: 0, length: (pageText as NSString).length)
        regex.enumerateMatches(in: pageText, range: nsRange) { match, _, _ in
            guard let match, let range = Range(match.range, in: pageText) else { return }
            extracted.append(String(pageText[range]))
        }
    }

    #expect(extracted == markers, "Extracted markers diverged from source — a page break duplicated or dropped text")
}

#if canImport(AppKit)
@Test func tableNearPageBoundaryLandsWhollyOnOnePageRatherThanBeingSplit() throws {
    // A `TableAttachment` rides through the pagination loop as a single atomic CTRun (see
    // `withAttachmentSizingDelegates`) — CoreText line-breaking can't split a run mid-glyph, so a
    // table that doesn't fully fit on the current page should move whole to the next one rather
    // than being cut in half. Padding the markdown with enough filler paragraphs to land the
    // table right at a page boundary is what actually exercises that, unlike the single-page
    // table tests elsewhere which never get near an edge at all.
    let filler = (1...60).map { "Fuellzeile \($0)." }.joined(separator: "\n\n")
    let markdown = filler + "\n\n| A | B |\n| --- | --- |\n| eins | zwei |\n| drei | vier |"
    let attributed = DocumentRenderer.attributedString(from: DocumentParser.parse(markdown), title: "Test")
    let data = try PDFRenderer.render(attributed)

    guard let document = PDFDocument(data: data) else {
        Issue.record("PDFRenderer produced data PDFDocument couldn't parse")
        return
    }

    var pagesContainingTableText: [Int] = []
    for pageIndex in 0..<document.pageCount {
        guard let page = document.page(at: pageIndex), let pageText = page.string else { continue }
        if pageText.contains("eins") || pageText.contains("zwei") || pageText.contains("drei") || pageText.contains("vier") {
            pagesContainingTableText.append(pageIndex)
        }
    }

    #expect(pagesContainingTableText.count == 1, "Table cell text appeared on \(pagesContainingTableText.count) pages instead of exactly one — the table may have been split across a page break")
}
#endif
#endif
