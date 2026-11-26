import XCTest
import OCore
@testable import OEngine

/// Spec 11 §3 — the `render` query's request, read against the roots: its
/// three subjects, and "Errors. An unknown list, cue, preset, layout, grade
/// or media id is `unknownObject`; a width outside 160 to 1920, a canvas name
/// that isn't letters and digits or is longer than 16, or a connection's
/// ninth canvas is `badValue`". The ninth canvas is the queue's
/// (`RenderQueueTests`).
final class RenderRequestTests: XCTestCase {
    typealias E = EngineFixtures

    var library: Library!
    var machine: Machine!

    override func setUpWithError() throws {
        library = try E.library()
        machine = try E.spikeMachine()
    }

    var list: String { E.list42.uuidString.lowercased() }
    var cue: String { E.list42Cues[1].uuidString.lowercased() }

    func cueSubject(_ change: (inout [String: JSONValue]) -> Void = { _ in }) -> JSONValue {
        var subject: [String: JSONValue] = ["kind": .string("cue"), "listUuid": .string(list), "cue": .string(cue), "stack": .number(1)]
        change(&subject)
        return .object(subject)
    }

    func layoutSubject(_ change: (inout [String: JSONValue]) -> Void = { _ in }) -> JSONValue {
        var subject: [String: JSONValue] = ["kind": .string("layout"), "preset": .number(3), "layout": .string("*"), "stack": .number(1),
                                            "sample": .object(["content": .object(["kind": .string("text"), "fields": .object(["body": .string("Amazing grace")])])])]
        change(&subject)
        return .object(subject)
    }

    func parse(_ subject: JSONValue, canvas: JSONValue? = .string("inspector"), width: JSONValue? = .number(640)) -> Result<RenderRequest, Rejection> {
        var members: [String: JSONValue] = ["subject": subject]
        if let canvas { members["canvas"] = canvas }
        if let width { members["width"] = width }
        return RenderRequest.parse(members, library: library, machine: machine)
    }

    func reason(_ result: Result<RenderRequest, Rejection>) -> RejectionReason? {
        if case .failure(let rejection) = result { return rejection.reason }
        return nil
    }

    // MARK: - The subjects

    func test_aCueOnAStack() throws {
        let request = try parse(cueSubject()).get()
        XCTAssertEqual(request.canvas, "inspector")
        XCTAssertEqual(request.width, 640)
        guard case .cue(let found, let index, let stack, _) = request.subject else { return XCTFail("a cue") }
        XCTAssertEqual(found.number, 42)
        XCTAssertEqual(index, 1, "the cue's place in its list, from 0")
        XCTAssertEqual(stack.number, 1)
        // Any stack of the machine, not the thumbnail stack alone.
        guard case .cue(_, _, let other, _) = try parse(cueSubject { $0["stack"] = .number(2) }).get().subject else { return XCTFail("a cue") }
        XCTAssertEqual(other.number, 2)
        // A local copy, by `local`.
        let local = try XCTUnwrap(machine.localLists.first)
        let localCue = try XCTUnwrap(local.cues.first)
        let asked = parse(cueSubject {
            $0["listUuid"] = nil
            $0["local"] = .string(local.uuid.uuidString.lowercased())
            $0["cue"] = .string(localCue.uuid.uuidString.lowercased())
        })
        guard case .cue(let copy, 0, _, _) = try asked.get().subject else { return XCTFail("the local copy's first cue") }
        XCTAssertEqual(copy, local)
        // Spec 11 §3 as corrected 2026-11-24 — "optionally `hide`": channel numbers, none by default.
        guard case .cue(_, _, _, let none) = try parse(cueSubject()).get().subject else { return XCTFail("a cue") }
        XCTAssertEqual(none, [])
        guard case .cue(_, _, _, let hidden) = try parse(cueSubject { $0["hide"] = .array([.number(2), .number(9)]) }).get().subject else {
            return XCTFail("a cue")
        }
        XCTAssertEqual(hidden, [2, 9])
        XCTAssertEqual(reason(parse(cueSubject { $0["hide"] = .string("2") })), .badValue)
        XCTAssertEqual(reason(parse(cueSubject { $0["hide"] = .array([.string("two")]) })), .badValue)
    }

    func test_aLayoutWithItsSample() throws {
        guard case .layout(let preset, let key, let stack, let sample) = try parse(layoutSubject()).get().subject else { return XCTFail("a layout") }
        XCTAssertEqual(preset.number, 3)
        XCTAssertEqual(key, .any)
        XCTAssertEqual(stack.number, 1, "the `*` layout, drawn for the stack named")
        XCTAssertEqual(sample.content, .text(fields: ["body": "Amazing grace"]))
        XCTAssertEqual(sample.next, [])
        XCTAssertNil(sample.list)

        // A stack's own layout is drawn for that stack, whatever `stack` says.
        guard case .layout(_, let own, let its, _) = try parse(layoutSubject { $0["layout"] = .number(2); $0["stack"] = nil }).get().subject else {
            return XCTFail("a layout")
        }
        XCTAssertEqual(own, .stack(2))
        XCTAssertEqual(its.number, 2)

        // Media, nothing, what comes next, and where the sample came from.
        let full = parse(layoutSubject {
            $0["sample"] = .object([
                "content": .object(["kind": .string("media"), "ref": .string(E.dawn)]),
                "next": .array([.object(["kind": .string("empty")]), .object(["kind": .string("text"), "fields": .object(["body": .string("next")])])]),
                "listUuid": .string(self.list), "cue": .string(self.cue),
            ])
        })
        guard case .layout(_, _, _, let rich) = try full.get().subject else { return XCTFail("a layout") }
        XCTAssertEqual(rich.content, .media(MediaContent(ref: E.dawn)))
        XCTAssertEqual(rich.next, [.empty, .text(fields: ["body": "next"])])
        XCTAssertEqual(rich.list?.number, 42)
        XCTAssertEqual(rich.cue, E.list42Cues[1])

        // No sample at all is an empty channel.
        guard case .layout(_, _, _, let none) = try parse(layoutSubject { $0["sample"] = nil }).get().subject else { return XCTFail("a layout") }
        XCTAssertEqual(none, RenderSample())

        // Spec 11 §3 as corrected 2026-11-24 — "the engine's test pattern (`{"kind": "pattern"}`)", for pixel boxes as a
        // media item would be, at the stack's size.
        let pattern = parse(layoutSubject {
            $0["sample"] = .object(["content": .object(["kind": .string("pattern")]), "next": .array([.object(["kind": .string("pattern")])])])
        })
        guard case .layout(_, _, _, let drawn) = try pattern.get().subject else { return XCTFail("a layout") }
        XCTAssertEqual(drawn.content, TestPattern.content)
        XCTAssertEqual(drawn.next, [TestPattern.content])
    }

    func test_aMediaItemThroughAGradeOrAsItIs() throws {
        guard case .grade(let grade, let media, let at) = try parse(.object(["kind": .string("grade"), "grade": .number(1), "media": .string(E.dawn)])).get().subject else {
            return XCTFail("a grade")
        }
        XCTAssertEqual(grade?.number, 1)
        XCTAssertEqual(media, E.dawn)
        XCTAssertNil(at, "the poster without `atMs`")
        guard case .grade(nil, _, _) = try parse(.object(["kind": .string("grade"), "grade": .null, "media": .string(E.dawn)])).get().subject else {
            return XCTFail("as it is when `grade` is null")
        }
    }

    func gradeSubject(_ grade: JSONValue, atMs: JSONValue? = nil) -> JSONValue {
        var subject: [String: JSONValue] = ["kind": .string("grade"), "grade": grade, "media": .string(E.dawn)]
        if let atMs { subject["atMs"] = atMs }
        return .object(subject)
    }

    /// Spec 11 §3 as corrected 2026-11-26 (G-43) — "A grade's values (Spec 1 §2's `hue`, `saturation`, `brightness`,
    /// `contrast`, `blur`, `tint` and `opacity`, each in its range, the identity's for any left out)"; "for a video with
    /// `atMs`, its frame at that time from the item's start".
    func test_aGradesValuesAndATimeIntoTheItem() throws {
        let values: JSONValue = .object([
            "brightness": .number(-0.25), "hue": .number(30), "blur": .number(4),
            "tint": .object(["r": .number(1), "g": .number(0.5), "b": .number(0), "a": .number(0.2)]),
        ])
        guard case .grade(let grade?, let media, let at) = try parse(gradeSubject(values, atMs: .number(1500))).get().subject else {
            return XCTFail("a grade's values")
        }
        XCTAssertEqual(media, E.dawn)
        XCTAssertEqual(at, 1500)
        XCTAssertEqual(grade.brightness, -0.25)
        XCTAssertEqual(grade.hue, 30)
        XCTAssertEqual(grade.blur, 4)
        XCTAssertEqual(grade.tint, Color(r: 1, g: 0.5, b: 0, a: 0.2))
        let identity = Grade(number: 0)
        XCTAssertEqual(grade.saturation, identity.saturation, "the identity's for one left out")
        XCTAssertEqual(grade.contrast, identity.contrast)
        XCTAssertEqual(grade.opacity, identity.opacity)
        // Values that aren't in the library: nothing names a grade's number.
        XCTAssertNil(library.grades.first { $0.number == grade.number && $0.brightness == -0.25 })
        guard case .grade(_, _, 0) = try parse(gradeSubject(.number(1), atMs: .number(0))).get().subject else {
            return XCTFail("a stored grade at a time")
        }
    }

    /// "each in its range": the ranges an edit of a grade is checked against (Spec 5 §6, check 4).
    func test_aGradeValueOutOfItsRangeUnknownOrOfTheWrongKindAndABadTimeAreBadValue() {
        let bad: [[String: JSONValue]] = [
            ["saturation": .number(-0.1)], ["contrast": .number(-1)], ["blur": .number(-2)], ["opacity": .number(1.5)], ["opacity": .number(-0.1)],
            ["tint": .object(["r": .number(2), "g": .number(0), "b": .number(0), "a": .number(1)])],
            ["tint": .object(["r": .number(1), "g": .number(0), "b": .number(0)])],
            ["tint": .string("red")], ["hue": .string("30")], ["glow": .number(1)],
        ]
        for values in bad {
            XCTAssertEqual(reason(parse(gradeSubject(.object(values)))), .badValue, "\(values)")
        }
        for at: JSONValue in [.number(-1), .number(1.5), .string("1500"), .null] {
            XCTAssertEqual(reason(parse(gradeSubject(.number(1), atMs: at))), .badValue, "\(at)")
        }
        XCTAssertEqual(reason(parse(gradeSubject(.string("1")))), .badValue, "a grade is a number, its values or null")
    }

    // MARK: - Errors

    func test_anUnknownListCuePresetLayoutGradeMediaOrStackIsUnknownObject() {
        let nobody = UUID().uuidString.lowercased()
        XCTAssertEqual(reason(parse(cueSubject { $0["listUuid"] = .string(nobody) })), .unknownObject)
        XCTAssertEqual(reason(parse(cueSubject { $0["cue"] = .string(nobody) })), .unknownObject)
        XCTAssertEqual(reason(parse(cueSubject { $0["stack"] = .number(9) })), .unknownObject)
        XCTAssertEqual(reason(parse(layoutSubject { $0["preset"] = .number(99) })), .unknownObject)
        XCTAssertEqual(reason(parse(layoutSubject { $0["layout"] = .number(1) })), .unknownObject, "preset 3 has no layout for stack 1")
        XCTAssertEqual(reason(parse(layoutSubject { $0["stack"] = .number(9) })), .unknownObject)
        XCTAssertEqual(reason(parse(layoutSubject {
            $0["sample"] = .object(["content": .object(["kind": .string("media"), "ref": .string("sha256:" + String(repeating: "0", count: 64))])])
        })), .unknownObject)
        XCTAssertEqual(reason(parse(.object(["kind": .string("grade"), "grade": .number(99), "media": .string(E.dawn)]))), .unknownObject)
        XCTAssertEqual(reason(parse(.object(["kind": .string("grade"), "grade": .null, "media": .string("sha256:nothing")]))), .unknownObject)
    }

    func test_aWidthOrACanvasNameOutOfBoundsIsBadValue() throws {
        for width in [159, 1921, 0, -640] { XCTAssertEqual(reason(parse(cueSubject(), width: .number(Double(width)))), .badValue, "\(width)") }
        XCTAssertEqual(reason(parse(cueSubject(), width: .number(640.5))), .badValue)
        XCTAssertEqual(reason(parse(cueSubject(), width: .string("640"))), .badValue)
        XCTAssertEqual(try parse(cueSubject(), width: .number(160)).get().width, 160)
        XCTAssertEqual(try parse(cueSubject(), width: .number(1920)).get().width, 1920)
        for canvas in ["", "a canvas", "inspector-1", "précis", "abcdefghijklmnopq"] {
            XCTAssertEqual(reason(parse(cueSubject(), canvas: .string(canvas))), .badValue, canvas)
        }
        XCTAssertEqual(reason(parse(cueSubject(), canvas: .number(3))), .badValue)
        XCTAssertEqual(try parse(cueSubject(), canvas: .string("abcdefghijklmnop")).get().canvas, "abcdefghijklmnop", "sixteen")
        XCTAssertEqual(try parse(cueSubject(), canvas: .string("Canvas2")).get().canvas, "Canvas2")
    }

    func test_whatIsMissingOrOfTheWrongKind() {
        XCTAssertEqual(reason(parse(cueSubject(), canvas: nil)), .missingArgument)
        XCTAssertEqual(reason(parse(cueSubject(), width: nil)), .missingArgument)
        XCTAssertEqual(reason(RenderRequest.parse(["canvas": .string("a"), "width": .number(640)], library: library, machine: machine)), .missingArgument)
        XCTAssertEqual(reason(parse(.object(["kind": .string("stack"), "stack": .number(1)]))), .badValue, "there are three subjects")
        XCTAssertEqual(reason(parse(.string("cue"))), .badValue)
        XCTAssertEqual(reason(parse(cueSubject { $0["listUuid"] = nil })), .missingArgument)
        XCTAssertEqual(reason(parse(cueSubject { $0["cue"] = nil })), .missingArgument)
        XCTAssertEqual(reason(parse(cueSubject { $0["stack"] = nil })), .missingArgument)
        XCTAssertEqual(reason(parse(cueSubject { $0["listUuid"] = .string("forty-two") })), .badValue)
        XCTAssertEqual(reason(parse(layoutSubject { $0["stack"] = nil })), .missingArgument, "the `*` layout needs the stack it is drawn for")
        XCTAssertEqual(reason(parse(layoutSubject { $0["layout"] = .string("all") })), .badValue)
        XCTAssertEqual(reason(parse(layoutSubject { $0["sample"] = .object(["content": .object(["kind": .string("slide")])]) })), .badValue)
        XCTAssertEqual(reason(parse(layoutSubject { $0["sample"] = .object(["content": .object(["kind": .string("text"), "fields": .object(["body": .number(3)])])]) })), .badValue)
        let four = JSONValue.array(Array(repeating: .object(["kind": .string("empty")]), count: 4))
        XCTAssertEqual(reason(parse(layoutSubject { $0["sample"] = .object(["next": four]) })), .badValue, "up to three more")
        XCTAssertEqual(reason(parse(layoutSubject { $0["sample"] = .object(["cue": .string(self.cue)]) })), .badValue, "a cue with no list")
        XCTAssertEqual(reason(parse(.object(["kind": .string("grade"), "grade": .null]))), .missingArgument)
    }

    /// "named by connection, canvas and request `id` (`c3-inspector-61.png`)".
    func test_theIdAFilesNameCarries() {
        XCTAssertEqual(RenderRequest.fileID(.number(61)), "61")
        XCTAssertEqual(RenderRequest.fileID(.string("drag7")), "drag7")
        XCTAssertNil(RenderRequest.fileID(.string("../../etc")), "nothing that could leave the folder")
        XCTAssertNil(RenderRequest.fileID(.string("")))
        XCTAssertNil(RenderRequest.fileID(.number(1.5)))
        XCTAssertNil(RenderRequest.fileID(.number(-1)))
        XCTAssertNil(RenderRequest.fileID(.null))
        XCTAssertNil(RenderRequest.fileID(.string(String(repeating: "a", count: 33))))
    }
}
