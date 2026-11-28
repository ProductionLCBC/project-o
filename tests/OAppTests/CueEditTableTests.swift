import Foundation
import XCTest
import OCore
@testable import OApp

/// Spec 11 §13, "Area 14, the Cues page" — "a table of each control and the
/// edit or group it sends", read in the canonical text the log will hold
/// (Spec 5 §4), against the recorded fixture's lists 42 and 7.
final class CueEditTableTests: XCTestCase {
    private func text(_ sending: Sending?, file: StaticString = #filePath, line: UInt = #line) -> [String] {
        guard let sending else { return [] }
        XCTAssertEqual(sending.source, .ui, file: file, line: line)
        XCTAssertEqual(sending.group, sending.commands.count > 1, file: file, line: line)
        // What is sent reads back as what was meant (`parse(print(x)) == x`).
        for command in sending.commands {
            guard let printed = CommandText.print(command) else {
                XCTFail("\(command.cmd) doesn't print", file: file, line: line)
                continue
            }
            XCTAssertEqual(try? CommandText.parse(printed).get().command, command, printed, file: file, line: line)
        }
        return sending.text
    }

    private func list42() throws -> List { try Recorded.list("list-42").list }
    private func list7() throws -> List { try Recorded.list("list-7").list }
    private func id(_ cue: Cue) -> String { cue.uuid.uuidString.lowercased() }

    // MARK: - Write, Clear, Hold (Spec 11 §4, "The Channel column")

    func test_clearAndHoldKeepTheAttributeWritesAndATrackRider() throws {
        let list = try list42()
        let verse = list.cues[0], chorus = list.cues[3]
        // Cue 1 writes media on channel 1 with a transition for this cue only: "drops its `once` riders".
        XCTAssertEqual(text(CueEdits.hold(channel: 1, cue: verse, list: 42)), ["edit list 42 cue \(id(verse)) channel 1 hold"])
        XCTAssertEqual(text(CueEdits.clear(channel: 1, cue: verse, list: 42)), ["edit list 42 cue \(id(verse)) channel 1 clear"])
        // The chorus's text has an audio transition for this cue only and a tracked grade: "Leaving a
        // write for Clear or Hold keeps each of its `track` riders as a standalone attribute write".
        XCTAssertEqual(text(CueEdits.clear(channel: 2, cue: chorus, list: 42)), ["edit list 42 cue \(id(chorus)) channel 2 grade 1 2.0 clear"])
        XCTAssertEqual(text(CueEdits.hold(channel: 2, cue: chorus, list: 42)), ["edit list 42 cue \(id(chorus)) channel 2 grade 1 2.0 hold"])
        // Channel 1 holds there with a gain write: "keeping the channel's standalone attribute writes".
        XCTAssertEqual(text(CueEdits.clear(channel: 1, cue: chorus, list: 42)), ["edit list 42 cue \(id(chorus)) channel 1 gain -6 clear"])
        // Nothing is sent for the state a cell already has.
        XCTAssertNil(CueEdits.hold(channel: 1, cue: chorus, list: 42))
        XCTAssertNil(CueEdits.hold(channel: 3, cue: verse, list: 42))
        XCTAssertNil(CueEdits.clear(channel: 2, cue: try list7().cues[2], list: 7))
    }

    func test_aNewPickKeepsTheRidersADropKeepsAndAnEditOfTheSameContentKeepsThemAll() throws {
        let list = try list42()
        let verse = list.cues[0], second = list.cues[1], chorus = list.cues[3]
        // "Write on a held or cleared cell ... writes nothing until something is chosen": then one edit.
        XCTAssertEqual(text(CueEdits.write(.text(fields: ["body": "Hello"]), channel: 1, cue: second, list: 42)),
                       ["edit list 42 cue \(id(second)) channel 1 write text \"Hello\""])
        // The same write edited, its body or its other fields: every rider stays.
        XCTAssertEqual(text(CueEdits.write(.text(fields: ["body": "New", "title": "T"]), channel: 2, cue: chorus, list: 42)),
                       ["edit list 42 cue \(id(chorus)) channel 2 write text body \"New\" title \"T\" audiotransition 2 once grade 1 2.0 track"])
        // Another kind of content is a new pick: "keeps its transition and audio-transition riders and the attribute writes".
        XCTAssertEqual(text(CueEdits.write(.text(fields: ["body": "Over"]), channel: 1, cue: verse, list: 42)),
                       ["edit list 42 cue \(id(verse)) channel 1 write text \"Over\" transition 2 1.0 once"])
        // Another media item is a new pick too, with "the item's default grade as a `grade G once` rider".
        let ocean = try XCTUnwrap(try Recorded.media().first { $0.id.hasPrefix("sha256:9f2c") })
        XCTAssertEqual(text(CueEdits.pick(media: ocean.id, defaultGrade: 1, channel: 1, cue: verse, list: 42)),
                       ["edit list 42 cue \(id(verse)) channel 1 write media \(ocean.id) transition 2 1.0 once grade 1 once"])
        // Nothing is sent for the content a cell already has.
        XCTAssertNil(CueEdits.write(.text(fields: ["body": "There is no shadow\nof turning with Thee"]), channel: 2, cue: second, list: 42))
    }

    func test_trimAndLoopAreOverridesOnTheWrite() throws {
        let verse = try list42().cues[0]
        guard case .write(.media(let item), _) = CueSays.about(1, in: verse).state else { return XCTFail("cue 1 writes media") }
        // "for the chosen item its trim (in and out) and loop as overrides on the write (choice A-6)".
        var trimmed = item
        trimmed.inMs = 500
        trimmed.outMs = 1500
        let sending = try XCTUnwrap(CueEdits.write(.media(trimmed), channel: 1, cue: verse, list: 42))
        XCTAssertEqual(text(sending).count, 1)
        guard case .edit(let edit) = sending.commands[0], case .cueChannel(let change) = edit.action,
              case .write(.media(let sent), let riders) = change.state else { return XCTFail("one edit.cueChannel") }
        XCTAssertEqual(sent.inMs, 500)
        XCTAssertEqual(sent.outMs, 1500)
        XCTAssertTrue(sent.loop, "the fixture's write loops, and stays so")
        XCTAssertEqual(riders.transition?.ref, 2, "the same item: its riders stay")
        // Another item picked with a trim is a new pick with those overrides, and the item's default grade for this cue only.
        let ocean = try XCTUnwrap(try Recorded.media().first { $0.id.hasPrefix("sha256:9f2c") })
        let picked = try XCTUnwrap(CueEdits.pick(MediaContent(ref: ocean.id, inMs: 2000, loop: true), defaultGrade: 1, channel: 1, cue: verse, list: 42))
        guard case .edit(let pick) = picked.commands[0], case .cueChannel(let other) = pick.action,
              case .write(.media(let item2), let riders2) = other.state else { return XCTFail("one edit.cueChannel") }
        XCTAssertEqual(text(picked).count, 1)
        XCTAssertEqual(item2.inMs, 2000)
        XCTAssertEqual(riders2.transition?.ref, 2, "the transition rider stays, as on a drop")
        XCTAssertEqual(riders2.grade, GradeRider(ref: 1, scope: .once))
        // "Loop only turns looping on, since a write can't refuse an item's own loop".
        XCTAssertTrue(CueEdits.loop(true, on: MediaContent(ref: "sha256:x")).loop)
        XCTAssertFalse(CueEdits.loop(false, on: MediaContent(ref: "sha256:x", loop: true)).loop)
    }

    // MARK: - Chips (Spec 11 §4, "Attribute chips")

    func test_aChipIsARiderOnAWriteAndATrackedCommandWithClearOrHold() throws {
        let list = try list42()
        let second = list.cues[1], chorus = list.cues[3]
        // On a write: a rider, with the scope chosen.
        XCTAssertEqual(text(CueEdits.set(CueAttribute(kind: .transition, ref: 2, ms: 500, scope: .once, isRider: true), channel: 2, cue: second, list: 42)),
                       ["edit list 42 cue \(id(second)) channel 2 write text \"There is no shadow\\nof turning with Thee\" transition 2 0.5 once"])
        XCTAssertEqual(text(CueEdits.set(CueAttribute(kind: .gain, db: -3, scope: .track, isRider: true), channel: 2, cue: second, list: 42)),
                       ["edit list 42 cue \(id(second)) channel 2 write text \"There is no shadow\\nof turning with Thee\" gain -3 track"])
        // With Hold: "a standalone attribute command, which is always `track`", whatever scope was asked.
        XCTAssertEqual(text(CueEdits.set(CueAttribute(kind: .grade, ref: 1, scope: .once, isRider: true), channel: 1, cue: second, list: 42)),
                       ["edit list 42 cue \(id(second)) channel 1 grade 1 hold"])
        // A chip that is set already changes in place, beside the cell's other attribute writes.
        XCTAssertEqual(text(CueEdits.set(CueAttribute(kind: .gain, db: -12, scope: .track, isRider: false), channel: 1, cue: chorus, list: 42)),
                       ["edit list 42 cue \(id(chorus)) channel 1 gain -12 hold"])
        XCTAssertEqual(text(CueEdits.set(CueAttribute(kind: .audioTransition, ref: 2, scope: .track, isRider: false), channel: 1, cue: chorus, list: 42)),
                       ["edit list 42 cue \(id(chorus)) channel 1 gain -6 audiotransition 2 hold"])
        // Remove.
        XCTAssertEqual(text(CueEdits.remove(.gain, channel: 1, cue: chorus, list: 42)), ["edit list 42 cue \(id(chorus)) channel 1 hold"])
        XCTAssertEqual(text(CueEdits.remove(.grade, channel: 2, cue: chorus, list: 42)),
                       ["edit list 42 cue \(id(chorus)) channel 2 write text \"Great is Thy faithfulness!\\nGreat is Thy faithfulness!\" audiotransition 2 once"])
        XCTAssertNil(CueEdits.remove(.grade, channel: 1, cue: chorus, list: 42), "nothing to remove")
        XCTAssertNil(CueEdits.set(CueAttribute(kind: .gain, db: -6, scope: .track, isRider: false), channel: 1, cue: chorus, list: 42), "as it is")
    }

    func test_withTrackingOffANewChipIsThisCueOnlyAndATrackRiderKeepsItsScope() throws {
        let chorus = try list42().cues[3]
        let says = CueSays.about(2, in: chorus)
        // "A new chip for that attribute is "this cue only"."
        XCTAssertEqual(CueChips.scope(for: .transition, in: says, tracking: false), .once)
        XCTAssertEqual(CueChips.scope(for: .transition, in: says, tracking: true), .track)
        // "an existing `track` rider keeps its scope when its value changes".
        XCTAssertEqual(CueChips.scope(for: .grade, in: says, tracking: false), .track)
        // "A standalone command reads "this cue only", since that is how it plays here".
        let held = CueSays.about(1, in: chorus)
        XCTAssertEqual(CueChips.shownScope(of: try XCTUnwrap(held.attribute(.gain)), tracking: false), .once)
        XCTAssertEqual(CueChips.shownScope(of: try XCTUnwrap(held.attribute(.gain)), tracking: true), .track)
        // A popover offers a scope only for a rider: "with Clear or Hold ... its popover offers no scope".
        XCTAssertTrue(CueChips.offersScope(in: says))
        XCTAssertFalse(CueChips.offersScope(in: held))
    }

    func test_aChipOnSeveralCuesIsOneGroupAndThisCueOnlySkipsTheCuesThatHoldOrClear() throws {
        let list = try list42()
        // Channel 1 over cues 1 to 3: only cue 1 writes content there.
        let cues = Array(list.cues[0...2])
        let tracked = CueEdits.set(CueAttribute(kind: .grade, ref: 1, scope: .track, isRider: true), channel: 1, cues: cues, list: 42)
        XCTAssertEqual(tracked.skipped, 0)
        XCTAssertEqual(text(tracked.sending), [
            "edit list 42 cue \(id(cues[0])) channel 1 write media sha256:55c84469c37e1e6a72a9b8938422cd6536b302b583a5c127241c8304246f3527 loop transition 2 1.0 once grade 1 track",
            "edit list 42 cue \(id(cues[1])) channel 1 grade 1 hold",
            "edit list 42 cue \(id(cues[2])) channel 1 grade 1 hold",
        ])
        // ""This cue only" applies to the selected cues that write content on that channel and skips the rest, saying how many it skipped".
        let once = CueEdits.set(CueAttribute(kind: .grade, ref: 1, scope: .once, isRider: true), channel: 1, cues: cues, list: 42)
        XCTAssertEqual(once.skipped, 2)
        XCTAssertEqual(text(once.sending).count, 1)
        XCTAssertTrue(text(once.sending)[0].hasSuffix("grade 1 once"))
    }

    // MARK: - Cues (Spec 11 §4, "Selecting")

    func test_aNewCueADuplicateAndADelete() throws {
        let list = try list42()
        let fresh = try XCTUnwrap(UUID(uuidString: "c0c00000-0000-4000-8000-000000000001"))
        // "A new cue holds every channel, has a Go trigger, an empty label and note, and the section of the
        // cue before it: `edit list L insert cues K {…}` with a uuid the app makes".
        XCTAssertEqual(text(CueEdits.newCue(uuid: fresh, after: list.cues[1], in: list)),
                       ["edit list 42 insert cues 2 { \"section\": \"Verse 1\", \"uuid\": \"c0c00000-0000-4000-8000-000000000001\" }"])
        // The + header "adds a cue at the end".
        XCTAssertEqual(text(CueEdits.newCue(uuid: fresh, after: nil, in: list)),
                       ["edit list 42 insert cues 4 { \"section\": \"Chorus\", \"uuid\": \"c0c00000-0000-4000-8000-000000000001\" }"])
        var empty = list
        empty.cues = []
        XCTAssertEqual(text(CueEdits.newCue(uuid: fresh, after: nil, in: empty)),
                       ["edit list 42 insert cues 0 { \"uuid\": \"c0c00000-0000-4000-8000-000000000001\" }"])
        XCTAssertEqual(text(CueEdits.duplicate(cue: list.cues[3], list: 42)), ["edit list 42 cue \(id(list.cues[3])) duplicate"])
        // "Delete (`… remove`, several as one group)".
        XCTAssertEqual(text(CueEdits.remove(cues: [list.cues[1]], list: 42)), ["edit list 42 cue \(id(list.cues[1])) remove"])
        XCTAssertEqual(text(CueEdits.remove(cues: [list.cues[1], list.cues[2]], list: 42)),
                       ["edit list 42 cue \(id(list.cues[1])) remove", "edit list 42 cue \(id(list.cues[2])) remove"])
        XCTAssertEqual(text(CueEdits.label("Refrain", cue: list.cues[3], list: 42)), ["edit list 42 cue \(id(list.cues[3])) label \"Refrain\""])
        XCTAssertEqual(text(CueEdits.section("Bridge", cue: list.cues[3], list: 42)), ["edit list 42 cue \(id(list.cues[3])) section \"Bridge\""])
        XCTAssertEqual(text(CueEdits.section("", cue: list.cues[3], list: 42)), ["edit list 42 cue \(id(list.cues[3])) section null"])
        XCTAssertNil(CueEdits.label("Chorus", cue: list.cues[3], list: 42), "as it is")
        XCTAssertNil(CueEdits.section("Chorus", cue: list.cues[3], list: 42))
    }

    /// Spec 11 §4 as corrected 2026-11-24 — "A section carries forward in the editor alone: set on one cue, it is set
    /// too on the cues after it whose section was the same as that cue's, up to the first that differs, all as one group".
    func test_aSectionCarriesOnToTheCuesAfterItThatSharedItsOldOne() throws {
        var list = try list42()
        XCTAssertEqual(list.cues.count, 4)
        for (index, name) in ["Verse", "Verse", "Verse", "Chorus"].enumerated() { list.cues[index].section = name }
        // Set on cue 2: cue 3 was Verse with it; cue 4 had another.
        XCTAssertEqual(text(CueEdits.sectionRun("Bridge", from: list.cues[1], in: list)),
                       ["edit list 42 cue \(id(list.cues[1])) section \"Bridge\"", "edit list 42 cue \(id(list.cues[2])) section \"Bridge\""])
        // The last cue of its run: that cue alone.
        XCTAssertEqual(text(CueEdits.sectionRun("Bridge", from: list.cues[2], in: list)), ["edit list 42 cue \(id(list.cues[2])) section \"Bridge\""])
        // Cues with no section carry one on, up to the first that has any.
        var bare = list
        for index in 0..<3 { bare.cues[index].section = nil }
        XCTAssertEqual(text(CueEdits.sectionRun("Verse 1", from: bare.cues[0], in: bare)),
                       (0..<3).map { "edit list 42 cue \(id(bare.cues[$0])) section \"Verse 1\"" })
        // As it is: nothing to send.
        XCTAssertNil(CueEdits.sectionRun("Verse", from: list.cues[0], in: list))
    }

    func test_deleteAsksOnlyForEditsTheLiveCueOrTheArmedOne() throws {
        var list = try list42()
        // "Deleting cues asks first only when the cues hold edits, or include the live cue or the armed one (choice A-11)".
        XCTAssertFalse(CueEdits.deleteAsks(cues: [list.cues[1], list.cues[2]], live: id(list.cues[0]), armed: nil))
        XCTAssertTrue(CueEdits.deleteAsks(cues: [list.cues[0], list.cues[2]], live: id(list.cues[0]), armed: nil))
        XCTAssertTrue(CueEdits.deleteAsks(cues: [list.cues[2]], live: nil, armed: id(list.cues[2])))
        list.cues[1].commands.append(GuardedCommand(.edit(EditCommand(.list(7), .set(path: "title", value: .string("x"))))))
        XCTAssertTrue(CueEdits.deleteAsks(cues: [list.cues[1]], live: nil, armed: nil))
    }

    func test_cuesMoveToANewPlaceInTheirOrderAsOneGroup() throws {
        let list = try list42()
        let c = list.cues.map(id)
        // Move Earlier and Move Later: one cue, one place.
        XCTAssertEqual(text(CueEdits.move(cues: [list.cues[2]], before: 1, in: list)), ["edit list 42 cue \(c[2]) move 1"])
        XCTAssertEqual(text(CueEdits.move(cues: [list.cues[1]], before: 3, in: list)), ["edit list 42 cue \(c[1]) move 2"])
        // Dropped where it is: nothing to send.
        XCTAssertNil(CueEdits.move(cues: [list.cues[1]], before: 1, in: list))
        XCTAssertNil(CueEdits.move(cues: [list.cues[1]], before: 2, in: list))
        // Two cues dragged to the end keep their order: each step is the engine's `move K`, the place the cue ends at.
        let toEnd = try XCTUnwrap(CueEdits.move(cues: [list.cues[0], list.cues[1]], before: 4, in: list))
        XCTAssertEqual(text(toEnd), ["edit list 42 cue \(c[0]) move 3", "edit list 42 cue \(c[1]) move 3"])
        XCTAssertEqual(apply(toEnd, to: c), [c[2], c[3], c[0], c[1]])
        // Two cues that aren't neighbors, dragged to the front, land together in the list's order.
        let toFront = try XCTUnwrap(CueEdits.move(cues: [list.cues[1], list.cues[3]], before: 0, in: list))
        XCTAssertEqual(apply(toFront, to: c), [c[1], c[3], c[0], c[2]])
        // Dragged between themselves.
        let between = try XCTUnwrap(CueEdits.move(cues: [list.cues[0], list.cues[3]], before: 2, in: list))
        XCTAssertEqual(apply(between, to: c), [c[1], c[0], c[3], c[2]])
    }

    /// Runs a group of `edit list L cue C move K` on an order, as the engine does: one after another.
    private func apply(_ sending: Sending, to order: [String]) -> [String] {
        var order = order
        for command in sending.commands {
            guard case .edit(let edit) = command, case .cue(_, let cue) = edit.address, case .move(nil, nil, let at) = edit.action,
                  let from = order.firstIndex(of: cue.uuidString.lowercased()) else { continue }
            let moved = order.remove(at: from)
            order.insert(moved, at: at)
        }
        return order
    }

    // MARK: - Commands (Spec 11 §4, "The Commands column")

    func test_theCuesOtherCommandsMoveAndGoByPosition() throws {
        let out = try list7().cues[2]
        // Doxology's last cue: clear channel 2, run macro 1, write a slide on channel 1. Its
        // Commands column lists the macro alone, at its place in the cue's commands.
        XCTAssertEqual(CueEdits.others(in: out).map(\.position), [1])
        XCTAssertEqual(text(CueEdits.insert(.macro(2), after: 1, cue: out, list: 7)),
                       ["edit list 7 cue \(id(out)) insert commands 2 { \"cmd\": \"macro.run\", \"macro\": 2 }"])
        // "Add inserts the command after the selected one, or at the end."
        XCTAssertEqual(text(CueEdits.insert(.systemClearAll, after: nil, cue: out, list: 7)),
                       ["edit list 7 cue \(id(out)) insert commands 3 { \"cmd\": \"system.clearAll\" }"])
        XCTAssertEqual(text(CueEdits.removeCommand(at: 1, cue: out, list: 7)), ["edit list 7 cue \(id(out)) remove commands 1"])
        XCTAssertEqual(text(CueEdits.setCommand(.macro(3), at: 1, cue: out, list: 7)),
                       ["edit list 7 cue \(id(out)) commands.1 { \"cmd\": \"macro.run\", \"macro\": 3 }"])
        // Move Up and Move Down step over the channel commands between two of the listed ones.
        var cue = out
        cue.commands.append(GuardedCommand(.timerStart(timer: 1)))
        XCTAssertEqual(CueEdits.others(in: cue).map(\.position), [1, 3])
        XCTAssertEqual(text(CueEdits.moveCommand(at: 3, up: true, cue: cue, list: 7)), ["edit list 7 cue \(id(cue)) move commands 3 1"])
        XCTAssertEqual(text(CueEdits.moveCommand(at: 1, up: false, cue: cue, list: 7)), ["edit list 7 cue \(id(cue)) move commands 1 3"])
        XCTAssertNil(CueEdits.moveCommand(at: 1, up: true, cue: cue, list: 7), "the first has nowhere to go")
        XCTAssertNil(CueEdits.moveCommand(at: 3, up: false, cue: cue, list: 7))
    }

    func test_commandsAsTextSendsTheWholeListOnlyWhileNoLineHasAnError() throws {
        let out = try list7().cues[2]
        // "the cue's whole command list, one command per line, in order, in canonical text".
        let lines = CommandsText.lines(of: out)
        XCTAssertEqual(lines, ["channel 2 clear", "macro 1", "channel 1 write slide:51de0000-0000-4000-8000-000000000001 build 2"])
        // Unchanged: nothing to send.
        XCTAssertEqual(CommandsText.parse(lines.joined(separator: "\n"), cue: out).errors, [:])
        XCTAssertNil(CommandsText.edit(lines.joined(separator: "\n"), cue: out, list: 7))
        // A changed line: "one `edit.set` of the cue's `commands` with the parsed list".
        let changed = "channel 2 clear\nmacro 2\n\nsystem clearall"
        let sending = try XCTUnwrap(CommandsText.edit(changed, cue: out, list: 7))
        XCTAssertEqual(sending.commands.count, 1)
        guard case .edit(let edit) = sending.commands[0], case .set("commands", let value) = edit.action else { return XCTFail("an edit.set of commands") }
        XCTAssertEqual(edit.address, .cue(list: 7, cue: out.uuid))
        XCTAssertEqual(value.arrayValue?.count, 3, "a blank line is no command")
        XCTAssertEqual(value.arrayValue?.compactMap { $0["cmd"]?.stringValue }, ["channel.clear", "macro.run", "system.clearAll"])
        // "each error beside its line ... with one, nothing is sent".
        let broken = CommandsText.parse("channel 2 clear\nmacro banana\nsystem clearall", cue: out)
        XCTAssertEqual(Array(broken.errors.keys), [1])
        XCTAssertNil(CommandsText.edit("channel 2 clear\nmacro banana", cue: out, list: 7))
        XCTAssertTrue(CommandsText.hasErrors("channel 2 clear\nmacro banana", cue: out))
    }

    func test_aCommandKeptVerbatimShowsAsItsJSONOnALockedLineAndGoesBackAsItWas() throws {
        var cue = try list7().cues[2]
        let kept = Command.unknown(cmd: "laser.fire", fields: ["power": .number(11)])
        cue.commands.insert(GuardedCommand(kept), at: 1)
        // "A command kept verbatim because it is unknown has no text form, so it shows as its JSON on one locked line".
        let lines = CommandsText.lines(of: cue)
        XCTAssertEqual(lines[1], "{ \"cmd\": \"laser.fire\", \"power\": 11 }")
        XCTAssertEqual(CommandsText.locked(in: cue), [1])
        // "and goes back as the object it was (Spec 1 §6)".
        var text = lines
        text[2] = "macro 4"
        let parsed = CommandsText.parse(text.joined(separator: "\n"), cue: cue)
        XCTAssertEqual(parsed.errors, [:])
        XCTAssertEqual(parsed.commands.map(\.command)[1], kept)
        XCTAssertEqual(parsed.commands.map(\.command)[2], .macro(4))
    }

    // MARK: - The list, and a channel number no channel has

    func test_renumberSwapAndTheNoChannelRowsHold() throws {
        // "Renumber… (`edit list N renumber M`, or Swap for a taken number)".
        XCTAssertEqual(text(CueEdits.renumber(list: 42, to: 43)), ["edit list 42 renumber 43"])
        XCTAssertEqual(text(CueEdits.swap(list: 42, with: 7)), ["edit list 42 swap 7"])
        // "On a "No channel" row the only action is Hold, sent as `edit.remove` of those commands in one group."
        var cue = try list42().cues[0]
        cue.commands.insert(GuardedCommand(.channelGain(channel: .number(7), db: -3)), at: 0)
        cue.commands.append(GuardedCommand(.channelWrite(ChannelWrite(channel: .number(7), content: .text(fields: ["body": "Stray"])))))
        XCTAssertEqual(text(CueEdits.holdMissing(channel: 7, cue: cue, list: 42)),
                       ["edit list 42 cue \(id(cue)) remove commands 3", "edit list 42 cue \(id(cue)) remove commands 0"],
                       "from the last, so each position still names its command")
        XCTAssertNil(CueEdits.holdMissing(channel: 9, cue: cue, list: 42))
    }
}
