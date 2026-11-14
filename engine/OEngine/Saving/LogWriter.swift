// OEngine — Spec 9 §2, the command log and the engine log on disk.

import Foundation
import OCore
import Synchronization
import os

/// Spec 9 §2 — "How they're written. The control thread hands each applied
/// group's lines to a utility thread, which appends them in order, so nothing
/// on the control or render threads waits for the disk. A group's lines go out
/// in one write ending in a newline, and each file is synced once a second."
///
/// One serial queue at utility priority owns both files:
/// `machine/logs/commands-YYYY-MM-DD.jsonl` and `engine-YYYY-MM-DD.jsonl`,
/// each line in the file of the day its own stamp gives (the machine's local
/// day, choice G-8). Lines are printed to JSON here, off the control thread.
/// Never called from the render thread.
public final class LogWriter: @unchecked Sendable {
    /// Spec 9 §2 — one line of the engine log before it is printed: "Engine
    /// log lines each carry `ts` and the run's uuid ... `kind` says what
    /// follows: `start` ..., `log` ..., `minute` ... or `media`".
    public struct EngineRecord: Sendable {
        public var at: Date
        public var kind: String
        public var fields: [String: JSONValue]

        public init(at: Date, kind: String, fields: [String: JSONValue]) {
            self.at = at
            self.kind = kind
            self.fields = fields
        }
    }

    /// Spec 9 §2 — "each file is synced once a second", on engine time.
    public static let syncInterval: Int64 = 1_000_000_000

    public let folder: URL
    public let run: UUID
    private let stamp: @Sendable (Date) -> String
    private let queue = DispatchQueue(label: "o.engine.log", qos: .utility)
    private let lastSync = Atomic<Int64>(Int64.min)
    // The queue's own.
    private let commandsFile: JournalFile
    private let engineFile: JournalFile
    private var failures = 0
    /// The unified log, for a write that failed: never the engine log's own file.
    private let system = Logger(subsystem: "o.engine", category: "log")

    /// `folder` is `machine/logs/`; `stamp` prints a date as a line's `ts`,
    /// in the machine's time zone (Spec 2 §9).
    public init(folder: URL, run: UUID, disk: Disk, stamp: @escaping @Sendable (Date) -> String) {
        self.folder = folder
        self.run = run
        self.stamp = stamp
        commandsFile = JournalFile(folder: folder, prefix: "commands-", disk: disk)
        engineFile = JournalFile(folder: folder, prefix: "engine-", disk: disk)
    }

    // MARK: - Any thread

    /// Spec 9 §2 — the lines of one applied group (or one note), in `seq`
    /// order, to the command log: "A group's lines go out in one write". The
    /// caller hands batches over in the order they were logged.
    public func commands(_ lines: [LogLine]) {
        guard !lines.isEmpty else { return }
        queue.async { [self] in
            write(lines.map { (day: $0.day, text: $0.line) }, to: commandsFile)
        }
    }

    /// Spec 9 §2 — one line to the engine log, with its `ts` and the run.
    public func engine(_ record: EngineRecord) {
        queue.async { [self] in
            var members = record.fields
            let ts = stamp(record.at)
            members["ts"] = .string(ts)
            members["run"] = .string(run.uuidString.lowercased())
            members["kind"] = .string(record.kind)
            write([(day: String(ts.prefix(10)), text: JSONCanonical.line(.object(members)))], to: engineFile)
        }
    }

    /// Spec 9 §2 — "each file is synced once a second": called as engine time
    /// passes (every tick in the harness, a timer in the process); the files
    /// with lines written since the last sync are synced when a second has
    /// gone by.
    public func pulse(now: MonotonicTime) {
        let last = lastSync.load(ordering: .relaxed)
        if last == Int64.min {
            _ = lastSync.compareExchange(expected: last, desired: now.nanoseconds, ordering: .relaxed)
            return
        }
        guard now.nanoseconds - last >= Self.syncInterval,
              lastSync.compareExchange(expected: last, desired: now.nanoseconds, ordering: .relaxed).exchanged else { return }
        queue.async { [self] in
            commandsFile.sync()
            engineFile.sync()
        }
    }

    /// Everything handed over so far is written.
    public func waitUntilIdle() {
        queue.sync {}
    }

    /// Everything handed over so far is written and synced: the engine stops.
    public func flush() {
        queue.sync {
            commandsFile.sync()
            engineFile.sync()
        }
    }

    /// How many batches could not be written.
    public var failedWrites: Int {
        queue.sync { failures }
    }

    // MARK: - On the queue

    /// The lines in order, each run of one day's lines in one write.
    private func write(_ lines: [(day: String, text: String)], to file: JournalFile) {
        var index = 0
        while index < lines.count {
            let day = lines[index].day
            var text = ""
            while index < lines.count, lines[index].day == day {
                text += lines[index].text
                text += "\n"
                index += 1
            }
            do {
                try file.append(text, key: day)
            } catch {
                failures += 1
                system.error("could not write \(file.prefix, privacy: .public)\(day, privacy: .public).jsonl: \(String(describing: error), privacy: .public)")
            }
        }
    }
}
