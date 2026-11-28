import Foundation
import XCTest
@testable import OCore

/// Spec 5 §11 — "Rejections. A table with one row per rejection code: each
/// yields `rejected` with that code, nothing changes, and nothing is logged."
/// The codes the edits Areas 9 and 14 build can give (Spec 7 §7);
/// `conflict` comes with Area 12's undo, `noTrash` with Area 8, `diskFull`
/// with Area 12, `noPasscode` and `keychain` with Area 18. Nothing logged:
/// EditGroupTests, at the runner.
final class EditRejectionTests: XCTestCase {
    typealias F = FixtureLibrary

    static func u(_ uuid: UUID) -> String { uuid.uuidString.lowercased() }

    struct Row {
        let code: RejectionReason
        let text: String
        let setUp: (inout Edits) -> Void
        let line: UInt
    }

    static func row(_ code: RejectionReason, _ text: String, line: UInt = #line, setUp: @escaping (inout Edits) -> Void = { _ in }) -> Row {
        Row(code: code, text: text, setUp: setUp, line: line)
    }

    static var rows: [Row] {
        let c1 = u(F.list42Cues[0])
        let p = u(F.playlistUuid)
        let a = u(F.archivedSundayUuid)
        return [
            row(.unknownObject, "edit list 99 title \"x\""),
            row(.unknownObject, "edit list 42 cue \(u(F.uuid("ffff", 1))) label \"x\""),
            row(.unknownObject, "edit playlist \(u(F.uuid("ffff", 2))) title \"x\""),
            row(.unknownObject, "edit folder \"Easter\" delete"),
            row(.unknownPath, "edit list 42 color \"red\""),
            row(.readOnlyField, "edit list 42 version 99"),
            row(.badValue, "edit list 42 trackThrough \"yes\""),
            row(.unknownReference, "edit list 42 cue \(c1) insert commands 0 { \"cmd\": \"macro.run\", \"macro\": 99 }"),
            row(.duplicate, "edit list 7 renumber 42"),
            row(.duplicate, "edit playlist create \"sunday\""),
            row(.danglingReferences, "edit list 42 renumber 60") { edits in
                edits.machine.keys.append(KeyBinding(device: "keyboard", key: "f6", command: .listCue(list: 60, cue: 1)))
            },
            row(.onAir, "edit playlist \(p) archived true") { edits in
                var state = ShowState()
                state.pointer = LivePointer(playlist: F.playlistUuid)
                edits.context.state = state
            },
            row(.archived, "edit playlist \(a) title \"x\""),
            row(.notEmpty, "edit folder \"Hymns\" delete"),
            row(.cycle, "edit list 42 cue \(c1) insert commands 0 { \"cmd\": \"macro.run\", \"macro\": 1 }") { edits in
                edits.library.macros[0].commands.append(GuardedCommand(.macro(1)))
            },
            row(.operatorLock, "edit playlist \(p) title \"x\"") { edits in edits.machine.settings.operatorLock.enabled = true },
            row(.readOnlyLibrary, "edit list 42 title \"x\"") { edits in edits.machine.settings.libraryMode = .readOnlyMasters },
            row(.protected, "edit preset 1 delete"),
            row(.protected, "edit transition 2 renumber 9"),
            row(.onAir, "edit stack 1 delete") { edits in edits.play() },
            row(.onAir, "edit channel 2 renumber 9") { edits in edits.play("channel 2 write text \"Great is Thy faithfulness\"") },
            row(.duplicate, "edit stack 1 insert slots 0 { \"channel\": 2, \"mute\": false, \"opacity\": 1, \"preset\": null }"),
            row(.unknownPath, "edit preset 3 layouts.2.boxes.4.frame.x 0.1"),
            row(.readOnlyField, "edit transition 2 builtIn false"),
            row(.notInV1, "edit output 1 label \"Wall\""),
            row(.notInV1, "edit playlist \(p) insert items 0 { \"kind\": \"local\", \"localUuid\": \"\(u(F.localCopyUuid))\" }"),
        ]
    }

    func test_oneRowPerCodeAndNothingChanges() {
        var codes: Set<RejectionReason> = []
        for row in Self.rows {
            var edits = Edits()
            row.setUp(&edits)
            XCTAssertEqual(edits.refuse(row.text, line: row.line)?.reason, row.code, row.text, line: row.line)
            codes.insert(row.code)
        }
        XCTAssertEqual(codes, [.unknownObject, .unknownPath, .readOnlyField, .badValue, .unknownReference, .duplicate,
                               .danglingReferences, .protected, .onAir, .archived, .notEmpty, .cycle, .operatorLock, .readOnlyLibrary,
                               .notInV1])
    }

    /// Spec 5 §6 — "The first failure rejects it": lock and library mode come
    /// first, before the object is even looked up.
    func test_lockAndLibraryModeComeFirst() {
        var locked = Edits()
        locked.machine.settings.operatorLock.enabled = true
        XCTAssertEqual(locked.refuse("edit list 99 title \"x\"")?.reason, .operatorLock)
        XCTAssertEqual(locked.refuse("edit channel 2 label \"x\"")?.reason, .operatorLock)
        var readOnly = Edits(writable: false)
        XCTAssertEqual(readOnly.refuse("edit list 99 title \"x\"")?.reason, .readOnlyLibrary)
        XCTAssertEqual(readOnly.refuse("edit folder \"Worship\" create")?.reason, .readOnlyLibrary)
        // Spec 5 §7 — "Machine-level edits pass": playlists are the machine's.
        readOnly.apply("edit playlist \(Self.u(F.playlistUuid)) title \"Sunday Morning\"")
        XCTAssertEqual(readOnly.sunday.title, "Sunday Morning")
    }

    /// Spec 7 §7 as Spec 11 corrected it — "Area 17 for settings (the rest of
    /// outputs, audio outputs, keys and the machine)": rejected with
    /// `notInV1`, naming the area, until it lands. Areas 8 and 14 have built
    /// theirs (MediaDefaultsEditTests; EditChannelTests and its neighbors).
    func test_theSettingsEditsWaitForArea17() {
        var edits = Edits()
        let expected: [(String, String)] = [
            ("edit output 1 colorRange limited", "Area 17"), ("edit output 1 delete", "Area 17"),
            ("edit audiooutput 1 delayMs 40", "Area 17"), ("edit keys keyboard \"space\" command null", "Area 17"),
            ("edit machine timers 8", "Area 17"),
        ]
        for (text, area) in expected {
            let rejection = edits.refuse(text)
            XCTAssertEqual(rejection?.reason, .notInV1, text)
            XCTAssertTrue(rejection?.message.contains(area) == true, "\(text): \(rejection?.message ?? "")")
        }
        // What Area 14 opened applies.
        for text in ["edit channel 2 label \"x\"", "edit preset 3 duplicate 9", "edit textstyle 1 size.value 48",
                     "edit stack 2 slot 3 remove", "edit output 1 defaultStack 2"] {
            edits.apply(text)
        }
    }
}
