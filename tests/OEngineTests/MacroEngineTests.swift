import XCTest
import OCore
@testable import OEngine

/// Area 15 — the machine-level and library macros as first-class objects the
/// engine runs from a key, OSC and a cue. Spec 2 §10, Groups: "a macro's
/// commands run in order with each inner command logged under the macro's
/// group id"; Spec 2 §8, Timing: "a group of writes lands on the same frame";
/// Spec 2 §5, Macro depth: "A macro runs whole or not at all". A key's
/// command reaches the engine as a group with source `key` (Spec 10 §9: "The
/// app reads the table and sends a binding's command with source `key`").
final class MacroEngineTests: XCTestCase {
    var engine: HeadlessEngine!

    /// The fixture library plus macro 20 (a text write and `stack all
    /// blackout on`, portable by Spec 1 §2) and macros 21 and 22, which call
    /// each other; list 50's cue 1 runs macro 21.
    static func library() throws -> Library {
        var library = try EngineFixtures.library()
        library.macros.append(Macro(number: 20, commands: [
            GuardedCommand(.channelWrite(ChannelWrite(channel: .number(2), content: .text(fields: ["body": "Welcome"])))),
            GuardedCommand(.stackBlackout(stack: .all, state: .on)),
        ]))
        library.macros.append(Macro(number: 21, commands: [
            GuardedCommand(.channelWrite(ChannelWrite(channel: .number(2), content: .text(fields: ["body": "loop"])))),
            GuardedCommand(.macro(22)),
        ]))
        library.macros.append(Macro(number: 22, commands: [GuardedCommand(.macro(21))]))
        library.lists.append(List(uuid: EngineFixtures.uuid("5050", 1), number: 50, title: "Loop", cues: [
            Cue(uuid: EngineFixtures.uuid("5050", 2), label: "Loop", commands: [Command.macro(21)]),
        ]))
        return library
    }

    override func setUpWithError() throws {
        engine = try HeadlessEngine(library: Self.library(), machine: EngineFixtures.spikeMachine(), media: EngineFixtures.media)
    }

    // MARK: - From a key and from OSC

    /// The macro's commands land on one frame boundary: the text is live and
    /// both outputs start their blackout on the tick the key's group ran.
    func test_aMacroFromAKeyLandsOnOneFrameBoundary() throws {
        XCTAssertNil(engine.send("macro 20", source: .key))
        engine.tick()
        XCTAssertEqual(engine.lastExecuted.map(\.command), [
            .macro(20),
            .channelWrite(ChannelWrite(channel: .number(2), content: .text(fields: ["body": "Welcome"]))),
            .stackBlackout(stack: .all, state: .on),
        ])
        XCTAssertEqual(engine.lastExecuted.map(\.source), [CommandSource(kind: .key), CommandSource(kind: .macro, macro: 20),
                                                           CommandSource(kind: .macro, macro: 20)])
        XCTAssertEqual(Set(engine.lastExecuted.map(\.group)).count, 1)
        XCTAssertEqual(engine.state.channels[2]?.content.kind, "text")
        let frame = engine.frame
        XCTAssertEqual(engine.control.model.outputs[1]?.blackout?.startFrame, frame)
        XCTAssertEqual(engine.control.model.outputs[2]?.blackout?.startFrame, frame)
    }

    /// The fixture's machine macro 2 from OSC: its inner lines carry source
    /// `macro` and its number, under the OSC group.
    func test_theMachineMacroFromOSC() throws {
        XCTAssertNil(engine.send("macro 2", source: .osc))
        engine.tick()
        let executed = engine.lastExecuted
        XCTAssertEqual(executed.first?.command, .macro(2))
        XCTAssertEqual(executed.first?.source, CommandSource(kind: .osc))
        XCTAssertTrue(executed.dropFirst().allSatisfy { $0.source == CommandSource(kind: .macro, macro: 2) })
        XCTAssertEqual(Set(executed.map(\.group)).count, 1)
        XCTAssertTrue(executed.contains { $0.command == .audioMute(audio: .all, state: .off) })
    }

    /// From a key, a macro that loops is rejected before anything runs.
    func test_aLoopingMacroFromAKeyIsRejected() throws {
        engine.send("macro 21", source: .key)
        engine.tick()
        XCTAssertTrue(engine.lastExecuted.isEmpty)
        XCTAssertEqual(engine.rejections.last?.reason, .macroCycle)
    }

    // MARK: - From OSC over UDP (Spec 2 §6)

    /// An OSC server on a free port wired to the harness the way the process
    /// wires it: groups into the queue, feedback and errors after each build.
    private func startServer() throws -> (OSCServer, UDPTestClient) {
        let ids = Set(engine.engine.library.mediaIndex.entries.map(\.id))
        let enqueue: @Sendable (CommandGroup) -> Void = { [weak engine] group in engine?.send(group) }
        let server = OSCServer(port: 0, targets: [], mediaIDs: ids, log: engine.log, enqueue: enqueue)
        try server.start()
        let library = engine.engine.library, machine = engine.engine.machine
        let afterBuild: @Sendable (ControlLoop) -> Void = { [server, library, machine] control in
            server.afterBuild(control, library: library, machine: machine)
        }
        engine.engine.afterBuild = afterBuild
        return (server, try UDPTestClient())
    }

    private func error(from client: UDPTestClient) -> OSCMessage? {
        guard let data = client.receive(timeout: 2), case .success(.message(let message)) = OSCPacket.decode(data) else { return nil }
        return message
    }

    /// `/o/macro/N` runs with source `osc`, and an accepted group brings no error.
    func test_aMacroOverOSCRunsAndIsNotAnswered() throws {
        let (server, client) = try startServer()
        defer { server.stop(); client.close() }
        try client.send(OSCMessage("/o/macro/20").encoded(), to: server.boundPort)
        XCTAssertTrue(waitUntil(5) { engine.control.queuedGroups == 1 })
        engine.tick()
        XCTAssertEqual(engine.lastExecuted.first?.command, .macro(20))
        XCTAssertEqual(engine.lastExecuted.first?.source, CommandSource(kind: .osc))
        XCTAssertNil(client.receive(timeout: 0.3), "nothing comes back for a group that ran")
        XCTAssertEqual(server.rejected, 0)
    }

    /// A macro the engine rejects (Spec 2 §8) brings `/o/error` back to the
    /// sender, naming the address and the reason.
    func test_aRejectedMacroOverOSCIsAnsweredWithAnError() throws {
        let (server, client) = try startServer()
        defer { server.stop(); client.close() }
        try client.send(OSCMessage("/o/macro/99").encoded(), to: server.boundPort)
        XCTAssertTrue(waitUntil(5) { engine.control.queuedGroups == 1 })
        engine.tick()
        XCTAssertTrue(engine.lastExecuted.isEmpty)
        let unknown = try XCTUnwrap(error(from: client))
        XCTAssertEqual(unknown.address, "/o/error")
        XCTAssertEqual(unknown.arguments.first, .string("/o/macro/99"))
        guard case .string(let reason)? = unknown.arguments.last else { return XCTFail("a reason") }
        XCTAssertTrue(reason.contains("macro 99 does not exist"), reason)

        try client.send(OSCMessage("/o/macro/21").encoded(), to: server.boundPort)
        XCTAssertTrue(waitUntil(5) { engine.control.queuedGroups == 1 })
        engine.tick()
        let loop = try XCTUnwrap(error(from: client))
        XCTAssertEqual(loop.arguments.first, .string("/o/macro/21"))
        guard case .string(let loopReason)? = loop.arguments.last else { return XCTFail("a reason") }
        XCTAssertTrue(loopReason.contains("macro 21 → macro 22 → macro 21"), loopReason)
        XCTAssertEqual(server.rejected, 2)
    }

    /// Spec 2 §6 — "Bundles run as one group ... and either all validate or
    /// none run": a bundle holding a bad macro runs nothing and is answered
    /// at `#bundle`.
    func test_aBundleWithABadMacroIsAnsweredAtBundle() throws {
        let (server, client) = try startServer()
        defer { server.stop(); client.close() }
        let bundle = OSCBundle(elements: [
            .message(OSCMessage("/o/channel/2/write", [.string("text \"x\"")])),
            .message(OSCMessage("/o/macro/21")),
        ])
        try client.send(bundle.encoded(), to: server.boundPort)
        XCTAssertTrue(waitUntil(5) { engine.control.queuedGroups == 1 })
        engine.tick()
        XCTAssertTrue(engine.lastExecuted.isEmpty, "none run")
        XCTAssertEqual(engine.state.channels[2]?.content, .empty)
        let reply = try XCTUnwrap(error(from: client))
        XCTAssertEqual(reply.address, "/o/error")
        XCTAssertEqual(reply.arguments.first, .string("#bundle"))
        XCTAssertEqual(engine.lastRejected.first?.rejection.index, 1)
    }

    // MARK: - From a cue

    /// The doxology's cue 3 clears channel 2, runs macro 1, then writes
    /// channel 1: the navigation's line, then the cue group, the macro's
    /// inner lines carrying the cue's source and the macro's number.
    func test_aCueThatRunsAMacro() throws {
        engine.send("list 7 cue 3", source: .key)
        engine.tick()
        let executed = engine.lastExecuted
        XCTAssertEqual(executed.map { CommandText.print($0.command) ?? "" }.map { $0.split(separator: " ").prefix(3).joined(separator: " ") }, [
            "list 7 cue", "channel 2 clear", "macro 1", "channel 2 write", "timer 1 set", "timer 1 start", "popup 3 set", "channel 1 write",
        ])
        let list = try XCTUnwrap(engine.engine.library.list(number: 7))
        let cueSource = CommandSource(kind: .cue, list: list.uuid, cue: list.cues[2].uuid)
        XCTAssertEqual(executed[1].source, cueSource)
        XCTAssertEqual(executed[2].source, cueSource)
        XCTAssertEqual(executed[3...6].map(\.source), Array(repeating: cueSource.inMacro(1), count: 4))
        XCTAssertEqual(executed[7].source, cueSource)
        XCTAssertEqual(Set(executed.dropFirst().map(\.group)).count, 1, "one cue group")
        XCTAssertEqual(engine.state.popups[3], "Nursery: please come to room 12")
    }

    /// A looping macro held by a cue runs nothing and the engine log says why.
    func test_aLoopingMacroInACueRunsNothingAndIsLogged() throws {
        engine.send("list 50 cue 1", source: .key)
        engine.tick()
        XCTAssertEqual(engine.lastExecuted.map(\.command), [.listCue(list: 50, cue: 1), .macro(21)])
        XCTAssertEqual(engine.lastExecuted.last?.result, .noop)
        XCTAssertEqual(engine.state.channels[2]?.content, .empty)
        XCTAssertTrue(engine.log.contains("macro 21 ran nothing: macros call each other in a loop: macro 21 → macro 22 → macro 21"),
                      "\(engine.log.recent.map(\.message))")
    }

    /// Spec 3 §5 — a list that doesn't track through resets every attribute
    /// at its boundary, and the engine's gain follows (before Area 15 the
    /// engine kept the previous list's gain for the channel).
    func test_aBoundaryResetsTheEnginesGain() throws {
        engine.send("list 7 cue 1", source: .key)
        engine.tick()
        engine.send("channel 1 gain -6", source: .ui)
        engine.tick()
        XCTAssertEqual(engine.control.model.channels[1]?.gainDb, -6)
        engine.send("list 42 cue 1", source: .key)
        engine.tick()
        XCTAssertEqual(engine.state.channels[1]?.attributes.gain.value, 0)
        XCTAssertEqual(engine.control.model.channels[1]?.gainDb, 0)
    }
}
