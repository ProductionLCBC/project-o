import Foundation
import OCore
import OFormats
import XCTest
@testable import OEngine

/// Spec 8 §5, §11 — the defaults edits in the engine, on a temporary copy of
/// the fixture. Posters: "A `defaults.trimInMs` edit gives a new poster under
/// a new name, and only the thumbnails of lists using the item redraw."
/// Resolver: "A write of a replaced id takes the defaults of the item it
/// resolves to, and a later edit of that item's defaults reaches it."
final class MediaDefaultsEngineTests: XCTestCase {
    typealias E = EngineFixtures

    func test_aTrimInEditGivesANewPosterAndOnlyTheListsUsingTheItemRedraw() throws {
        let media = try MediaFixture()
        let hex = String(E.dawn.dropFirst(7))
        func version(_ number: Int) throws -> String {
            let list = try XCTUnwrap(media.control.library.list(number: number))
            return LibraryVersion.hash(library: media.control.library, machine: media.control.machine, list: list,
                                       missing: media.control.missing, posters: media.control.posterFiles)
        }
        let (list42, list7) = (try version(42), try version(7))
        media.library.clear()
        XCTAssertNil(media.run("edit media \(E.dawn) defaults.trimInMs 1500"))
        // The edit names the new poster at once; a machine that receives it shows none for a moment.
        let event = try XCTUnwrap(media.library.all.first { $0["cause"] == .string("edit") })
        XCTAssertEqual(event["changed"], .array([.object(["object": .string("media"), "media": .string(E.dawn),
                                                         "paths": .array([.string("defaults.trimInMs"), .string("poster")])])]))
        XCTAssertEqual(media.control.library.mediaIndex.entry(E.dawn)?.poster, ".posters/\(hex)-1500.png")
        // The worker makes the frame at the new in-point and its tile; the old ones go.
        XCTAssertEqual(media.frames.asked.last, FakeMediaFrames.Ask(file: "dawn.mp4", inMs: 1500, alpha: false))
        XCTAssertTrue(media.exists(.mediaRoot, ".posters/\(hex)-1500.png"))
        XCTAssertFalse(media.exists(.mediaRoot, ".posters/\(hex)-0.png"))
        XCTAssertTrue(media.tiles.contains("\(hex)-1500.png"))
        XCTAssertFalse(media.tiles.contains("\(hex)-0.png"))
        XCTAssertNotEqual(try version(42), list42, "list 42 writes dawn: its thumbnails redraw")
        XCTAssertEqual(try version(7), list7, "list 7 doesn't: none of its do")
        // A write of dawn now starts at its new in-point.
        XCTAssertNil(media.run("channel 1 write media \(E.dawn)"))
        XCTAssertEqual(media.engine.state.channels[1]?.content.media?.inMs, 1500)
    }

    func test_aLaterEditOfTheDefaultsReachesAWriteOfAReplacedId() throws {
        let media = try MediaFixture()
        XCTAssertNil(media.run("media replace \(E.mountains) \(E.dawn)"))
        let ref = try XCTUnwrap(media.control.library.list(number: 7)?.cues[0].commands[0].command.mediaRef)
        XCTAssertEqual(ref, E.dawn, "list 7's cue was rewritten")
        // A write still naming mountains, as a local copy or another machine would.
        XCTAssertNil(media.run("channel 2 write media \(E.mountains)"))
        XCTAssertEqual(media.engine.state.channels[2]?.content.media?.gainOverride, nil, "dawn's defaults: no gain")
        XCTAssertEqual(media.engine.state.channels[2]?.content.media?.missing, false, "it plays dawn")
        XCTAssertNil(media.run("edit media \(E.dawn) defaults.gain -9"))
        XCTAssertNil(media.run("channel 2 write media \(E.mountains)"))
        XCTAssertEqual(media.engine.state.channels[2]?.content.media?.gainOverride, -9, "the edit reaches the next write")
    }
}
