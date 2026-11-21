import Foundation
import XCTest
import OCore
@testable import OEngine

/// Spec 11 §3 — the `render` query over the API: "`render` answers with a
/// file on this Mac, so it is the local socket's only, refused on the LAN
/// with `localOnly`"; "Like every query, each is answered with its request's
/// `id` as `{"id": …, "type": "answer", …}`, and refused with Spec 10 §3's
/// rejected result". Spec 11 §13, Area 14: "the `render` and `uses` queries".
/// The first tests run the hub over a drawing that makes a few bytes, so they
/// run anywhere; the last draws on the GPU, where the Metal tests run.
final class ApiRenderTests: XCTestCase {
    typealias E = EngineFixtures

    /// What the stand-in drawing was asked to draw.
    final class Seen: @unchecked Sendable {
        private let lock = NSLock()
        private var all: [RenderQueue.Job] = []

        func add(_ job: RenderQueue.Job) {
            lock.lock()
            all.append(job)
            lock.unlock()
        }

        var jobs: [RenderQueue.Job] {
            lock.lock()
            defer { lock.unlock() }
            return all
        }
    }

    var cueSubject: JSONValue {
        .object(["kind": .string("cue"), "listUuid": .string(E.list42.uuidString.lowercased()), "cue": .string(E.list42Cues[0].uuidString.lowercased()),
                 "stack": .number(1)])
    }

    /// An engine on disk whose pictures are a few bytes, drawn at once where the queue would hand them to the thumbnail job.
    func fixture() throws -> (api: ApiFixture, seen: Seen) {
        let api = try ApiFixture()
        let seen = Seen()
        let root = api.disk.machineRoot
        api.engine.engine.renders = RenderQueue(folder: root.appendingPathComponent("thumbnails/render"), machineRoot: root,
                                               log: EngineLog(category: "test-render"), schedule: { $0() },
                                               draw: { job in
                                                   seen.add(job)
                                                   return .success(RenderDrawn(png: Data("png".utf8), size: PixelSize(width: job.request.width, height: 90)))
                                               })
        return (api, seen)
    }

    @discardableResult
    func ask(_ api: ApiFixture, _ client: ApiTestClient, _ fields: [String: JSONValue]) throws -> [String: JSONValue] {
        var members = fields
        members["what"] = .string("render")
        let id = client.send("query", members)
        api.tick()
        return try XCTUnwrap(client.answer(to: id), "no answer to the render")
    }

    func rejected(_ answer: [String: JSONValue], _ code: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(answer["result"], .string("rejected"), file: file, line: line)
        XCTAssertEqual(answer["reason"]?.stringValue?.hasPrefix(code + ": "), true, "\(answer["reason"] ?? .null)", file: file, line: line)
    }

    func test_renderIsTheLocalSocketsOnly() throws {
        let (api, seen) = try fixture()
        let lan = api.lan()
        rejected(try ask(api, lan, ["canvas": .string("inspector"), "width": .number(640), "subject": cueSubject]), "localOnly")
        XCTAssertTrue(seen.jobs.isEmpty)
    }

    func test_anEngineWithNoThumbnailJobDrawsNoPictures() throws {
        let api = try ApiFixture()
        XCTAssertNil(api.engine.engine.thumbnails, "the recording backend draws nothing")
        rejected(try ask(api, api.local(), ["canvas": .string("inspector"), "width": .number(640), "subject": cueSubject]), "conflict")
    }

    func test_aRenderIsAnsweredWithItsFileUnderTheMachineRoot() throws {
        let (api, seen) = try fixture()
        let client = api.local()
        let id = client.send("query", ["what": .string("render"), "canvas": .string("inspector"), "width": .number(640), "subject": cueSubject])
        api.tick()
        let answer = try XCTUnwrap(client.answer(to: id))
        XCTAssertEqual(answer["type"], .string("answer"))
        XCTAssertEqual(answer["id"], .number(Double(id)))
        let file = try XCTUnwrap(answer["file"]?.stringValue)
        XCTAssertEqual(file, "thumbnails/render/c\(client.connection.id)-inspector-\(id).png", "named by connection, canvas and request id")
        XCTAssertTrue(FileManager.default.fileExists(atPath: api.disk.machineRoot.appendingPathComponent(file).path))
        XCTAssertEqual(answer["width"], .number(640))
        XCTAssertEqual(answer["height"], .number(90))
        XCTAssertEqual(answer["overflow"], .array([]))
        XCTAssertEqual(answer["fallbackFonts"], .array([]))
        // What it was read against: the roots and the sizes as the build left them.
        let job = try XCTUnwrap(seen.jobs.first)
        XCTAssertEqual(job.connection, client.connection.id)
        XCTAssertEqual(job.geometry, api.engine.control.geometry)
        guard case .cue(let list, 0, let stack) = job.request.subject else { return XCTFail("the cue asked for") }
        XCTAssertEqual(list.number, 42)
        XCTAssertEqual(stack.number, 1)
    }

    /// "so that what an editor shows is what the engine draws": a render sent
    /// behind an edit is read against the library the edit left.
    func test_aRenderBehindAnEditSeesTheEdit() throws {
        let (api, seen) = try fixture()
        let client = api.local()
        try api.send("edit preset 3 label \"Lower third\"", from: client)
        let subject: JSONValue = .object(["kind": .string("layout"), "preset": .number(3), "layout": .string("*"), "stack": .number(1)])
        try ask(api, client, ["canvas": .string("preset"), "width": .number(480), "subject": subject])
        guard case .layout(let preset, .any, _, _)? = seen.jobs.last?.request.subject else { return XCTFail("the layout asked for") }
        XCTAssertEqual(preset.label, "Lower third")
    }

    func test_whatCannotBeDrawnIsARejectedResult() throws {
        let (api, seen) = try fixture()
        let client = api.local()
        rejected(try ask(api, client, ["canvas": .string("inspector"), "width": .number(100), "subject": cueSubject]), "badValue")
        rejected(try ask(api, client, ["canvas": .string("the inspector"), "width": .number(640), "subject": cueSubject]), "badValue")
        rejected(try ask(api, client, ["canvas": .string("inspector"), "width": .number(640),
                                       "subject": .object(["kind": .string("layout"), "preset": .number(99), "layout": .string("*"), "stack": .number(1)])]), "unknownObject")
        rejected(try ask(api, client, ["canvas": .string("inspector"), "width": .number(640)]), "missingArgument")
        // An id a file's name can't carry.
        let id = client.send("query", ["id": .string("../61"), "what": .string("render"), "canvas": .string("inspector"), "width": .number(640), "subject": cueSubject])
        api.tick()
        _ = id
        let refused = try XCTUnwrap(client.messages().first { $0["id"] == .string("../61") })
        rejected(refused, "badValue")
        XCTAssertTrue(seen.jobs.isEmpty, "nothing was drawn")
        // "a connection's ninth canvas is `badValue`".
        for index in 1...8 { try ask(api, client, ["canvas": .string("c\(index)"), "width": .number(160), "subject": cueSubject]) }
        rejected(try ask(api, client, ["canvas": .string("c9"), "width": .number(160), "subject": cueSubject]), "badValue")
    }

    /// "a connection's files when it closes."
    func test_aConnectionsFilesGoWhenItCloses() throws {
        let (api, _) = try fixture()
        let folder = api.disk.machineRoot.appendingPathComponent("thumbnails/render")
        let client = api.local()
        let other = api.local()
        try ask(api, client, ["canvas": .string("inspector"), "width": .number(640), "subject": cueSubject])
        try ask(api, other, ["canvas": .string("inspector"), "width": .number(640), "subject": cueSubject])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path).count, 2)
        client.connection.close()
        let left = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        XCTAssertEqual(left.count, 1)
        XCTAssertTrue(left[0].hasPrefix("c\(other.connection.id)-"), "\(left)")
    }

    // MARK: - On the GPU

    /// The whole path: the request over the API, the picture drawn by the
    /// thumbnail job on its queue, the file written, the answer sent when it
    /// is; and a newer request for the canvas replacing one still waiting.
    func test_thePictureIsDrawnOnTheThumbnailJobsQueueAndANewerRequestReplacesOneWaiting() throws {
        let metal = try MetalHarness.backend()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("oengine-render-api-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = try HeadlessEngine(library: E.library(), machine: E.spikeMachine(), media: E.media, metal: metal,
                                        thumbnailFolder: root.appendingPathComponent("thumbnails"))
        let service = try XCTUnwrap(engine.engine.thumbnails)
        engine.engine.setUpRenders(folder: root.appendingPathComponent("thumbnails/render"))
        XCTAssertNotNil(engine.engine.renders)
        engine.tick()
        let client = ApiTestClient(hub: engine.engine.api)

        // "waits as that job does while the render thread is skipping aux passes (Spec 4 §10)".
        let blocked = Blocked()
        service.auxBlocked = { blocked.value }
        blocked.value = true
        var ids: [Int] = []
        for width in [320, 400, 480] {
            ids.append(client.send("query", ["what": .string("render"), "canvas": .string("inspector"), "width": .number(Double(width)), "subject": cueSubject]))
            engine.tick()
            engine.engine.api.workers.sync {}
        }
        // Two were replaced while the render thread had no headroom, and say so; the third still waits.
        XCTAssertEqual(client.answer(to: ids[0])?["superseded"], .bool(true))
        XCTAssertEqual(client.answer(to: ids[1])?["superseded"], .bool(true))
        XCTAssertNil(client.answer(to: ids[2], wait: 0.2))
        blocked.value = false
        service.waitUntilIdle()
        let answer = try XCTUnwrap(client.answer(to: ids[2]))
        XCTAssertEqual(answer["type"], .string("answer"))
        XCTAssertEqual(answer["width"], .number(480))
        XCTAssertEqual(answer["height"], .number(270))
        let file = try XCTUnwrap(answer["file"]?.stringValue)
        XCTAssertTrue(file.hasSuffix("c\(client.connection.id)-inspector-\(ids[2]).png"), file)
        let png = try Data(contentsOf: URL(fileURLWithPath: file))
        XCTAssertEqual(Array(png.prefix(4)), [0x89, 0x50, 0x4E, 0x47], "a PNG")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("thumbnails/render").path).count, 1,
                       "one picture was drawn for the three requests")
    }

    final class Blocked: @unchecked Sendable {
        private let lock = NSLock()
        private var held = false

        var value: Bool {
            get {
                lock.lock()
                defer { lock.unlock() }
                return held
            }
            set {
                lock.lock()
                held = newValue
                lock.unlock()
            }
        }
    }
}
