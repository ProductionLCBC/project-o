import Foundation
import XCTest
@testable import OCore

/// Spec 1 §4 — Media: "A media file's identity is the SHA-256 of its bytes,
/// written as `sha256:` followed by 64 lowercase hex characters"; authored
/// documents are `slide:` followed by the UUID. The hash is the format's own
/// so OCore stays free of Apple frameworks (ADR 0005).
final class MediaIdentityTests: XCTestCase {
    typealias F = FixtureLibrary

    func test_sha256MatchesTheStandardVectors() {
        XCTAssertEqual(SHA256.hex(SHA256.digest(Data())), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(SHA256.hex(SHA256.digest(Data("abc".utf8))), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(SHA256.hex(SHA256.digest(Data("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq".utf8))),
                       "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
        XCTAssertEqual(SHA256.hex(SHA256.digest(Data(repeating: UInt8(ascii: "a"), count: 1_000_000))),
                       "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0")
    }

    func test_incrementalHashingMatchesOneShot() {
        let bytes = Data((0..<10_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        var hasher = SHA256()
        var offset = 0
        for chunk in [1, 63, 64, 65, 1000, 4096, 2000, 2711] {
            hasher.update(bytes[offset..<(offset + chunk)])
            offset += chunk
        }
        hasher.update(bytes[offset...])
        XCTAssertEqual(hasher.finalize(), SHA256.digest(bytes))
    }

    func test_mediaIdsAreTheHashOfTheFixtureFiles() throws {
        let dawn = try XCTUnwrap(FileManager.default.contents(atPath: F.mediaRoot.appendingPathComponent("backgrounds/dawn.mp4").path))
        XCTAssertEqual(MediaID.sha256(of: dawn), F.dawn)
        let announcement = try XCTUnwrap(FileManager.default.contents(atPath: F.mediaRoot.appendingPathComponent("local/announcement.png").path))
        XCTAssertEqual(MediaID.sha256(of: announcement), F.announcement)
    }

    func test_idFormsAreValidated() {
        XCTAssertTrue(MediaID.isValid(F.dawn))
        XCTAssertTrue(MediaID.isValid(F.welcomeSlide))
        XCTAssertFalse(MediaID.isValid("sha256:" + String(repeating: "A", count: 64)), "lowercase only")
        XCTAssertFalse(MediaID.isValid("sha256:" + String(repeating: "a", count: 63)))
        XCTAssertFalse(MediaID.isValid("sha256:" + String(repeating: "g", count: 64)))
        XCTAssertFalse(MediaID.isValid("md5:" + String(repeating: "a", count: 64)))
        XCTAssertFalse(MediaID.isValid("slide:not-a-uuid"))
        XCTAssertFalse(MediaID.isValid(""))
        XCTAssertEqual(MediaID.slide(F.slideUuid), F.welcomeSlide)
        XCTAssertTrue(MediaID.isSlide(F.welcomeSlide))
        XCTAssertFalse(MediaID.isSlide(F.dawn))
    }
}
