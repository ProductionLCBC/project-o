// OEngine — Spec 9 §3, the snapshot's zip.

import Compression
import Foundation

/// Spec 9 §3 — "A snapshot is one zip file ... It uses deflate, so the Finder
/// and `unzip` open it." The container is written here (local headers, the
/// central directory, CRC-32) and the deflate is Apple's Compression
/// framework, part of the system as CryptoKit is (Adam's answer of
/// 2026-11-14: no new dependency, so no ADR).
///
/// Only what a snapshot needs: files at relative paths, deflated when that
/// makes them smaller and stored when not, UTF-8 names, no zip64 (a snapshot
/// is "a few megabytes for a whole library"). Reading takes any zip made of
/// stored and deflated entries, and refuses the rest: the bytes came from a
/// file, so nothing here traps on them.
public enum Zip {
    public struct Entry: Equatable, Sendable {
        public var path: String
        public var data: Data

        public init(path: String, data: Data) {
            self.path = path
            self.data = data
        }
    }

    public struct Failure: Error, Equatable, Sendable, CustomStringConvertible {
        public var message: String
        public var description: String { message }

        init(_ message: String) {
            self.message = message
        }
    }

    /// The most an entry may inflate to: far above any document, and a
    /// bound on what a damaged header can make the reader allocate.
    static let largestEntry = 256 << 20

    // MARK: - Writing

    /// The archive's bytes: `entries` in order, each stamped `modified` as
    /// `timeZone` reads it (a zip's times are local ones).
    public static func archive(_ entries: [Entry], modified: Date, timeZone: TimeZone) throws -> Data {
        guard entries.count <= Int(UInt16.max) else { throw Failure("\(entries.count) files are more than a zip holds without zip64") }
        let (time, date) = dosStamp(modified, timeZone: timeZone)
        var out = Data()
        var directory = Data()
        for entry in entries {
            let name = Data(entry.path.utf8)
            guard name.count <= Int(UInt16.max), entry.data.count <= Int(UInt32.max) else {
                throw Failure("\(entry.path) is too large for a zip without zip64")
            }
            let packed = deflate(entry.data)
            let method: UInt16 = packed == nil ? 0 : 8
            let body = packed ?? entry.data
            let crc = crc32(entry.data)
            guard out.count <= Int(UInt32.max) else { throw Failure("the archive is too large for a zip without zip64") }
            let offset = UInt32(out.count)

            // The local file header.
            out.append(u32: 0x0403_4B50)
            out.append(u16: 20)             // version needed: deflate
            out.append(u16: 0x0800)         // names are UTF-8
            out.append(u16: method)
            out.append(u16: time)
            out.append(u16: date)
            out.append(u32: crc)
            out.append(u32: UInt32(body.count))
            out.append(u32: UInt32(entry.data.count))
            out.append(u16: UInt16(name.count))
            out.append(u16: 0)
            out.append(name)
            out.append(body)

            // Its entry in the central directory.
            directory.append(u32: 0x0201_4B50)
            directory.append(u16: 20 | (3 << 8))    // made on Unix, so the mode below is read
            directory.append(u16: 20)
            directory.append(u16: 0x0800)
            directory.append(u16: method)
            directory.append(u16: time)
            directory.append(u16: date)
            directory.append(u32: crc)
            directory.append(u32: UInt32(body.count))
            directory.append(u32: UInt32(entry.data.count))
            directory.append(u16: UInt16(name.count))
            directory.append(u16: 0)                // extra
            directory.append(u16: 0)                // comment
            directory.append(u16: 0)                // disk
            directory.append(u16: 0)                // internal attributes
            directory.append(u32: 0o100644 << 16)   // a regular file, rw-r--r--
            directory.append(u32: offset)
            directory.append(name)
        }
        guard out.count <= Int(UInt32.max), directory.count <= Int(UInt32.max) else {
            throw Failure("the archive is too large for a zip without zip64")
        }
        let start = UInt32(out.count)
        out.append(directory)
        out.append(u32: 0x0605_4B50)
        out.append(u16: 0)
        out.append(u16: 0)
        out.append(u16: UInt16(entries.count))
        out.append(u16: UInt16(entries.count))
        out.append(u32: UInt32(directory.count))
        out.append(u32: start)
        out.append(u16: 0)
        return out
    }

    /// Raw deflate of `data`, or nil when storing it is no larger.
    static func deflate(_ data: Data) -> Data? {
        guard !data.isEmpty else { return nil }
        let capacity = data.count
        var packed = Data(count: capacity)
        let written = packed.withUnsafeMutableBytes { (target: UnsafeMutableRawBufferPointer) -> Int in
            data.withUnsafeBytes { (source: UnsafeRawBufferPointer) -> Int in
                guard let to = target.bindMemory(to: UInt8.self).baseAddress, let from = source.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_encode_buffer(to, capacity, from, data.count, nil, COMPRESSION_ZLIB)
            }
        }
        // Zero: it didn't fit in the file's own size, so it is stored.
        guard written > 0, written < data.count else { return nil }
        packed.removeSubrange(written...)
        return packed
    }

    static func inflate(_ data: Data, to size: Int) -> Data? {
        guard size > 0 else { return Data() }
        guard !data.isEmpty else { return nil }
        // One byte more than expected, so data that inflates past its stated size is told from data that fits.
        var out = Data(count: size + 1)
        let written = out.withUnsafeMutableBytes { (target: UnsafeMutableRawBufferPointer) -> Int in
            data.withUnsafeBytes { (source: UnsafeRawBufferPointer) -> Int in
                guard let to = target.bindMemory(to: UInt8.self).baseAddress, let from = source.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_decode_buffer(to, size + 1, from, data.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written == size else { return nil }
        out.removeSubrange(size...)
        return out
    }

    /// A zip's two-second local time and its date.
    static func dosStamp(_ date: Date, timeZone: TimeZone) -> (time: UInt16, date: UInt16) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let year: Int = min(max((c.year ?? 1980) - 1980, 0), 127)
        let hour: Int = c.hour ?? 0
        let minute: Int = c.minute ?? 0
        let second: Int = c.second ?? 0
        let month: Int = c.month ?? 1
        let day: Int = c.day ?? 1
        let time: Int = (hour << 11) | (minute << 5) | (second / 2)
        let stamp: Int = (year << 9) | (month << 5) | day
        return (UInt16(truncatingIfNeeded: time), UInt16(truncatingIfNeeded: stamp))
    }

    // MARK: - Reading

    /// The files of an archive, in the order its directory lists them.
    /// Folder entries are left out. Throws for anything that isn't a whole
    /// zip of stored and deflated files whose checksums hold.
    public static func entries(of archive: Data) throws -> [Entry] {
        let bytes = [UInt8](archive)
        let end = try endRecord(in: bytes)
        let count = try Int(u16(bytes, end + 10))
        let size = try Int(u32(bytes, end + 12))
        var at = try Int(u32(bytes, end + 16))
        guard at + size <= end else { throw Failure("the zip's directory runs past its end") }
        var out: [Entry] = []
        out.reserveCapacity(count)
        for _ in 0..<count {
            guard try u32(bytes, at) == 0x0201_4B50 else { throw Failure("the zip's directory is damaged") }
            let flags = try u16(bytes, at + 8)
            let method = try u16(bytes, at + 10)
            let crc = try u32(bytes, at + 16)
            let packedSize = try Int(u32(bytes, at + 20))
            let fullSize = try Int(u32(bytes, at + 24))
            let nameLength = try Int(u16(bytes, at + 28))
            let extraLength = try Int(u16(bytes, at + 30))
            let commentLength = try Int(u16(bytes, at + 32))
            let local = try Int(u32(bytes, at + 42))
            guard at + 46 + nameLength <= bytes.count else { throw Failure("the zip's directory is cut short") }
            let path = String(decoding: bytes[(at + 46)..<(at + 46 + nameLength)], as: UTF8.self)
            at += 46 + nameLength + extraLength + commentLength
            if path.hasSuffix("/") { continue }
            guard flags & 0x0001 == 0 else { throw Failure("\(path) is encrypted") }
            guard fullSize <= largestEntry else { throw Failure("\(path) is larger than a document can be") }

            guard try u32(bytes, local) == 0x0403_4B50 else { throw Failure("\(path) has no file header") }
            let start = try local + 30 + Int(u16(bytes, local + 26)) + Int(u16(bytes, local + 28))
            guard start + packedSize <= bytes.count else { throw Failure("\(path) is cut short") }
            let packed = Data(bytes[start..<(start + packedSize)])
            let data: Data
            switch method {
            case 0:
                guard packedSize == fullSize else { throw Failure("\(path) is stored at the wrong size") }
                data = packed
            case 8:
                guard let inflated = inflate(packed, to: fullSize) else { throw Failure("\(path) doesn't inflate") }
                data = inflated
            default:
                throw Failure("\(path) is packed in a way this app doesn't read")
            }
            guard crc32(data) == crc else { throw Failure("\(path) fails its checksum") }
            out.append(Entry(path: path, data: data))
        }
        return out
    }

    /// Where the end-of-directory record starts: the last one, behind any comment.
    private static func endRecord(in bytes: [UInt8]) throws -> Int {
        guard bytes.count >= 22 else { throw Failure("too short to be a zip") }
        var at = bytes.count - 22
        let lowest = max(0, bytes.count - 22 - Int(UInt16.max))
        while at >= lowest {
            if bytes[at] == 0x50, bytes[at + 1] == 0x4B, bytes[at + 2] == 0x05, bytes[at + 3] == 0x06 {
                let comment = Int(bytes[at + 20]) | Int(bytes[at + 21]) << 8
                if at + 22 + comment == bytes.count { return at }
            }
            at -= 1
        }
        throw Failure("not a zip, or cut short")
    }

    private static func u16(_ bytes: [UInt8], _ at: Int) throws -> UInt16 {
        guard at >= 0, at + 2 <= bytes.count else { throw Failure("the zip is cut short") }
        return UInt16(bytes[at]) | UInt16(bytes[at + 1]) << 8
    }

    private static func u32(_ bytes: [UInt8], _ at: Int) throws -> UInt32 {
        guard at >= 0, at + 4 <= bytes.count else { throw Failure("the zip is cut short") }
        return UInt32(bytes[at]) | UInt32(bytes[at + 1]) << 8 | UInt32(bytes[at + 2]) << 16 | UInt32(bytes[at + 3]) << 24
    }

    // MARK: - CRC-32

    private static let table: [UInt32] = (0..<256).map { index in
        var value = UInt32(index)
        for _ in 0..<8 { value = value & 1 == 1 ? 0xEDB8_8320 ^ (value >> 1) : value >> 1 }
        return value
    }

    /// The zip's checksum of a file's bytes.
    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        data.withUnsafeBytes { buffer in
            for byte in buffer { crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
        }
        return crc ^ 0xFFFF_FFFF
    }
}

private extension Data {
    mutating func append(u16 value: UInt16) {
        append(UInt8(value & 0xFF))
        append(UInt8(value >> 8))
    }

    mutating func append(u32 value: UInt32) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8(value >> 24))
    }
}
