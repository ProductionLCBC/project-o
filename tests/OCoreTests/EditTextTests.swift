import Foundation
import XCTest
@testable import OCore

/// Spec 5 §3 and §4 — the edit family's text and object forms. Spec 5 §11 —
/// "Parse and print. Every verb's text form round-trips (`parse(print(x)) ==
/// x`). Short forms expand to uuids with a library and are never printed."
final class EditTextTests: XCTestCase {
    typealias F = FixtureLibrary
    typealias E = EditCommand

    static let C = F.list42Cues[1]
    static let P = F.playlistUuid
    static var I: UUID { F.sundayItems[1] }
    static let U = F.uuid("dddd", 1)
    static let V = F.uuid("dddd", 2)
    static let W = F.uuid("dddd", 3)
    static func text(_ u: UUID) -> String { u.uuidString.lowercased() }
    static var c: String { text(C) }
    static var p: String { text(P) }
    static var i: String { text(I) }
    static var u: String { text(U) }
    static var v: String { text(V) }
    static var w: String { text(W) }

    struct Row {
        let text: String
        let edit: EditCommand
        let canonical: String
        let line: UInt
    }

    static func row(_ text: String, _ edit: EditCommand, canonical: String? = nil, line: UInt = #line) -> Row {
        Row(text: text, edit: edit, canonical: canonical ?? text, line: line)
    }

    func parsed(_ text: String, _ options: ParseOptions = ParseOptions(), line: UInt = #line) -> Command? {
        switch CommandText.parse(text, options: options) {
        case .success(let entry):
            XCTAssertNil(entry.when, line: line)
            return entry.command
        case .failure(let rejection):
            XCTFail("\(text) → \(rejection.reason): \(rejection.message)", line: line)
            return nil
        }
    }

    func rejection(_ text: String, _ options: ParseOptions = ParseOptions()) -> Rejection? {
        if case .failure(let r) = CommandText.parse(text, options: options) { return r }
        return nil
    }

    // MARK: - Every verb

    static var rows: [Row] {
        let dawn = F.dawn
        return [
            // set: "When the word after the address is a path, the verb is `set`."
            row("edit channel 2 label \"Lyrics\"", E(.numbered(.channel, 2), .set(path: "label", value: .string("Lyrics")))),
            row("edit machine network.oscInPort 8001", E(.machine, .set(path: "network.oscInPort", value: .number(8001)))),
            row("edit textstyle 1 size.value 48", E(.numbered(.textStyle, 1), .set(path: "size.value", value: .number(48)))),
            row("edit audiotransition 1 offsetMs -200", E(.numbered(.audioTransition, 1), .set(path: "offsetMs", value: .number(-200)))),
            row("edit audiooutput 2 delayMs 40", E(.numbered(.audioOutput, 2), .set(path: "delayMs", value: .number(40)))),
            row("edit media \(dawn) defaults.loop true", E(.media(dawn), .set(path: "defaults.loop", value: .bool(true)))),
            row("edit keys keyboard \"space\" command { \"cmd\": \"playlist.next\" }",
                E(.key(device: "keyboard", key: "space"), .set(path: "command", value: .object(["cmd": .string("playlist.next")])))),
            row("edit list 42 title \"Great Is Thy Faithfulness\"", E(.list(42), .set(path: "title", value: .string("Great Is Thy Faithfulness")))),
            row("edit list 42 cue \(c) advanceAfterMs 12000", E(.cue(list: 42, cue: C), .set(path: "advanceAfterMs", value: .number(12000)))),
            row("edit list 42 cue \(c) advanceAfterMs null", E(.cue(list: 42, cue: C), .set(path: "advanceAfterMs", value: .null))),
            row("edit list 42 cue \(c) trigger { \"ms\": 8000, \"type\": \"time\" }",
                E(.cue(list: 42, cue: C), .set(path: "trigger", value: .object(["type": .string("time"), "ms": .number(8000)])))),
            row("edit list 42 cue \(c) commands [{ \"channel\": 2, \"cmd\": \"channel.clear\" }]",
                E(.cue(list: 42, cue: C), .set(path: "commands", value: .array([.object(["cmd": .string("channel.clear"), "channel": .number(2)])])))),
            // `section` with a value is the field; with duplicate, move or remove, the verb.
            row("edit list 42 cue \(c) section \"Chorus\"", E(.cue(list: 42, cue: C), .set(path: "section", value: .string("Chorus")))),
            row("edit list 42 cue \(c) section null", E(.cue(list: 42, cue: C), .set(path: "section", value: .null))),
            row("edit playlist \(p) title \"Sunday Night\"", E(.playlist(P), .set(path: "title", value: .string("Sunday Night")))),
            row("edit playlist \(p) serviceTime \"10:30\"", E(.playlist(P), .set(path: "serviceTime", value: .string("10:30")))),
            row("edit playlist \(p) archived true", E(.playlist(P), .set(path: "archived", value: .bool(true)))),
            row("edit playlist \(p) item \(i) label \"Worship\"", E(.item(playlist: P, item: I), .set(path: "label", value: .string("Worship")))),
            // unset
            row("edit preset 3 unset layouts.2", E(.numbered(.preset, 3), .unset(path: "layouts.2"))),
            // create
            row("edit preset 7 create", E(.numbered(.preset, 7), .create(body: nil, folder: nil, title: nil))),
            row("edit list create", E(.list(nil), .create(body: nil, folder: nil, title: nil))),
            row("edit list 57 create folder \"Worship/Hymns\"", E(.list(57), .create(body: nil, folder: "Worship/Hymns", title: nil))),
            row("edit list 57 create { \"title\": \"New\", \"uuid\": \"\(u)\" }",
                E(.list(57), .create(body: .object(["title": .string("New"), "uuid": .string(u)]), folder: nil, title: nil))),
            row("edit playlist create \"Sunday\"", E(.playlist(nil), .create(body: nil, folder: nil, title: "Sunday"))),
            row("edit playlist \(u) create \"Sunday\"", E(.playlist(U), .create(body: nil, folder: nil, title: "Sunday"))),
            row("edit folder \"Worship/New\" create", E(.folder("Worship/New"), .create(body: nil, folder: nil, title: nil))),
            // delete, renumber, swap
            row("edit channel 5 delete", E(.numbered(.channel, 5), .delete)),
            row("edit list 42 renumber 57", E(.list(42), .renumber(to: 57))),
            row("edit list 42 swap 7", E(.list(42), .swap(with: 7))),
            // insert, remove, move
            row("edit list 42 insert cues 2 { \"label\": \"Verse 2\", \"uuid\": \"\(w)\" }",
                E(.list(42), .insert(path: "cues", at: 2, value: .object(["label": .string("Verse 2"), "uuid": .string(w)])))),
            row("edit list 42 cue \(c) insert commands 3 { \"cmd\": \"macro.run\", \"macro\": 1 }",
                E(.cue(list: 42, cue: C), .insert(path: "commands", at: 3, value: .object(["cmd": .string("macro.run"), "macro": .number(1)])))),
            row("edit playlist \(p) insert items 3 { \"kind\": \"linked\", \"list\": 42 }",
                E(.playlist(P), .insert(path: "items", at: 3, value: .object(["kind": .string("linked"), "list": .number(42)])))),
            row("edit list 42 cue \(c) remove", E(.cue(list: 42, cue: C), .remove(path: nil, at: nil))),
            row("edit stack 2 slot 3 remove", E(.slot(stack: 2, channel: 3), .remove(path: nil, at: nil))),
            row("edit preset 3 remove layouts.2.boxes 1", E(.numbered(.preset, 3), .remove(path: "layouts.2.boxes", at: 1))),
            row("edit list 42 cue \(c) move 4", E(.cue(list: 42, cue: C), .move(path: nil, from: nil, at: 4))),
            row("edit playlist \(p) item \(i) move 0", E(.item(playlist: P, item: I), .move(path: nil, from: nil, at: 0))),
            row("edit preset 3 move layouts.2.boxes 1 3", E(.numbered(.preset, 3), .move(path: "layouts.2.boxes", from: 1, at: 3))),
            // Spec 11 §4 — "a cue's command ... named by its array's path and its position".
            row("edit list 42 cue \(c) move commands 1 3", E(.cue(list: 42, cue: C), .move(path: "commands", from: 1, at: 3))),
            // duplicate, archive
            row("edit list 42 cue \(c) duplicate", E(.cue(list: 42, cue: C), .duplicate(to: nil, title: nil, picks: .none))),
            row("edit list 42 cue \(c) duplicate { \"uuid\": \"\(u)\" }",
                E(.cue(list: 42, cue: C), .duplicate(to: nil, title: nil, picks: EditPicks(uuid: U)))),
            row("edit preset 3 duplicate 9", E(.numbered(.preset, 3), .duplicate(to: 9, title: nil, picks: .none))),
            row("edit list 42 duplicate 57 { \"cueUuids\": [\"\(v)\", \"\(w)\"], \"uuid\": \"\(u)\" }",
                E(.list(42), .duplicate(to: 57, title: nil, picks: EditPicks(uuid: U, cueUuids: [V, W])))),
            row("edit playlist \(p) duplicate \"Sunday Night\" { \"itemUuids\": [\"\(v)\"], \"uuid\": \"\(u)\" }",
                E(.playlist(P), .duplicate(to: nil, title: "Sunday Night", picks: EditPicks(uuid: U, itemUuids: [V])))),
            row("edit playlist \(p) archive", E(.playlist(P), .archive(title: nil, picks: .none))),
            row("edit playlist \(p) archive \"Sunday 2026-11-01\" { \"itemUuids\": [\"\(v)\", \"\(w)\"], \"uuid\": \"\(u)\" }",
                E(.playlist(P), .archive(title: "Sunday 2026-11-01", picks: EditPicks(uuid: U, itemUuids: [V, W])))),
            // section, folder, rename
            row("edit list 42 cue \(c) section duplicate", E(.cue(list: 42, cue: C), .section(.duplicate))),
            row("edit list 42 cue \(c) section move 9", E(.cue(list: 42, cue: C), .section(.move(at: 9)))),
            row("edit list 42 cue \(c) section remove", E(.cue(list: 42, cue: C), .section(.remove))),
            row("edit list 42 folder \"Worship/Hymns\"", E(.list(42), .folder("Worship/Hymns"))),
            row("edit list 42 folder \"\"", E(.list(42), .folder(""))),
            row("edit folder \"Worship\" rename \"Music\"", E(.folder("Worship"), .rename(to: "Music"))),
            // channel: write, clear, hold, with attribute writes before the state
            row("edit list 42 cue \(c) channel 2 write text \"There is no shadow\\nof turning with Thee\"",
                E(.cue(list: 42, cue: C), .cueChannel(CueChannelEdit(channel: 2, state: .write(.text(fields: ["body": "There is no shadow\nof turning with Thee"]), .none))))),
            row("edit list 42 cue \(c) channel 2 clear", E(.cue(list: 42, cue: C), .cueChannel(CueChannelEdit(channel: 2, state: .clear)))),
            row("edit list 42 cue \(c) channel 2 grade 5 hold",
                E(.cue(list: 42, cue: C), .cueChannel(CueChannelEdit(channel: 2, state: .hold,
                                                                    attributes: [.channelGrade(channel: .number(2), ref: 5, ms: nil)])))),
            row("edit list 42 cue \(c) channel 1 transition 2 0.75 gain -6 write media \(dawn) loop transition 3 once { \"at\": 1 }",
                E(.cue(list: 42, cue: C), .cueChannel(CueChannelEdit(
                    channel: 1,
                    state: .write(.media(MediaContent(ref: dawn, loop: true)), Riders(transition: TransitionRider(ref: 3, scope: .once))),
                    attributes: [.channelTransition(channel: .number(1), ref: 2, ms: 750), .channelGain(channel: .number(1), db: -6)],
                    at: 1)))),
        ]
    }

    func test_everyVerbParsesAndPrintsCanonically() {
        var verbs: Set<String> = []
        for row in Self.rows {
            guard let command = parsed(row.text, line: row.line) else { continue }
            XCTAssertEqual(command, .edit(row.edit), row.text, line: row.line)
            XCTAssertEqual(CommandText.print(.edit(row.edit)), row.canonical, line: row.line)
            XCTAssertEqual(parsed(row.canonical, line: row.line), .edit(row.edit), "parse(print(x)) == x", line: row.line)
            verbs.insert(row.edit.cmd)
        }
        XCTAssertEqual(verbs, Set(EditAction.commandNames), "every verb has a row")
    }

    /// Spec 2 §2 — "Any accepted spelling parses; only the canonical spelling is printed."
    func test_otherSpellingsPrintCanonically() {
        let spellings: [(String, String)] = [
            // Spec 5 §4's own spelling of attributes after the state.
            ("edit list 42 cue \(Self.c) channel 2 hold grade 5", "edit list 42 cue \(Self.c) channel 2 grade 5 hold"),
            ("edit list 42 cue \(Self.c) channel 2 clear tr 2 track", "edit list 42 cue \(Self.c) channel 2 transition 2 clear"),
            ("EDIT LIST 42 cue \(Self.c.uppercased()) REMOVE", "edit list 42 cue \(Self.c) remove"),
            ("edit list 42 cue \(Self.c) label Verse", "edit list 42 cue \(Self.c) label \"Verse\""),
            ("edit list 42 cue \(Self.c) advanceAfterMs 12000.0", "edit list 42 cue \(Self.c) advanceAfterMs 12000"),
        ]
        for (text, canonical) in spellings {
            guard let command = parsed(text) else { continue }
            XCTAssertEqual(CommandText.print(command), canonical, text)
        }
    }

    /// Spec 2 §2 — the json token: an object or an array, its strings' brackets
    /// and quotes left alone; a guard's `[Value]` stays a value name.
    func test_jsonValuesKeepTheirBracketsAndGuardsKeepTheirs() {
        let text = "edit list 42 cue \(Self.c) commands [{ \"channel\": 2, \"cmd\": \"channel.write\", \"content\": { \"fields\": { \"body\": \"a ] \\\"b\\\" [ c\" }, \"kind\": \"text\" } }]"
        guard case .edit(let edit)? = parsed(text), case .set(_, let value) = edit.action else { return XCTFail("no edit") }
        XCTAssertEqual(value[0]?["content"]?["fields"]?["body"], .string("a ] \"b\" [ c"))
        XCTAssertEqual(CommandText.print(.edit(edit)), text)
        guard case .success(let guarded) = CommandText.parse("when [Timer 1] is 0:00 channel 2 clear") else { return XCTFail("guard") }
        XCTAssertEqual(guarded.when?.variable, "Timer 1")
        XCTAssertEqual(rejection("edit list 42 title { \"a\": ")?.reason, .malformed)
    }

    /// Spec 5 §3 — "The command bar accepts `list 42 cue 3`, `playlist
    /// "Sunday"` and `playlist "Sunday" item 4` as short forms. It expands them
    /// to uuids when it parses ... Only the uuid form is printed and logged".
    func test_shortFormsExpandWithALibraryAndAreNeverPrinted() {
        let (library, machine, _) = F.load()
        let options = ParseOptions(library: library, machine: machine)
        XCTAssertEqual(parsed("edit list 42 cue 2 label \"Verse 1b\"", options),
                       .edit(E(.cue(list: 42, cue: F.list42Cues[1]), .set(path: "label", value: .string("Verse 1b")))))
        XCTAssertEqual(parsed("edit playlist \" sunday\" title \"Sunday\"", options),
                       .edit(E(.playlist(F.playlistUuid), .set(path: "title", value: .string("Sunday")))))
        let short = parsed("edit playlist \"Sunday\" item 2 move 0", options)
        XCTAssertEqual(short, .edit(E(.item(playlist: F.playlistUuid, item: F.sundayItems[1]), .move(path: nil, from: nil, at: 0))))
        XCTAssertEqual(short.flatMap(CommandText.print), "edit playlist \(Self.p) item \(Self.i) move 0")

        XCTAssertEqual(rejection("edit list 42 cue 2 label \"x\"")?.reason, .badArgument, "a short form needs the library")
        XCTAssertEqual(rejection("edit playlist \"Sunday\" title \"x\"")?.reason, .badArgument)
        XCTAssertEqual(rejection("edit list 42 cue 9 remove", options)?.reason, .badArgument, "no cue 9")
        XCTAssertEqual(rejection("edit playlist \"Easter\" archive", options)?.reason, .badArgument, "no such playlist")
    }

    func test_rejections() {
        XCTAssertEqual(rejection("edit")?.reason, .missingArgument)
        XCTAssertEqual(rejection("edit sprocket 2 label \"x\"")?.reason, .unknownTarget)
        XCTAssertEqual(rejection("edit list 42")?.reason, .missingArgument)
        XCTAssertEqual(rejection("edit list 42 title")?.reason, .missingArgument)
        XCTAssertEqual(rejection("edit list 42 title \"x\" \"y\"")?.reason, .unexpectedToken)
        XCTAssertEqual(rejection("edit list 0 title \"x\"")?.reason, .badArgument)
        XCTAssertEqual(rejection("edit folder Worship create")?.reason, .badArgument, "a folder's path is quoted")
        XCTAssertEqual(rejection("edit list 42 cue \(Self.c) channel 2 grade 5 once hold")?.reason, .badArgument)
        XCTAssertEqual(rejection("edit list 42 cue \(Self.c) channel 2 paint")?.reason, .badArgument)
        XCTAssertEqual(rejection("edit list 42 cue \(Self.c) channel 2 clear { \"where\": 1 }")?.reason, .badArgument)
        XCTAssertEqual(rejection("edit playlist \(Self.p) duplicate \"x\" { \"colour\": 1 }")?.reason, .badArgument)
        XCTAssertEqual(rejection("channel 2 write text \"x\" { \"at\": 1 }")?.reason, .unexpectedToken, "a plain write takes no JSON after it")
    }

    // MARK: - Spec 5 §4, the object form

    func object(_ json: String) throws -> Command {
        try JSONCoding.decode(Command.self, from: JSONValue.parse(json))
    }

    /// Spec 5 §4's examples, read and written back.
    func test_theObjectFormExamplesReadAndWriteBack() throws {
        let examples: [(String, EditCommand)] = [
            (#"{ "cmd": "edit.set", "object": "channel", "channel": 2, "path": "label", "value": "Lyrics" }"#,
             E(.numbered(.channel, 2), .set(path: "label", value: .string("Lyrics")))),
            (#"{ "cmd": "edit.cueChannel", "object": "cue", "list": 42, "cue": "\#(Self.c)", "channel": 2, "state": "write", "content": { "kind": "text", "fields": { "body": "There is no shadow\nof turning with Thee" } } }"#,
             E(.cue(list: 42, cue: Self.C), .cueChannel(CueChannelEdit(channel: 2, state: .write(.text(fields: ["body": "There is no shadow\nof turning with Thee"]), .none))))),
            (#"{ "cmd": "edit.insert", "object": "list", "list": 42, "path": "cues", "at": 2, "value": { "label": "Verse 2", "uuid": "\#(Self.w)" } }"#,
             E(.list(42), .insert(path: "cues", at: 2, value: .object(["label": .string("Verse 2"), "uuid": .string(Self.w)])))),
            (#"{ "cmd": "edit.renumber", "object": "channel", "channel": 2, "to": 5 }"#, E(.numbered(.channel, 2), .renumber(to: 5))),
            (#"{ "cmd": "edit.move", "object": "preset", "preset": 3, "path": "layouts.2.boxes", "from": 1, "at": 3 }"#,
             E(.numbered(.preset, 3), .move(path: "layouts.2.boxes", from: 1, at: 3))),
            (#"{ "cmd": "edit.create", "object": "playlist", "playlist": "\#(Self.u)", "title": "Sunday" }"#,
             E(.playlist(Self.U), .create(body: nil, folder: nil, title: "Sunday"))),
            (#"{ "cmd": "edit.cueChannel", "object": "cue", "list": 42, "cue": "\#(Self.c)", "channel": 2, "state": "hold", "attributes": [{ "channel": 2, "cmd": "channel.grade", "ref": 5 }], "at": 0 }"#,
             E(.cue(list: 42, cue: Self.C), .cueChannel(CueChannelEdit(channel: 2, state: .hold, attributes: [.channelGrade(channel: .number(2), ref: 5, ms: nil)], at: 0)))),
            (#"{ "cmd": "edit.section", "object": "cue", "list": 42, "cue": "\#(Self.c)", "action": "move", "at": 9 }"#,
             E(.cue(list: 42, cue: Self.C), .section(.move(at: 9)))),
            (#"{ "cmd": "edit.archive", "object": "playlist", "playlist": "\#(Self.p)", "title": "Sunday 2026-11-01", "uuid": "\#(Self.u)", "itemUuids": ["\#(Self.v)"] }"#,
             E(.playlist(Self.P), .archive(title: "Sunday 2026-11-01", picks: EditPicks(uuid: Self.U, itemUuids: [Self.V])))),
        ]
        for (json, edit) in examples {
            let tree = try JSONValue.parse(json)
            XCTAssertEqual(try object(json), .edit(edit), json)
            XCTAssertEqual(try JSONCoding.encode(Command.edit(edit)), tree, json)
        }
    }

    /// Spec 1 §6 and §8 — an edit object that doesn't decode is kept verbatim
    /// as `.invalid`; unknown keys on one survive a round trip.
    func test_aBadEditObjectIsKeptAndUnknownKeysSurvive() throws {
        for json in [#"{ "cmd": "edit.set", "object": "channel", "channel": 2, "value": 1 }"#,
                     #"{ "cmd": "edit.set", "object": "sprocket", "path": "x", "value": 1 }"#,
                     #"{ "cmd": "edit.remove", "object": "preset", "preset": 3, "path": "layouts.2.boxes" }"#,
                     #"{ "cmd": "edit.cueChannel", "object": "cue", "list": 42, "cue": "\#(Self.c)", "channel": 2, "state": "hold", "attributes": [{ "cmd": "channel.clear", "channel": 2 }] }"#] {
            let command = try object(json)
            XCTAssertTrue(command.isInvalid, "\(json) → \(command)")
            XCTAssertEqual(try JSONCoding.encode(command), try JSONValue.parse(json), "kept as written")
        }
        let entry = try JSONCoding.decode(GuardedCommand.self, from: JSONValue.parse(
            #"{ "cmd": "edit.delete", "object": "list", "list": 42, "zzNewer": [1] }"#))
        XCTAssertEqual(entry.command, .edit(E(.list(42), .delete)))
        XCTAssertEqual(entry.extra, ["zzNewer": .array([.number(1)])])
        XCTAssertEqual(try JSONCoding.encode(entry)["zzNewer"], .array([.number(1)]))
    }

    /// Spec 1 §4 — renumbering rewrites the numbers an edit held by a cue or a
    /// macro names: its address and what a channel edit writes.
    func test_anEditsReferencesFollowARenumber() {
        let held = Command.edit(E(.cue(list: 42, cue: Self.C), .cueChannel(CueChannelEdit(
            channel: 2, state: .write(.text(fields: ["body": "x"]), Riders(grade: GradeRider(ref: 1, scope: .track))),
            attributes: [.channelTransition(channel: .number(2), ref: 2, ms: nil)]))))
        let mapped = held.mapReferences { type, n in
            switch (type, n) {
            case (.list, 42): return 43
            case (.channel, 2): return 5
            case (.grade, 1): return 7
            case (.transition, 2): return 3
            default: return n
            }
        }
        XCTAssertEqual(mapped, .edit(E(.cue(list: 43, cue: Self.C), .cueChannel(CueChannelEdit(
            channel: 5, state: .write(.text(fields: ["body": "x"]), Riders(grade: GradeRider(ref: 7, scope: .track))),
            attributes: [.channelTransition(channel: .number(5), ref: 3, ms: nil)])))))
        var lists: [Int] = []
        Command.edit(E(.list(99), .set(path: "title", value: .string("x")))).forEachReference(of: .list) { lists.append($0) }
        XCTAssertEqual(lists, [99], "a held edit names its list, so a new list's number goes past it (Spec 7 §2)")
        XCTAssertEqual(Command.edit(E(.list(42), .delete)).undoClass, .edit)
        XCTAssertEqual(Command.edit(E(.list(42), .delete)).logKind, .edit)
    }

    // MARK: - Spec 5 §2, over OSC

    /// "over OSC as `/o/edit/...` (the text form with slashes, Spec 2 §6)".
    func test_editsTravelOverOSC() {
        func command(_ message: OSCMessage, line: UInt = #line) -> Command? {
            switch OSCMapping.command(from: message) {
            case .success(let c): return c
            case .failure(let r):
                XCTFail("\(message) → \(r.message)", line: line)
                return nil
            }
        }
        let title = Command.edit(E(.list(42), .set(path: "title", value: .string("Great Is Thy Faithfulness"))))
        XCTAssertEqual(OSCMapping.message(for: title), OSCMessage("/o/edit", [.string("list 42 title \"Great Is Thy Faithfulness\"")]))
        XCTAssertEqual(command(OSCMessage("/o/edit", [.string("list 42 title \"Great Is Thy Faithfulness\"")])), title)
        XCTAssertEqual(command(OSCMessage("/o/edit/list/42/title", [.string("Great Is Thy Faithfulness")])), title)
        XCTAssertEqual(command(OSCMessage("/o/edit/list/42/title", [.string("\"Great Is Thy Faithfulness\"")])), title)
        // A path keeps its case; a typed number is a number.
        XCTAssertEqual(command(OSCMessage("/o/edit/list/42/cue/\(Self.c)/advanceAfterMs", [.int32(12000)])),
                       .edit(E(.cue(list: 42, cue: Self.C), .set(path: "advanceAfterMs", value: .number(12000)))))
        XCTAssertEqual(command(OSCMessage("/o/edit/list/42/cue/\(Self.c)/channel/2/hold")),
                       .edit(E(.cue(list: 42, cue: Self.C), .cueChannel(CueChannelEdit(channel: 2, state: .hold)))))
        XCTAssertEqual(command(OSCMessage("/o/edit", [.string("folder \"Worship/Hymns\" create")])),
                       .edit(E(.folder("Worship/Hymns"), .create(body: nil, folder: nil, title: nil))))
        if case .success = OSCMapping.command(from: OSCMessage("/o/edit")) { XCTFail("an edit needs what it changes") }
    }
}
