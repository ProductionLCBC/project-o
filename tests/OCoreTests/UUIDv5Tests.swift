import Foundation
import XCTest
@testable import OCore

/// Spec 7 §3 — "An item without a uuid, from a hand-made file, gets one at
/// load: a UUIDv5 with the playlist's uuid as its namespace and, as its name,
/// the UTF-8 text `KIND:KEY:N`." UUIDv5 is SHA-1 based (RFC 9562 §5.5), and
/// OCore carries its own SHA-1 so it stays free of Apple frameworks.
final class UUIDv5Tests: XCTestCase {
    func test_sha1MatchesTheStandardVectors() {
        XCTAssertEqual(SHA256.hex(SHA1.digest(Data())), "da39a3ee5e6b4b0d3255bfef95601890afd80709")
        XCTAssertEqual(SHA256.hex(SHA1.digest(Data("abc".utf8))), "a9993e364706816aba3e25717850c26c9cd0d89d")
        XCTAssertEqual(SHA256.hex(SHA1.digest(Data("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq".utf8))),
                       "84983e441c3bd26ebaae4aa1f95129e5e54670f1")
        XCTAssertEqual(SHA256.hex(SHA1.digest(Data(repeating: UInt8(ascii: "a"), count: 1_000_000))),
                       "34aa973cd4c4daa4f61eeb2bdbad27316534016f")
    }

    func test_incrementalSha1MatchesOneShot() {
        let bytes = Data((0..<5_000).map { UInt8(truncatingIfNeeded: $0 &* 13) })
        var hasher = SHA1()
        var offset = 0
        for chunk in [1, 55, 56, 64, 65, 1000, 2047] {
            hasher.update(bytes[offset..<(offset + chunk)])
            offset += chunk
        }
        hasher.update(bytes[offset...])
        XCTAssertEqual(hasher.finalize(), SHA1.digest(bytes))
    }

    /// RFC 9562 Appendix A.4: the DNS namespace and "www.example.com".
    func test_uuidV5MatchesTheRFCVector() throws {
        let dns = try XCTUnwrap(UUID(uuidString: "6ba7b810-9dad-11d1-80b4-00c04fd430c8"))
        XCTAssertEqual(UUID.v5(namespace: dns, name: "www.example.com").uuidString.lowercased(),
                       "2ed6657d-e927-568b-95e1-2665a8aea6a2")
        XCTAssertEqual(UUID.v5(namespace: dns, name: "python.org").uuidString.lowercased(),
                       "886313e1-3b8a-5372-9b90-0c9aee199e5d")
    }

    func test_uuidV5IsStableAndCarriesItsVersionAndVariant() throws {
        let namespace = try XCTUnwrap(UUID(uuidString: "b1a70000-0000-4000-8000-000000000001"))
        let a = UUID.v5(namespace: namespace, name: "linked:42:0")
        XCTAssertEqual(a, UUID.v5(namespace: namespace, name: "linked:42:0"))
        XCTAssertNotEqual(a, UUID.v5(namespace: namespace, name: "linked:42:1"))
        let text = a.uuidString.lowercased()
        let characters = Array(text)
        XCTAssertEqual(characters[14], "5", "version 5 in the thirteenth hex digit")
        XCTAssertTrue("89ab".contains(characters[19]), "the RFC variant in the seventeenth hex digit: \(text)")
    }
}
