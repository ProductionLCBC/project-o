import Foundation
import XCTest
@testable import OCore

/// Spec 1 §10 — Stack rule: "A second slot for a channel in a stack is ignored
/// and reported." Spec 6 §2 — "The engine uses the first slot for a channel
/// and ignores any later one. A later slot stays in the document as read and
/// is reported on every load (Spec 1 §8)"; "A stacks document that still has
/// `offset` on a slot keeps it as an unknown key (Spec 1 §8), which the engine
/// ignores; an old +1 slot is then a duplicate." Spec 6 §3 — a box's
/// `offset`, "written on every box, 0 included", flagged outside −2 to +3.
final class StackRuleTests: XCTestCase {
    typealias F = FixtureLibrary

    private func stacksDocument(slots: [JSONValue]) throws -> Data {
        var tree = try JSONValue.parse(try XCTUnwrap(F.machineSnapshot.files["stacks.json"]))
        var stacks = tree["stacks"]?.arrayValue ?? []
        stacks[0] = stacks[0].setting("slots", to: .array(slots))
        tree = tree.setting("stacks", to: .array(stacks))
        return JSONCanonical.data(tree)
    }

    private func slot(_ channel: Int, preset: Int? = nil, opacity: Double = 1, offset: Int? = nil) -> JSONValue {
        var members: [String: JSONValue] = ["channel": .number(Double(channel)), "mute": .bool(false), "opacity": .number(opacity),
                                            "preset": preset.map { .number(Double($0)) } ?? .null]
        if let offset { members["offset"] = .number(Double(offset)) }
        return .object(members)
    }

    // MARK: - Slots (Spec 6 §2)

    func test_aSecondSlotForAChannelIsIgnoredReportedAndKept() throws {
        var snapshot = F.machineSnapshot
        let document = try stacksDocument(slots: [slot(1), slot(2), slot(2, preset: 3)])
        snapshot.files["stacks.json"] = document
        let loaded = Loader.machine(from: snapshot)
        XCTAssertEqual(loaded.report.issues.map(\.code), [.duplicateSlot])
        let issue = try XCTUnwrap(loaded.report.issues.first)
        XCTAssertEqual(issue.subject, "stack 1 slot 3")
        XCTAssertEqual(issue.file, "stacks.json")
        XCTAssertEqual(issue.message, "channel 2 already has a slot in this stack; this one is ignored")
        XCTAssertEqual(loaded.machine.stack(1)?.slots.count, 3, "the document is kept as read")
        let effective = try XCTUnwrap(loaded.machine.stack(1)?.effectiveSlots(library: F.load().library))
        XCTAssertEqual(effective.map(\.channel), [1, 2], "the later slot is ignored at use")
        XCTAssertNil(effective[1].preset, "the engine uses the first slot for the channel")

        // Written back as read, the later slot included.
        let written = Writer.data(for: try Loader.document(path: "stacks.json", data: document))
        XCTAssertEqual(written, document)

        let (library, machine, _) = F.load()
        var stack = try XCTUnwrap(machine.stack(1))
        stack.slots.append(StackSlot(channel: 1, preset: nil, opacity: 1, mute: true))
        XCTAssertEqual(stack.duplicateSlotIndices, [2])
        XCTAssertEqual(Validator.validate(library: library, machine: machine).issues, [], "the fixture has one slot per channel")
    }

    /// Spec 6 §2 — "No migration ... A stacks document that still has
    /// `offset` on a slot keeps it as an unknown key (Spec 1 §8), which the
    /// engine ignores; an old +1 slot is then a duplicate."
    func test_anOldSlotOffsetIsAnUnknownKeyAndAnOldPlusOneSlotIsADuplicate() throws {
        var snapshot = F.machineSnapshot
        let document = try stacksDocument(slots: [slot(2, offset: 0), slot(2, preset: 3, offset: 1)])
        snapshot.files["stacks.json"] = document
        let loaded = Loader.machine(from: snapshot)
        XCTAssertEqual(loaded.report.issues.map(\.code), [.duplicateSlot])
        XCTAssertEqual(loaded.report.issues.first?.subject, "stack 1 slot 2")
        XCTAssertEqual(loaded.machine.stack(1)?.slots.map { $0.extra["offset"] }, [.number(0), .number(1)])
        XCTAssertEqual(loaded.machine.stack(1)?.effectiveSlots(library: F.load().library).map(\.channel), [2])
        let written = Writer.data(for: try Loader.document(path: "stacks.json", data: document))
        XCTAssertEqual(written, document, "the old key round-trips byte for byte")
    }

    /// Spec 1 §3 — opacity runs from 0 to 1.
    func test_slotOpacityIsChecked() throws {
        var snapshot = F.machineSnapshot
        snapshot.files["stacks.json"] = try stacksDocument(slots: [slot(1, opacity: 1.5), slot(2, opacity: -0.25)])
        let loaded = Loader.machine(from: snapshot)
        XCTAssertEqual(loaded.report.issues.map(\.code), [.slotOutOfRange, .slotOutOfRange])
        XCTAssertEqual(loaded.report.issues.map(\.subject), ["stack 1 slot 1", "stack 1 slot 2"])
        XCTAssertEqual(loaded.report.issues.first?.message, "opacity 1.5 must be 0 to 1")
    }

    // MARK: - Box offsets (Spec 6 §3)

    /// "The Box gains `offset`, an integer that defaults to 0 and is written
    /// on every box, 0 included (Spec 1 §5 writes every known key)."
    func test_aBoxOffsetDefaultsToZeroAndIsWrittenOnEveryBox() throws {
        let tree = try JSONValue.parse(Data(#"{"binding":{"kind":"pixels"},"fallback":false,"fit":"fit","frame":{"h":1,"w":1,"x":0,"y":0},"grade":null,"transition":{"ms":null,"ref":1}}"#.utf8))
        let box = try JSONCoding.decode(Box.self, from: tree)
        XCTAssertEqual(box.offset, 0)
        XCTAssertEqual(try JSONCoding.encode(box)["offset"], .number(0), "written even at 0")

        var later = box
        later.offset = 2
        XCTAssertEqual(try JSONCoding.decode(Box.self, from: try JSONCoding.encode(later)).offset, 2)

        // Every box of every fixture preset carries the key.
        for preset in F.load().library.presets {
            for (key, layout) in preset.layouts {
                for (index, box) in layout.boxes.enumerated() {
                    XCTAssertEqual(try JSONCoding.encode(box)["offset"], .number(Double(box.offset)), "preset \(preset.number) layout \(key.string) box \(index + 1)")
                }
            }
        }
    }

    /// "The schema accepts −2 to +3 ... Outside −2 to +3, the reference report
    /// flags the box and it draws nothing."
    func test_boxOffsetsOutsideMinusTwoToPlusThreeAreFlagged() throws {
        var (library, machine, _) = F.load()
        for offset in Box.offsetRange {
            library.presets[0].layouts[.any]?.boxes[0].offset = offset
            XCTAssertEqual(Validator.validate(library: library, machine: machine).issues, [], "offset \(offset) is accepted")
        }
        library.presets[0].layouts[.any]?.boxes[0].offset = 4
        library.presets[0].layouts[.any]?.boxes[1].offset = -3
        let issues = Validator.validate(library: library, machine: machine).issues
        XCTAssertEqual(issues.map(\.code), [.boxOffsetOutOfRange, .boxOffsetOutOfRange])
        XCTAssertEqual(issues.map(\.subject), ["preset 1 layout * box 1", "preset 1 layout * box 2"])
        XCTAssertEqual(issues.first?.message, "offset 4 must be -2 to +3; the box draws nothing")
        XCTAssertEqual(library.presets[0].layouts[.any]?.boxes.map(\.isDrawnOffset), [false, false])
    }
}
