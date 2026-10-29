// OEngine — Spec 4 §15, "Driven by the Spec 2 vocabulary over OSC from a
// script": the script, its schedule, and the driver that sends it.

import Foundation
import Darwin
import OCore
import Synchronization

public enum ScenarioError: Error, CustomStringConvertible, Equatable {
    case notAScenario(String)
    case badPeer(String)

    public var description: String {
        switch self {
        case .notAScenario(let kind): return "not a soak scenario (kind \(kind))"
        case .badPeer(let text): return "not a host:port: \(text)"
        }
    }
}

/// Spec 4 §15 — the soak script: command lines in the Spec 2 text form, each
/// at a time within one pass of `loopMs`; with `loop` the pass repeats until
/// the run's duration is up. "writes with dissolves, video-to-video dissolves,
/// text changes every few seconds, a grade animated over two seconds, a stack
/// switch and a blackout every ten minutes, `next` through the fixture list".
public struct SoakScenario: Codable, Equatable, Sendable {
    public struct Step: Codable, Equatable, Sendable {
        public var atMs: Int
        public var cmd: String

        public init(atMs: Int, cmd: String) {
            self.atMs = atMs
            self.cmd = cmd
        }
    }

    public var app: String
    public var kind: String
    public var schema: Int
    public var title: String
    public var loop: Bool
    public var loopMs: Int
    public var steps: [Step]

    public init(title: String, loop: Bool = true, loopMs: Int, steps: [Step]) {
        app = OCore.appVersion
        kind = "soakScenario"
        schema = 1
        self.title = title
        self.loop = loop
        self.loopMs = loopMs
        self.steps = steps
    }

    public static func load(_ url: URL) throws -> SoakScenario {
        let scenario = try JSONDecoder().decode(SoakScenario.self, from: Data(contentsOf: url))
        guard scenario.kind == "soakScenario" else { throw ScenarioError.notAScenario(scenario.kind) }
        return scenario
    }

    /// Every step parsed against a library's media ids (Spec 2 §4): the
    /// commands in step order, and a rejection for every step that did not parse.
    public func parsed(options: ParseOptions) -> (commands: [Command], rejections: [(step: Int, rejection: Rejection)]) {
        var commands: [Command] = []
        var rejections: [(Int, Rejection)] = []
        for (index, step) in steps.enumerated() {
            switch CommandText.parse(step.cmd, options: options) {
            case .success(let guarded): commands.append(guarded.command)
            case .failure(let rejection): rejections.append((index, rejection))
            }
        }
        return (commands, rejections)
    }

    /// The steps of a run of `durationMs`, in time order, the pass repeated
    /// every `loopMs` while `loop` is set.
    public func schedule(durationMs: Int) -> [(atMs: Int, step: Step)] {
        let ordered = steps.sorted { $0.atMs < $1.atMs }
        guard !ordered.isEmpty, durationMs > 0 else { return [] }
        let period = max(loopMs, (ordered.last?.atMs ?? 0) + 1)
        var out: [(Int, Step)] = []
        var base = 0
        repeat {
            for step in ordered {
                let at = base + step.atMs
                guard at < durationMs else { return out }
                out.append((at, step))
            }
            base += period
        } while loop
        return out
    }
}

/// A UDP sender for OSC packets.
public final class OSCClient: @unchecked Sendable {
    private let fd: Int32

    public init() throws {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { throw OSCServerError.socket(String(cString: strerror(errno))) }
        self.fd = fd
    }

    deinit {
        close(fd)
    }

    /// Spec 4 §15 — host:port as written on a command line.
    public static func peer(_ text: String) throws -> OSCPeer {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, let port = UInt16(parts[1]) else { throw ScenarioError.badPeer(text) }
        let host = parts[0].isEmpty ? "127.0.0.1" : String(parts[0])
        guard host == "localhost" || inet_addr(host) != INADDR_NONE else { throw ScenarioError.badPeer(text) }
        return OSCPeer(host: host == "localhost" ? "127.0.0.1" : host, port: port)
    }

    @discardableResult
    public func send(_ data: Data, to peer: OSCPeer) -> Bool {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = peer.port.bigEndian
        guard inet_pton(AF_INET, peer.host, &address.sin_addr) == 1 else { return false }
        let sent = data.withUnsafeBytes { raw in
            withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, raw.baseAddress, data.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        return sent == data.count
    }
}

/// Spec 4 §15 — sends a scenario to the engine: each step at its time, as the
/// OSC message Spec 2 §6 maps its command to, over UDP.
public final class ScenarioDriver: @unchecked Sendable {
    public let scenario: SoakScenario
    public let peer: OSCPeer
    public let options: ParseOptions
    private let log: EngineLog
    private let client: OSCClient
    private let stopping = Atomic<Bool>(false)
    private let sentCount = Atomic<Int64>(0)
    private let lock = NSLock()
    private var failures: [String] = []

    public init(scenario: SoakScenario, options: ParseOptions, to peer: OSCPeer, log: EngineLog) throws {
        self.scenario = scenario
        self.options = options
        self.peer = peer
        self.log = log
        client = try OSCClient()
    }

    public var sent: Int64 { sentCount.load(ordering: .relaxed) }

    /// Steps that did not parse or had no OSC form, one line each.
    public var failed: [String] {
        lock.lock()
        defer { lock.unlock() }
        return failures
    }

    /// Runs the schedule for `durationMs` of wall time on the calling thread,
    /// then returns; `stop()` from any thread returns early.
    public func run(durationMs: Int) {
        let start = MonotonicClock.now().nanoseconds
        for (atMs, step) in scenario.schedule(durationMs: durationMs) {
            let due = start + Int64(atMs) * 1_000_000
            while !stopping.load(ordering: .relaxed) {
                let remaining = due - MonotonicClock.now().nanoseconds
                if remaining <= 0 { break }
                Thread.sleep(forTimeInterval: min(0.25, Double(remaining) / 1e9))
            }
            if stopping.load(ordering: .relaxed) { return }
            autoreleasepool { send(step) }
        }
        let end = start + Int64(durationMs) * 1_000_000
        while !stopping.load(ordering: .relaxed), MonotonicClock.now().nanoseconds < end {
            Thread.sleep(forTimeInterval: 0.25)
        }
    }

    public func stop() {
        stopping.store(true, ordering: .releasing)
    }

    /// One step: parsed, mapped (Spec 2 §6) and sent.
    public func send(_ step: SoakScenario.Step) {
        switch CommandText.parse(step.cmd, options: options) {
        case .failure(let rejection):
            record("\(step.atMs) ms '\(step.cmd)': \(rejection.message)")
        case .success(let guarded):
            guard let message = OSCMapping.message(for: guarded.command) else {
                record("\(step.atMs) ms '\(step.cmd)': no OSC form")
                return
            }
            if client.send(message.encoded(), to: peer) {
                sentCount.add(1, ordering: .relaxed)
            } else {
                record("\(step.atMs) ms '\(step.cmd)': send failed")
            }
        }
    }

    private func record(_ line: String) {
        log.warning("drive: \(line)")
        lock.lock()
        failures.append(line)
        lock.unlock()
    }
}
