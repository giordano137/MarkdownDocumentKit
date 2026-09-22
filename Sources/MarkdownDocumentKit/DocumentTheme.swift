// DocumentTheme
//
// Every color, font size, and spacing value `DocumentRenderer`/`TableRenderer` use, gathered into
// one injectable value instead of scattered `static let`s and inline literals — the same
// "optional injection, sane default" shape `FormulaRenderer`/`ImageRenderer` already use, so a
// consumer that doesn't care about styling changes nothing (every call site defaults to
// `.default`, which reproduces this package's original hardcoded look exactly), while one that
// does can override just the fields it cares about.
//
// Deliberately *not* stretched to cover font *family* (only sizes): every text run in this
// package is a system-font regular/bold/italic/monospaced variant, and letting a consumer swap in
// an arbitrary custom typeface would mean re-deriving bold/italic synthesis for that typeface too
// (a real, separate feature, not a "small" addition) — sizes/colors/spacing are what "our brand
// colors instead of yours" concretely means in practice, and cover that need on their own.

#if canImport(AppKit) || canImport(UIKit)
import Foundation

public struct DocumentTheme {
    /// One callout kind's tinted body background + accent label color — see
    /// `DocumentRenderer.calloutParagraph` for why the label itself carries no background of its
    /// own.
    public struct CalloutTint {
        public var background: PlatformColor
        public var accent: PlatformColor

        public init(background: PlatformColor, accent: PlatformColor) {
            self.background = background
            self.accent = accent
        }
    }

    // MARK: - Colors

    public var codeBlockBackground: PlatformColor
    public var codeText: PlatformColor
    public var tableBorder: PlatformColor
    public var tableHeaderBackground: PlatformColor
    public var tableText: PlatformColor
    /// Blockquote text and the missing-image fallback's "[image: ...]" text — both are muted
    /// asides, not primary content.
    public var secondaryText: PlatformColor
    public var calloutTints: [CalloutKind: CalloutTint]
    /// Handed to a `DiagramRenderer` alongside a `.diagram` block's Mermaid source — see
    /// `DiagramPalette`'s own doc comment for why colors are what crosses that boundary, never a
    /// font.
    public var diagramPalette: DiagramPalette

    // MARK: - Font sizes (system font family — see this file's top-of-file comment)

    public var titleFontSize: CGFloat
    /// Indexed by heading level - 1 (`# H1` at index 0); a level past the array's end clamps to
    /// the last entry, matching `DocumentRenderer.headingParagraph`'s existing behavior.
    public var headingFontSizes: [CGFloat]
    public var bodyFontSize: CGFloat
    public var codeFontSize: CGFloat
    public var tableCellFontSize: CGFloat
    public var tableHeaderFontSize: CGFloat
    public var calloutLabelFontSize: CGFloat
    /// Font size handed to `FormulaRenderer` for a standalone `.formula` block (display math).
    /// Inline formulas instead use whatever surrounding text's own size already is — no separate
    /// theme field needed there, it falls out of `bodyFontSize`/`headingFontSizes`/etc. naturally.
    public var formulaDisplayFontSize: CGFloat

    // MARK: - Spacing

    /// Left indent for a blockquote, a callout's label/body, and one list nesting level (a list
    /// at level *n* indents by `indentUnit * n`).
    public var indentUnit: CGFloat
    public var titleSpacing: CGFloat
    public var headingSpacing: CGFloat
    public var bodySpacing: CGFloat
    public var listItemSpacing: CGFloat
    public var codeBlockSpacingBefore: CGFloat
    public var codeBlockSpacingAfter: CGFloat
    public var calloutLabelSpacing: CGFloat
    public var tableHorizontalPadding: CGFloat
    public var tableVerticalPadding: CGFloat
    public var tableMinRowHeight: CGFloat
    public var tableMinColumnWidth: CGFloat

    public init(
        codeBlockBackground: PlatformColor,
        codeText: PlatformColor,
        tableBorder: PlatformColor,
        tableHeaderBackground: PlatformColor,
        tableText: PlatformColor,
        secondaryText: PlatformColor,
        calloutTints: [CalloutKind: CalloutTint],
        diagramPalette: DiagramPalette,
        titleFontSize: CGFloat,
        headingFontSizes: [CGFloat],
        bodyFontSize: CGFloat,
        codeFontSize: CGFloat,
        tableCellFontSize: CGFloat,
        tableHeaderFontSize: CGFloat,
        calloutLabelFontSize: CGFloat,
        formulaDisplayFontSize: CGFloat,
        indentUnit: CGFloat,
        titleSpacing: CGFloat,
        headingSpacing: CGFloat,
        bodySpacing: CGFloat,
        listItemSpacing: CGFloat,
        codeBlockSpacingBefore: CGFloat,
        codeBlockSpacingAfter: CGFloat,
        calloutLabelSpacing: CGFloat,
        tableHorizontalPadding: CGFloat,
        tableVerticalPadding: CGFloat,
        tableMinRowHeight: CGFloat,
        tableMinColumnWidth: CGFloat
    ) {
        self.codeBlockBackground = codeBlockBackground
        self.codeText = codeText
        self.tableBorder = tableBorder
        self.tableHeaderBackground = tableHeaderBackground
        self.tableText = tableText
        self.secondaryText = secondaryText
        self.calloutTints = calloutTints
        self.diagramPalette = diagramPalette
        self.titleFontSize = titleFontSize
        self.headingFontSizes = headingFontSizes
        self.bodyFontSize = bodyFontSize
        self.codeFontSize = codeFontSize
        self.tableCellFontSize = tableCellFontSize
        self.tableHeaderFontSize = tableHeaderFontSize
        self.calloutLabelFontSize = calloutLabelFontSize
        self.formulaDisplayFontSize = formulaDisplayFontSize
        self.indentUnit = indentUnit
        self.titleSpacing = titleSpacing
        self.headingSpacing = headingSpacing
        self.bodySpacing = bodySpacing
        self.listItemSpacing = listItemSpacing
        self.codeBlockSpacingBefore = codeBlockSpacingBefore
        self.codeBlockSpacingAfter = codeBlockSpacingAfter
        self.calloutLabelSpacing = calloutLabelSpacing
        self.tableHorizontalPadding = tableHorizontalPadding
        self.tableVerticalPadding = tableVerticalPadding
        self.tableMinRowHeight = tableMinRowHeight
        self.tableMinColumnWidth = tableMinColumnWidth
    }

    /// Reproduces this package's original hardcoded look exactly — every `DocumentRenderer`/
    /// `TableRenderer` call site defaults to this, so an existing consumer that never asks for a
    /// theme sees zero change.
    public static let `default` = DocumentTheme(
        codeBlockBackground: PlatformColor(white: 0.95, alpha: 1),
        codeText: .black,
        tableBorder: PlatformColor(white: 0.75, alpha: 1),
        tableHeaderBackground: PlatformColor(white: 0.91, alpha: 1),
        tableText: .black,
        secondaryText: .documentSecondaryText,
        calloutTints: [
            .note: CalloutTint(
                background: PlatformColor(red: 0.90, green: 0.95, blue: 1.0, alpha: 1),
                accent: PlatformColor(red: 0.16, green: 0.40, blue: 0.85, alpha: 1)
            ),
            .tip: CalloutTint(
                background: PlatformColor(red: 0.89, green: 0.97, blue: 0.90, alpha: 1),
                accent: PlatformColor(red: 0.16, green: 0.55, blue: 0.28, alpha: 1)
            ),
            .warning: CalloutTint(
                background: PlatformColor(red: 1.0, green: 0.95, blue: 0.82, alpha: 1),
                accent: PlatformColor(red: 0.70, green: 0.48, blue: 0.05, alpha: 1)
            ),
            .important: CalloutTint(
                background: PlatformColor(red: 0.95, green: 0.90, blue: 1.0, alpha: 1),
                accent: PlatformColor(red: 0.50, green: 0.20, blue: 0.75, alpha: 1)
            ),
        ],
        // Matches .note's tint on purpose — a coherent default for a consumer that wires this
        // straight into Mermaid's themeVariables without picking its own colors first, rather than
        // Mermaid's own stock purple, which doesn't relate to anything else in this theme.
        diagramPalette: DiagramPalette(
            nodeBackground: PlatformColor(red: 0.90, green: 0.95, blue: 1.0, alpha: 1),
            nodeBorder: PlatformColor(red: 0.16, green: 0.40, blue: 0.85, alpha: 1),
            lineColor: PlatformColor(white: 0.42, alpha: 1),
            textColor: .black
        ),
        titleFontSize: 22,
        headingFontSizes: [20, 18, 16, 14, 13, 12],
        bodyFontSize: 13,
        codeFontSize: 12,
        tableCellFontSize: 12,
        tableHeaderFontSize: 12,
        calloutLabelFontSize: 13,
        formulaDisplayFontSize: 16,
        indentUnit: 18,
        titleSpacing: 16,
        headingSpacing: 10,
        bodySpacing: 8,
        listItemSpacing: 4,
        codeBlockSpacingBefore: 4,
        codeBlockSpacingAfter: 12,
        calloutLabelSpacing: 2,
        tableHorizontalPadding: 8,
        tableVerticalPadding: 5,
        tableMinRowHeight: 22,
        tableMinColumnWidth: 36
    )

    /// Falls back to `.default`'s tint for a kind the caller's `calloutTints` dictionary doesn't
    /// cover — a consumer overriding just one or two kinds shouldn't have to supply all four. The
    /// second fallback (`neutralFallbackTint`) only matters if `.default` itself is ever missing a
    /// case — e.g. a new `CalloutKind` added without a matching `.default.calloutTints` entry —
    /// and exists so that gap degrades to a generic gray tint instead of a crash (this used to be
    /// a force-unwrap on the `.default` lookup). `DocumentThemeTests.defaultThemeSuppliesATintForEveryCalloutKind`
    /// is what actually catches that gap, by iterating `CalloutKind.allCases`.
    func calloutTint(for kind: CalloutKind) -> CalloutTint {
        calloutTints[kind] ?? DocumentTheme.default.calloutTints[kind] ?? DocumentTheme.neutralFallbackTint
    }

    private static let neutralFallbackTint = CalloutTint(
        background: PlatformColor(white: 0.93, alpha: 1),
        accent: PlatformColor(white: 0.35, alpha: 1)
    )
}
#endif
