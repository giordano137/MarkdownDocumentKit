import Testing
@testable import MarkdownDocumentKit

@Test func versionIsSet() {
    #expect(!MarkdownDocumentKit.version.isEmpty)
}
