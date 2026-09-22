#if canImport(AppKit) || canImport(UIKit)
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif
import Testing
@testable import MarkdownDocumentKit

@Test func customThemeChangesCodeBlockColors() {
    var theme = DocumentTheme.default
    theme.codeBlockBackground = .red
    theme.codeText = .green

    let blocks: [DocumentBlock] = [.codeBlock(lines: ["let x = 1"])]
    let attributed = DocumentRenderer.attributedString(from: blocks, title: "", theme: theme)
    let range = (attributed.string as NSString).range(of: "let x = 1")
    let background = attributed.attribute(.backgroundColor, at: range.location, effectiveRange: nil) as? PlatformColor
    let foreground = attributed.attribute(.foregroundColor, at: range.location, effectiveRange: nil) as? PlatformColor
    #expect(background == .red)
    #expect(foreground == .green)
}

@Test func customThemeChangesCalloutTint() {
    var theme = DocumentTheme.default
    theme.calloutTints[.note] = DocumentTheme.CalloutTint(background: .red, accent: .green)

    let blocks: [DocumentBlock] = [.callout(kind: .note, text: "Body.")]
    let attributed = DocumentRenderer.attributedString(from: blocks, title: "", theme: theme)

    let labelRange = (attributed.string as NSString).range(of: "Note")
    let accent = attributed.attribute(.foregroundColor, at: labelRange.location, effectiveRange: nil) as? PlatformColor
    #expect(accent == .green)

    let bodyRange = (attributed.string as NSString).range(of: "Body.")
    let background = attributed.attribute(.backgroundColor, at: bodyRange.location, effectiveRange: nil) as? PlatformColor
    #expect(background == .red)
}

@Test func overridingOneCalloutKindLeavesOthersAtDefault() {
    // A consumer overriding just their brand's "warning" color shouldn't have to also supply
    // note/tip/important — `DocumentTheme.calloutTint(for:)` falls back to `.default` per kind,
    // not per whole theme.
    var theme = DocumentTheme.default
    theme.calloutTints = [.warning: DocumentTheme.CalloutTint(background: .red, accent: .green)]

    let blocks: [DocumentBlock] = [.callout(kind: .tip, text: "Body.")]
    let attributed = DocumentRenderer.attributedString(from: blocks, title: "", theme: theme)
    let labelRange = (attributed.string as NSString).range(of: "Tip")
    let accent = attributed.attribute(.foregroundColor, at: labelRange.location, effectiveRange: nil) as? PlatformColor
    #expect(accent == DocumentTheme.default.calloutTints[.tip]?.accent)
}

@Test func customThemeChangesHeadingAndBodyFontSizes() {
    var theme = DocumentTheme.default
    theme.headingFontSizes = [40, 30]
    theme.bodyFontSize = 22

    let blocks: [DocumentBlock] = [.heading(level: 1, text: "Title"), .paragraph(text: "Body text.")]
    let attributed = DocumentRenderer.attributedString(from: blocks, title: "", theme: theme)

    let headingRange = (attributed.string as NSString).range(of: "Title")
    let headingFont = attributed.attribute(.font, at: headingRange.location, effectiveRange: nil) as? PlatformFont
    #expect(headingFont?.pointSize == 40)

    let bodyRange = (attributed.string as NSString).range(of: "Body text.")
    let bodyFont = attributed.attribute(.font, at: bodyRange.location, effectiveRange: nil) as? PlatformFont
    #expect(bodyFont?.pointSize == 22)
}

@Test func customThemeChangesTableColorsAndFontSizes() {
    var theme = DocumentTheme.default
    theme.tableBorder = .red
    theme.tableHeaderBackground = .green
    theme.tableText = .blue
    theme.tableCellFontSize = 30
    theme.tableHeaderFontSize = 40

    guard
        let layout = TableRenderer.computeLayout(
            header: ["A"],
            alignments: [.none],
            rows: [["1"]],
            maxWidth: 300,
            theme: theme
        )
    else {
        Issue.record("computeLayout returned nil")
        return
    }
    #expect(layout.theme.tableBorder == .red)
    #expect(layout.theme.tableHeaderBackground == .green)

    let headerColor = layout.headerCells[0].attribute(.foregroundColor, at: 0, effectiveRange: nil) as? PlatformColor
    let headerFont = layout.headerCells[0].attribute(.font, at: 0, effectiveRange: nil) as? PlatformFont
    #expect(headerColor == .blue)
    #expect(headerFont?.pointSize == 40)

    let bodyFont = layout.bodyCells[0][0].attribute(.font, at: 0, effectiveRange: nil) as? PlatformFont
    #expect(bodyFont?.pointSize == 30)
}

@Test func defaultThemeStillMatchesOriginalHardcodedValues() {
    // Regression guard: introducing DocumentTheme must not change a single pixel of output for
    // an existing consumer that never asks for a theme — every value here is copied from what
    // was a `static let`/inline literal before this feature existed.
    let theme = DocumentTheme.default
    #expect(theme.codeBlockBackground == PlatformColor(white: 0.95, alpha: 1))
    #expect(theme.tableBorder == PlatformColor(white: 0.75, alpha: 1))
    #expect(theme.tableHeaderBackground == PlatformColor(white: 0.91, alpha: 1))
    #expect(theme.headingFontSizes == [20, 18, 16, 14, 13, 12])
    #expect(theme.bodyFontSize == 13)
    #expect(theme.indentUnit == 18)
}

@Test func defaultThemeSuppliesATintForEveryCalloutKind() {
    // `calloutTint(for:)` falls back to `DocumentTheme.default.calloutTints[kind]` for any kind
    // a caller's own theme doesn't cover — that fallback used to be a force-unwrap, so a new
    // `CalloutKind` case added without a matching entry here would have crashed at render time
    // instead of failing this test. Iterating `CalloutKind.allCases` (not a hardcoded list of the
    // four current kinds) is what makes this actually catch that when a case is added later.
    for kind in CalloutKind.allCases {
        #expect(DocumentTheme.default.calloutTints[kind] != nil, "DocumentTheme.default.calloutTints is missing an entry for \(kind)")
    }
}

@Test func calloutTintFallsBackToDefaultThemeForAnUncoveredKind() {
    var theme = DocumentTheme.default
    theme.calloutTints = [.note: DocumentTheme.CalloutTint(background: .red, accent: .green)]

    let tipTint = theme.calloutTint(for: .tip)
    #expect(tipTint.background == DocumentTheme.default.calloutTints[.tip]?.background)
    #expect(tipTint.accent == DocumentTheme.default.calloutTints[.tip]?.accent)
}
#endif
