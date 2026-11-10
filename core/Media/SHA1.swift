// OCore — Spec 7 §3, the hash behind derived item uuids.
//
// A plain SHA-1 (FIPS 180-4) for UUIDv5 (RFC 9562 §5.5), so the core needs no
// Apple framework for it, as with SHA-256 (ADR 0005). SHA-1 is used here only
// to name things deterministically, never for integrity.

import Foundation

/// Spec 7 §3 — the SHA-1 that UUIDv5 is built on.
public struct SHA1: Sendable {
    private var state: [UInt32] = [0x67452301, 0xEFCDAB89, 0x98BADCFE, 0x10325476, 0xC3D2E1F0]
    private var buffer: [UInt8] = []
    private var length: UInt64 = 0

    public init() {}

    /// Feed bytes in any chunking.
    public mutating func update(_ bytes: some Sequence<UInt8>) {
        for byte in bytes {
            buffer.append(byte)
            length &+= 1
            if buffer.count == 64 {
                compress(buffer)
                buffer.removeAll(keepingCapacity: true)
            }
        }
    }

    /// The 20-byte digest. Finalizing consumes the padding state.
    public mutating func finalize() -> [UInt8] {
        let bitLength = length &* 8
        buffer.append(0x80)
        while buffer.count % 64 != 56 { buffer.append(0) }
        for shift in stride(from: 56, through: 0, by: -8) {
            buffer.append(UInt8(truncatingIfNeeded: bitLength >> UInt64(shift)))
        }
        var offset = 0
        while offset < buffer.count {
            compress(Array(buffer[offset..<(offset + 64)]))
            offset += 64
        }
        buffer.removeAll()
        var digest: [UInt8] = []
        digest.reserveCapacity(20)
        for word in state {
            digest.append(UInt8(truncatingIfNeeded: word >> 24))
            digest.append(UInt8(truncatingIfNeeded: word >> 16))
            digest.append(UInt8(truncatingIfNeeded: word >> 8))
            digest.append(UInt8(truncatingIfNeeded: word))
        }
        return digest
    }

    /// One-shot digest of a buffer.
    public static func digest(_ data: Data) -> [UInt8] {
        var hasher = SHA1()
        hasher.update(data)
        return hasher.finalize()
    }

    private mutating func compress(_ block: [UInt8]) {
        var w = [UInt32](repeating: 0, count: 80)
        for i in 0..<16 {
            w[i] = UInt32(block[i * 4]) << 24 | UInt32(block[i * 4 + 1]) << 16 | UInt32(block[i * 4 + 2]) << 8 | UInt32(block[i * 4 + 3])
        }
        for i in 16..<80 {
            w[i] = rotl(w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16], 1)
        }
        var a = state[0], b = state[1], c = state[2], d = state[3], e = state[4]
        for i in 0..<80 {
            let f: UInt32
            let k: UInt32
            switch i {
            case 0..<20:
                f = (b & c) | (~b & d)
                k = 0x5A827999
            case 20..<40:
                f = b ^ c ^ d
                k = 0x6ED9EBA1
            case 40..<60:
                f = (b & c) | (b & d) | (c & d)
                k = 0x8F1BBCDC
            default:
                f = b ^ c ^ d
                k = 0xCA62C1D6
            }
            let t = rotl(a, 5) &+ f &+ e &+ k &+ w[i]
            e = d
            d = c
            c = rotl(b, 30)
            b = a
            a = t
        }
        state[0] &+= a
        state[1] &+= b
        state[2] &+= c
        state[3] &+= d
        state[4] &+= e
    }

    private func rotl(_ x: UInt32, _ n: UInt32) -> UInt32 {
        (x << n) | (x >> (32 - n))
    }
}
