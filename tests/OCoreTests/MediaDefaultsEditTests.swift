import Foundation
import XCTest
@testable import OCore

/// Spec 5 §3 and §6 — edits of a media item's defaults, which Spec 7 §7
/// gives Area 8. Spec 8 §11, Defaults: "Each default edits the index that
/// holds the entry; a library item's defaults are refused with
/// `readOnlyLibrary` on a `readOnlyMasters` machine." Spec 8 §5 — a
/// `defaults.trimInMs` edit gives the poster a new name in the same edit.
final class MediaDefaultsEditTests: XCTestCase {
    typealias F = FixtureLibrary
    var dawnHex: String { String(F.dawn.dropFirst(7)) }

    func test_eachDefaultEditsTheIndexThatHoldsTheEntry() throws {
        var edits = Edits()
        let outcome = try XCTUnwrap(edits.apply("edit media \(F.dawn) defaults.gain -6").first)
        XCTAssertEqual(edits.library.mediaIndex.entry(F.dawn)?.defaults.gain, -6)
        XCTAssertEqual(outcome.inverse, EditCommand(.media(F.dawn), .set(path: "defaults.gain", value: .null)), "set back to what it was")
        XCTAssertEqual(outcome.changes, [LibraryChange(object: "media", address: ["media": .string(F.dawn)], paths: ["defaults.gain"])])
        // The machine's own media: the machine index.
        edits.apply("edit media \(F.announcement) defaults.syncOffsetMs 40")
        XCTAssertEqual(edits.machine.mediaLocal.entry(F.announcement)?.defaults.syncOffsetMs, 40)
        // Every field, typed.
        edits.apply("edit media \(F.dawn) defaults.loop false")
        edits.apply("edit media \(F.dawn) defaults.grade 1")
        edits.apply("edit media \(F.dawn) defaults.defaultChannel 2")
        edits.apply("edit media \(F.dawn) defaults.trimOutMs 1800")
        let defaults = try XCTUnwrap(edits.library.mediaIndex.entry(F.dawn)?.defaults)
        XCTAssertEqual(defaults, MediaDefaults(trimInMs: nil, trimOutMs: 1800, loop: false, gain: -6, grade: 1, syncOffsetMs: nil, defaultChannel: 2))
        // unset puts a field back to none; a value equal to the current one is a noop.
        let unset = try XCTUnwrap(edits.apply("edit media \(F.dawn) unset defaults.grade").first)
        XCTAssertNil(edits.library.mediaIndex.entry(F.dawn)?.defaults.grade)
        XCTAssertEqual(unset.inverse, EditCommand(.media(F.dawn), .set(path: "defaults.grade", value: .number(1))))
        XCTAssertTrue(try XCTUnwrap(edits.apply("edit media \(F.dawn) defaults.gain -6").first).isNoop)
    }

    /// Spec 8 §5 — "The new in-point gives the poster a new name", in the same
    /// edit; its inverse names the old one again.
    func test_aTrimInEditNamesTheNewPoster() throws {
        var edits = Edits()
        let outcome = try XCTUnwrap(edits.apply("edit media \(F.dawn) defaults.trimInMs 1500").first)
        XCTAssertEqual(edits.library.mediaIndex.entry(F.dawn)?.poster, ".posters/\(dawnHex)-1500.png")
        XCTAssertEqual(outcome.changes.first?.paths, ["defaults.trimInMs", "poster"])
        let inverse = try XCTUnwrap(outcome.inverse)
        _ = try edits.run(inverse).get()
        XCTAssertEqual(edits.library.mediaIndex.entry(F.dawn)?.poster, ".posters/\(dawnHex)-0.png")
        XCTAssertNil(edits.library.mediaIndex.entry(F.dawn)?.defaults.trimInMs)
    }

    /// Spec 5 §6 — the path, the value's type and range, the references,
    /// and library mode.
    func test_whatTheDefaultsEditRefuses() {
        var edits = Edits()
        XCTAssertEqual(edits.refuse("edit media \(F.dawn) path \"elsewhere.mp4\"")?.reason, .readOnlyField, "read from the file")
        XCTAssertEqual(edits.refuse("edit media \(F.dawn) defaults.colour 3")?.reason, .unknownPath)
        XCTAssertEqual(edits.refuse("edit media \(F.dawn) defaults.gain 61")?.reason, .badValue, "within ±60 dB")
        XCTAssertEqual(edits.refuse("edit media \(F.dawn) defaults.syncOffsetMs 1001")?.reason, .badValue, "within ±1000 ms")
        XCTAssertEqual(edits.refuse("edit media \(F.dawn) defaults.trimInMs -1")?.reason, .badValue)
        XCTAssertEqual(edits.refuse("edit media \(F.dawn) defaults.trimInMs 2500")?.reason, .badValue, "past dawn's 2000 ms")
        XCTAssertEqual(edits.refuse("edit media \(F.dawn) defaults.trimInMs 1.5")?.reason, .badValue)
        XCTAssertEqual(edits.refuse("edit media \(F.dawn) defaults.loop 1")?.reason, .badValue)
        XCTAssertEqual(edits.refuse("edit media \(F.dawn) defaults.grade 99")?.reason, .unknownReference)
        XCTAssertEqual(edits.refuse("edit media \(F.dawn) defaults.defaultChannel 99")?.reason, .unknownReference)
        edits.apply("edit media \(F.dawn) defaults.trimOutMs 1000")
        XCTAssertEqual(edits.refuse("edit media \(F.dawn) defaults.trimInMs 1200")?.reason, .badValue, "the out-point before the in-point")
        XCTAssertEqual(edits.refuse("edit media \(F.dawn) delete")?.reason, .badValue, "media delete is the media command")
        // "a library item's defaults are refused with `readOnlyLibrary` on a `readOnlyMasters` machine".
        var readOnly = Edits(writable: false)
        XCTAssertEqual(readOnly.refuse("edit media \(F.dawn) defaults.gain -3")?.reason, .readOnlyLibrary)
        readOnly.apply("edit media \(F.announcement) defaults.gain -3")
        XCTAssertEqual(readOnly.machine.mediaLocal.entry(F.announcement)?.defaults.gain, -3, "the machine's own media passes")
    }
}
