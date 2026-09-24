// MinimalZipArchive
//
// A `.docx` is a ZIP container (see `WordDocumentExporter`'s own top-of-file comment for why this
// package needs to open and rewrite one). This is a from-scratch, single-purpose ZIP reader/writer for
// exactly the shape AppKit's own `.officeOpenXML` writer produces — a small, flat set of entries
// (`word/document.xml`, `_rels/.rels`, etc.), each plain-Deflate or Stored, no encryption, no
// Zip64, no split archives, no data-descriptor-trailer entries. It intentionally does not attempt
// to be a general-purpose ZIP library: that scope (arbitrary nesting, every historical ZIP
// extension) would be a real dependency's worth of work for a document type this package only
// ever produces itself, never reads from an untrusted third party. Kept dependency-free like the
// rest of this package (see `Package.swift`) via `Compression` (a system framework, not a package)
// for the one part a from-scratch implementation genuinely shouldn't hand-roll: the deflate codec
// itself.
//
// Reading decompresses every entry (`compressed size` is tiny for a document this size — a few KB
// per part) so `WordDocumentExporter` can text-search-and-replace inside `word/document.xml`.
// Writing always re-emits every entry as **Stored** (uncompressed) rather than re-deflating: this
// package only ever calls `compression_decode_buffer` (decode), never the encode half, since
// `WordDocumentExporter` only replaces one small XML entry — reusing the same one-way dependency on
// `Compression` avoids having to separately verify a hand-rolled raw-deflate *encoder* produces
// byte-correct output (encoding is materially easier to get subtly wrong than decoding: a reader
// forgives extra decode slack, a writer's framing has to be exactly right). Stored entries are a
// completely ordinary, spec-legal ZIP shape — mixing Stored and Deflated entries in one archive is
// routine and every ZIP reader (Word's own included) already has to handle it — the only cost is a
// few extra KB in the final `.docx`, immaterial for a text document.

#if canImport(AppKit)
import Compression
import Foundation

struct ZipEntry {
    let name: String
    let uncompressedData: Data
    let dosTime: UInt16
    let dosDate: UInt16
}

enum ZipArchiveError: Error {
    case notAZipFile
    case corruptEntry(name: String)
    case inflateFailed(name: String)
}

enum MinimalZipArchive {
    private static let localFileHeaderSignature: UInt32 = 0x0403_4b50
    private static let centralDirectorySignature: UInt32 = 0x0201_4b50
    private static let endOfCentralDirectorySignature: UInt32 = 0x0605_4b50

    // MARK: - Reading

    /// Every entry, fully decompressed — see this file's top comment for why reading always
    /// inflates rather than exposing raw compressed bytes.
    static func read(_ data: Data) throws -> [ZipEntry] {
        guard let eocdOffset = findEndOfCentralDirectory(in: data) else { throw ZipArchiveError.notAZipFile }
        let entryCount = Int(readUInt16(data, at: eocdOffset + 10))
        let centralDirectoryOffset = Int(readUInt32(data, at: eocdOffset + 16))

        var entries: [ZipEntry] = []
        var cursor = centralDirectoryOffset
        for _ in 0..<entryCount {
            guard readUInt32(data, at: cursor) == centralDirectorySignature else {
                throw ZipArchiveError.notAZipFile
            }
            let method = readUInt16(data, at: cursor + 10)
            let dosTime = readUInt16(data, at: cursor + 12)
            let dosDate = readUInt16(data, at: cursor + 14)
            let compressedSize = Int(readUInt32(data, at: cursor + 20))
            let uncompressedSize = Int(readUInt32(data, at: cursor + 24))
            let nameLength = Int(readUInt16(data, at: cursor + 28))
            let extraLength = Int(readUInt16(data, at: cursor + 30))
            let commentLength = Int(readUInt16(data, at: cursor + 32))
            let localHeaderOffset = Int(readUInt32(data, at: cursor + 42))
            let nameStart = cursor + 46
            guard let name = String(data: data.subdata(in: nameStart..<(nameStart + nameLength)), encoding: .utf8)
            else { throw ZipArchiveError.notAZipFile }

            let compressedData = try readLocalFileData(
                data,
                headerOffset: localHeaderOffset,
                compressedSize: compressedSize,
                entryName: name
            )
            let uncompressedData: Data
            switch method {
            case 0: uncompressedData = compressedData
            case 8: uncompressedData = try inflate(compressedData, uncompressedSize: uncompressedSize, entryName: name)
            default: throw ZipArchiveError.corruptEntry(name: name)
            }

            entries.append(ZipEntry(name: name, uncompressedData: uncompressedData, dosTime: dosTime, dosDate: dosDate))
            cursor = nameStart + nameLength + extraLength + commentLength
        }
        return entries
    }

    /// Central directory records commit to a *count*, unlike a local file header (which the ZIP
    /// spec would let a writer instead terminate with a trailing data-descriptor) — searching
    /// backward from the file's end for the End Of Central Directory record's signature is the
    /// standard, only-reliable way any ZIP reader locates it, since a variable-length trailing
    /// comment field (rarely used, but legal) means it isn't always at a fixed offset from the end.
    private static func findEndOfCentralDirectory(in data: Data) -> Int? {
        guard data.count >= 22 else { return nil }
        let searchFloor = max(0, data.count - 22 - 65535)
        var offset = data.count - 22
        while offset >= searchFloor {
            if readUInt32(data, at: offset) == endOfCentralDirectorySignature { return offset }
            offset -= 1
        }
        return nil
    }

    private static func readLocalFileData(_ data: Data, headerOffset: Int, compressedSize: Int, entryName: String) throws -> Data {
        guard readUInt32(data, at: headerOffset) == localFileHeaderSignature else {
            throw ZipArchiveError.corruptEntry(name: entryName)
        }
        let nameLength = Int(readUInt16(data, at: headerOffset + 26))
        let extraLength = Int(readUInt16(data, at: headerOffset + 28))
        let dataStart = headerOffset + 30 + nameLength + extraLength
        guard dataStart + compressedSize <= data.count else { throw ZipArchiveError.corruptEntry(name: entryName) }
        return data.subdata(in: dataStart..<(dataStart + compressedSize))
    }

    /// Raw deflate (no zlib/gzip wrapper) — the framing ZIP's method 8 actually uses. Verified
    /// empirically against a real AppKit-produced `.docx` before relying on it here: `COMPRESSION_ZLIB`
    /// is, despite the name, `Compression`'s identifier for exactly this raw-deflate stream, not the
    /// RFC 1950 zlib-wrapped format its name suggests.
    private static func inflate(_ compressed: Data, uncompressedSize: Int, entryName: String) throws -> Data {
        guard uncompressedSize > 0 else { return Data() }
        var output = [UInt8](repeating: 0, count: uncompressedSize)
        let decodedCount = compressed.withUnsafeBytes { srcPtr -> Int in
            output.withUnsafeMutableBytes { dstPtr in
                compression_decode_buffer(
                    dstPtr.bindMemory(to: UInt8.self).baseAddress!,
                    uncompressedSize,
                    srcPtr.bindMemory(to: UInt8.self).baseAddress!,
                    compressed.count,
                    nil,
                    COMPRESSION_ZLIB
                )
            }
        }
        guard decodedCount == uncompressedSize else { throw ZipArchiveError.inflateFailed(name: entryName) }
        return Data(output)
    }

    // MARK: - Writing

    /// Re-emits every entry Stored (see top-of-file comment for why) with a fresh central
    /// directory/EOCD reflecting each entry's new offset — offsets shift for every entry after
    /// whichever one `WordDocumentExporter` replaced, so the whole archive is rebuilt rather than
    /// patched in place.
    static func write(_ entries: [ZipEntry]) -> Data {
        var body = Data()
        var centralDirectory = Data()
        var localHeaderOffsets: [Int] = []

        for entry in entries {
            localHeaderOffsets.append(body.count)
            let nameData = Data(entry.name.utf8)
            let crc = CRC32.checksum(entry.uncompressedData)
            let size = UInt32(entry.uncompressedData.count)

            var local = Data()
            appendUInt32(&local, localFileHeaderSignature)
            appendUInt16(&local, 20) // version needed to extract
            appendUInt16(&local, 0) // general purpose flag
            appendUInt16(&local, 0) // method: stored
            appendUInt16(&local, entry.dosTime)
            appendUInt16(&local, entry.dosDate)
            appendUInt32(&local, crc)
            appendUInt32(&local, size) // compressed size == uncompressed size when stored
            appendUInt32(&local, size)
            appendUInt16(&local, UInt16(nameData.count))
            appendUInt16(&local, 0) // extra field length
            local.append(nameData)
            local.append(entry.uncompressedData)
            body.append(local)

            var central = Data()
            appendUInt32(&central, centralDirectorySignature)
            appendUInt16(&central, 20) // version made by
            appendUInt16(&central, 20) // version needed to extract
            appendUInt16(&central, 0) // general purpose flag
            appendUInt16(&central, 0) // method: stored
            appendUInt16(&central, entry.dosTime)
            appendUInt16(&central, entry.dosDate)
            appendUInt32(&central, crc)
            appendUInt32(&central, size)
            appendUInt32(&central, size)
            appendUInt16(&central, UInt16(nameData.count))
            appendUInt16(&central, 0) // extra field length
            appendUInt16(&central, 0) // comment length
            appendUInt16(&central, 0) // disk number start
            appendUInt16(&central, 0) // internal file attributes
            appendUInt32(&central, 0) // external file attributes
            appendUInt32(&central, UInt32(localHeaderOffsets.last!))
            central.append(nameData)
            centralDirectory.append(central)
        }

        var archive = body
        let centralDirectoryOffset = archive.count
        archive.append(centralDirectory)

        var eocd = Data()
        appendUInt32(&eocd, endOfCentralDirectorySignature)
        appendUInt16(&eocd, 0) // this disk number
        appendUInt16(&eocd, 0) // disk with central directory start
        appendUInt16(&eocd, UInt16(entries.count)) // entries on this disk
        appendUInt16(&eocd, UInt16(entries.count)) // total entries
        appendUInt32(&eocd, UInt32(centralDirectory.count))
        appendUInt32(&eocd, UInt32(centralDirectoryOffset))
        appendUInt16(&eocd, 0) // comment length
        archive.append(eocd)

        return archive
    }

    // MARK: - Little-endian primitives

    private static func readUInt16(_ data: Data, at offset: Int) -> UInt16 {
        UInt16(data[data.startIndex + offset]) | (UInt16(data[data.startIndex + offset + 1]) << 8)
    }

    private static func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
        (0..<4).reduce(UInt32(0)) { partial, i in
            partial | (UInt32(data[data.startIndex + offset + i]) << (8 * i))
        }
    }

    private static func appendUInt16(_ data: inout Data, _ value: UInt16) {
        data.append(UInt8(value & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
    }

    private static func appendUInt32(_ data: inout Data, _ value: UInt32) {
        for shift in stride(from: 0, to: 32, by: 8) {
            data.append(UInt8((value >> shift) & 0xFF))
        }
    }
}
#endif
