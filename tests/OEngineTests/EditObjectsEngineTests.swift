import XCTest
import OCore
import OFormats
@testable import OEngine

/// Spec 11 §13 — "Area 14, the engine's edits", through the engine's one
/// queue and onto disk: Spec 5 §2 — "The engine writes a changed document
/// ... within one second of each change"; "An edit that changes where a file
/// lives does so in the same write: a renumbered object ... renames its
/// file; ... a macro whose edit makes it name a stack or an output moves from
/// the library root to the machine root". On a temporary copy of the fixture.
final class EditObjectsEngineTests: XCTestCase {
    var disk: DiskFixture!
    var library: Library { disk.engine.engine.library }
    var machine: Machine { disk.engine.engine.machine }

    override func setUpWithError() throws {
        disk = try DiskFixture(launch: true)
        disk.settleSaving()
    }

    override func tearDown() {
        disk = nil
    }

    private func reread() throws -> LoadedRoots {
        try LoadedRoots.load(libraryRoot: disk.libraryRoot, machineRoot: disk.machineRoot)
    }

    private func apply(_ texts: String..., file: StaticString = #filePath, line: UInt = #line) {
        for text in texts {
            if let rejection = disk.send(text) { XCTFail("\(text) → \(rejection.reason): \(rejection.message)", file: file, line: line) }
            let before = disk.control.rejections.count
            disk.settle()
            if disk.control.rejections.count > before, let last = disk.control.rejections.last {
                XCTFail("\(text) → \(last.reason): \(last.message)", file: file, line: line)
            }
        }
    }

    private func rejected(_ text: String) -> RejectionReason? {
        let before = disk.control.rejections.count
        disk.send(text)
        disk.settle()
        return disk.control.rejections.count > before ? disk.control.rejections.last?.reason : nil
    }

    /// What is on disk reads back as what the engine holds.
    private func assertOnDisk(file: StaticString = #filePath, line: UInt = #line) throws {
        // "at most once a second": a document written a moment ago takes its next write a second later.
        disk.nextSecond()
        let onDisk = try reread()
        XCTAssertEqual(onDisk.library.channels, library.channels, "channels.json", file: file, line: line)
        XCTAssertEqual(onDisk.library.textStyles, library.textStyles, "text-styles.json", file: file, line: line)
        XCTAssertEqual(onDisk.library.grades, library.grades, "grades.json", file: file, line: line)
        XCTAssertEqual(onDisk.library.transitions, library.transitions, "transitions.json", file: file, line: line)
        XCTAssertEqual(onDisk.library.audioTransitions, library.audioTransitions, "audio-transitions.json", file: file, line: line)
        XCTAssertEqual(onDisk.library.presets, library.presets, "presets/", file: file, line: line)
        XCTAssertEqual(onDisk.library.macros, library.macros, "library macros/", file: file, line: line)
        XCTAssertEqual(onDisk.machine.macros, machine.macros, "machine macros/", file: file, line: line)
        XCTAssertEqual(onDisk.machine.stacks, machine.stacks, "stacks.json", file: file, line: line)
        XCTAssertEqual(onDisk.library.lists.map(\.cues), library.lists.map(\.cues), "lists/", file: file, line: line)
    }

    // MARK: - Writing (Spec 5 §2)

    func test_anEditOfEachObjectReachesItsDocument() throws {
        apply("edit channel 2 label \"Lyrics\"", "edit textstyle 1 size.value 48", "edit grade 1 hue 10", "edit transition 2 ms 750",
              "edit audiotransition 2 offsetMs -200", "edit preset 3 layouts.2.boxes.0.frame.x 0.1", "edit macro 1 label \"Hello\"",
              "edit macro 2 tileLabel \"PRE\"", "edit stack 2 slot 3 opacity 0.5", "edit stack 2 label \"Stage\"")
        XCTAssertEqual(library.channel(2)?.label, "Lyrics")
        XCTAssertEqual(machine.stack(2)?.slots[1].opacity, 0.5)
        try assertOnDisk()
        // A preset and a macro are files of their own, renamed to their label on a save (Spec 1 §5).
        XCTAssertTrue(disk.exists(.library, "macros/001-hello.json"))
        XCTAssertFalse(disk.exists(.library, "macros/001-welcome.json"))
    }

    /// Spec 11 §6 — an output's default stack and transitions, in `outputs.json`.
    func test_anOutputsDefaultStackAndTransitionsAreWritten() throws {
        apply("edit output 2 defaultStack 1", "edit output 1 transitions.blackout 3")
        disk.nextSecond()
        let onDisk = try reread()
        XCTAssertEqual(onDisk.machine.outputs.map(\.defaultStack), machine.outputs.map(\.defaultStack))
        XCTAssertEqual(onDisk.machine.outputs.map(\.transitions), machine.outputs.map(\.transitions))
        XCTAssertEqual(machine.output(1)?.transitions.blackout, 3)
    }

    /// Spec 1 §4 — "every internal reference in the library and the machine
    /// root is rewritten in the same save": a channel's renumber reaches the
    /// stacks, the lists, the media index and the machine's drop channels.
    func test_aChannelsRenumberWritesEveryDocumentItRewrote() throws {
        apply("edit channel 1 renumber 8")
        try assertOnDisk()
        let onDisk = try reread()
        XCTAssertEqual(onDisk.machine.stacks.first?.slots.map(\.channel), [8, 2])
        XCTAssertEqual(onDisk.machine.settings.dropChannels, DropChannels(video: 8, image: 8, audio: nil), "machine.json")
        XCTAssertEqual(onDisk.library.mediaIndex, library.mediaIndex)
        XCTAssertEqual(onDisk.machine.localLists.map(\.cues), machine.localLists.map(\.cues), "the local copy, in the machine root")
    }

    /// Spec 5 §2 — "a renumbered object ... renames its file".
    func test_aPresetsFileFollowsItsNumber() throws {
        apply("edit preset 2 renumber 9")
        XCTAssertTrue(disk.exists(.library, "presets/009-clock.json"))
        XCTAssertFalse(disk.exists(.library, "presets/002-clock.json"))
        XCTAssertEqual(disk.document(.library, "channels.json"), .channels(library.channels), "channel 3 defaults to preset 9 now")

        apply("edit preset 9 swap 3")
        disk.nextSecond()   // preset 9's file was written a moment ago, so its next write is due a second later
        XCTAssertTrue(disk.exists(.library, "presets/003-clock.json"))
        XCTAssertTrue(disk.exists(.library, "presets/009-lower-third.json"))
        XCTAssertFalse(disk.exists(.library, "presets/009-clock.json"))
        XCTAssertFalse(disk.exists(.library, "presets/003-lower-third.json"))
        try assertOnDisk()

        apply("edit preset 3 delete")
        XCTAssertFalse(disk.exists(.library, "presets/003-clock.json"))
        try assertOnDisk()
    }

    /// Two presets with one label swap numbers: each file's new name is the
    /// other's old one, and neither write may take the other's file.
    func test_twoPresetsWithOneLabelSwapWithoutLosingAFile() throws {
        apply("edit preset 2 label \"Look\"", "edit preset 3 label \"Look\"")
        XCTAssertTrue(disk.exists(.library, "presets/002-look.json"))
        XCTAssertTrue(disk.exists(.library, "presets/003-look.json"))
        let clock = library.preset(2)?.uuid
        let lowerThird = library.preset(3)?.uuid
        apply("edit preset 2 swap 3")
        XCTAssertEqual(library.preset(3)?.uuid, clock)
        try assertOnDisk()
        let onDisk = try reread()
        XCTAssertEqual(onDisk.library.preset(2)?.uuid, lowerThird)
        XCTAssertEqual(onDisk.library.preset(3)?.uuid, clock)
        XCTAssertEqual(disk.files(.library, under: "presets").sorted(),
                       ["presets/001-default.json", "presets/002-look.json", "presets/003-look.json", "presets/004-credits.json"])
    }

    /// Spec 5 §2 — "a macro whose edit makes it name a stack or an output
    /// moves from the library root to the machine root (Spec 1 §2)", and back.
    func test_aMacrosFileMovesBetweenTheRoots() throws {
        apply("edit macro 1 insert commands 0 {\"cmd\": \"stack.blackout\", \"stack\": 1, \"state\": \"on\"}")
        XCTAssertFalse(disk.exists(.library, "macros/001-welcome.json"))
        XCTAssertTrue(disk.exists(.machine, "macros/001-welcome.json"))
        XCTAssertNotNil(machine.macro(1))
        try assertOnDisk()

        apply("edit macro 1 remove commands 0")
        XCTAssertTrue(disk.exists(.library, "macros/001-welcome.json"))
        XCTAssertFalse(disk.exists(.machine, "macros/001-welcome.json"))
        try assertOnDisk()
    }

    func test_newObjectsAreWrittenAndDeletedOnesGo() throws {
        apply("edit channel create", "edit stack create", "edit preset create", "edit grade create", "edit textstyle create",
              "edit audiotransition create", "edit macro create", "edit stack 3 insert slots 0 {\"channel\": 4, \"mute\": false, \"opacity\": 1, \"preset\": 5}")
        XCTAssertTrue(disk.exists(.library, "presets/005.json"), "a preset with no label is named by its number")
        XCTAssertTrue(disk.exists(.library, "macros/003.json"))
        try assertOnDisk()
        apply("edit macro 3 delete", "edit preset 5 delete", "edit stack 3 delete", "edit channel 4 delete")
        XCTAssertFalse(disk.exists(.library, "presets/005.json"))
        XCTAssertFalse(disk.exists(.library, "macros/003.json"))
        try assertOnDisk()
    }

    // MARK: - The event, the log and undo (Spec 5 §2, §8)

    func test_theLibraryEventNamesTheObjectAndUndoPutsItBack() throws {
        apply("edit stack 1 slot 2 preset 3")
        let event = try XCTUnwrap(disk.events.all.last)
        XCTAssertEqual(event["cause"], .string("edit"))
        XCTAssertEqual(event["changed"], .array([.object(["object": .string("stack"), "stack": .number(1),
                                                          "paths": .array([.string("slots.1.preset")])])]))
        let line = try XCTUnwrap(disk.commandLog().last?.entry)
        XCTAssertEqual(line.text, "edit stack 1 slot 2 preset 3")
        XCTAssertEqual(line.inverse.flatMap { CommandText.print($0) }, "edit stack 1 slot 2 preset null")

        apply("undo")
        XCTAssertNil(machine.stack(1)?.slots[1].preset)
        XCTAssertEqual(disk.events.all.last?["cause"], .string("undo"))
        try assertOnDisk()
        apply("redo")
        XCTAssertEqual(machine.stack(1)?.slots[1].preset, 3)
        try assertOnDisk()
    }

    /// Spec 5 §8 — one step is one group: a deleted preset and the stack that
    /// named it come back together, with the file.
    func test_undoBringsBackADeletedObjectWithItsFile() throws {
        let preset = library.preset(3)
        apply("edit preset 3 delete")
        XCTAssertFalse(disk.exists(.library, "presets/003-lower-third.json"))
        apply("undo")
        XCTAssertEqual(library.preset(3), preset)
        XCTAssertTrue(disk.exists(.library, "presets/003-lower-third.json"))
        try assertOnDisk()

        apply("edit macro 1 insert commands 0 {\"cmd\": \"stack.blackout\", \"stack\": 1, \"state\": \"on\"}", "undo")
        XCTAssertNotNil(library.macro(1))
        XCTAssertTrue(disk.exists(.library, "macros/001-welcome.json"))
        XCTAssertFalse(disk.exists(.machine, "macros/001-welcome.json"))
    }

    // MARK: - On air, in the engine (Spec 5 §6, check 7)

    func test_whatIsOnAirIsHeldAndAHeldEditIsBlockedWhenItFires() throws {
        apply("channel 2 write text \"Great is Thy faithfulness\"")
        XCTAssertEqual(rejected("edit channel 2 delete"), .onAir)
        XCTAssertEqual(rejected("edit stack 1 renumber 9"), .onAir)
        XCTAssertNotNil(library.channel(2))
        // Spec 5 §2 — "A failing edit doesn't stop the cue": held by a macro it is `blocked`, and the rest runs.
        apply("edit macro 1 commands [{\"channel\": 2, \"cmd\": \"edit.delete\", \"object\": \"channel\"}, {\"cmd\": \"timer.start\", \"timer\": 1}]")
        apply("timer 1 set 5:00", "macro 1")
        XCTAssertNotNil(library.channel(2), "the delete was blocked: channel 2 is on air")
        let ran = disk.commandLog().suffix(3).compactMap(\.entry)
        XCTAssertTrue(ran.contains { $0.text == "edit channel 2 delete" && $0.result == .blocked }, "\(ran.map(\.text))")
        XCTAssertTrue(ran.contains { $0.text == "timer 1 start" && $0.result == .ok }, "\(ran.map(\.text))")
    }
}
