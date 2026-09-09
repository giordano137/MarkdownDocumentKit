// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "MarkdownDocumentKit",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "MarkdownDocumentKit",
            targets: ["MarkdownDocumentKit"]
        )
    ],
    // Deliberately zero dependencies — see README's "Math rendering is injected, not
    // bundled" section. A consumer that doesn't care about formulas shouldn't have to pull
    // in SwiftMath/TeXEnvironments (or anything else) just to lay out headings/tables/callouts.
    targets: [
        .target(
            name: "MarkdownDocumentKit"
        ),
        .testTarget(
            name: "MarkdownDocumentKitTests",
            dependencies: ["MarkdownDocumentKit"]
        )
    ]
)
