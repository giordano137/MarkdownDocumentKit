#if canImport(AppKit)
import Foundation
import Testing
@testable import MarkdownDocumentKit

@Test func minimalZipArchiveRoundTripsEntryNamesAndContent() throws {
    let entries = [
        ZipEntry(name: "hello.txt", uncompressedData: Data("Hello, world!".utf8), dosTime: 0, dosDate: 0x21),
        ZipEntry(name: "dir/empty.txt", uncompressedData: Data(), dosTime: 0, dosDate: 0x21),
    ]
    let archiveData = MinimalZipArchive.write(entries)
    let readBack = try MinimalZipArchive.read(archiveData)

    #expect(readBack.map(\.name) == ["hello.txt", "dir/empty.txt"])
    #expect(readBack[0].uncompressedData == Data("Hello, world!".utf8))
    #expect(readBack[1].uncompressedData == Data())
}

@Test func minimalZipArchiveOutputIsListableByAnIndependentUnzipTool() throws {
    // Round-tripping only through our own reader wouldn't catch a writer bug the reader happens
    // to tolerate the same way — `unzip -l` (a completely independent implementation) validates
    // the archive is actually spec-correct, not just self-consistent.
    let entries = [ZipEntry(name: "a.txt", uncompressedData: Data("content".utf8), dosTime: 0, dosDate: 0x21)]
    let archiveData = MinimalZipArchive.write(entries)

    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }
    let zipURL = tempDir.appendingPathComponent("test.zip")
    try archiveData.write(to: zipURL)

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
    process.arguments = ["-l", zipURL.path]
    let pipe = Pipe()
    process.standardOutput = pipe
    try process.run()
    process.waitUntilExit()
    let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

    #expect(process.terminationStatus == 0)
    #expect(output.contains("a.txt"))
}

@Test func crc32MatchesTheKnownReferenceValueForAnEmptyString() {
    // "" -> 0x00000000 and "123456789" -> 0xCBF43926 are the two standard CRC-32/ISO-HDLC test
    // vectors (the same table/polynomial ZIP, PNG, and gzip all use) — cheap, independent
    // confirmation the table-generation and byte order in `CRC32.checksum` are both correct.
    #expect(CRC32.checksum(Data()) == 0x0000_0000)
    #expect(CRC32.checksum(Data("123456789".utf8)) == 0xCBF4_3926)
}
#endif
