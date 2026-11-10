import Foundation
import XCTest
@testable import OCore

/// Spec 5 §4 — the verbs on a list's cues: insert, remove, move and
/// duplicate, the fields, a cue's commands by position, `edit.section` and
/// `edit.cueChannel`. Spec 11 §13, what it adds to Area 9: "A cue's command
/// moves by position, with its inverse; a cue inserted with a uuid its list
/// already has is refused."
final class EditCueTests: XCTestCase {
    typealias F = FixtureLibrary

    static func u(_ uuid: UUID) -> String { uuid.uuidString.lowercased() }
    static var c1: String { u(F.list42Cues[0]) }
    static var c2: String { u(F.list42Cues[1]) }
    static var c4: String { u(F.list42Cues[3]) }

    func commands(_ edits: Edits, _ list: Int, cue: Int) -> [Command] {
        edits.list(list)?.cues[cue - 1].commands.map(\.command) ?? []
    }

    // MARK: - Insert, remove, move, duplicate

    /// Spec 11 §4 — the app picks a new cue's uuid, "so a group can name the
    /// cue it inserts"; Spec 5 §6, check 6 — "a cue's uuid within its list"
    /// is unique.
    func test_aCueInsertedWithAUuidItsListHasIsRefused() throws {
        var edits = Edits()
        let inserted = edits.apply("edit list 42 insert cues 1 { \"label\": \"Verse 2\", \"uuid\": \"\(Self.u(F.uuid("c0c0", 1)))\" }")
        XCTAssertEqual(edits.list(42)?.cues.map(\.uuid)[1], F.uuid("c0c0", 1))
        XCTAssertEqual(edits.list(42)?.cues[1].trigger, .go, "the type's defaults fill what the value leaves out")
        XCTAssertEqual(inserted.first?.inverse, EditCommand(.cue(list: 42, cue: F.uuid("c0c0", 1)), .remove(path: nil, at: nil)))
        XCTAssertEqual(edits.refuse("edit list 42 insert cues 0 { \"uuid\": \"\(Self.c2)\" }")?.reason, .duplicate)
        XCTAssertEqual(edits.refuse("edit list 42 insert cues 9 { \"label\": \"x\" }")?.reason, .badValue, "past the end")
        // Without a uuid the engine picks one, and the log records it.
        let picked = edits.apply("edit list 42 insert cues 0 { \"label\": \"Intro\" }")
        guard case .insert(_, _, let value)? = picked.first.map(\.logged.action) else { return XCTFail("an insert") }
        XCTAssertEqual(value["uuid"], .string(Self.u(Edits.pick(1))))
        XCTAssertEqual(edits.list(42)?.cues.first?.uuid, Edits.pick(1))
    }

    /// Spec 5 §4 as Spec 11 corrected it — "a child without an address of its
    /// own, such as a box or a cue's command, is named by its array's path and
    /// its position"; "Positions ... count from 0".
    func test_aCuesCommandMovesByPositionWithItsInverse() throws {
        var edits = Edits()
        let before = commands(edits, 42, cue: 1)
        let moved = edits.apply("edit list 42 cue \(Self.c1) move commands 1 0")
        XCTAssertEqual(commands(edits, 42, cue: 1), [before[1], before[0]])
        XCTAssertEqual(moved.first?.inverse, EditCommand(.cue(list: 42, cue: F.list42Cues[0]), .move(path: "commands", from: 0, at: 1)))
        XCTAssertEqual(moved.first?.changes, [LibraryChange(object: "cue", address: [
            "list": .number(42), "listUuid": .string(Self.u(F.listUuid(42))), "cue": .string(Self.c1)], paths: ["commands"])])
        XCTAssertEqual(edits.refuse("edit list 42 cue \(Self.c1) move commands 0 2")?.reason, .badValue)
        XCTAssertEqual(edits.refuse("edit list 42 cue \(Self.c1) move labels 0 1")?.reason, .unknownPath)
        XCTAssertEqual(edits.refuse("edit list 42 cue \(Self.c1) move label 0 1")?.reason, .badValue, "label isn't an array")
        XCTAssertEqual(edits.refuse("edit list 42 cue \(Self.c1) commands.0.channel 3")?.reason, .unknownPath)
    }

    func test_aCueMovesRemovesAndDuplicates() throws {
        var edits = Edits()
        edits.apply("edit list 42 cue \(Self.c1) move 3")
        XCTAssertEqual(edits.list(42)?.cues.map(\.uuid), [F.list42Cues[1], F.list42Cues[2], F.list42Cues[3], F.list42Cues[0]])
        let removed = edits.apply("edit list 42 cue \(Self.c2) remove")
        XCTAssertEqual(edits.list(42)?.cues.count, 3)
        guard case .insert("cues", 0, let value)? = removed.first?.inverse?.action else { return XCTFail("the inverse inserts it back") }
        XCTAssertEqual(value["uuid"], .string(Self.c2))
        let copied = edits.apply("edit list 42 cue \(Self.c4) duplicate")
        XCTAssertEqual(edits.list(42)?.cues.map(\.uuid)[2], Edits.pick(1), "just after itself")
        XCTAssertEqual(edits.list(42)?.cues[2].commands, edits.list(42)?.cues[1].commands)
        XCTAssertEqual(copied.first?.logged.action, .duplicate(to: nil, title: nil, picks: EditPicks(uuid: Edits.pick(1))))
        XCTAssertEqual(edits.refuse("edit list 42 cue \(Self.c4) delete")?.reason, .badValue)
    }

    // MARK: - Fields and the commands a cue holds

    func test_fieldsAndTheirChecks() throws {
        var edits = Edits()
        edits.apply("edit list 42 cue \(Self.c1) section \"Chorus\"")
        XCTAssertEqual(edits.list(42)?.cues[0].section, "Chorus")
        edits.apply("edit list 42 cue \(Self.c1) section null")
        XCTAssertNil(edits.list(42)?.cues[0].section)
        edits.apply("edit list 42 cue \(Self.c1) trigger { \"ms\": 4000, \"type\": \"time\" }")
        XCTAssertEqual(edits.list(42)?.cues[0].trigger, .time(ms: 4000))
        XCTAssertEqual(edits.refuse("edit list 42 cue \(Self.c1) trigger { \"type\": \"later\" }")?.reason, .badValue)
        XCTAssertEqual(edits.refuse("edit list 42 cue \(Self.c1) trigger { \"ms\": -1, \"type\": \"time\" }")?.reason, .badValue)
        XCTAssertEqual(edits.refuse("edit list 42 cue \(Self.c1) trigger { \"tc\": \"1:00\", \"type\": \"timecode\" }")?.reason, .badValue)
        XCTAssertEqual(edits.refuse("edit list 42 cue \(Self.c1) advanceAfterMs -5")?.reason, .badValue)
        XCTAssertEqual(edits.refuse("edit list 42 cue \(Self.c1) uuid \"\(Self.c2)\"")?.reason, .readOnlyField)
        XCTAssertEqual(edits.refuse("edit list 42 cue \(Self.c1) colour \"red\"")?.reason, .unknownPath)
        XCTAssertEqual(edits.refuse("edit list 42 cue \(Self.c1) commands.5 { \"cmd\": \"playlist.next\" }")?.reason, .unknownPath)
    }

    /// Spec 5 §6 — the value's checks (4), its references (5, a portable
    /// document's machine-level numbers excepted) and structure (8): an edit
    /// a cue holds "is validated when its holder is saved, like any edit".
    func test_theCommandsACueGainsAreChecked() throws {
        var edits = Edits()
        func insert(_ object: String) -> String { "edit list 42 cue \(Self.c2) insert commands 0 \(object)" }
        XCTAssertEqual(edits.refuse(insert("{ \"cmd\": \"sprocket.spin\" }"))?.reason, .badValue, "not in the vocabulary")
        XCTAssertEqual(edits.refuse(insert("{ \"channel\": 9, \"cmd\": \"channel.clear\" }"))?.reason, .unknownReference)
        XCTAssertEqual(edits.refuse(insert("{ \"cmd\": \"macro.run\", \"macro\": 99 }"))?.reason, .unknownReference)
        XCTAssertEqual(edits.refuse(insert("{ \"channel\": 2, \"cmd\": \"channel.gain\", \"db\": 90 }"))?.reason, .badValue)
        XCTAssertEqual(edits.refuse(insert("{ \"channel\": 2, \"cmd\": \"channel.clear\", \"when\": { \"op\": \"is empty\", \"var\": \"Timer 1\" } }"))?.reason,
                       .badValue, "a guard on a cue command is reserved")
        XCTAssertEqual(edits.refuse(insert("{ \"cmd\": \"edit.set\", \"list\": 99, \"object\": \"list\", \"path\": \"title\", \"value\": \"x\" }"))?.reason,
                       .unknownObject, "the edit the cue holds names no list 99")
        // A portable document may name machine-level numbers this machine lacks.
        edits.apply(insert("{ \"cmd\": \"output.stack\", \"output\": 9, \"stack\": 7 }"))
        edits.apply(insert("{ \"cmd\": \"playlist.load\", \"title\": \"Easter\" }"))
        edits.apply(insert("{ \"cmd\": \"edit.set\", \"list\": 7, \"object\": \"list\", \"path\": \"title\", \"value\": \"Doxology (2)\" }"))
        XCTAssertEqual(commands(edits, 42, cue: 2).count, 4)
        // Spec 2 §5 — a macro cycle is refused when its holder is saved.
        edits.library.macros[0].commands.append(GuardedCommand(.macro(2)))
        edits.machine.macros[0].commands.append(GuardedCommand(.macro(1)))
        XCTAssertEqual(edits.refuse(insert("{ \"cmd\": \"macro.run\", \"macro\": 1 }"))?.reason, .cycle)
        // A command already in the cue isn't checked again, unknown ones included.
        edits.library.lists[1].cues[1].commands.append(GuardedCommand(.unknown(cmd: "future.thing", fields: ["x": .number(1)])))
        let all = edits.list(42)?.cues[1].commands.map { (try? JSONCoding.encode($0)) ?? .null } ?? []
        edits.apply("edit list 42 cue \(Self.c2) commands \(JSONCanonical.line(.array(Array(all.reversed()))))")
        XCTAssertEqual(edits.list(42)?.cues[1].commands.first?.command, .unknown(cmd: "future.thing", fields: ["x": .number(1)]))
    }

    // MARK: - Spec 5 §4, `edit.section`

    /// "Acts on the cue's section block, the run of consecutive cues that share
    /// its section label ... The engine runs it as one group of cue edits";
    /// each is logged with its own inverse.
    func test_sectionVerbsRunAsTheCueEditsTheyMake() throws {
        var edits = Edits()
        let duplicated = edits.apply("edit list 42 cue \(Self.c2) section duplicate")
        XCTAssertEqual(duplicated.count, 3, "Verse 1 is cues 1 to 3")
        XCTAssertEqual(duplicated.map(\.logged.cmd), ["edit.insert", "edit.insert", "edit.insert"])
        let cues = try XCTUnwrap(edits.list(42)?.cues)
        XCTAssertEqual(cues.map(\.uuid), Array(F.list42Cues.prefix(3)) + (1...3).map(Edits.pick) + [F.list42Cues[3]])
        XCTAssertEqual(cues[3...5].map(\.commands), cues[0...2].map(\.commands), "copies, with new uuids")

        var moving = Edits()
        moving.apply("edit list 42 cue \(Self.c1) section move 1")
        XCTAssertEqual(moving.list(42)?.cues.map(\.uuid), [F.list42Cues[3], F.list42Cues[0], F.list42Cues[1], F.list42Cues[2]])
        moving.apply("edit list 42 cue \(Self.c1) section move 0")
        XCTAssertEqual(moving.list(42)?.cues.map(\.uuid), F.list42Cues)
        XCTAssertEqual(moving.refuse("edit list 42 cue \(Self.c1) section move 2")?.reason, .badValue, "three cues can't start at 2 of 4")

        var removing = Edits()
        let removed = removing.apply("edit list 42 cue \(Self.c4) section remove")
        XCTAssertEqual(removed.map(\.logged), [EditCommand(.cue(list: 42, cue: F.list42Cues[3]), .remove(path: nil, at: nil))])
        XCTAssertEqual(removing.list(42)?.cues.count, 3)
    }

    /// Labels compare without regard to case, as section jumps do (Spec 3 §5),
    /// and a cue without a section is a block of its own.
    func test_aSectionBlockIsItsRunOfLabels() throws {
        var edits = Edits()
        edits.apply("edit list 42 cue \(Self.c2) section \"VERSE 1\"")
        XCTAssertEqual(edits.apply("edit list 42 cue \(Self.c1) section remove").count, 3)
        var lone = Edits()
        lone.apply("edit list 42 cue \(Self.c4) section null")
        XCTAssertEqual(lone.apply("edit list 42 cue \(Self.c4) section duplicate").count, 1)
    }

    // MARK: - Spec 5 §4, `edit.cueChannel`

    /// "Sets everything a cue says about one channel": its content state and
    /// its standalone attribute writes, in the place its old commands were, the
    /// attribute writes before the content; the log records the place.
    func test_aChannelEditReplacesTheChannelsCommandsWhereTheyWere() throws {
        var edits = Edits()
        let c1 = F.list42Cues[0]
        let before = commands(edits, 42, cue: 1)   // channel 1 write, channel 2 write
        let edit = edits.apply("edit list 42 cue \(Self.c1) channel 1 gain -6 clear")
        XCTAssertEqual(commands(edits, 42, cue: 1), [.channelGain(channel: .number(1), db: -6), .channelClear(channel: .number(1)), before[1]])
        XCTAssertEqual(edit.first?.logged, EditCommand(.cue(list: 42, cue: c1), .cueChannel(CueChannelEdit(
            channel: 1, state: .clear, attributes: [.channelGain(channel: .number(1), db: -6)], at: 0))))
        guard case .cueChannel(let previous)? = edit.first?.inverse?.action, case .write = previous.state else {
            return XCTFail("the inverse puts the write back: \(String(describing: edit.first?.inverse))")
        }
        XCTAssertEqual(previous.at, 0)
        XCTAssertEqual(previous.attributes, [])

        // A channel the cue didn't mention goes in channel-number order.
        let second = edits.apply("edit list 42 cue \(Self.c2) channel 1 grade 1 hold")
        XCTAssertEqual(commands(edits, 42, cue: 2).first, .channelGrade(channel: .number(1), ref: 1, ms: nil))
        XCTAssertEqual(second.first?.inverse, EditCommand(.cue(list: 42, cue: F.list42Cues[1]), .cueChannel(CueChannelEdit(channel: 1, state: .hold))))

        // The same state again changes nothing.
        XCTAssertEqual(edits.apply("edit list 42 cue \(Self.c2) channel 1 grade 1 hold").first?.isNoop, true)
        XCTAssertEqual(edits.refuse("edit list 42 cue \(Self.c2) channel 9 clear")?.reason, .unknownReference)
        XCTAssertEqual(edits.refuse("edit list 42 cue \(Self.c2) channel 2 write text \"x\" grade 7 once")?.reason, .unknownReference)
    }

    /// The inverse is the channel's previous state, or the cue's whole
    /// `commands` when that can't be put back by a channel edit (Spec 5 §4 as
    /// Area 9 corrected it): two content commands, or other commands between.
    func test_aChannelEditsInverseFallsBackToTheWholeCommands() throws {
        var edits = Edits()
        let cue = F.list42Cues[1]
        edits.library.lists[1].cues[1].commands = [
            GuardedCommand(.channelWrite(ChannelWrite(channel: .number(2), content: .text(fields: ["body": "a"])))),
            GuardedCommand(.macro(1)),
            GuardedCommand(.channelGrade(channel: .number(2), ref: 1, ms: nil)),
        ]
        let original = edits.library.lists[1].cues[1].commands
        let edit = edits.apply("edit list 42 cue \(Self.c2) channel 2 hold")
        XCTAssertEqual(commands(edits, 42, cue: 2), [.macro(1)])
        XCTAssertEqual(edit.first?.inverse, EditCommand(.cue(list: 42, cue: cue), .set(path: "commands", value: .array(original.map {
            (try? JSONCoding.encode($0)) ?? .null
        }))))
        edits.undo(edit)
        XCTAssertEqual(edits.library.lists[1].cues[1].commands, original)
    }
}
