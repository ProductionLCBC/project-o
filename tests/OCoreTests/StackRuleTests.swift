import Foundation
import XCTest
@testable import OCore

/// Spec 1 §10 — Stack rule: "Duplicate channel-and-offset pairs in a stack are
/// rejected; distinct offsets of one channel are accepted." Spec 1 §9: "a
/// channel appears at most once per stack at each offset, and the loader
/// enforces that form."
final class StackRuleTests: XCTestCase {
    typealias F = FixtureLibrary

    private func stacksDocument(slots: [JSONValue]) throws -> Data {
        var tree = try JSONValue.parse(try XCTUnwrap(F.machineSnapshot.files["stacks.json"]))
        var stacks = tree["stacks"]?.arrayValue ?? []
        stacks[0] = stacks[0].setting("slots", to: .array(slots))
        tree = tree.setting("stacks", to: .array(stacks))
        return JSONCanonical.data(tree)
    }

    private func slot(_ channel: Int, offset: Int, preset: Int? = nil) -> JSONValue {
        .object(["channel": .number(Double(channel)), "mute": .bool(false), "offset": .number(Double(offset)),
                 "opacity": .number(1), "preset": preset.map { .number(Double($0)) } ?? .null])
    }

    func test_duplicateChannelAndOffsetPairsAreRejected() throws {
        var snapshot = F.machineSnapshot
        snapshot.files["stacks.json"] = try stacksDocument(slots: [slot(1, offset: 0), slot(2, offset: 0), slot(2, offset: 0, preset: 3)])
        let loaded = Loader.machine(from: snapshot)
        XCTAssertEqual(loaded.report.issues.map(\.code), [.duplicateSlot])
        XCTAssertEqual(loaded.report.issues.first?.subject, "stack 1 slot 3")
        XCTAssertEqual(loaded.report.issues.first?.file, "stacks.json")
        XCTAssertEqual(loaded.machine.stack(1)?.slots.count, 3, "the document is kept as read")
        XCTAssertEqual(loaded.machine.stack(1)?.effectiveSlots(library: F.load().library).map(\.channel), [1, 2], "the duplicate is an empty slot at use")

        let (library, machine, _) = F.load()
        var stack = try XCTUnwrap(machine.stack(1))
        stack.slots.append(StackSlot(channel: 1, preset: nil, offset: 0, opacity: 1, mute: true))
        XCTAssertEqual(stack.duplicateSlotIndices, [2])
        XCTAssertEqual(Validator.validate(library: library, machine: machine).issues, [])
    }

    func test_distinctOffsetsOfOneChannelAreAccepted() throws {
        var snapshot = F.machineSnapshot
        snapshot.files["stacks.json"] = try stacksDocument(slots: [slot(2, offset: -2), slot(2, offset: -1), slot(2, offset: 0), slot(2, offset: 1), slot(2, offset: 2), slot(2, offset: 3)])
        let loaded = Loader.machine(from: snapshot)
        XCTAssertEqual(loaded.report.issues, [])
        XCTAssertEqual(loaded.machine.stack(1)?.slots.map(\.offset), [-2, -1, 0, 1, 2, 3])
        XCTAssertEqual(loaded.machine.stack(1)?.duplicateSlotIndices, [])
        // The §9 confidence stack is the worked example of the rule.
        XCTAssertEqual(F.load().machine.stack(2)?.slots.map { ($0.channel, $0.offset) }.map { "\($0.0)@\($0.1)" }, ["2@0", "2@1"])
    }

    /// Spec 1 §3 — offsets run from -2 to +3 and opacity from 0 to 1.
    func test_slotRangesAreChecked() throws {
        var snapshot = F.machineSnapshot
        snapshot.files["stacks.json"] = try stacksDocument(slots: [slot(1, offset: 4), slot(2, offset: -3)])
        let loaded = Loader.machine(from: snapshot)
        XCTAssertEqual(loaded.report.issues.map(\.code), [.slotOutOfRange, .slotOutOfRange])
        XCTAssertEqual(loaded.report.issues.map(\.subject), ["stack 1 slot 1", "stack 1 slot 2"])
    }
}
