import Foundation
import XCTest
@testable import OCore

/// Spec 10 §7 — "**Clears**: tiles that each send one command (choice U-4):
/// Clear All (`system clearall`); Blackout Stack S, for the selected preview
/// stack (`stack S blackout toggle`); Blackout All (`stack all blackout
/// toggle`, which Area 15 adds); Mute All Audio (`audio all mute toggle`);
/// Reset Channels (`channel all reset`); Clear Popups (`popup N clear` for
/// every slot, as one group, Spec 6 §7)." The app sends them (Area 13); here
/// each tile's command parses, validates and runs against the fixture library
/// of Spec 1 §10 as the tab describes.
final class ClearsTabTests: XCTestCase {
    typealias F = FixtureLibrary

    var library: Library!
    var machine: Machine!

    override func setUp() {
        (library, machine, _) = F.load()
    }

    /// Every tile's command in its canonical text and as the engine takes it.
    func test_everyTileSendsOneCommandTheVocabularyKnows() throws {
        let tiles: [(String, Command)] = [
            ("system clearall", .systemClearAll),
            ("stack 2 blackout toggle", .stackBlackout(stack: .number(2), state: .toggle)),
            ("stack all blackout toggle", .stackBlackout(stack: .all, state: .toggle)),
            ("audio all mute toggle", .audioMute(audio: .all, state: .toggle)),
            ("channel all reset", .channelReset(channel: .all)),
            ("popup 1 clear", .popupClear(popup: 1)),
        ]
        let context = ValidationContext(library: library, machine: machine, source: CommandSource(kind: .ui))
        for (text, command) in tiles {
            XCTAssertEqual(try CommandText.parse(text).get().command, command, text)
            XCTAssertEqual(CommandText.print(command), text)
            XCTAssertNil(CommandValidator.validate(command, context: context), text)
            XCTAssertEqual(command.lockClass, .passes, "a clear works on a locked channel too: \(text)")
        }
    }

    private func run(_ commands: [Command], state: ShowState) throws -> RunOutcome {
        let group = CommandGroup(id: GroupID("g-clears"), source: CommandSource(kind: .ui), commands: commands)
        let context = ProjectionContext(frame: 100, rate: .fps60, library: library, machine: machine, missing: [],
                                        source: CommandSource(kind: .ui), variables: { _ in nil })
        return try CommandRunner.run(group, state: state, context: context).get()
    }

    /// Clear All clears every channel and leaves popups up (Spec 6 §7).
    func test_clearAllLeavesPopupsUp() throws {
        var state = ShowState.fresh(library: library, machine: machine)
        state.channels[2]?.content = .text(TextInstance(fields: ["body": "Verse"]))
        state.popups[1] = "Nursery"
        let outcome = try run([.systemClearAll], state: state)
        XCTAssertEqual(outcome.state.channels[2]?.content, .empty)
        XCTAssertEqual(outcome.state.popups[1], "Nursery")
    }

    /// Blackout All with one stack already black turns on the rest; with all
    /// on, it turns them all off — "so a stack blacked out on purpose never
    /// comes back by mistake".
    func test_blackoutAllAndBlackoutStack() throws {
        let fresh = ShowState.fresh(library: library, machine: machine)
        let one = try run([.stackBlackout(stack: .number(1), state: .toggle)], state: fresh)
        XCTAssertEqual(one.state.stacks.filter { $0.value.blackout }.keys.sorted(), [1])
        let all = try run([.stackBlackout(stack: .all, state: .toggle)], state: one.state)
        XCTAssertEqual(all.state.stacks.filter { $0.value.blackout }.keys.sorted(), [1, 2])
        let none = try run([.stackBlackout(stack: .all, state: .toggle)], state: all.state)
        XCTAssertTrue(none.state.stacks.values.allSatisfy { !$0.blackout })
    }

    /// Mute All Audio reaches the engine as one command (Spec 4 §11, "`audio
    /// all mute` is one command over every device"), which applies the rule.
    func test_muteAllAudioIsOneCommandForTheEngine() throws {
        let outcome = try run([.audioMute(audio: .all, state: .toggle)], state: ShowState.fresh(library: library, machine: machine))
        XCTAssertEqual(outcome.executed.map(\.effects), [[.passthrough(.audioMute(audio: .all, state: .toggle))]])
    }

    /// Reset Channels returns tracked attributes to their defaults and leaves
    /// content alone.
    func test_resetChannels() throws {
        var state = ShowState.fresh(library: library, machine: machine)
        state.channels[2]?.content = .text(TextInstance(fields: ["body": "Verse"]))
        let gained = try run([.channelGain(channel: .number(2), db: -6)], state: state)
        let reset = try run([.channelReset(channel: .all)], state: gained.state)
        XCTAssertEqual(reset.state.channels[2]?.attributes.gain.value, 0)
        XCTAssertEqual(reset.state.channels[2]?.content, .text(TextInstance(fields: ["body": "Verse"])))
    }

    /// Clear Popups: `popup N clear` for every slot the machine has, as one
    /// group — one group id on every line of the log (Spec 2 §5, Groups).
    func test_clearPopupsIsOneGroupOverEverySlot() throws {
        var state = ShowState.fresh(library: library, machine: machine)
        state.popups[1] = "Nursery"
        state.popups[3] = "Parking"
        let commands = (1...machine.settings.popups).map { Command.popupClear(popup: $0) }
        XCTAssertEqual(commands.count, 4)
        let outcome = try run(commands, state: state)
        XCTAssertEqual(outcome.state.popups, [:])
        let entries = LogEntry.entries(for: outcome, firstSeq: 1, ts: "2026-11-10T09:00:00.000-05:00")
        XCTAssertEqual(entries.map(\.text), ["popup 1 clear", "popup 2 clear", "popup 3 clear", "popup 4 clear"])
        XCTAssertEqual(Set(entries.map(\.group.rawValue)), ["g-clears"])
        XCTAssertEqual(entries.map(\.result), [.ok, .noop, .ok, .noop])
    }
}
