import Foundation
import Compression

/// Reads a single named file out of a ZIP archive held in memory (#420).
///
/// Exists because a `.pkpass` is a ZIP whose `pass.json` states every field on the
/// pass exactly as its issuer wrote it, and neither iOS nor macOS gives us a way to
/// open one:
///  - `Foundation` has no unarchiver at all. `FileManager` can copy, move and trash
///    a zip but not look inside it.
///  - `PassKit`'s `PKPass` can read a pass, but only field-by-field through
///    `localizedValue(forFieldKey:)`, and there is no public way to ENUMERATE the
///    keys — so you can only ask it for fields you already knew the names of, which
///    is precisely what we do not know for an arbitrary issuer. It is also iOS-only,
///    and the Mac has to read the same file.
///  - Shelling out to `/usr/bin/unzip` does not exist on iOS.
///
/// So: ~120 lines against the format's own spec (PKWARE APPNOTE 6.3.x), scoped
/// hard to what a pass needs. Deliberately NOT a general archiver:
///  - Reads one entry by exact name, rather than expanding the whole archive. A
///    pass's payload is `pass.json`; the images beside it are not wanted.
///  - Supports the only two compression methods a real zip writer uses for small
///    text: stored (0) and deflate (8).
///  - No ZIP64, no encryption, no multi-disk, no streaming. A `.pkpass` is a few
///    hundred kilobytes; anything claiming otherwise is not a pass.
///
/// Every read is bounds-checked against the buffer and every declared size is
/// sanity-capped, because the input is a file someone downloaded from the internet
/// and a malformed one must fail rather than crash.
struct ZipArchiveReader {

    /// Largest uncompressed entry we will inflate, as a guard against a declared
    /// size that would have us allocate arbitrarily much. `pass.json` is a few
    /// kilobytes; 16 MB is far past any honest value.
    private static let maxEntrySize = 16 * 1024 * 1024

    private let data: Data

    /// `nil` when the buffer is not a readable ZIP (no end-of-central-directory
    /// record within reach of the end).
    init?(data: Data) {
        guard data.count > 22, ZipArchiveReader.endOfCentralDirectory(in: data) != nil else {
            return nil
        }
        self.data = data
    }

    /// The bytes of the entry named exactly `name`, or `nil` when the archive has
    /// no such entry or it cannot be decompressed.
    ///
    /// Names are compared exactly and case-sensitively. A `.pkpass` manifest always
    /// spells its payload `pass.json`, and matching loosely would let a stray
    /// `Pass.JSON` in a subdirectory stand in for the real one.
    func entry(named name: String) -> Data? {
        guard let eocd = Self.endOfCentralDirectory(in: data) else { return nil }
        var offset = eocd.centralDirectoryOffset
        for _ in 0..<eocd.entryCount {
            guard let header = centralHeader(at: offset) else { return nil }
            if header.name == name {
                return payload(of: header)
            }
            offset = header.nextOffset
        }
        return nil
    }

    // MARK: - Central directory

    private struct CentralHeader {
        let name: String
        let method: UInt16
        let compressedSize: Int
        let uncompressedSize: Int
        let localHeaderOffset: Int
        /// Offset of the next central-directory record.
        let nextOffset: Int
    }

    /// One central-directory record. Field offsets are from the format spec:
    /// signature 0, method 10, compressed size 20, uncompressed size 24, name
    /// length 28, extra length 30, comment length 32, local header offset 42.
    private func centralHeader(at offset: Int) -> CentralHeader? {
        guard u32(offset) == 0x0201_4b50 else { return nil }
        guard let method = u16(offset + 10),
              let compressed = u32(offset + 20),
              let uncompressed = u32(offset + 24),
              let nameLength = u16(offset + 28),
              let extraLength = u16(offset + 30),
              let commentLength = u16(offset + 32),
              let localOffset = u32(offset + 42) else { return nil }

        let nameStart = offset + 46
        let nameEnd = nameStart + Int(nameLength)
        guard nameEnd <= data.count,
              let name = String(data: data[nameStart..<nameEnd], encoding: .utf8) else { return nil }

        return CentralHeader(
            name: name,
            method: method,
            compressedSize: Int(compressed),
            uncompressedSize: Int(uncompressed),
            localHeaderOffset: Int(localOffset),
            nextOffset: nameEnd + Int(extraLength) + Int(commentLength)
        )
    }

    /// The entry's bytes, decompressed if need be.
    ///
    /// The local file header is re-read rather than trusted from the central
    /// directory, because only it tells us how long ITS name and extra fields are,
    /// and the data begins immediately after them.
    private func payload(of header: CentralHeader) -> Data? {
        let local = header.localHeaderOffset
        guard u32(local) == 0x0403_4b50,
              let nameLength = u16(local + 26),
              let extraLength = u16(local + 28) else { return nil }

        let start = local + 30 + Int(nameLength) + Int(extraLength)
        let end = start + header.compressedSize
        guard start >= 0, end <= data.count, header.compressedSize >= 0,
              header.uncompressedSize >= 0,
              header.uncompressedSize <= Self.maxEntrySize else { return nil }

        let raw = data[start..<end]
        switch header.method {
        case 0:
            return Data(raw)
        case 8:
            return Self.inflate(Data(raw), expectedSize: header.uncompressedSize)
        default:
            // Bzip2, LZMA and friends are legal ZIP but no pass writer emits them.
            return nil
        }
    }

    // MARK: - Deflate

    /// Inflate a raw DEFLATE stream.
    ///
    /// `COMPRESSION_ZLIB` in Apple's `Compression` framework is RAW deflate with no
    /// zlib header or trailer, which is exactly what a ZIP entry stores — the name
    /// is the misleading part, not the behaviour.
    private static func inflate(_ input: Data, expectedSize: Int) -> Data? {
        guard !input.isEmpty, expectedSize > 0 else { return nil }
        var out = Data(count: expectedSize)
        let written: Int = out.withUnsafeMutableBytes { dst -> Int in
            guard let dstBase = dst.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return input.withUnsafeBytes { src -> Int in
                guard let srcBase = src.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_decode_buffer(
                    dstBase, expectedSize,
                    srcBase, input.count,
                    nil, COMPRESSION_ZLIB
                )
            }
        }
        guard written > 0 else { return nil }
        return written == expectedSize ? out : out.prefix(written)
    }

    // MARK: - End of central directory

    private struct EOCD {
        let entryCount: Int
        let centralDirectoryOffset: Int
    }

    /// Locate the end-of-central-directory record.
    ///
    /// It sits at the very end of the file unless the archive carries a trailing
    /// comment, so the signature is searched for backwards over the last 64 KB plus
    /// the record's own length — the largest window a comment can push it back by.
    private static func endOfCentralDirectory(in data: Data) -> EOCD? {
        let minimumRecord = 22
        guard data.count >= minimumRecord else { return nil }
        let searchFloor = max(0, data.count - (minimumRecord + 0xFFFF))
        var offset = data.count - minimumRecord
        while offset >= searchFloor {
            if read32(data, offset) == 0x0605_4b50,
               let count = read16(data, offset + 10),
               let directory = read32(data, offset + 16),
               Int(directory) < data.count {
                return EOCD(entryCount: Int(count), centralDirectoryOffset: Int(directory))
            }
            offset -= 1
        }
        return nil
    }

    // MARK: - Little-endian reads, bounds-checked

    private func u16(_ offset: Int) -> UInt16? { Self.read16(data, offset) }
    private func u32(_ offset: Int) -> UInt32? { Self.read32(data, offset) }

    private static func read16(_ data: Data, _ offset: Int) -> UInt16? {
        guard offset >= 0, offset + 2 <= data.count else { return nil }
        let base = data.startIndex + offset
        return UInt16(data[base]) | (UInt16(data[base + 1]) << 8)
    }

    private static func read32(_ data: Data, _ offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= data.count else { return nil }
        let base = data.startIndex + offset
        return UInt32(data[base])
            | (UInt32(data[base + 1]) << 8)
            | (UInt32(data[base + 2]) << 16)
            | (UInt32(data[base + 3]) << 24)
    }
}
