import Foundation
import XCTest
import OCore
@testable import OEngine

/// Spec 10 §3, "Queries (Spec 2 §9's `query`)" — `state`, `catalog`, `list`,
/// `media`, `mediaUse`, `listUse`, `versions`, `snapshots`, `thumbnails`,
/// `devices`, `fonts`, and `render` and `uses`, which are Area 14's. Spec 2
/// §9 — "A query is answered with its request's `id` as `{"id": …, "type":
/// "answer", …}` and the fields its definition gives, and refused with the
/// rejected result Spec 10 §3 shows." Spec 10 §18, Area 19 — "`state`
/// carries the `live`, `channels` and `popups` events".
final class ApiQueryTests: XCTestCase {
    func ask(_ api: ApiFixture, _ client: ApiTestClient, _ what: String, _ fields: [String: JSONValue] = [:]) throws -> [String: JSONValue] {
        var members = fields
        members["what"] = .string(what)
        let id = client.send("query", members)
        api.tick()
        let answer = try XCTUnwrap(client.answer(to: id), "no answer to \(what)")
        XCTAssertEqual(answer["id"], .number(Double(id)), "answered with its request's id")
        return answer
    }

    func rejected(_ answer: [String: JSONValue], _ code: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(answer["type"], .string("result"), file: file, line: line)
        XCTAssertEqual(answer["result"], .string("rejected"), file: file, line: line)
        XCTAssertEqual(answer["reason"]?.stringValue?.hasPrefix(code + ": "), true, "\(answer["reason"] ?? .null)", file: file, line: line)
    }

    // MARK: - state

    func test_stateCarriesShowStateTheTimersAndEveryTopicsEventsNow() throws {
        let api = try ApiFixture()
        let client = api.local()
        try api.engine.send("playlist \"Sunday\"", source: .ui).map { throw $0 }
        try api.engine.send("next", source: .ui).map { throw $0 }
        try api.engine.send("popup 1 set \"Welcome\"", source: .ui).map { throw $0 }
        try api.engine.send("timer 2 set 5:00", source: .ui).map { throw $0 }
        api.tick()
        let answer = try ask(api, client, "state")
        XCTAssertEqual(answer["type"], .string("answer"))
        XCTAssertEqual(answer["state"], try JSONCoding.encode(api.engine.state), "ShowState (Spec 3 §2), whole")
        XCTAssertEqual(answer["seq"]?.intValue, api.entries.last?.seq)
        XCTAssertNotNil(answer["rev"]?.intValue)

        let timers = try XCTUnwrap(answer["timers"]?.arrayValue?.compactMap(\.objectValue))
        XCTAssertEqual(timers.count, api.engine.engine.machine.settings.timers, "one per slot")
        XCTAssertEqual(timers.map { $0["topic"] }, Array(repeating: .string("timers"), count: timers.count))
        XCTAssertEqual(timers.first { $0["timer"] == .number(2) }?["setMs"], .number(300_000))

        let events = try XCTUnwrap(answer["events"]?.arrayValue?.compactMap(\.objectValue))
        let machine = api.engine.engine.machine, library = api.engine.engine.library
        XCTAssertEqual(events.events("live").count, 1)
        XCTAssertEqual(events.events("live").first?["listTitle"], .string("Great Is Thy Faithfulness"))
        XCTAssertEqual(events.events("channels").compactMap { $0["channel"]?.intValue }, library.channels.map(\.number).sorted(), "every channel, empty ones too")
        XCTAssertEqual(events.events("popups").compactMap { $0["popup"]?.intValue }, Array(1...machine.settings.popups))
        XCTAssertEqual(events.events("popups").first?["text"], .string("Welcome"))
        let outputs = events.events("outputs")
        XCTAssertEqual(outputs.filter { $0["output"] != nil }.compactMap { $0["output"]?.intValue }, machine.outputs.map(\.number).sorted())
        XCTAssertEqual(outputs.filter { $0["output"] == nil }.compactMap { $0["stack"]?.intValue }, machine.stacks.map(\.number).sorted())
        XCTAssertEqual(events.events("audio").compactMap { $0["audioOutput"]?.intValue }, machine.audioOutputs.map(\.number).sorted())

        // The channel the cue wrote is in the answer as its topic would send it: no transition, which was said once.
        let foreground = try XCTUnwrap(events.events("channels").first { $0["channel"] == .number(2) })
        XCTAssertEqual(foreground["content"]?.objectValue?["kind"], .string("text"))
        XCTAssertNil(foreground["transition"])
    }

    // MARK: - catalog, list, listUse

    func test_catalogCarriesBothRootsDocumentsAndASummaryOfEachList() throws {
        let api = try ApiFixture()
        let client = api.local()
        let answer = try ask(api, client, "catalog")
        let library = try XCTUnwrap(answer["library"]?.objectValue), machine = try XCTUnwrap(answer["machine"]?.objectValue)
        let roots = (library: api.engine.engine.library, machine: api.engine.engine.machine)
        XCTAssertEqual(Set(library.keys), ["info", "channels", "textStyles", "grades", "transitions", "audioTransitions", "presets", "macros", "folders"])
        XCTAssertEqual(Set(machine.keys), ["settings", "stacks", "outputs", "audioOutputs", "inputs", "keys", "macros", "playlists"])
        XCTAssertEqual(library["channels"], try JSONCoding.encode(roots.library.channels), "each document as it is")
        XCTAssertEqual(library["presets"]?.arrayValue?.count, roots.library.presets.count)
        XCTAssertEqual(machine["settings"], try JSONCoding.encode(roots.machine.settings))
        XCTAssertEqual(machine["keys"]?.arrayValue?.count, roots.machine.keys.count)
        XCTAssertEqual(library["folders"], .array(roots.library.folders.sorted().map(JSONValue.string)), "the library's folders, empty ones too")
        XCTAssertNil(library["mediaIndex"], "the media indexes have a query of their own")

        // Every playlist with its items.
        let playlists = try XCTUnwrap(machine["playlists"]?.arrayValue?.compactMap(\.objectValue))
        XCTAssertEqual(playlists.count, roots.machine.playlists.count)
        let sunday = try XCTUnwrap(playlists.first { $0["title"] == .string("Sunday") })
        XCTAssertEqual(sunday["items"]?.arrayValue?.count, 5)
        XCTAssertEqual(sunday["named"], .bool(true), "`playlist \"Sunday\"` loads this one")

        // A summary of each list, and no cues.
        let lists = try XCTUnwrap(answer["lists"]?.arrayValue?.compactMap(\.objectValue))
        XCTAssertEqual(lists.count, roots.library.lists.count + roots.machine.localLists.count)
        let master = try XCTUnwrap(lists.first { $0["number"] == .number(42) && $0["local"] == .bool(false) })
        XCTAssertEqual(master["uuid"], .string(EngineFixtures.list42.uuidString.lowercased()))
        XCTAssertEqual(master["title"], .string("Great Is Thy Faithfulness"))
        XCTAssertEqual(master["author"], .string("Thomas Chisholm"))
        XCTAssertEqual(master["ccli"], .string("18723"))
        XCTAssertEqual(master["trackThrough"], .bool(false))
        XCTAssertEqual(master["version"], .number(17))
        XCTAssertEqual(master["folder"], .string("Hymns"))
        XCTAssertEqual(master["cues"], .number(4), "its cue count, not its cues")
        XCTAssertEqual(master["named"], .bool(true), "`list 42` fires the master")
        let local = try XCTUnwrap(lists.first { $0["local"] == .bool(true) })
        XCTAssertEqual(local["number"], .number(42), "the fixture's local copy shares the master's number")
        XCTAssertEqual(local["named"], .bool(false))
    }

    func test_catalogSaysWhichOfTwoListsANumberNames() throws {
        // A second list 42, as a sync can leave one (Spec 7 §2): the number names the first, and the catalog says so.
        let twin = UUID()
        let api = try ApiFixture(prepare: { folder in
            let source = folder.appendingPathComponent("library/lists/Hymns/042-great-is-thy-faithfulness.json")
            var text = try String(contentsOf: source, encoding: .utf8)
            text = text.replacingOccurrences(of: EngineFixtures.list42.uuidString.lowercased(), with: twin.uuidString.lowercased())
            text = text.replacingOccurrences(of: "Great Is Thy Faithfulness", with: "Great Is Thy Faithfulness (old)")
            try Data(text.utf8).write(to: folder.appendingPathComponent("library/lists/042-old.json"))
        })
        let client = api.local()
        let lists = try XCTUnwrap(try ask(api, client, "catalog")["lists"]?.arrayValue?.compactMap(\.objectValue))
        let both = lists.filter { $0["number"] == .number(42) && $0["local"] == .bool(false) }
        XCTAssertEqual(both.count, 2)
        XCTAssertEqual(both.filter { $0["named"] == .bool(true) }.count, 1, "exactly one of them is what `list 42` names")
        let named = api.engine.engine.library.list(number: 42)?.uuid.uuidString.lowercased()
        XCTAssertEqual(both.first { $0["named"] == .bool(true) }?["uuid"], named.map(JSONValue.string))

        // "A linked item's list is asked for by its `listUuid`, since two lists can share a number".
        let other = try ask(api, client, "list", ["listUuid": .string(twin.uuidString.lowercased())])
        XCTAssertEqual(other["list"]?.objectValue?["title"], .string("Great Is Thy Faithfulness (old)"))
    }

    func test_listAnswersOneListWholeByUuidNumberOrLocalUuid() throws {
        let api = try ApiFixture()
        let client = api.local()
        let master = try XCTUnwrap(api.engine.engine.library.list(number: 42))
        let byNumber = try ask(api, client, "list", ["list": .number(42)])
        XCTAssertEqual(byNumber["list"], try JSONCoding.encode(master), "whole, with its cues")
        XCTAssertEqual(byNumber["folder"], .string("Hymns"))
        XCTAssertEqual(byNumber["local"], .bool(false))
        let byUuid = try ask(api, client, "list", ["listUuid": .string(master.uuid.uuidString.lowercased())])
        XCTAssertEqual(byUuid["list"], byNumber["list"])

        let copy = try XCTUnwrap(api.engine.engine.machine.localLists.first)
        let local = try ask(api, client, "list", ["local": .string(copy.uuid.uuidString.lowercased())])
        XCTAssertEqual(local["list"], try JSONCoding.encode(copy))
        XCTAssertEqual(local["local"], .bool(true))

        rejected(try ask(api, client, "list", ["list": .number(999)]), "unknownObject")
        rejected(try ask(api, client, "list", ["listUuid": .string("not-a-uuid")]), "badValue")
        rejected(try ask(api, client, "list"), "missingArgument")
    }

    func test_listUseNamesThePlaylistsThatLinkAList() throws {
        let api = try ApiFixture(configure: { machine in
            if let index = machine.playlists.firstIndex(where: { $0.title == "Sunday Night" }) { machine.playlists[index].archived = true }
        })
        let client = api.local()
        let use = try ask(api, client, "listUse", ["list": .number(7)])
        let playlists = try XCTUnwrap(use["playlists"]?.arrayValue?.compactMap(\.objectValue))
        let linking = api.engine.engine.machine.playlists.filter { playlist in
            playlist.items.contains { api.engine.engine.library.list(for: $0.kind)?.number == 7 }
        }
        XCTAssertEqual(Set(playlists.compactMap { $0["title"]?.stringValue }), Set(linking.map(\.title)))
        XCTAssertTrue(playlists.contains { $0["title"] == .string("Sunday") && $0["archived"] == .bool(false) })
        XCTAssertTrue(playlists.contains { $0["title"] == .string("Sunday Night") && $0["archived"] == .bool(true) }, "archived ones marked")
        XCTAssertNotNil(playlists.first?["uuid"]?.stringValue)
        rejected(try ask(api, client, "listUse", ["list": .number(999)]), "unknownObject")
    }

    // MARK: - what the earlier areas answer, now on the wire

    func test_mediaMediaUseVersionsAndSnapshotsAreAnsweredOnTheApi() throws {
        let api = try ApiFixture()
        let client = api.local()
        let media = try XCTUnwrap(try ask(api, client, "media")["media"]?.arrayValue?.compactMap(\.objectValue))
        let known = api.engine.engine.library.mediaIndex.entries.count + api.engine.engine.machine.mediaLocal.entries.count
        XCTAssertEqual(media.count, known, "every entry of both indexes")
        XCTAssertNotNil(media.first?["presence"]?.stringValue)
        XCTAssertNotNil(media.first?["index"]?.stringValue)
        XCTAssertNotNil(media.first?["uses"]?.intValue)

        let use = try ask(api, client, "mediaUse", ["media": .string(EngineFixtures.dawn)])
        XCTAssertEqual(use["type"], .string("answer"))
        XCTAssertNotNil(use["cues"]?.intValue)
        rejected(try ask(api, client, "mediaUse", ["media": .string("sha256:" + String(repeating: "0", count: 64))]), "unknownObject")

        let versions = try ask(api, client, "versions", ["list": .number(42)])
        XCTAssertEqual(versions["type"], .string("answer"))
        XCTAssertEqual(versions["versions"]?.arrayValue?.count, 1, "the fixture keeps v0016")
        let snapshots = try ask(api, client, "snapshots")
        XCTAssertEqual(snapshots["snapshots"]?.arrayValue?.count, api.disk.snapshotIDs.count)
    }

    // MARK: - devices, fonts, thumbnails

    func test_devicesAnswersWhatTheMacHas() throws {
        let api = try ApiFixture()
        let client = api.local()
        rejected(try ask(api, client, "devices"), "conflict")

        let fake = FakeDevices(DetectedDevices(
            screens: [FakeDevices.screen("AAAAAAAA-0000-4000-8000-000000000001", name: "DELL U2720Q", x: 1920)],
            ports: [DetectedPort(device: "decklink:8f3a21c0", name: "DeckLink 8K Pro (1)", modes: [VideoFormat(rate: FrameRate(num: 60000, den: 1001))])],
            audio: [DetectedAudioDevice(uid: "BuiltInSpeakerDevice", name: "Mac mini Speakers", channels: 2, isDefault: true)]))
        api.engine.engine.deviceLister = fake
        let answer = try ask(api, client, "devices")
        XCTAssertEqual(answer["type"], .string("answer"))
        let screen = try XCTUnwrap(answer["screens"]?.arrayValue?.first?.objectValue)
        XCTAssertEqual(screen["device"], .string("display:AAAAAAAA-0000-4000-8000-000000000001"))
        XCTAssertEqual(screen["name"], .string("DELL U2720Q"))
        XCTAssertEqual(screen["mirrored"], .bool(false))
        XCTAssertNotNil(screen["frame"]?.objectValue?["x"])
        XCTAssertNotNil(screen["mode"]?.objectValue?["rate"])
        XCTAssertEqual(answer["ports"]?.arrayValue?.first?.objectValue?["device"], .string("decklink:8f3a21c0"))
        XCTAssertEqual(answer["ports"]?.arrayValue?.first?.objectValue?["modes"]?.arrayValue?.count, 1)
        XCTAssertEqual(answer["audio"]?.arrayValue?.first?.objectValue?["isDefault"], .bool(true))
    }

    /// Spec 10 §3, the `devices` topic — "On subscribe and when a screen, a
    /// card or an audio device comes or goes".
    func test_theDevicesTopicIsSentOnSubscribeAndWhenADeviceComesOrGoes() throws {
        let api = try ApiFixture()
        let fake = FakeDevices(DetectedDevices(screens: [FakeDevices.screen("AAAAAAAA-0000-4000-8000-000000000001")]))
        api.engine.engine.deviceLister = fake
        api.engine.engine.devicesChanged()
        api.hub.workers.sync {}

        let client = api.local()
        client.send("subscribe", ["topics": .array([.string("devices")])])
        api.tick()
        let first = client.next().events("devices")
        XCTAssertEqual(first.count, 1, "on subscribe")
        XCTAssertEqual(first.first?["screens"]?.arrayValue?.count, 1)

        fake.list.screens.append(FakeDevices.screen("BBBBBBBB-0000-4000-8000-000000000002", x: 1920))
        api.engine.engine.devicesChanged()
        let second = client.next().events("devices")
        XCTAssertEqual(second.count, 1, "when a screen comes")
        XCTAssertEqual(second.first?["screens"]?.arrayValue?.count, 2)
    }

    func test_fontsNamesWhatTheEngineResolves() throws {
        let api = try ApiFixture()
        let client = api.local()
        let fonts = try XCTUnwrap(try ask(api, client, "fonts")["fonts"]?.arrayValue?.compactMap(\.objectValue))
        XCTAssertFalse(fonts.isEmpty)
        let helvetica = try XCTUnwrap(fonts.first { $0["name"] == .string("HelveticaNeue-Bold") }, "the fixture's body face is installed on every Mac")
        XCTAssertEqual(helvetica["family"], .string("Helvetica Neue"))
        XCTAssertEqual(helvetica["bundled"], .bool(false))
        XCTAssertFalse(fonts.contains { $0["name"]?.stringValue?.hasPrefix(".") == true }, "not the system's own interface faces")
    }

    func test_thumbnailsAnswersEachCuesFileOrNull() throws {
        // Without a thumbnail job (this harness has no GPU) every file is null and nothing is queued; the job itself
        // and its events are MetalThumbnailApiTests'.
        let api = try ApiFixture()
        let client = api.local()
        let answer = try ask(api, client, "thumbnails", ["list": .number(42), "stack": .number(1)])
        XCTAssertEqual(answer["stack"], .number(1))
        let thumbnails = try XCTUnwrap(answer["thumbnails"]?.arrayValue?.compactMap(\.objectValue))
        XCTAssertEqual(thumbnails.compactMap { $0["cue"]?.stringValue }, EngineFixtures.list42Cues.map { $0.uuidString.lowercased() })
        XCTAssertEqual(thumbnails.map { $0["file"] }, Array(repeating: .null, count: 4))
        rejected(try ask(api, client, "thumbnails", ["list": .number(999)]), "unknownObject")
    }

    // MARK: - not yet, and never

    func test_renderAndUsesWaitForEditModeAndAnUnknownQueryIsRefused() throws {
        let api = try ApiFixture()
        let client = api.local()
        rejected(try ask(api, client, "render"), "notInV1")
        rejected(try ask(api, client, "uses"), "notInV1")
        rejected(try ask(api, client, "weather"), "badValue")
        rejected(try ask(api, client, ""), "badValue")
    }
}
