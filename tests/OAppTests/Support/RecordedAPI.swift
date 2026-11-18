import Foundation
import XCTest
import OCore

/// The engine's answers and events as recorded from the real API hub on the
/// fixture roots, in `tests/fixtures/api-v1/`: one canonical JSON file each
/// (Spec 1 §5's form, so the diffs read). `EngineContractTests` records them
/// and fails when the engine's answers move; the scripted engine's stock
/// answers, and the model tests, read them (Spec 10 §16).
enum RecordedAPI {
    static let folder = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // Support
        .deletingLastPathComponent()   // OAppTests
        .deletingLastPathComponent()   // tests
        .appendingPathComponent("fixtures/api-v1")

    /// Set `O_RECORD_API=1` to write what the engine sends in place of comparing with it.
    static var isRecording: Bool { ProcessInfo.processInfo.environment["O_RECORD_API"] == "1" }

    static func url(_ name: String) -> URL {
        folder.appendingPathComponent(name + ".json")
    }

    /// A recorded message; fails the test when the file isn't there or isn't JSON.
    static func load(_ name: String, file: StaticString = #filePath, line: UInt = #line) throws -> [String: JSONValue] {
        let data = try Data(contentsOf: url(name))
        return try XCTUnwrap(JSONValue.parse(data).objectValue, "\(name).json isn't a JSON object", file: file, line: line)
    }

    /// The recorded events, by the name the recording gave each.
    static func event(_ name: String, file: StaticString = #filePath, line: UInt = #line) throws -> [String: JSONValue] {
        let events = try load("events", file: file, line: line)
        return try XCTUnwrap(events[name]?.objectValue, "events.json has no \(name)", file: file, line: line)
    }

    /// Records `message` under `name`, or compares it with what is recorded.
    /// What differs from run to run is blanked on both sides first.
    static func check(_ name: String, _ message: [String: JSONValue], file: StaticString = #filePath, line: UInt = #line) throws {
        // The request's own id is the asker's, not the engine's: it depends on how many requests came before.
        var message = message
        if message["type"] == .string("answer") { message["id"] = nil }
        let settled = settle(.object(message))
        if isRecording {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try JSONCanonical.data(settled).write(to: url(name))
            return
        }
        guard FileManager.default.fileExists(atPath: url(name).path) else {
            return XCTFail("\(name).json isn't recorded: run the contract tests once with O_RECORD_API=1", file: file, line: line)
        }
        let recorded = try JSONValue.parse(Data(contentsOf: url(name)))
        if recorded != settled {
            let differing = difference(recorded, settled, at: name)
            XCTFail("the engine's \(name) is no longer what tests/fixtures/api-v1/\(name).json records; record again with O_RECORD_API=1 once the change is meant.\n" + differing.prefix(12).joined(separator: "\n"), file: file, line: line)
        }
    }

    /// The values that change from one run to the next, by their key: a
    /// process id, a run's uuid, a random group id, a line's place in the
    /// log, where playing media has got to, how long is left on a countdown,
    /// a file's date on this disk, a zip's size. Each is blanked to a value
    /// of its own kind, so what reads the record still finds a number where
    /// the engine sends one.
    static let volatile: Set<String> = ["pid", "run", "group", "seq", "positionMs", "inMs", "clearInMs", "keptAt", "bytes", "ts", "writtenAt",
                                        "takenAt", "addedAt"]

    static func settle(_ value: JSONValue) -> JSONValue {
        switch value {
        case .object(let members):
            var out: [String: JSONValue] = [:]
            for (key, member) in members {
                guard volatile.contains(key) else {
                    out[key] = settle(member)
                    continue
                }
                switch member {
                case .number: out[key] = .number(0)
                case .string: out[key] = .string("…")
                default: out[key] = settle(member)
                }
            }
            return .object(out)
        case .array(let items):
            return .array(items.map(settle))
        default:
            return value
        }
    }

    /// Where two values differ, as lines a person can read.
    static func difference(_ old: JSONValue, _ new: JSONValue, at path: String) -> [String] {
        switch (old, new) {
        case (.object(let a), .object(let b)):
            var lines: [String] = []
            for key in Set(a.keys).union(b.keys).sorted() {
                switch (a[key], b[key]) {
                case (let x?, let y?): lines += difference(x, y, at: path + "." + key)
                case (nil, _?): lines.append("\(path).\(key): new")
                case (_?, nil): lines.append("\(path).\(key): gone")
                case (nil, nil): break
                }
            }
            return lines
        case (.array(let a), .array(let b)):
            if a.count != b.count { return ["\(path): \(a.count) items recorded, \(b.count) now"] }
            return zip(a, b).enumerated().flatMap { index, pair in difference(pair.0, pair.1, at: "\(path)[\(index)]") }
        default:
            return old == new ? [] : ["\(path): recorded \(JSONCanonical.line(old)), now \(JSONCanonical.line(new))"]
        }
    }
}
