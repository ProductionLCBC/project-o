import Foundation
import XCTest
@testable import OCore

/// Spec 8 §2 — the media commands, as Spec 2 §2, §3, §6 and §9 take them in:
/// the `media` target, the `hash` and `json` arguments, the object and text
/// forms and `parse(print(x)) == x` for each, the OSC form, the log kind and
/// undo class, and the validator's form checks.
final class MediaCommandTests: XCTestCase {
    typealias F = FixtureLibrary

    static let oldID = F.dawn
    static let newID = F.cross
    static let files = [MediaTrashedFile(location: MediaLocation(.mediaRoot, "backgrounds/dawn.mp4") ?? MediaLocation(.mediaRoot, "x")!,
                                         trash: "/Users/av/.Trash/dawn.mp4")]
    static var filesBody: String {
        JSONCanonical.line(.object(["files": (try? JSONCoding.encode(files)) ?? .null]))
    }
    static let record = MediaReplaceRecord(
        refs: [MediaReference(object: "cue", address: ["list": .number(42), "cue": .string(F.list42Cues[0].uuidString.lowercased())],
                              path: "commands.0.content.ref")],
        mapping: MediaMappingChanges(removed: [], added: [MediaMapping(index: .library, from: F.dawn, to: F.cross)]),
        defaults: MediaDefaults(loop: false))
    static var recordBody: String {
        JSONCanonical.line(.object(MediaCommand.unreplace(old: oldID, new: newID, record: record).fields.filter { MediaReplaceRecord.keys.contains($0.key) }))
    }

    /// Every form, as text and as an object, both ways.
    static var forms: [(text: String, command: MediaCommand)] {
        [
            ("media import \"/Users/Shared/Project O/Staging/Welcome.mov\"", .importFile(path: "/Users/Shared/Project O/Staging/Welcome.mov")),
            ("media rebuild", .rebuild),
            ("media replace \(oldID) \(newID)", .replace(old: oldID, new: newID, record: nil)),
            ("media replace \(oldID) \(newID) \(recordBody)", .replace(old: oldID, new: newID, record: record)),
            ("media delete \(oldID)", .delete(id: oldID, files: nil)),
            ("media delete \(oldID) \(filesBody)", .delete(id: oldID, files: files)),
            ("media undelete \(oldID) \(filesBody)", .undelete(id: oldID, files: files)),
            ("media unreplace \(oldID) \(newID) \(recordBody)", .unreplace(old: oldID, new: newID, record: record)),
        ]
    }

    func parse(_ text: String, _ options: ParseOptions = ParseOptions()) -> Result<Command, Rejection> {
        CommandText.parse(text, options: options).map(\.command)
    }

    /// Spec 2 §4 — "One function each way, and `parse(print(x)) == x` for
    /// every object", the logged forms with their recorded bodies included.
    func test_everyFormParsesPrintsAndRoundTripsItsObject() throws {
        for (text, media) in Self.forms {
            let command = Command.media(media)
            XCTAssertEqual(try parse(text).get(), command, text)
            XCTAssertEqual(CommandText.print(command), text)
            let object = try JSONCoding.encode(command)
            XCTAssertEqual(object["cmd"], .string(media.cmd))
            XCTAssertEqual(try JSONCoding.decode(Command.self, from: object), command, text)
        }
    }

    /// Spec 8 §2's table — the object forms.
    func test_theObjectForms() throws {
        func object(_ media: MediaCommand) throws -> String { JSONCanonical.line(try JSONCoding.encode(Command.media(media))) }
        XCTAssertEqual(try object(.importFile(path: "/x/a.mov")), #"{ "cmd": "media.import", "path": "/x/a.mov" }"#)
        XCTAssertEqual(try object(.rebuild), #"{ "cmd": "media.rebuild" }"#)
        XCTAssertEqual(try object(.replace(old: Self.oldID, new: Self.newID, record: nil)),
                       "{ \"cmd\": \"media.replace\", \"new\": \"\(Self.newID)\", \"old\": \"\(Self.oldID)\" }")
        XCTAssertEqual(try object(.delete(id: Self.oldID, files: nil)), "{ \"cmd\": \"media.delete\", \"id\": \"\(Self.oldID)\" }")
        let undelete = try JSONCoding.encode(Command.media(.undelete(id: Self.oldID, files: Self.files)))
        XCTAssertEqual(undelete["files"]?.arrayValue?.first?["trash"], .string("/Users/av/.Trash/dawn.mp4"))
        XCTAssertEqual(undelete["files"]?.arrayValue?.first?["folder"], .string("mediaRoot"))
        let unreplace = try JSONCoding.encode(Command.media(.unreplace(old: Self.oldID, new: Self.newID, record: MediaReplaceRecord())))
        XCTAssertEqual(unreplace["defaults"], .null, "NEW kept its own defaults")
        XCTAssertEqual(unreplace["refs"], .array([]))
    }

    /// Spec 2 §2 — a hash is "abbreviated to its first 12 hex characters in
    /// the command bar as in a ref" and expanded on parse; printing is full.
    func test_abbreviatedHashesExpand() throws {
        let options = ParseOptions(mediaIDs: [Self.oldID, Self.newID])
        let short = "media replace sha256:55c84469c37e sha256:eb6384847a49"
        XCTAssertEqual(try parse(short, options).get(), .media(.replace(old: Self.oldID, new: Self.newID, record: nil)))
        XCTAssertEqual(CommandText.print(try parse(short, options).get()), "media replace \(Self.oldID) \(Self.newID)")
        XCTAssertEqual(parse("media delete sha256:55c8", options).failure?.reason, .badArgument, "fewer than 12 hex characters")
        XCTAssertEqual(parse("media delete sha256:55c84469c37e").failure?.reason, .unknownMedia, "no id to expand against")
        let twins = ParseOptions(mediaIDs: ["sha256:" + String(repeating: "a", count: 64), "sha256:" + String(repeating: "a", count: 63) + "b"])
        XCTAssertEqual(parse("media delete sha256:aaaaaaaaaaaa", twins).failure?.reason, .ambiguousMedia)
    }

    /// Spec 8 §2 — "The two inverses carry their recorded details as a JSON body".
    func test_bodiesAreChecked() {
        XCTAssertEqual(parse("media undelete \(Self.oldID)").failure?.reason, .missingArgument)
        XCTAssertEqual(parse("media unreplace \(Self.oldID) \(Self.newID)").failure?.reason, .missingArgument)
        XCTAssertEqual(parse("media delete \(Self.oldID) {\"bogus\": 1}").failure?.reason, .unexpectedToken)
        XCTAssertEqual(parse("media delete \(Self.oldID) [1, 2]").failure?.reason, .badArgument)
        XCTAssertEqual(try? parse("media unreplace \(Self.oldID) \(Self.newID) {}").get(),
                       .media(.unreplace(old: Self.oldID, new: Self.newID, record: MediaReplaceRecord())))
        XCTAssertEqual(parse("media import /no/quotes.mov").failure?.reason, .badArgument)
        XCTAssertEqual(parse("media export").failure?.reason, .unknownVerb)
    }

    /// Spec 2 §6 — "The OSC address is the text form with slashes";
    /// `media rebuild` is `/o/media/rebuild`.
    func test_theOSCForm() throws {
        XCTAssertEqual(OSCMapping.message(for: .media(.rebuild)), OSCMessage("/o/media/rebuild", []))
        XCTAssertEqual(try OSCMapping.command(from: OSCMessage("/o/media/rebuild", [])).get(), .media(.rebuild))
        let imported = Command.media(.importFile(path: "/Users/Shared/Staging/a.mov"))
        XCTAssertEqual(try OSCMapping.command(from: OSCMessage("/o/media/import", [.string("/Users/Shared/Staging/a.mov")])).get(), imported)
        XCTAssertEqual(try OSCMapping.command(from: OSCMessage("/o/media/import", [.string("\"/Users/Shared/Staging/a.mov\"")])).get(), imported,
                       "one string, the remainder of the text form")
        let delete = Command.media(.delete(id: Self.oldID, files: Self.files))
        XCTAssertEqual(OSCMapping.message(for: delete), OSCMessage("/o/media/delete", [.string(Self.oldID), .string(Self.filesBody)]))
        XCTAssertEqual(try OSCMapping.command(from: OSCMessage("/o/media/delete", [.string(Self.oldID), .string(Self.filesBody)])).get(), delete)
        XCTAssertEqual(try OSCMapping.command(from: OSCMessage("/o/media/delete", [.string("\(Self.oldID) \(Self.filesBody)")])).get(), delete)
    }

    /// Spec 2 §3 as Spec 8 §2 corrected it — lock `passes` for all six;
    /// undo `edit` for replace, delete and their inverses, `none` for import
    /// and rebuild; Spec 2 §9 — the four edits log as kind `edit`.
    func test_lockUndoAndLogClasses() {
        for (_, media) in Self.forms {
            let command = Command.media(media)
            XCTAssertEqual(command.lockClass, .passes, media.cmd)
            XCTAssertEqual(command.undoClass, media.isEdit ? .edit : .none, media.cmd)
            XCTAssertEqual(command.logKind, media.isEdit ? .edit : .runtime, media.cmd)
        }
        XCTAssertFalse(MediaCommand.rebuild.isEdit)
        XCTAssertFalse(MediaCommand.importFile(path: "/x").isEdit)
        XCTAssertTrue(MediaCommand.delete(id: Self.oldID, files: nil).isEdit)
    }

    /// Spec 3 §6 as Spec 8 corrected it — `media` commands "pass through as a
    /// `passthrough` effect for the caller to act on".
    func test_theProjectionPassesMediaCommandsThrough() {
        let (library, machine, _) = F.load()
        let context = ProjectionContext(frame: 1, library: library, machine: machine, source: CommandSource(kind: .ui))
        let state = ShowState.fresh(library: library, machine: machine)
        for (_, media) in Self.forms {
            let (after, effects) = project(state, [.media(media)], context: context)
            XCTAssertEqual(after, state)
            XCTAssertEqual(effects, [.passthrough(.media(media))])
        }
    }

    /// Spec 8 §7 — "A command's own rejections are Spec 2 §9's `code:
    /// message` results": an id neither index holds is `unknownObject`, and a
    /// PATH that isn't absolute is `unreadable`. Spec 8 §2 — "A holder's media
    /// commands are checked when it's saved, for their form and that their
    /// ids resolve (Spec 5 §6, step 8)".
    func test_theValidatorChecksIdsAndPaths() {
        let (library, machine, _) = F.load()
        let context = ValidationContext(library: library, machine: machine, state: nil, source: CommandSource(kind: .ui))
        func reason(_ media: MediaCommand) -> RejectionReason? {
            CommandValidator.validate(.media(media), guard: nil, context: context)?.reason
        }
        let ghost = "sha256:" + String(repeating: "cd", count: 32)
        XCTAssertNil(reason(.replace(old: F.dawn, new: F.cross, record: nil)))
        XCTAssertNil(reason(.delete(id: F.announcement, files: nil)), "a machine-index item")
        XCTAssertNil(reason(.rebuild))
        XCTAssertNil(reason(.importFile(path: "/Users/Shared/Staging/a.mov")))
        XCTAssertEqual(reason(.delete(id: ghost, files: nil)), .unknownObject)
        XCTAssertEqual(reason(.replace(old: F.dawn, new: ghost, record: nil)), .unknownObject)
        XCTAssertEqual(reason(.delete(id: F.welcomeSlide, files: nil)), .unknownObject, "HASH is sha256: and the hex")
        XCTAssertEqual(reason(.importFile(path: "Staging/a.mov")), .unreadable)

        // A cue that would hold a media command naming no item can't be saved.
        let cue = F.list42Cues[1].uuidString.lowercased()
        let insert = EditCommand(.cue(list: 42, cue: F.list42Cues[1]),
                                 .insert(path: "commands", at: 0, value: (try? JSONCoding.encode(Command.media(.delete(id: ghost, files: nil)))) ?? .null))
        var editable = machine
        editable.settings.libraryMode = .writable
        switch LibraryEditor.apply(insert, library: library, machine: editable, context: EditContext()) {
        case .success: XCTFail("cue \(cue) took a media command naming no item")
        case .failure(let rejection): XCTAssertEqual(rejection.reason, .unknownReference, rejection.message)
        }
    }
}

extension Result {
    var failure: Failure? {
        if case .failure(let error) = self { return error }
        return nil
    }
}
