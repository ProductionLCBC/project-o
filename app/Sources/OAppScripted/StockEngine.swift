// OAppScripted — a scripted engine that answers as the engine does, from recorded answers.

import Foundation
import OCore

/// Spec 10 §16 — the scripted engine's stock part: it says `hello`, takes
/// subscriptions, answers the queries from the engine's own answers as
/// `tests/fixtures/api-v1/` records them (the contract suite fails when the
/// engine's answers move, so these can't drift), and answers every command
/// `ok`. A test that wants something else answers it first, in `before`.
public final class StockEngine: @unchecked Sendable {
    private let lock = NSLock()
    private var seq = 100
    private var answersHeld: [String: [String: JSONValue]]
    private var currentHeld: [[String: JSONValue]]

    /// Called with each request before the stock answer is worked out; what
    /// it returns is sent in the stock answer's place, and nil leaves the
    /// request to the stock.
    public var before: (@Sendable (JSONValue) -> [JSONValue]?)?

    /// `answers` by query: `state`, `catalog`, `media`, and a list's by
    /// `list <uuid>`, `thumbnails <uuid>` and so on. `current` are the
    /// events sent on subscribe, as the topics that keep a value send theirs.
    public init(answers: [String: [String: JSONValue]] = [:], current: [[String: JSONValue]] = []) {
        answersHeld = answers
        currentHeld = current
    }

    /// The stock engine over the recorded answers in `folder`
    /// (`tests/fixtures/api-v1/`): the fixture library, with a playlist live
    /// on its first cue.
    public static func recorded(in folder: URL) throws -> StockEngine {
        func load(_ name: String) throws -> [String: JSONValue] {
            let value = try JSONValue.parse(Data(contentsOf: folder.appendingPathComponent(name + ".json")))
            guard let members = value.objectValue else { throw CocoaError(.fileReadCorruptFile) }
            return members
        }
        var answers: [String: [String: JSONValue]] = [:]
        for name in ["state", "catalog", "media", "snapshots"] { answers[name] = try load(name) }
        for (file, what) in [("list-42", "list"), ("list-7", "list"), ("list-local", "list")] {
            let answer = try load(file)
            if let uuid = answer["list"]?.objectValue?["uuid"]?.stringValue { answers["\(what) \(uuid)"] = answer }
        }
        let events = try load("events")
        let current = ["history.empty", "saving", "engine"].compactMap { events[$0]?.objectValue }
        return StockEngine(answers: answers, current: current)
    }

    /// Changes one stock answer.
    public func set(_ key: String, _ answer: [String: JSONValue]?) {
        lock.lock()
        answersHeld[key] = answer
        lock.unlock()
    }

    /// The `hello` of an engine with this process id: `api` 1, and the version given.
    public static func hello(pid: Int32, engine: String = OCore.appVersion, run: String = "51e251e2-0000-4000-8000-000000000002") -> JSONValue {
        .object(["type": .string("hello"), "api": .number(1), "engine": .string(engine), "pid": .number(Double(pid)),
                 "machine": .string("7a7a0000-0000-4000-8000-000000000001"), "run": .string(run),
                 "mach": .string("org.lcbc.projecto.engine." + run)])
    }

    /// The answer to one request; give this to `ScriptedEngine.respond`.
    public func respond(_ request: JSONValue) -> [JSONValue] {
        if let custom = before?(request) { return custom }
        guard let members = request.objectValue, let type = members["type"]?.stringValue else { return [] }
        let id = members["id"] ?? .null
        func result(_ fields: [String: JSONValue]) -> JSONValue {
            var message = fields
            message["id"] = id
            message["type"] = .string("result")
            return .object(message)
        }
        func next() -> JSONValue {
            lock.lock()
            defer { lock.unlock() }
            seq += 1
            return .number(Double(seq))
        }
        switch type {
        case "subscribe":
            lock.lock()
            let current = currentHeld
            lock.unlock()
            return [result(["result": .string("ok")])] + current.map(JSONValue.object)
        case "query":
            let what = members["what"]?.stringValue ?? ""
            let list = members["listUuid"]?.stringValue ?? members["local"]?.stringValue
            lock.lock()
            let answer = answersHeld[list.map { "\(what) \($0)" } ?? what]
            lock.unlock()
            guard var answer else {
                if what == "thumbnails" { return [.object(["id": id, "type": .string("answer"), "stack": .number(1), "thumbnails": .array([])])] }
                return [result(["result": .string("rejected"), "reason": .string("unknownObject: the scripted engine has no \(what) answer")])]
            }
            answer["id"] = id
            answer["type"] = .string("answer")
            return [.object(answer)]
        case "command", "commands", "note":
            return [result(["result": .string("ok"), "seq": next()])]
        case "ping":
            return [.object(["id": id, "type": .string("pong")])]
        case "stop":
            return [result(["result": .string("ok"), "unsaved": .array([])])]
        case "releaseScreen":
            return [result(["result": .string("ok"), "outputs": .array([])])]
        default:
            return [result(["result": .string("rejected"), "reason": .string("badValue: there is no \(type) request")])]
        }
    }
}
