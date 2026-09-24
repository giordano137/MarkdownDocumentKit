// CRC32
//
// Standard ZIP-flavored CRC-32 (polynomial 0xEDB88320, the same one PNG/gzip/ZIP all use) — needed
// by `MinimalZipArchive` because every ZIP central directory record and local file header carries
// each entry's CRC-32 of its *uncompressed* bytes, checked by any reader (Word included) before it
// trusts an entry's contents. No platform framework exposes this directly (`Compression` only
// handles the deflate codec itself), so it's reimplemented here rather than pulled in as a
// dependency for one small, stable algorithm.

import Foundation

enum CRC32 {
    private static let table: [UInt32] = {
        (0...255).map { i -> UInt32 in
            var c = UInt32(i)
            for _ in 0..<8 {
                c = (c & 1 != 0) ? (0xEDB8_8320 ^ (c >> 1)) : (c >> 1)
            }
            return c
        }
    }()

    static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            let index = Int((crc ^ UInt32(byte)) & 0xFF)
            crc = table[index] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }
}
