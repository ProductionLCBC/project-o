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
        guard case .cue(let found, let index, let stack) = request.subject else { return XCTFail("a cue") }
        XCTAssertEqual(found.number, 42)
        XCTAssertEqual(index, 1, "the cue's place in its list, from 0")
        XCTAssertEqual(stack.number, 1)
        // Any stack of the machine, not the thumbnail stack alone.
        guard case .cue(_, _, let other) = try parse(cueSubject { $0["stack"] = .number(2) }).get().subject else { return XCTFail("a cue") }
        XCTAssertEqual(other.number, 2)
        // A local copy, by `local`.
        let local = try XCTUnwrap(machine.localLists.first)
        let localCue = try XCTUnwrap(local.cues.first)
        let asked = parse(cueSubject {
            $0["listUuid"] = nil
            $0["local"] = .string(local.uuid.uuidString.lowercased())
            $0["cue"] = .string(localCue.uuid.uuidString.lowercased())
        })
        guard case .cue(let copy, 0, _) = try asked.get().subject else { return XCTFail("the local copy's first cue") }
        XCTAssertEqual(copy, local)
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
    }

    func test_aMediaItemThroughAGradeOrAsItIs() throws {
        guard case .grade(let grade, let media) = try parse(.object(["kind": .string("grade"), "grade": .number(1), "media": .string(E.dawn)])).get().subject else {
            return XCTFail("a grade")
        }
        XCTAssertEqual(grade?.number, 1)
        XCTAssertEqual(media, E.dawn)
        guard case .grade(nil, _) = try parse(.object(["kind": .string("grade"), "grade": .null, "media": .string(E.dawn)])).get().subject else {
            return XCTFail("as it is when `grade` is null")
        }
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
