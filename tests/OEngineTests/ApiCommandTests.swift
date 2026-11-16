import Foundation
import XCTest
import OCore
@testable import OEngine

/// Spec 2 §9 — "A client sends a request and receives a response with the
/// same `id`". Spec 10 §2 — "The app names each command's source, `ui`,
/// `key` or `commandbar` (Spec 2 §5), and the engine takes it from this
/// socket only; a LAN client's commands are always `api`." Spec 10 §3,
/// "Results" — "An applied edit's result also carries its `group` and, as
/// `applied`, each of its commands as the log keeps it, with what the engine
/// picked, and its inverse". Spec 2 §8 — "A group validates as a whole, each
/// command against the state the commands before it leave". Spec 10 §18,
/// Area 19: the socket; topics and answers.
final class ApiCommandTests: XCTestCase {
    func test_aCommandIsAnsweredWithItsIdItsResultAndItsLinesSeq() throws {
        let api = try ApiFixture()
        let client = api.local()
        let id = try api.send("channel 2 write text \"Great is Thy faithfulness\"", from: client)
        XCTAssertNil(client.answer(to: id, wait: 0.2), "a command lands on the next frame boundary (Spec 2 §8): no answer before a build runs")
        api.tick()
        let result = try XCTUnwrap(client.answer(to: id))
        XCTAssertEqual(result["type"], .string("result"))
        XCTAssertEqual(result["result"], .string("ok"))
        let entry = try XCTUnwrap(api.entries.last)
        XCTAssertEqual(result["seq"]?.intValue, entry.seq, "the seq of the line it logged")
        XCTAssertNil(result["applied"], "a runtime command applied no edit")
        XCTAssertNil(result["results"], "one command, one result")
    }

    func test_commandsKeepTheSourceTheAppGivesThem() throws {
        let api = try ApiFixture()
        let client = api.local()
        for (source, expected) in [(nil, SourceKind.ui), ("ui", .ui), ("key", .key), ("commandbar", .commandbar)] as [(String?, SourceKind)] {
            let id = try api.send("stack 1 blackout toggle", from: client, source: source)
            api.tick()
            XCTAssertEqual(client.answer(to: id)?["result"], .string("ok"))
            XCTAssertEqual(api.entries.last?.source.kind, expected, "source \(source ?? "(none)")")
        }
        // The socket takes the three sources an app has and no other: nothing is queued, nothing logged.
        let before = api.entries.count
        let id = try api.send("stack 1 blackout toggle", from: client, source: "osc")
        api.tick()
        let refused = try XCTUnwrap(client.answer(to: id))
        XCTAssertEqual(refused["result"], .string("rejected"))
        XCTAssertEqual(refused["reason"]?.stringValue?.hasPrefix("badValue:"), true)
        XCTAssertEqual(api.entries.count, before)
    }

    func test_aLanClientsCommandsAreAlwaysApi() throws {
        let api = try ApiFixture()
        let client = api.lan()
        let id = try api.send("stack 1 blackout on", from: client, source: "key")
        api.tick()
        XCTAssertEqual(client.answer(to: id)?["result"], .string("ok"))
        XCTAssertEqual(api.entries.last?.source.kind, .api, "whatever the client says its source is")
    }

    func test_aRejectedCommandIsAnsweredWithItsReasonAndIsNotLogged() throws {
        let api = try ApiFixture()
        let client = api.local()
        let before = api.entries.count
        let id = try api.send("channel 99 clear", from: client)
        api.tick()
        let result = try XCTUnwrap(client.answer(to: id))
        XCTAssertEqual(result["type"], .string("result"))
        XCTAssertEqual(result["result"], .string("rejected"))
        let reason = try XCTUnwrap(result["reason"]?.stringValue)
        XCTAssertTrue(reason.contains(": "), "code: message (Spec 2 §9), got \(reason)")
        XCTAssertNil(result["seq"])
        XCTAssertEqual(api.entries.count, before, "a rejected command never reaches the runtime log")
    }

    func test_aLineThatIsNotARequestIsAnsweredAndTheConnectionStaysOpen() throws {
        let api = try ApiFixture()
        let client = api.local()
        client.send(raw: "not json at all")
        client.send("command", ["command": .object(["cmd": .string("channel.write")])])
        client.send("command", [:])
        client.send("commands", ["commands": .array([])])
        let ping = client.send("ping")
        api.tick()
        let answers = client.next().filter { $0["type"] != .string("hello") }
        XCTAssertEqual(answers.count, 5)
        XCTAssertEqual(answers.prefix(4).map { $0["result"] }, Array(repeating: .string("rejected"), count: 4), "in the order they were sent")
        XCTAssertEqual(answers.last?["type"], .string("pong"))
        XCTAssertEqual(answers.last?["id"], .number(Double(ping)))
        XCTAssertFalse(client.connection.isClosed)
    }

    /// Spec 2 §8 as Spec 10 corrected it — "so `playlist "TITLE"` then `item
    /// N cue M` fires a cue of that playlist".
    func test_aGroupValidatesEachCommandAgainstTheStateTheEarlierOnesLeave() throws {
        let api = try ApiFixture()
        let client = api.local()
        XCTAssertNil(api.engine.state.pointer, "no playlist is loaded")

        // Alone, `item 2 cue 3` has no playlist to count items in.
        let alone = try api.send("item 2 cue 3", from: client)
        api.tick()
        XCTAssertEqual(client.answer(to: alone)?["result"], .string("rejected"))

        // After `playlist "Sunday"` in the same group, it names a cue of that playlist.
        let group = client.send("commands", ["group": .bool(true), "commands": .array([try api.command("playlist \"Sunday\""), try api.command("item 2 cue 3")])])
        api.tick()
        let result = try XCTUnwrap(client.answer(to: group))
        XCTAssertEqual(result["result"], .string("ok"))
        let results = try XCTUnwrap(result["results"]?.arrayValue)
        XCTAssertEqual(results.count, 2, "one entry per command sent, not per line the cue logged")
        XCTAssertEqual(results.map { $0.objectValue?["result"] }, [.string("ok"), .string("ok")])
        XCTAssertEqual(result["seq"], results.last?.objectValue?["seq"], "the last sent command's line")
        XCTAssertEqual(api.engine.state.pointer?.listUuid, EngineFixtures.list42)
        XCTAssertEqual(api.engine.state.pointer?.cueUuid, EngineFixtures.list42Cues[2])
    }

    func test_oneBadCommandRejectsTheGroupAndNamesIt() throws {
        let api = try ApiFixture()
        let client = api.local()
        let before = api.entries.count
        let group = client.send("commands", ["commands": .array([try api.command("stack 1 blackout on"), try api.command("channel 99 clear")])])
        api.tick()
        let result = try XCTUnwrap(client.answer(to: group))
        XCTAssertEqual(result["result"], .string("rejected"))
        XCTAssertEqual(result["reason"]?.stringValue?.contains("command 2 of 2"), true, "the rejection names the command: \(result["reason"] ?? .null)")
        XCTAssertEqual(api.entries.count, before, "none of the group ran")
        XCTAssertNotEqual(api.engine.state.stacks[1]?.blackout, true)
    }

    /// Area 19 reading — `"group": false`: each command its own group, one answer.
    func test_commandsNotSentAsAGroupRunEachOnItsOwn() throws {
        let api = try ApiFixture()
        let client = api.local()
        let id = client.send("commands", ["group": .bool(false), "commands": .array([try api.command("stack 1 blackout on"), try api.command("channel 99 clear"),
                                                                                    try api.command("stack 2 blackout on")])])
        api.tick()
        let result = try XCTUnwrap(client.answer(to: id))
        XCTAssertEqual(result["result"], .string("ok"))
        let results = try XCTUnwrap(result["results"]?.arrayValue)
        XCTAssertEqual(results.map { $0.objectValue?["result"] }, [.string("ok"), .string("rejected"), .string("ok")], "the bad one is rejected alone")
        XCTAssertEqual(api.engine.state.stacks[1]?.blackout, true)
        XCTAssertEqual(api.engine.state.stacks[2]?.blackout, true)
        let groups = Set(api.entries.suffix(2).map(\.group))
        XCTAssertEqual(groups.count, 2, "two groups in the log, not one")
    }

    /// Spec 10 §3 — "so the app can find a new object, or revert exactly what
    /// it sent without reaching for `undo`".
    func test_anAppliedEditsResultCarriesItsGroupAndWhatItAppliedWithInverses() throws {
        let api = try ApiFixture()
        let client = api.local()
        let id = try api.send("edit list 42 title \"Great Is Thy Faithfulness (2026)\"", from: client)
        api.tick()
        let result = try XCTUnwrap(client.answer(to: id))
        XCTAssertEqual(result["result"], .string("ok"))
        // A title is typed text: its edit opens a typing run (Spec 5 §5), whose one line is written when the run
        // closes a second later. The result names the run's group at once.
        XCTAssertNotNil(result["seq"]?.intValue)
        api.tick(61)
        let entry = try XCTUnwrap(api.entries.last)
        XCTAssertEqual(result["group"], .string(entry.group.rawValue), "the group the log keeps it under")
        let applied = try XCTUnwrap(result["applied"]?.arrayValue)
        XCTAssertEqual(applied.count, 1)
        XCTAssertEqual(applied.first?.objectValue?["command"], try JSONCoding.encode(entry.command), "the command as the log keeps it")
        let inverse = try XCTUnwrap(entry.inverse)
        XCTAssertEqual(applied.first?.objectValue?["inverse"], try JSONCoding.encode(inverse))

        // Sending the inverse it was given puts the title back.
        let back = client.send("command", ["command": try XCTUnwrap(applied.first?.objectValue?["inverse"])])
        api.tick()
        XCTAssertEqual(client.answer(to: back)?["result"], .string("ok"))
        XCTAssertEqual(api.engine.engine.library.list(number: 42)?.title, "Great Is Thy Faithfulness")
    }

    /// "with what the engine picked": a new playlist's uuid is the engine's
    /// to choose, and the result says which.
    func test_anEditsResultShowsWhatTheEnginePicked() throws {
        let api = try ApiFixture()
        let client = api.local()
        let id = try api.send("edit playlist create \"Easter\"", from: client)
        api.tick()
        let result = try XCTUnwrap(client.answer(to: id))
        XCTAssertEqual(result["result"], .string("ok"), "\(result)")
        let command = try XCTUnwrap(result["applied"]?.arrayValue?.first?.objectValue?["command"])
        let created = try XCTUnwrap(api.engine.engine.machine.playlists.first { $0.title == "Easter" })
        let text = JSONCanonical.line(command)
        XCTAssertTrue(text.contains(created.uuid.uuidString.lowercased()), "the uuid it picked is in the applied command: \(text)")
        XCTAssertEqual(result["seq"]?.intValue, api.entries.last?.seq)
        XCTAssertNotEqual(result["applied"]?.arrayValue?.first?.objectValue?["inverse"], .null, "with the delete that takes it away again")
    }

    func test_aNavigationAnswersForItsOwnLineNotTheCuesItFired() throws {
        let api = try ApiFixture()
        let client = api.local()
        let load = try api.send("playlist \"Sunday\"", from: client)
        let next = try api.send("next", from: client)
        api.tick()
        XCTAssertEqual(client.answer(to: load)?["result"], .string("ok"))
        let result = try XCTUnwrap(client.answer(to: next))
        XCTAssertEqual(result["result"], .string("ok"))
        let navigation = try XCTUnwrap(api.entries.first { $0.seq == result["seq"]?.intValue })
        XCTAssertEqual(navigation.text, "next")
        XCTAssertNil(result["results"])
        XCTAssertGreaterThan(api.entries.last?.seq ?? 0, navigation.seq, "the cue it fired logged its own lines after it")
    }

    /// Spec 9 §3 — `system snapshot`'s "result arrives once the file is
    /// complete and names it": a group the engine parks is answered in the
    /// build it finishes in, and requests sent meanwhile don't wait for it.
    func test_aParkedCommandIsAnsweredWhenItFinishesAndPingsDoNotWaitForIt() throws {
        let api = try ApiFixture()
        let client = api.local()
        let snapshot = try api.send("system snapshot", from: client)
        let ping = client.send("ping")
        api.tick()
        XCTAssertEqual(client.answer(to: ping)?["type"], .string("pong"), "the engine answers while its worker writes")
        api.engine.waitForSnapshots()
        api.tick()
        let result = try XCTUnwrap(client.answer(to: snapshot))
        XCTAssertEqual(result["result"], .string("ok"))
        let id = try XCTUnwrap(result["snapshot"]?.stringValue)
        XCTAssertTrue(api.disk.snapshotIDs.contains(id), "it names the snapshot it wrote")
    }
}
