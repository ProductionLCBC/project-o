import Foundation
import XCTest
@testable import OCore

/// Spec 1 §10 — Command encoding: "Every command object in the fixtures
/// converts to canonical text and back without loss (shared with Spec 2's
/// tests)." The text half is Area 3's parser; here every fixture command is a
/// known object that re-encodes to the same JSON, and §6's "kept verbatim and
/// flagged" rule holds for what the vocabulary does not know.
final class CommandEncodingTests: XCTestCase {
    typealias F = FixtureLibrary

    private func allCommands(_ library: Library, _ machine: Machine) -> [(where: String, entry: GuardedCommand)] {
        var out: [(String, GuardedCommand)] = []
        for list in library.lists + machine.localLists {
            for (c, cue) in list.cues.enumerated() {
                for (i, entry) in cue.commands.enumerated() { out.append(("list \(list.number) cue \(c + 1) command \(i + 1)", entry)) }
            }
        }
        for macro in library.macros + machine.macros {
            for (i, entry) in macro.commands.enumerated() { out.append(("macro \(macro.number) command \(i + 1)", entry)) }
        }
        for (i, key) in machine.keys.enumerated() { out.append(("key binding \(i + 1)", GuardedCommand(key.command))) }
        return out
    }

    func test_everyFixtureCommandIsAKnownObjectThatReEncodesWithoutLoss() throws {
        let (library, machine, _) = F.load()
        let commands = allCommands(library, machine)
        XCTAssertGreaterThan(commands.count, 25)
        var seen: Set<String> = []
        for (location, entry) in commands {
            XCTAssertFalse(entry.command.isUnknown, "\(location): \(entry.command)")
            XCTAssertFalse(entry.command.isInvalid, "\(location): \(entry.command)")
            seen.insert(entry.command.cmd)
            let tree = try JSONCoding.encode(entry)
            XCTAssertEqual(try JSONCoding.decode(GuardedCommand.self, from: tree), entry, location)
            XCTAssertEqual(try JSONCoding.decode(Command.self, from: try JSONCoding.encode(entry.command)), entry.command, location)
        }
        // The fixtures reach across the vocabulary (Spec 2 §3).
        let expected: Set<String> = [
            "channel.write", "channel.clear", "channel.reset", "channel.transition", "channel.gain", "channel.endBehavior",
            "channel.lock", "output.stack", "stack.blackout", "stack.mute", "playlist.next", "playlist.previous",
            "timer.set", "timer.start", "popup.set", "audio.mute", "macro.run", "system.clearAll",
        ]
        XCTAssertTrue(expected.isSubset(of: seen), "\(expected.subtracting(seen))")
    }

    /// Spec 1 §6 — "the command is kept verbatim so a newer version can still read it."
    func test_anUnknownCommandKeepsEveryParameterVerbatim() throws {
        let object: JSONValue = .object([
            "cmd": .string("channel.teleport"), "channel": .number(2), "where": .string("narnia"),
            "options": .object(["fast": .bool(true)]),
        ])
        let command = try JSONCoding.decode(Command.self, from: object)
        XCTAssertEqual(command, .unknown(cmd: "channel.teleport", fields: [
            "channel": .number(2), "where": .string("narnia"), "options": .object(["fast": .bool(true)]),
        ]))
        XCTAssertTrue(command.isUnknown)
        XCTAssertEqual(try JSONCoding.encode(command), object)

        let guarded = try JSONCoding.decode(GuardedCommand.self, from: object.setting("when", to: .object(["var": .string("Timer 1"), "op": .string("is"), "value": .string("0:00")])))
        XCTAssertEqual(guarded.command, command)
        XCTAssertEqual(guarded.when, Guard(variable: "Timer 1", op: .is, value: "0:00"))

        // Spec 3 §6 — the projection answers `noop`.
        let (library, machine, _) = F.load()
        let context = ProjectionContext(frame: 1, library: library, machine: machine, source: CommandSource(kind: .ui))
        let (_, effects) = project(ShowState.fresh(library: library, machine: machine), [command], context: context)
        XCTAssertEqual(effects, [.noop(command)])
    }

    /// Spec 1 §6 — "bad parameters": a known `cmd` whose parameters do not
    /// decode is kept whole, flagged, and answered with `noop`.
    func test_aKnownCommandWithBadParametersIsKeptWholeAndFlagged() throws {
        let object: JSONValue = .object(["cmd": .string("channel.clear"), "channel": .string("two"), "note": .string("typo")])
        let command = try JSONCoding.decode(Command.self, from: object)
        guard case .invalid(let cmd, let fields) = command else { return XCTFail("\(command)") }
        XCTAssertEqual(cmd, "channel.clear")
        XCTAssertEqual(fields, ["channel": .string("two"), "note": .string("typo")])
        XCTAssertTrue(command.isInvalid)
        XCTAssertEqual(try JSONCoding.encode(command), object)
        XCTAssertTrue(command.invalidReason?.contains("channel") == true, command.invalidReason ?? "nil")

        let (library, machine, _) = F.load()
        let context = ProjectionContext(frame: 1, library: library, machine: machine, source: CommandSource(kind: .ui))
        let (_, effects) = project(ShowState.fresh(library: library, machine: machine), [command], context: context)
        XCTAssertEqual(effects, [.noop(command)])

        let fine = try JSONCoding.decode(Command.self, from: .object(["cmd": .string("channel.clear"), "channel": .number(2)]))
        XCTAssertEqual(fine, .channelClear(channel: .number(2)))
        XCTAssertNil(fine.invalidReason)
    }

    /// Spec 1 §8 — a known command object keeps keys it did not recognise.
    func test_aKnownCommandKeepsUnknownKeys() throws {
        let object: JSONValue = .object(["cmd": .string("channel.clear"), "channel": .number(2), "zz": .array([.number(1)])])
        let entry = try JSONCoding.decode(GuardedCommand.self, from: object)
        XCTAssertEqual(entry.command, .channelClear(channel: .number(2)))
        XCTAssertEqual(entry.extra, ["zz": .array([.number(1)])])
        XCTAssertEqual(try JSONCoding.encode(entry), object)
    }

    /// A cue's commands decode one at a time, so one bad command never takes
    /// the list down (Spec 1 §6, §8).
    func test_oneBadCommandDoesNotFailTheList() throws {
        var tree = try JSONValue.parse(try XCTUnwrap(F.librarySnapshot.files["lists/042-great-is-thy-faithfulness.json"]))
        var cues = tree["cues"]?.arrayValue ?? []
        var commands = cues[1]["commands"]?.arrayValue ?? []
        commands.append(.object(["cmd": .string("channel.gain"), "channel": .number(1), "db": .string("loud")]))
        cues[1] = cues[1].setting("commands", to: .array(commands))
        tree = tree.setting("cues", to: .array(cues))
        let data = JSONCanonical.data(tree)
        let loaded = try Loader.document(path: "lists/042-great-is-thy-faithfulness.json", data: data)
        guard case .list(let list) = loaded.body else { return XCTFail("\(loaded.body)") }
        XCTAssertEqual(list.cues[1].commands.count, 2)
        XCTAssertTrue(list.cues[1].commands[1].command.isInvalid)
        XCTAssertEqual(Writer.data(for: loaded), data)
    }
}
