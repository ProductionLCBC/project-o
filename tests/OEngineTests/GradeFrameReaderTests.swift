import CoreVideo
import Foundation
import OCore
import XCTest
@testable import OEngine

/// Spec 11 §3 as corrected 2026-11-26 (G-43) — "for a video with `atMs`, its frame at that time from the item's
/// start, its last frame past its end"; "A grade's video frames come from one reader the job keeps open, reading
/// forward: pictures of the same time share its frame, a time before the last one read, more than two seconds after
/// it, or another item starts it again, and it closes after ten seconds unused." The fixture clips carry their frame
/// number in bars along the top (`FixtureMedia`); at 30 fps frame 45 starts at 1500 ms. AVFoundation runs on the
/// bench Mac, not the hosted runner.
final class GradeFrameReaderTests: XCTestCase {
    func index(_ reader: GradeFrameReader, _ url: URL, _ ms: Int, file: StaticString = #filePath, line: UInt = #line) throws -> Int? {
        let buffer = try XCTUnwrap(reader.frame(of: url, atMs: ms), "a frame at \(ms) ms", file: file, line: line)
        return FixtureMedia.frameIndex(in: buffer)
    }

    /// "its frame at that time": the frame showing then, the last to start at or before it.
    func test_theFrameShowingAtEachTimeReadingForwardOnOneReader() throws {
        let clip = try ClipFixtures.url(for: ClipFixtures.h264LongGOP)
        let reader = GradeFrameReader()
        for (ms, expected) in [(0, 0), (1500, 45), (1510, 45), (1999, 59), (2000, 60), (2100, 63)] {
            XCTAssertEqual(try index(reader, clip, ms), expected, "at \(ms) ms")
        }
        XCTAssertEqual(reader.opened, 1, "every time later than the last, and within two seconds of it")
        XCTAssertEqual(try index(reader, clip, 2100), 63, "the same time again")
        XCTAssertEqual(reader.opened, 1)
    }

    /// "a time before the last one read, more than two seconds after it, or another item starts it again".
    func test_anEarlierTimeAJumpOrAnotherItemStartsAgain() throws {
        let clip = try ClipFixtures.url(for: ClipFixtures.h264LongGOP)
        let other = try ClipFixtures.url(for: ClipFixtures.h264)
        let reader = GradeFrameReader()
        XCTAssertEqual(try index(reader, clip, 2000), 60)
        XCTAssertEqual(try index(reader, clip, 500), 15)
        XCTAssertEqual(reader.opened, 2, "earlier")
        XCTAssertEqual(try index(reader, clip, 3000), 90)
        XCTAssertEqual(reader.opened, 3, "more than two seconds on")
        XCTAssertEqual(try index(reader, other, 1000), 30)
        XCTAssertEqual(reader.opened, 4, "another item")
    }

    /// "its last frame past its end": a four-second clip at 30 fps ends on frame 119.
    func test_pastItsEndItsLastFrame() throws {
        let clip = try ClipFixtures.url(for: ClipFixtures.h264LongGOP)
        let reader = GradeFrameReader()
        XCTAssertEqual(try index(reader, clip, 600_000), 119)
        XCTAssertEqual(try index(reader, clip, 3990), 119)
        XCTAssertEqual(try index(reader, clip, 3900), 117, "an earlier time, read again")
    }

    /// "it closes after ten seconds unused".
    func test_itClosesAfterTenSecondsUnused() throws {
        let clip = try ClipFixtures.url(for: ClipFixtures.h264)
        let reader = GradeFrameReader()
        XCTAssertNotNil(reader.frame(of: clip, atMs: 0))
        XCTAssertTrue(reader.isOpen)
        let used = reader.lastUsedNs
        reader.closeIfIdle(nowNs: used + 9_000_000_000)
        XCTAssertTrue(reader.isOpen)
        reader.closeIfIdle(nowNs: used + 10_000_000_000)
        XCTAssertFalse(reader.isOpen)
        XCTAssertEqual(try index(reader, clip, 0), 0, "and opens again when asked")
        XCTAssertEqual(reader.opened, 2)
    }

    /// A file that isn't a video gives no frame, and no trap.
    func test_noFrameFromAFileThatIsNotAVideo() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("oengine-gradeframes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("not-a-video.mp4")
        try Data("not a video".utf8).write(to: file)
        let reader = GradeFrameReader()
        XCTAssertNil(reader.frame(of: file, atMs: 0))
        XCTAssertNil(reader.frame(of: folder.appendingPathComponent("gone.mp4"), atMs: 0))
    }
}
