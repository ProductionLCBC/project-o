import Foundation
import XCTest
@testable import OCore

/// Spec 5 §11 — "Inverse round trip. For every verb on every object type in
/// the fixtures, apply an edit and then its inverse. Every document is
/// byte-identical to before, apart from a list's `version` and its versions
/// files." Area 9's types: lists and their cues, folders, playlists and their
/// items (Spec 7 §7). Versions change only when a document is written, which
/// these in-memory edits never do.
final class EditInverseTests: XCTestCase {
    typealias F = FixtureLibrary

    static func u(_ uuid: UUID) -> String { uuid.uuidString.lowercased() }
    static var c1: String { u(F.list42Cues[0]) }
    static var c2: String { u(F.list42Cues[1]) }
    static var c3: String { u(F.list42Cues[2]) }
    static var c4: String { u(F.list42Cues[3]) }
    static var d1: String { u(F.list7Cues[0]) }
    static var d2: String { u(F.list7Cues[1]) }
    static var sunday: String { u(F.playlistUuid) }
    static var night: String { u(F.sundayNightUuid) }
    static var archived: String { u(F.archivedSundayUuid) }
    static func item(_ n: Int) -> String { u(F.sundayItems[n]) }

    func test_listEdits() {
        assertRoundTrip(["edit list 42 title \"Great Is Thy Faithfulness (1923)\""])
        assertRoundTrip(["edit list 42 author \"T. O. Chisholm\""])
        assertRoundTrip(["edit list 42 copyright \"Hope Publishing\""])
        assertRoundTrip(["edit list 42 ccli \"0\""])
        assertRoundTrip(["edit list 7 trackThrough false"])
        assertRoundTrip(["edit list 57 create"])
        assertRoundTrip(["edit list 57 create folder \"Hymns\" { \"title\": \"Be Thou My Vision\" }"])
        assertRoundTrip(["edit list create"])
        assertRoundTrip(["edit list 42 delete"])
        assertRoundTrip(["edit list 7 delete"])
        assertRoundTrip(["edit list 42 renumber 43"])
        assertRoundTrip(["edit list 42 swap 7"])
        assertRoundTrip(["edit list 42 duplicate"])
        assertRoundTrip(["edit list 42 duplicate 57"])
        assertRoundTrip(["edit list 42 folder \"Christmas\""])
        assertRoundTrip(["edit list 42 folder \"\""])
        assertRoundTrip(["edit list 7 folder \"Hymns\""])
        assertRoundTrip(["edit list 42 insert cues 2 { \"label\": \"Verse 2\", \"section\": \"Verse 2\" }"])
    }

    func test_cueEdits() {
        let c1 = Self.c1, c2 = Self.c2, c3 = Self.c3, c4 = Self.c4
        assertRoundTrip(["edit list 42 cue \(c1) label \"Verse 1a\""])
        assertRoundTrip(["edit list 42 cue \(c1) section null"])
        assertRoundTrip(["edit list 42 cue \(c1) note \"Lights up\""])
        assertRoundTrip(["edit list 42 cue \(c1) trigger { \"ms\": 4000, \"type\": \"time\" }"])
        assertRoundTrip(["edit list 7 cue \(Self.d1) trigger { \"type\": \"go\" }"])
        assertRoundTrip(["edit list 42 cue \(c3) advanceAfterMs null"])
        assertRoundTrip(["edit list 42 cue \(c2) commands []"])
        assertRoundTrip(["edit list 42 cue \(c1) commands.1 { \"channel\": 2, \"cmd\": \"channel.clear\" }"])
        assertRoundTrip(["edit list 42 cue \(c2) insert commands 0 { \"cmd\": \"macro.run\", \"macro\": 1 }"])
        assertRoundTrip(["edit list 42 cue \(c1) remove commands 0"])
        assertRoundTrip(["edit list 42 cue \(c1) move commands 1 0"])
        assertRoundTrip(["edit list 42 cue \(c2) remove"])
        assertRoundTrip(["edit list 42 cue \(c1) move 3"])
        assertRoundTrip(["edit list 42 cue \(c4) duplicate"])
        assertRoundTrip(["edit list 42 cue \(c1) section duplicate"])
        assertRoundTrip(["edit list 42 cue \(c1) section move 1"])
        assertRoundTrip(["edit list 42 cue \(c4) section move 0"])
        assertRoundTrip(["edit list 42 cue \(c2) section remove"])
        assertRoundTrip(["edit list 42 cue \(c2) channel 2 write text \"There is no shadow\""])
        assertRoundTrip(["edit list 42 cue \(c2) channel 2 clear"])
        assertRoundTrip(["edit list 42 cue \(c2) channel 2 hold"])
        assertRoundTrip(["edit list 42 cue \(c2) channel 1 grade 1 hold"])
        assertRoundTrip(["edit list 42 cue \(c4) channel 2 hold"])
        assertRoundTrip(["edit list 7 cue \(Self.d2) channel 1 hold"])
    }

    func test_folderEdits() {
        assertRoundTrip(["edit folder \"Worship\" create"])
        assertRoundTrip(["edit folder \"Worship\" create", "edit folder \"Worship/Hymns\" create"])
        assertRoundTrip(["edit folder \"Hymns\" rename \"Songs\""])
        assertRoundTrip(["edit folder \"Hymns\" rename \"Christmas/Hymns\""])
        assertRoundTrip(["edit folder \"Hymns\" rename \"HYMNS\""])
        assertRoundTrip(["edit folder \"Christmas\" delete"])
    }

    func test_playlistAndItemEdits() {
        let p = Self.sunday
        assertRoundTrip(["edit playlist create \"Easter\""])
        assertRoundTrip(["edit playlist \(p) title \"Sunday Morning\""])
        assertRoundTrip(["edit playlist \(p) title \"SUNDAY\""])
        assertRoundTrip(["edit playlist \(p) serviceDate null"])
        assertRoundTrip(["edit playlist \(Self.night) serviceTime \"09:30\""])
        assertRoundTrip(["edit playlist \(Self.night) archived true"])
        assertRoundTrip(["edit playlist \(Self.archived) archived false"])
        assertRoundTrip(["edit playlist \(p) duplicate \"Sunday Evening\""])
        assertRoundTrip(["edit playlist \(p) archive"])
        assertRoundTrip(["edit playlist \(p) delete"])
        assertRoundTrip(["edit playlist \(Self.archived) delete"])
        assertRoundTrip(["edit playlist \(p) insert items 2 { \"kind\": \"header\", \"label\": \"Worship\" }"])
        assertRoundTrip(["edit playlist \(p) insert items 5 { \"kind\": \"linked\", \"list\": 7 }"])
        assertRoundTrip(["edit playlist \(p) item \(Self.item(1)) remove"])
        assertRoundTrip(["edit playlist \(p) item \(Self.item(2)) remove"])
        assertRoundTrip(["edit playlist \(p) item \(Self.item(0)) move 3"])
        assertRoundTrip(["edit playlist \(p) item \(Self.item(0)) label \"Gathering\""])
    }

    /// A noop applies nothing and has no inverse (Spec 5 §4: "a value equal to
    /// the current one is a `noop`").
    func test_aNoopHasNoInverse() {
        var edits = Edits()
        let before = (edits.library, edits.machine)
        for text in ["edit list 42 title \"Great Is Thy Faithfulness\"", "edit list 42 folder \"Hymns\"",
                     "edit list 42 cue \(Self.c1) move 0", "edit list 42 cue \(Self.c4) section move 3",
                     "edit list 42 cue \(Self.c2) channel 2 write text \"There is no shadow\\nof turning with Thee\"",
                     "edit playlist \(Self.sunday) title \"Sunday\"", "edit folder \"Hymns\" rename \"Hymns\""] {
            let outcomes = edits.apply(text)
            XCTAssertEqual(outcomes.count, 1, text)
            XCTAssertTrue(outcomes.allSatisfy(\.isNoop), text)
            XCTAssertTrue(outcomes.allSatisfy { $0.changes.isEmpty && $0.structure.isEmpty }, text)
        }
        XCTAssertEqual(edits.library, before.0)
        XCTAssertEqual(edits.machine, before.1)
    }
}
