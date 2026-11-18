import Foundation
import XCTest
import OCore
@testable import OApp

/// A clock a test moves: `now` stands still until `advance`, which runs the
/// work that falls due, in the order of its times, as if that time had
/// passed. No test waits for time (CLAUDE.md, and what Area 19 learned on
/// the hosted runner).
@MainActor
final class ManualClock: AppClock {
    private(set) var now: TimeInterval = 1_000
    private var scheduled: [Scheduled] = []
    private var order = 0

    private final class Scheduled: ClockTask {
        let at: TimeInterval
        let order: Int
        var work: (@MainActor () -> Void)?

        init(at: TimeInterval, order: Int, work: @escaping @MainActor () -> Void) {
            self.at = at
            self.order = order
            self.work = work
        }

        func cancel() {
            work = nil
        }
    }

    @discardableResult
    func after(_ seconds: TimeInterval, _ work: @escaping @MainActor () -> Void) -> any ClockTask {
        order += 1
        let task = Scheduled(at: now + max(0, seconds), order: order, work: work)
        scheduled.append(task)
        return task
    }

    /// Moves the clock on by `seconds`, running everything due on the way, work scheduled by that work included.
    func advance(by seconds: TimeInterval) {
        let end = now + seconds
        while let next = scheduled.filter({ $0.work != nil && $0.at <= end }).min(by: { ($0.at, $0.order) < ($1.at, $1.order) }) {
            now = max(now, next.at)
            let work = next.work
            next.work = nil
            work?()
        }
        scheduled.removeAll { $0.work == nil }
        now = end
    }

    /// How much work is waiting for its time.
    var waiting: Int { scheduled.filter { $0.work != nil }.count }
}

/// A connection with no socket behind it: what the app sent is kept, and the
/// test plays the engine's part, on its own thread and in its own time.
final class FakeTransport: EngineTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [Data] = []
    private var onLine: (@Sendable (Data) -> Void)?
    private var onClose: (@Sendable () -> Void)?
    private var closed = false

    func start(onLine: @escaping @Sendable (Data) -> Void, onClose: @escaping @Sendable () -> Void) {
        lock.lock()
        self.onLine = onLine
        self.onClose = onClose
        lock.unlock()
    }

    @discardableResult
    func send(_ line: Data) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return false }
        lines.append(line)
        return true
    }

    func close() {
        engineCloses()
    }

    /// Every request the app sent, in order.
    var sent: [[String: JSONValue]] {
        lock.lock()
        defer { lock.unlock() }
        return lines.compactMap { (try? JSONValue.parse($0))?.objectValue }
    }

    /// The requests of one type.
    func sent(_ type: String) -> [[String: JSONValue]] {
        sent.filter { $0["type"] == .string(type) }
    }

    /// The queries sent, as `what` and, when the query names a list, its uuid.
    var queries: [String] {
        sent("query").map { query in
            let what = query["what"]?.stringValue ?? "?"
            let list = query["listUuid"]?.stringValue ?? query["local"]?.stringValue
            return list.map { "\(what) \($0.prefix(4))" } ?? what
        }
    }

    /// The id of the last request of `type` (and, for a query, of `what`).
    func id(of type: String, what: String? = nil) -> Int? {
        sent.last { $0["type"] == .string(type) && (what == nil || $0["what"] == .string(what ?? "")) }?["id"]?.intValue
    }

    /// The engine sends one message.
    func engineSends(_ message: [String: JSONValue]) {
        lock.lock()
        let onLine = self.onLine
        lock.unlock()
        onLine?(Data(JSONCanonical.line(.object(message)).utf8))
    }

    /// The engine answers the request with this id.
    func engineAnswers(_ id: Int?, _ fields: [String: JSONValue], type: String = "answer") {
        var message = fields
        message["id"] = .number(Double(id ?? -1))
        message["type"] = .string(type)
        engineSends(message)
    }

    /// The engine closes the connection, or ends.
    func engineCloses() {
        lock.lock()
        let already = closed
        closed = true
        let onClose = self.onClose
        lock.unlock()
        if !already { onClose?() }
    }

    var isClosed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return closed
    }
}

/// A hop that runs the work at once: the test is on the main thread already.
let immediateHop: MainHop = { work in
    MainActor.assumeIsolated { work() }
}

/// A `hello` for the tests.
extension Hello {
    static func test(api: Int = Hello.api, engine: String = OCore.appVersion, pid: Int32 = 4182, run: String = "51e2") -> Hello {
        Hello(api: api, engine: engine, pid: pid, machine: "7a7a", run: run, mach: "org.lcbc.projecto.engine." + run)
    }

    var message: [String: JSONValue] {
        ["type": .string("hello"), "api": .number(Double(api)), "engine": .string(engine), "pid": .number(Double(pid)),
         "machine": .string(machine), "run": .string(run), "mach": .string(mach)]
    }
}
