// OEngine — Spec 11 §13, Area 14: the soak's editing client on the API.

import Foundation
import OCore

/// Area 14 — the soak gains an editor: edits that make the engine rebuild its
/// textures between ticks (Spec 4 §5), and `render` queries (Spec 11 §3), so
/// a run measures what an operator editing during a service asks of the
/// engine, and its thresholds (Spec 4 §13) hold with that work in.
///
/// Like the soak's Mach client (Spec 10 §18) it is a client of the engine it
/// soaks, on the API's local side, and it changes nothing a screen shows:
/// each pass makes a stack no output shows and a channel no stack holds, or
/// removes the two again, which allocates and retires a stack's ring and
/// previews and a channel's textures and pictures and writes `stacks.json`
/// and `channels.json`; and it asks for a picture of the first cue of the
/// library's first list on the first output's stack. At the end it says what
/// it sent and what came back; a run whose edits were refused or whose
/// pictures never arrived did not measure them, so that fails the run.
public final class SoakEditClient: @unchecked Sendable {
    private let client: ApiTestClient
    private let log: EngineLog
    private let stack: Int
    private let channel: Int
    private let render: [String: JSONValue]?
    private let options: ParseOptions
    private let lock = NSLock()
    private var passes = 0
    private var edits: [Int] = []
    private var renders: [Int] = []
    private var made = false
    private var thread: Thread?
    private var stopping = false

    /// Reads the roots the engine started on: free numbers for the stack and
    /// the channel it makes, and the cue it asks pictures of.
    public init(hub: ApiHub, library: Library, machine: Machine, log: EngineLog) {
        client = ApiTestClient(hub: hub)
        self.log = log
        options = ParseOptions(library: library, machine: machine)
        stack = (References.numbers(of: .stack, library: library, machine: machine).union(machine.stacks.map(\.number)).max() ?? 0) + 1
        channel = (References.numbers(of: .channel, library: library, machine: machine).union(library.channels.map(\.number)).max() ?? 0) + 1
        if let list = library.lists.first(where: { !$0.cues.isEmpty }), let cue = list.cues.first, let output = machine.outputs.first {
            render = ["what": .string("render"), "canvas": .string("soak"), "width": .number(640),
                      "subject": .object(["kind": .string("cue"), "listUuid": .string(list.uuid.uuidString.lowercased()),
                                          "cue": .string(cue.uuid.uuidString.lowercased()), "stack": .number(Double(output.defaultStack))])]
        } else {
            render = nil
        }
    }

    /// One pass: this pass's two edits as one group, and one picture.
    public func pass() {
        lock.lock()
        let making = !made
        made = making
        passes += 1
        lock.unlock()
        let texts = making ? ["edit stack \(stack) create", "edit channel \(channel) create"]
            : ["edit stack \(stack) delete", "edit channel \(channel) delete"]
        var commands: [JSONValue] = []
        for text in texts {
            guard case .success(let guarded) = CommandText.parse(text, options: options), let object = try? JSONCoding.encode(guarded) else {
                log.error("soak: the edit '\(text)' did not parse")
                continue
            }
            commands.append(object)
        }
        let edit = client.send("commands", ["commands": .array(commands)])
        let asked = render.map { client.send("query", $0) }
        lock.lock()
        edits.append(edit)
        if let asked { renders.append(asked) }
        lock.unlock()
    }

    /// Runs a pass every `seconds`, the first after half of that, until `stop()`.
    public func start(every seconds: Double) {
        let thread = Thread { [self] in
            var wait = seconds / 2
            while true {
                let until = Date(timeIntervalSinceNow: wait)
                while Date() < until {
                    lock.lock()
                    let done = stopping
                    lock.unlock()
                    if done { return }
                    Thread.sleep(forTimeInterval: 0.25)
                }
                autoreleasepool { pass() }
                wait = seconds
            }
        }
        thread.name = "o.engine.soak.edits"
        self.thread = thread
        thread.start()
    }

    public func stop() {
        lock.lock()
        stopping = true
        lock.unlock()
    }

    /// What the client sent and what came back, in lines, and what the run holds against it.
    public func verdict() -> (lines: [String], failures: [String]) {
        lock.lock()
        let (passes, edits, renders) = (self.passes, self.edits, self.renders)
        lock.unlock()
        let messages = client.messages(wait: 5)
        func answer(_ id: Int) -> [String: JSONValue]? {
            messages.first { $0["id"] == .number(Double(id)) && $0["type"] != .string("event") }
        }
        var failures: [String] = []
        var applied = 0
        for id in edits {
            guard let result = answer(id) else {
                failures.append("the soak's edit \(id) had no result")
                continue
            }
            if result["result"] == .string("ok") {
                applied += 1
            } else {
                failures.append("the soak's edit \(id) was not applied: \(result["reason"]?.stringValue ?? result["result"]?.stringValue ?? "no reason given")")
            }
        }
        var drawn = 0
        var superseded = 0
        for id in renders {
            guard let result = answer(id) else {
                failures.append("the soak's render \(id) had no answer")
                continue
            }
            if result["file"] != nil {
                drawn += 1
            } else if result["superseded"] == .bool(true) {
                superseded += 1
            } else {
                failures.append("the soak's render \(id) was refused: \(result["reason"]?.stringValue ?? "no reason given")")
            }
        }
        if passes == 0 { failures.append("the soak's editing client made no pass: the run was shorter than its first") }
        if render == nil { failures.append("the soak's library has no cue to ask a picture of") }
        let lines = ["the editing client: \(passes) passes; \(applied) of \(edits.count) edit groups applied (stack \(stack) and channel \(channel), made and removed);",
                     "  \(drawn) of \(renders.count) pictures drawn\(superseded > 0 ? ", \(superseded) replaced by a newer request" : "")"]
        return (lines, Array(failures.prefix(12)))
    }
}
