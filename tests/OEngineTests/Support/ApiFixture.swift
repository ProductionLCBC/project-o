import Foundation
import XCTest
import OCore
@testable import OEngine

/// An engine on a temporary copy of the fixture roots (Spec 1 §10), launched
/// as the process launches it, with clients of its API in the same process:
/// the local socket's messages or a LAN client's, over a transport in memory.
/// A request is taken when the next tick's build starts and answered when
/// that build has finished, so a test sends, ticks and reads.
final class ApiFixture {
    static let token = "a-token-for-tests"

    let disk: DiskFixture
    var engine: HeadlessEngine { disk.engine }
    var hub: ApiHub { disk.engine.engine.api }

    init(launch: Bool = true, prepare: (URL) throws -> Void = { _ in }, configure: (inout Machine) -> Void = { _ in }) throws {
        disk = try DiskFixture(prepare: prepare, configure: configure, launch: launch)
        // The first build only remembers where things stand (Spec 10 §3: a client asks `state` for that).
        engine.tick()
    }

    /// A client on the local socket: its first message is `hello`.
    func local() -> ApiTestClient {
        ApiTestClient(hub: hub, origin: .local)
    }

    /// A client on the LAN, authorized with the token (Spec 2 §9).
    func lan() -> ApiTestClient {
        hub.token = Self.token
        let client = ApiTestClient(hub: hub, origin: .lan)
        client.send("auth", ["token": .string(Self.token)])
        engine.tick()
        _ = client.next()
        return client
    }

    /// A command's object form from its text form, as the app's parser makes it (Spec 2 §4).
    func command(_ text: String) throws -> JSONValue {
        let library = engine.engine.library, machine = engine.engine.machine
        let ids = MediaResolver.knownIds(library: library.mediaIndex, machine: machine.mediaLocal)
        switch CommandText.parse(text, options: ParseOptions(mediaIDs: ids, library: library, machine: machine)) {
        case .success(let guarded): return try JSONCoding.encode(guarded)
        case .failure(let rejection): throw rejection
        }
    }

    /// Sends one command from `client` and returns the request's id.
    @discardableResult
    func send(_ text: String, from client: ApiTestClient, source: String? = nil) throws -> Int {
        var fields: [String: JSONValue] = ["command": try command(text)]
        if let source { fields["source"] = .string(source) }
        return client.send("command", fields)
    }

    func tick(_ count: Int = 1) {
        for _ in 0..<count { engine.tick() }
    }

    /// The command log's entries, in order.
    var entries: [LogEntry] { engine.control.commandLog.entries }
}

extension Array where Element == [String: JSONValue] {
    /// The events among these messages, of one topic or of all.
    func events(_ topic: String? = nil) -> [[String: JSONValue]] {
        filter { $0["type"] == .string("event") && (topic == nil || $0["topic"] == .string(topic ?? "")) }
    }

    /// The messages' types (and an event's topic), in order: the shape of what arrived.
    var shape: [String] {
        map { message in
            let type = message["type"]?.stringValue ?? "?"
            return type == "event" ? "event:\(message["topic"]?.stringValue ?? "?")" : type
        }
    }
}
