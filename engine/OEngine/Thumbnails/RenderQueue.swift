// OEngine — Spec 11 §3, the `render` query: its canvases, the requests that
// wait, and the files it answers with.

import Foundation
import OCore

/// Spec 11 §3 — what one render drew: the picture, and "What it reports".
struct RenderDrawn: Sendable {
    var png: Data
    var size: PixelSize
    /// "`overflow` lists each text box whose sample text overflows (Spec 6
    /// §4) as `{ "box": 2, "offset": 0, "linesCut": 2 }`".
    var overflow: [JSONValue] = []
    /// "`fallbackFonts` each box whose font fell back to `fallbackFont`, with the font's name".
    var fallbackFonts: [JSONValue] = []
    /// "a media item whose file is missing draws nothing for the pixel boxes, and the answer says `missing: true`".
    var missing = false
}

/// Spec 11 §3 — "When. The engine draws it on the thumbnail job's background
/// queue, with the thumbnail job's code, ahead of thumbnails ... A request
/// names its `canvas`, up to 16 letters and digits, scoped to its connection,
/// which may use eight canvases; a newer request for the same canvas replaces
/// one still waiting, which is answered `{"superseded": true}`. A drag on a
/// canvas therefore never queues a picture per pixel moved."
///
/// "The files. `machine/thumbnails/render/`, named by connection, canvas and
/// request `id` (`c3-inspector-61.png`), keeping each canvas's newest two;
/// the folder is emptied at launch, and a connection's files when it closes.
/// Nothing else reads them."
///
/// The queue holds what waits and where the files are; the drawing is the
/// thumbnail job's (`draw`), run where `schedule` puts it. A request is
/// answered when its picture is written, on that thread, whatever else its
/// connection has asked meanwhile: a picture that takes a while holds no
/// other answer back.
final class RenderQueue: @unchecked Sendable {
    /// "scoped to its connection, which may use eight canvases".
    static let canvasesPerConnection = 8
    /// "keeping each canvas's newest two".
    static let filesKept = 2

    /// One request, with the roots and the sizes it was read against.
    struct Job: Sendable {
        var connection: Int
        var id: JSONValue
        /// The id as the file's name carries it (`RenderRequest.fileID`).
        var fileID: String
        var request: RenderRequest
        var library: Library
        var machine: Machine
        /// Spec 11 §3 — "the size its stack pass and preview use at that moment".
        var geometry: MachineGeometry
        var answer: @Sendable (JSONValue) -> Void
    }

    private struct Key: Hashable {
        var connection: Int
        var canvas: String
    }

    let folder: URL
    private let machineRoot: URL?
    private let log: EngineLog
    private let schedule: (@escaping @Sendable () -> Void) -> Void
    private let draw: @Sendable (Job) -> Result<RenderDrawn, Rejection>
    private let lock = NSLock()
    /// Each connection's canvases, in the order it first drew on them. A connection with none here has closed, or never asked.
    private var canvases: [Int: [String]] = [:]
    private var waiting: [Key: Job] = [:]
    /// The canvases with a request waiting, the longest wait first.
    private var order: [Key] = []
    private var files: [Key: [URL]] = [:]

    /// `folder` is `machine/thumbnails/render/`, emptied now; `schedule` runs
    /// its block on the thumbnail job's queue ahead of thumbnails; `draw`
    /// makes one picture there.
    init(folder: URL, machineRoot: URL?, log: EngineLog, schedule: @escaping (@escaping @Sendable () -> Void) -> Void,
         draw: @escaping @Sendable (Job) -> Result<RenderDrawn, Rejection>) {
        self.folder = folder
        self.machineRoot = machineRoot
        self.log = log
        self.schedule = schedule
        self.draw = draw
        emptyFolder()
    }

    /// "the folder is emptied at launch".
    private func emptyFolder() {
        let manager = FileManager.default
        for name in (try? manager.contentsOfDirectory(atPath: folder.path)) ?? [] {
            try? manager.removeItem(at: folder.appendingPathComponent(name))
        }
    }

    /// The file a request's picture is written to.
    func file(for job: Job) -> URL {
        folder.appendingPathComponent("c\(job.connection)-\(job.request.canvas)-\(job.fileID).png")
    }

    /// Takes a request: it waits its turn on its canvas, replacing one still
    /// waiting there, "which is answered `{"superseded": true}`". Refused
    /// with `badValue` when the canvas would be "a connection's ninth".
    func submit(_ job: Job) -> Rejection? {
        let key = Key(connection: job.connection, canvas: job.request.canvas)
        lock.lock()
        var names = canvases[job.connection] ?? []
        if !names.contains(job.request.canvas) {
            guard names.count < RenderQueue.canvasesPerConnection else {
                lock.unlock()
                return Rejection(reason: .badValue, message: "a connection draws on up to \(RenderQueue.canvasesPerConnection) canvases: \(names.joined(separator: ", "))")
            }
            names.append(job.request.canvas)
            canvases[job.connection] = names
        }
        let replaced = waiting.updateValue(job, forKey: key)
        if replaced == nil { order.append(key) }
        lock.unlock()
        if let replaced {
            replaced.answer(.object(["id": replaced.id, "type": .string("answer"), "superseded": .bool(true)]))
        } else {
            schedule { [self] in runNext() }
        }
        return nil
    }

    /// "a connection's files when it closes": its canvases, whatever of its
    /// waits, which is not answered, and its files.
    func forget(connection: Int) {
        lock.lock()
        canvases[connection] = nil
        waiting = waiting.filter { $0.key.connection != connection }
        order.removeAll { $0.connection == connection }
        let gone = files.filter { $0.key.connection == connection }
        for key in gone.keys { files[key] = nil }
        lock.unlock()
        for url in gone.values.flatMap({ $0 }) { try? FileManager.default.removeItem(at: url) }
    }

    /// How many requests wait, for the tests.
    var waitingCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return waiting.count
    }

    /// On the thumbnail job's queue: draws the request that has waited longest, writes its file and answers it.
    private func runNext() {
        lock.lock()
        guard let key = order.first else {
            lock.unlock()
            return
        }
        order.removeFirst()
        let taken = waiting.removeValue(forKey: key)
        lock.unlock()
        guard let job = taken else { return }
        switch draw(job) {
        case .failure(let rejection):
            job.answer(ApiHub.rejected(job.id, rejection))
        case .success(let drawn):
            let url = file(for: job)
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try drawn.png.write(to: url, options: .atomic)
            } catch {
                log.error("render: the picture for canvas \(job.request.canvas) could not be written: \(error)")
                job.answer(ApiHub.rejected(job.id, Rejection(reason: .conflict, message: "the picture could not be written: \(error.localizedDescription)")))
                return
            }
            lock.lock()
            guard canvases[job.connection] != nil else {
                // The connection closed while this was drawn: nobody is left to read it.
                lock.unlock()
                try? FileManager.default.removeItem(at: url)
                return
            }
            var kept = (files[key] ?? []).filter { $0 != url }
            kept.append(url)
            let old = Array(kept.dropLast(RenderQueue.filesKept))
            files[key] = Array(kept.suffix(RenderQueue.filesKept))
            lock.unlock()
            for stale in old { try? FileManager.default.removeItem(at: stale) }
            var fields: [String: JSONValue] = [
                "id": job.id, "type": .string("answer"), "file": .string(ApiQueries.relative(url, to: machineRoot)),
                "width": .number(Double(drawn.size.width)), "height": .number(Double(drawn.size.height)),
                "overflow": .array(drawn.overflow), "fallbackFonts": .array(drawn.fallbackFonts),
            ]
            if drawn.missing { fields["missing"] = .bool(true) }
            job.answer(.object(fields))
        }
    }
}
