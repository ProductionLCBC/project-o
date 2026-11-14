import Foundation
import XCTest
@testable import OCore

/// Spec 9 §4 — "`machine/state/last.json` holds ShowState (Spec 3 §2) as the
/// engine last projected it, and some facts about the run that wrote it":
/// `writtenAt`, `run`, `clean`, `restored` and `pendingClears` beside `state`.
/// "The new keys are optional, so the fixture's file reads as before."
final class LastStateFileTests: XCTestCase {
    typealias F = FixtureLibrary

    static let run = F.uuid("51e2", 1)
    static let stateJSON = "{ \"channels\": {}, \"outputs\": { \"1\": 1 }, \"popups\": { \"3\": \"Nursery 12\" }, \"stacks\": {} }"

    /// The fixture's machine root with `state/last.json` holding `text`, or without the file.
    func machine(lastJSON text: String?) -> Machine {
        var snapshot = F.machineSnapshot
        snapshot.files["state/last.json"] = text.map { Data($0.utf8) }
        return Loader.machine(from: snapshot).machine
    }

    func test_theKeysOfTheSpecExampleAreRead() throws {
        let machine = machine(lastJSON: """
        { "schema": 1, "app": "0.1.0", "kind": "state", "writtenAt": "2026-11-08T09:41:07.002-05:00",
          "run": "\(Self.run.uuidString.lowercased())", "clean": false, "restored": false, "pendingClears": [3],
          "state": \(Self.stateJSON) }
        """)
        let last = try XCTUnwrap(machine.last)
        XCTAssertEqual(last.writtenAt, "2026-11-08T09:41:07.002-05:00")
        XCTAssertEqual(last.run, Self.run)
        XCTAssertEqual(last.clean, false)
        XCTAssertEqual(last.restored, false)
        XCTAssertEqual(last.pendingClears, [3])
        XCTAssertEqual(last.state.popups, [3: "Nursery 12"])
        XCTAssertEqual(last.state.outputs, [1: 1])
        XCTAssertEqual(machine.lastState, last.state, "the loader's state is the same one")
    }

    /// Spec 9 §4 — "The new keys are optional": a file from before this spec.
    func test_aFileWithoutTheNewKeysReadsAsBefore() throws {
        let machine = machine(lastJSON: "{ \"schema\": 1, \"app\": \"0.1.0\", \"kind\": \"state\", \"state\": \(Self.stateJSON) }")
        let last = try XCTUnwrap(machine.last)
        XCTAssertNil(last.writtenAt)
        XCTAssertNil(last.run)
        XCTAssertNil(last.clean)
        XCTAssertNil(last.restored)
        XCTAssertEqual(last.pendingClears, [])
        XCTAssertEqual(last.state.popups, [3: "Nursery 12"])
    }

    func test_noFileIsNoLastState() {
        XCTAssertNil(machine(lastJSON: nil).last)
    }

    /// CLAUDE.md — nothing that came from a file may trap: a key of the wrong
    /// shape reads as absent, and the state still loads.
    func test_keysOfTheWrongShapeReadAsAbsent() throws {
        let machine = machine(lastJSON: """
        { "schema": 1, "app": "0.1.0", "kind": "state", "writtenAt": 12, "run": "not a uuid", "clean": "yes",
          "restored": 1, "pendingClears": "none", "state": \(Self.stateJSON) }
        """)
        let last = try XCTUnwrap(machine.last)
        XCTAssertNil(last.writtenAt)
        XCTAssertNil(last.run)
        XCTAssertNil(last.clean)
        XCTAssertNil(last.restored)
        XCTAssertEqual(last.pendingClears, [])
        XCTAssertEqual(last.state.outputs, [1: 1])
    }

    /// Spec 9 §4 — what the engine writes: the header every document has
    /// (Spec 1 §5), every fact of the run, and the state; sorted keys, LF.
    func test_theWrittenFileCarriesEveryFactAndReadsBack() throws {
        var state = ShowState()
        state.popups = [3: "Nursery 12", 1: "Welcome"]
        state.outputs = [1: 1]
        let written = LastState(writtenAt: "2026-11-08T09:41:07.002-05:00", run: Self.run, clean: false, restored: true,
                                pendingClears: [3, 1], state: state)
        let data = written.data
        let tree = try JSONValue.parse(data)
        XCTAssertEqual(tree["schema"], .number(1))
        XCTAssertEqual(tree["app"], .string(OCore.appVersion))
        XCTAssertEqual(tree["kind"], .string("state"))
        XCTAssertEqual(tree["writtenAt"], .string("2026-11-08T09:41:07.002-05:00"))
        XCTAssertEqual(tree["run"], .string(Self.run.uuidString.lowercased()), "uuids are lowercase (Spec 1 §5)")
        XCTAssertEqual(tree["clean"], .bool(false))
        XCTAssertEqual(tree["restored"], .bool(true))
        XCTAssertEqual(tree["pendingClears"], .array([.number(1), .number(3)]), "in slot order")
        XCTAssertEqual(tree["state"]?["popups"], .object(["1": .string("Welcome"), "3": .string("Nursery 12")]))
        XCTAssertEqual(data, JSONCanonical.data(tree), "canonical bytes")
        XCTAssertEqual(data.last, UInt8(ascii: "\n"))

        let read = try XCTUnwrap(machine(lastJSON: String(decoding: data, as: UTF8.self)).last)
        var expected = written
        expected.pendingClears = [1, 3]
        XCTAssertEqual(read, expected)
    }

    /// `formats/schemas/state.schema.json` describes the file as Spec 9 §4 has it.
    func test_theWrittenFileValidatesAgainstTheSchema() throws {
        let schemaURL = F.schemasRoot.appendingPathComponent("state.schema.json")
        let schema = try JSONValue.parse(try XCTUnwrap(FileManager.default.contents(atPath: schemaURL.path)))
        let written = LastState(writtenAt: "2026-11-08T09:41:07.002-05:00", run: Self.run, clean: true, restored: false,
                                pendingClears: [], state: F.load().machine.lastState ?? ShowState())
        XCTAssertEqual(MiniSchema.validate(try JSONValue.parse(written.data), against: schema), [])
        for key in ["writtenAt", "run", "clean", "restored", "pendingClears"] {
            XCTAssertNotNil(schema["properties"]?[key], "\(key) is described")
        }
        // A wrong shape is caught.
        let wrong = try JSONValue.parse(written.data).setting("clean", to: .string("yes"))
        XCTAssertEqual(MiniSchema.validate(wrong, against: schema).count, 1)
    }
}
