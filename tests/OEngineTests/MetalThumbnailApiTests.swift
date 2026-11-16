import Foundation
import XCTest
import OCore
@testable import OEngine

/// Spec 10 §3 — the `thumbnails` query: "For a list (by `listUuid`, number or
/// `local` uuid) and `stack` S, each cue's thumbnail file or null. The engine
/// queues the missing ones, and a `thumbnails` event follows each"; the
/// `thumbnails` topic: "A cue thumbnail written, with its stack, list, cue
/// and file ... When written". Spec 10 §18, Area 19 — "`thumbnails` answers
/// queue the missing files and each written file sends one event". The
/// thumbnail job draws on the GPU, so this runs where the Metal tests run.
final class MetalThumbnailApiTests: XCTestCase {
    func test_aThumbnailsQueryQueuesTheMissingFilesAndOneEventFollowsEach() throws {
        let metal = try MetalHarness.backend()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("oengine-thumbnails-api-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let engine = try HeadlessEngine(library: EngineFixtures.library(), machine: EngineFixtures.spikeMachine(mainSize: Size(width: 480, height: 270)),
                                        media: EngineFixtures.media, metal: metal, thumbnailFolder: folder)
        let service = try XCTUnwrap(engine.engine.thumbnails)
        engine.tick()

        let client = ApiTestClient(hub: engine.engine.api)
        client.send("subscribe", ["topics": .array([.string("thumbnails")])])
        let asked = client.send("query", ["what": .string("thumbnails"), "list": .number(42), "stack": .number(Double(service.stack))])
        engine.tick()
        let answer = try XCTUnwrap(client.answer(to: asked))
        XCTAssertEqual(answer["type"], .string("answer"))
        let cues = EngineFixtures.list42Cues.map { $0.uuidString.lowercased() }
        let first = try XCTUnwrap(answer["thumbnails"]?.arrayValue?.compactMap(\.objectValue))
        XCTAssertEqual(first.compactMap { $0["cue"]?.stringValue }, cues)
        XCTAssertEqual(first.map { $0["file"] }, Array(repeating: .null, count: cues.count), "none is drawn yet")

        // The job draws them in the background; an event follows each file, after the answer that queued it.
        XCTAssertTrue(waitUntil(30) { service.statistics.rendered == cues.count }, "rendered \(service.statistics.rendered)")
        service.waitUntilIdle()
        XCTAssertTrue(waitUntil(5) { client.messages().events("thumbnails").count >= cues.count }, "the last file's event follows it")
        let messages = client.messages().filter { $0["type"] != .string("hello") }
        let events = messages.events("thumbnails")
        XCTAssertEqual(events.count, cues.count, "one event per file written")
        XCTAssertEqual(Set(events.compactMap { $0["cue"]?.stringValue }), Set(cues))
        for event in events {
            XCTAssertEqual(event["stack"], .number(Double(service.stack)))
            XCTAssertEqual(event["list"], .number(42))
            XCTAssertEqual(event["listUuid"], .string(EngineFixtures.list42.uuidString.lowercased()))
            let file = try XCTUnwrap(event["file"]?.stringValue)
            XCTAssertTrue(file.hasSuffix(".png"))
            XCTAssertTrue(FileManager.default.fileExists(atPath: file), "the file it names is there: \(file)")
        }
        let answerAt = try XCTUnwrap(messages.firstIndex { $0["id"] == .number(Double(asked)) })
        let firstEventAt = try XCTUnwrap(messages.firstIndex { $0["topic"] == .string("thumbnails") })
        XCTAssertLessThan(answerAt, firstEventAt)

        // Asked again, each cue has its file, nothing is queued and no event follows.
        let again = client.send("query", ["what": .string("thumbnails"), "listUuid": .string(EngineFixtures.list42.uuidString.lowercased())])
        engine.tick()
        let second = try XCTUnwrap(client.answer(to: again)?["thumbnails"]?.arrayValue?.compactMap(\.objectValue))
        XCTAssertEqual(second.compactMap { $0["file"]?.stringValue }.count, cues.count)
        service.waitUntilIdle()
        XCTAssertEqual(service.statistics.rendered, cues.count)
        XCTAssertEqual(client.messages().events("thumbnails").count, cues.count)

        // Area 19 reading — v1 draws thumbnails on the thumbnail stack alone.
        let other = client.send("query", ["what": .string("thumbnails"), "list": .number(42), "stack": .number(Double(service.stack + 1))])
        engine.tick()
        XCTAssertEqual(client.answer(to: other)?["reason"]?.stringValue?.hasPrefix("notInV1: "), true)
    }
}
