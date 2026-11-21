import XCTest
import OCore
@testable import OEngine

/// Spec 11 §3 — "A request names its `canvas`, up to 16 letters and digits,
/// scoped to its connection, which may use eight canvases; a newer request
/// for the same canvas replaces one still waiting, which is answered
/// `{"superseded": true}`. A drag on a canvas therefore never queues a
/// picture per pixel moved." "The files. `machine/thumbnails/render/`, named
/// by connection, canvas and request `id` (`c3-inspector-61.png`), keeping
/// each canvas's newest two; the folder is emptied at launch, and a
/// connection's files when it closes." The queue alone, with a drawing that
/// makes a few bytes: no GPU.
final class RenderQueueTests: XCTestCase {
    typealias E = EngineFixtures

    /// The work the queue asked to have run on the thumbnail job's queue, run when the test says.
    final class Scheduled: @unchecked Sendable {
        private let lock = NSLock()
        private var work: [@Sendable () -> Void] = []

        func add(_ block: @escaping @Sendable () -> Void) {
            lock.lock()
            work.append(block)
            lock.unlock()
        }

        var count: Int {
            lock.lock()
            defer { lock.unlock() }
            return work.count
        }

        func runAll() {
            while true {
                lock.lock()
                guard !work.isEmpty else {
                    lock.unlock()
                    return
                }
                let next = work.removeFirst()
                lock.unlock()
                next()
            }
        }
    }

    final class Answers: @unchecked Sendable {
        private let lock = NSLock()
        private var all: [[String: JSONValue]] = []
        private var drawnIDs: [JSONValue] = []

        func add(_ message: JSONValue) {
            lock.lock()
            all.append(message.objectValue ?? [:])
            lock.unlock()
        }

        func drew(_ id: JSONValue) {
            lock.lock()
            drawnIDs.append(id)
            lock.unlock()
        }

        var messages: [[String: JSONValue]] {
            lock.lock()
            defer { lock.unlock() }
            return all
        }

        var drawn: [JSONValue] {
            lock.lock()
            defer { lock.unlock() }
            return drawnIDs
        }
    }

    var root: URL!
    var folder: URL!
    var scheduled: Scheduled!
    var answers: Answers!
    var library: Library!
    var machine: Machine!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("o-render-\(UUID().uuidString)")
        folder = root.appendingPathComponent("thumbnails/render")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        scheduled = Scheduled()
        answers = Answers()
        library = try E.library()
        machine = try E.spikeMachine()
    }

    override func tearDown() {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    func queue(failing: Bool = false) -> RenderQueue {
        let scheduled = self.scheduled!
        let answers = self.answers!
        return RenderQueue(folder: folder, machineRoot: root, log: EngineLog(category: "test-render"),
                           schedule: { scheduled.add($0) },
                           draw: { job in
                               answers.drew(job.id)
                               if failing { return .failure(Rejection(reason: .conflict, message: "no picture")) }
                               var drawn = RenderDrawn(png: Data("png \(job.fileID)".utf8), size: PixelSize(width: job.request.width, height: 90))
                               drawn.overflow = [.object(["box": .number(0), "offset": .number(0), "linesCut": .number(1)])]
                               return .success(drawn)
                           })
    }

    func job(_ id: Int, canvas: String = "inspector", connection: Int = 3) throws -> RenderQueue.Job {
        let subject: JSONValue = .object(["kind": .string("grade"), "grade": .null, "media": .string(E.dawn)])
        let request = try RenderRequest.parse(["canvas": .string(canvas), "width": .number(160), "subject": subject], library: library, machine: machine).get()
        let answers = self.answers!
        return RenderQueue.Job(connection: connection, id: .number(Double(id)), fileID: String(id), request: request, library: library, machine: machine,
                               geometry: MachineGeometry(library: library, machine: machine), answer: { answers.add($0) })
    }

    func files() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
    }

    func test_aRequestIsDrawnWrittenAndAnsweredWithItsFile() throws {
        let queue = queue()
        XCTAssertNil(queue.submit(try job(61)))
        XCTAssertTrue(answers.messages.isEmpty, "nothing is drawn until the thumbnail job's queue runs it")
        XCTAssertEqual(scheduled.count, 1)
        scheduled.runAll()
        XCTAssertEqual(files(), ["c3-inspector-61.png"])
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("c3-inspector-61.png")), Data("png 61".utf8))
        let answer = try XCTUnwrap(answers.messages.first)
        XCTAssertEqual(answer["id"], .number(61))
        XCTAssertEqual(answer["type"], .string("answer"))
        XCTAssertEqual(answer["file"], .string("thumbnails/render/c3-inspector-61.png"), "relative to the machine root")
        XCTAssertEqual(answer["width"], .number(160))
        XCTAssertEqual(answer["height"], .number(90))
        XCTAssertEqual(answer["overflow"], .array([.object(["box": .number(0), "offset": .number(0), "linesCut": .number(1)])]))
        XCTAssertEqual(answer["fallbackFonts"], .array([]))
        XCTAssertNil(answer["missing"], "said only when a file is missing")
    }

    /// "a newer request for the same canvas replaces one still waiting, which is answered `{"superseded": true}`".
    func test_aNewerRequestForACanvasReplacesTheOneStillWaiting() throws {
        let queue = queue()
        for id in 1...5 { XCTAssertNil(queue.submit(try job(id))) }
        XCTAssertEqual(queue.waitingCount, 1)
        let superseded = answers.messages
        XCTAssertEqual(superseded.map { $0["id"] }, [.number(1), .number(2), .number(3), .number(4)])
        for message in superseded {
            XCTAssertEqual(message["superseded"], .bool(true))
            XCTAssertEqual(message["type"], .string("answer"))
            XCTAssertNil(message["file"])
        }
        scheduled.runAll()
        XCTAssertEqual(answers.drawn, [.number(5)], "one picture was drawn for five requests")
        XCTAssertEqual(files(), ["c3-inspector-5.png"])
        // Another canvas, and another connection's canvas of the same name, wait on their own.
        XCTAssertNil(queue.submit(try job(6)))
        XCTAssertNil(queue.submit(try job(7, canvas: "preset")))
        XCTAssertNil(queue.submit(try job(8, connection: 4)))
        XCTAssertEqual(queue.waitingCount, 3)
        scheduled.runAll()
        XCTAssertEqual(answers.drawn, [.number(5), .number(6), .number(7), .number(8)], "in the order they came")
    }

    /// "keeping each canvas's newest two".
    func test_eachCanvasKeepsItsNewestTwoFiles() throws {
        let queue = queue()
        for id in 1...4 {
            XCTAssertNil(queue.submit(try job(id)))
            scheduled.runAll()
        }
        XCTAssertNil(queue.submit(try job(9, canvas: "preset")))
        scheduled.runAll()
        XCTAssertEqual(files(), ["c3-inspector-3.png", "c3-inspector-4.png", "c3-preset-9.png"])
    }

    /// "scoped to its connection, which may use eight canvases"; "a connection's ninth canvas is `badValue`".
    func test_aConnectionsNinthCanvasIsRefused() throws {
        let queue = queue()
        for index in 1...8 { XCTAssertNil(queue.submit(try job(index, canvas: "canvas\(index)"))) }
        XCTAssertEqual(queue.submit(try job(9, canvas: "canvas9"))?.reason, .badValue)
        XCTAssertNil(queue.submit(try job(10, canvas: "canvas3")), "one it already draws on")
        XCTAssertNil(queue.submit(try job(11, canvas: "canvas9", connection: 4)), "another connection has its own eight")
        XCTAssertEqual(RenderQueue.canvasesPerConnection, 8)
    }

    /// "the folder is emptied at launch, and a connection's files when it closes."
    func test_theFolderIsEmptiedAtLaunchAndAConnectionsFilesWhenItCloses() throws {
        try Data("old".utf8).write(to: folder.appendingPathComponent("c1-inspector-7.png"))
        let queue = queue()
        XCTAssertEqual(files(), [], "what a run before this one left")
        XCTAssertNil(queue.submit(try job(1)))
        XCTAssertNil(queue.submit(try job(2, connection: 4)))
        scheduled.runAll()
        XCTAssertEqual(files(), ["c3-inspector-1.png", "c4-inspector-2.png"])
        XCTAssertNil(queue.submit(try job(3)))
        queue.forget(connection: 3)
        XCTAssertEqual(files(), ["c4-inspector-2.png"])
        XCTAssertEqual(queue.waitingCount, 0, "what it had waiting goes too")
        let before = answers.messages.count
        scheduled.runAll()
        XCTAssertEqual(answers.messages.count, before, "and nobody is answered")
        XCTAssertEqual(files(), ["c4-inspector-2.png"])
        // It may connect again: its canvases start over.
        XCTAssertNil(queue.submit(try job(4)))
        scheduled.runAll()
        XCTAssertEqual(files(), ["c3-inspector-4.png", "c4-inspector-2.png"])
    }

    /// A picture that was being drawn as its connection closed is not left behind.
    func test_aPictureDrawnForAClosedConnectionIsRemoved() throws {
        let scheduled = self.scheduled!
        let folder = self.folder!
        final class Holder: @unchecked Sendable { var queue: RenderQueue? }
        let holder = Holder()
        holder.queue = RenderQueue(folder: folder, machineRoot: root, log: EngineLog(category: "test-render"), schedule: { scheduled.add($0) },
                                   draw: { job in
                                       holder.queue?.forget(connection: job.connection)      // the connection closes while this is drawn
                                       return .success(RenderDrawn(png: Data("png".utf8), size: PixelSize(width: 160, height: 90)))
                                   })
        XCTAssertNil(holder.queue?.submit(try job(1)))
        scheduled.runAll()
        XCTAssertEqual(files(), [])
        XCTAssertTrue(answers.messages.isEmpty)
    }

    func test_aPictureThatCouldNotBeDrawnIsARejectedResult() throws {
        let queue = queue(failing: true)
        XCTAssertNil(queue.submit(try job(1)))
        scheduled.runAll()
        let answer = try XCTUnwrap(answers.messages.first)
        XCTAssertEqual(answer["id"], .number(1))
        XCTAssertEqual(answer["result"], .string("rejected"))
        XCTAssertEqual(answer["reason"]?.stringValue?.hasPrefix("conflict: "), true)
        XCTAssertEqual(files(), [])
    }
}
