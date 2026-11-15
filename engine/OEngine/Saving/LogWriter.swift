// OEngine — Spec 9 §2, the command log and the engine log on disk; Spec 9 §7, their retention and a full disk.

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
///
/// Spec 9 §7 — "A full disk ... The logs go to memory: the command log up to
/// 64 MB of lines and the engine log up to 16 MB ... Every 30 seconds the
/// engine tries the waiting writes again. When one succeeds, the full state
/// ends: ... the logs go back to their files in order, and `logToFile` notes
/// any lines lost." Past its cap a log drops its oldest lines, counted as
/// lost (the plan's reading). And retention: when a day's file starts, the
/// log's files past their age or their size go, oldest first.
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
    /// Spec 9 §7 — "the command log up to 64 MB of lines".
    public static let commandMemoryBytes = 64 << 20
    /// Spec 9 §7 — "and the engine log up to 16 MB".
    public static let engineMemoryBytes = 16 << 20

    /// One of the two logs: its files, what it holds in memory while the
    /// disk is full, and its limits. The queue's own.
    private final class Log {
        let file: JournalFile
        let memoryBytes: Int
        let keptBytes: Int64
        var held: [(day: String, text: String)] = []
        var heldBytes = 0

        init(file: JournalFile, memoryBytes: Int, keptBytes: Int64) {
            self.file = file
            self.memoryBytes = memoryBytes
            self.keptBytes = keptBytes
        }
    }

    public let folder: URL
    public let run: UUID
    /// Spec 9 §7 — what every writer knows of the disk; nil for a writer on its own.
    public let status: DiskStatus?
    private let disk: Disk
    private let stamp: @Sendable (Date) -> String
    private let queue = DispatchQueue(label: "o.engine.log", qos: .utility)
    private let lastSync = Atomic<Int64>(Int64.min)
    private let memory = Atomic<Bool>(false)
    private let lost = Atomic<Int>(0)
    // The queue's own.
    private let commandLog: Log
    private let engineLog: Log
    private var failures = 0
    private var lastAttempt: Int64?
    /// The unified log, for a write that failed: never the engine log's own file.
    private let system = Logger(subsystem: "o.engine", category: "log")

    /// `folder` is `machine/logs/`; `stamp` prints a date as a line's `ts`,
    /// in the machine's time zone (Spec 2 §9). The memory limits are §7's
    /// unless a test gives smaller ones.
    public init(folder: URL, run: UUID, disk: Disk, status: DiskStatus? = nil, commandMemoryBytes: Int = LogWriter.commandMemoryBytes,
                engineMemoryBytes: Int = LogWriter.engineMemoryBytes, stamp: @escaping @Sendable (Date) -> String) {
        self.folder = folder
        self.run = run
        self.disk = disk
        self.status = status
        self.stamp = stamp
        commandLog = Log(file: JournalFile(folder: folder, prefix: "commands-", disk: disk), memoryBytes: commandMemoryBytes,
                         keptBytes: Retention.commandLogBytes)
        engineLog = Log(file: JournalFile(folder: folder, prefix: "engine-", disk: disk), memoryBytes: engineMemoryBytes,
                        keptBytes: Retention.engineLogBytes)
    }

    // MARK: - Any thread

    /// Spec 9 §2 — the lines of one applied group (or one note), in `seq`
    /// order, to the command log: "A group's lines go out in one write". The
    /// caller hands batches over in the order they were logged.
    public func commands(_ lines: [LogLine]) {
        guard !lines.isEmpty else { return }
        queue.async { [self] in
            write(lines.map { (day: $0.day, text: $0.line) }, to: commandLog)
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
            write([(day: String(ts.prefix(10)), text: JSONCanonical.line(.object(members)))], to: engineLog)
        }
    }

    /// Spec 9 §2 — "each file is synced once a second": called as engine time
    /// passes (every tick in the harness, a timer in the process); the files
    /// with lines written since the last sync are synced when a second has
    /// gone by. Spec 9 §7 — the same second measures the free space, and
    /// while the logs are in memory tries their files again every thirty.
    public func pulse(now: MonotonicTime) {
        let last = lastSync.load(ordering: .relaxed)
        if last == Int64.min {
            _ = lastSync.compareExchange(expected: last, desired: now.nanoseconds, ordering: .relaxed)
            return
        }
        guard now.nanoseconds - last >= Self.syncInterval,
              lastSync.compareExchange(expected: last, desired: now.nanoseconds, ordering: .relaxed).exchanged else { return }
        queue.async { [self] in
            status?.measure()
            guard memory.load(ordering: .relaxed) else {
                commandLog.file.sync()
                engineLog.file.sync()
                return
            }
            guard let attempted = lastAttempt else {
                lastAttempt = now.nanoseconds
                return
            }
            if now.nanoseconds - attempted >= DiskStatus.retryInterval || status?.full == false {
                lastAttempt = now.nanoseconds
                leaveMemory()
            }
        }
    }

    /// Everything handed over so far is written.
    public func waitUntilIdle() {
        queue.sync {}
    }

    /// Everything handed over so far is written and synced: the engine
    /// stops. Spec 9 §7 — "When the engine stops on request, it tries once more."
    public func flush() {
        queue.sync {
            if memory.load(ordering: .relaxed) { leaveMemory() }
            commandLog.file.sync()
            engineLog.file.sync()
        }
    }

    /// How many batches could not be written, for a reason other than space.
    public var failedWrites: Int {
        queue.sync { failures }
    }

    /// Spec 9 §7 — the `saving` topic's `log`: whether the logs are in memory (`memory`) or on disk (`file`).
    public var inMemory: Bool { memory.load(ordering: .relaxed) }

    /// Spec 9 §2 — `logToMemory`, `logToFile`: "`lost`: lines that couldn't
    /// be kept", counted since this was last asked.
    public func takeLost() -> Int {
        lost.exchange(0, ordering: .relaxed)
    }

    // MARK: - On the queue

    private func write(_ lines: [(day: String, text: String)], to log: Log) {
        if memory.load(ordering: .relaxed) {
            // "the logs go back to their files in order": what is held goes first, once the disk takes writes.
            if status?.full == false { leaveMemory() }
            if memory.load(ordering: .relaxed) {
                hold(lines, in: log)
                return
            }
        }
        if let stopped = append(lines, to: log) {
            enterMemory()
            hold(Array(lines[stopped...]), in: log)
        }
    }

    /// The lines in order, each run of one day's lines in one write. The
    /// index of the first line not written when the disk is full, else nil.
    private func append(_ lines: [(day: String, text: String)], to log: Log) -> Int? {
        var index = 0
        while index < lines.count {
            let first = index
            let day = lines[index].day
            var text = ""
            while index < lines.count, lines[index].day == day {
                text += lines[index].text
                text += "\n"
                index += 1
            }
            do {
                try log.file.append(text, key: day)
            } catch {
                let failure = Disk.Failure(error)
                if failure.isFull {
                    status?.failed(failure)
                    return first
                }
                failures += 1
                system.error("could not write \(log.file.prefix, privacy: .public)\(day, privacy: .public).jsonl: \(String(describing: error), privacy: .public)")
            }
            // Spec 9 §7 — "The retention pass runs ... when a day's ... file starts."
            if let started = log.file.takeStarted().max() { retain(log, today: started) }
        }
        return nil
    }

    // MARK: - A full disk (Spec 9 §7)

    private func enterMemory() {
        guard !memory.exchange(true, ordering: .relaxed) else { return }
        lastAttempt = nil
        // The next open of each file ends a line the failed write may have left partial (Spec 9 §2).
        commandLog.file.close()
        engineLog.file.close()
        system.error("the disk is full: the logs are kept in memory until a write succeeds")
    }

    /// "the command log up to 64 MB of lines and the engine log up to 16 MB":
    /// past its limit a log drops its oldest lines, counted as lost.
    private func hold(_ lines: [(day: String, text: String)], in log: Log) {
        for line in lines {
            log.held.append(line)
            log.heldBytes += line.text.utf8.count + 1
        }
        var dropped = 0
        while log.heldBytes > log.memoryBytes, dropped < log.held.count - 1 {
            log.heldBytes -= log.held[dropped].text.utf8.count + 1
            dropped += 1
        }
        if dropped > 0 {
            log.held.removeFirst(dropped)
            lost.add(dropped, ordering: .relaxed)
        }
    }

    /// "Every 30 seconds the engine tries the waiting writes again. When one
    /// succeeds, the full state ends": what each log holds is appended in
    /// order. While the disk is still full, what wasn't written stays held.
    private func leaveMemory() {
        for log in [commandLog, engineLog] {
            let held = log.held
            let stopped = append(held, to: log)
            let written = stopped ?? held.count
            log.held.removeFirst(written)
            log.heldBytes = log.held.reduce(0) { $0 + $1.text.utf8.count + 1 }
            if stopped != nil {
                log.file.close()
                return
            }
        }
        memory.store(false, ordering: .relaxed)
        status?.wrote()
        commandLog.file.sync()
        engineLog.file.sync()
        system.notice("the logs are written to their files again")
    }

    // MARK: - Retention (Spec 9 §7)

    /// Spec 9 §7 — "Command logs | 90 days and 2 GB in all; past either, the
    /// oldest go first. Today's file is never removed", and the engine logs
    /// "90 days and 1 GB in all, the same way". `today` is the day whose file
    /// just started, in the machine's time zone.
    private func retain(_ log: Log, today: String) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        let files: [(name: String, bytes: Int64)] = names.filter { $0.hasPrefix(log.file.prefix) }.map { name in
            let size = (try? FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent(name).path)[.size] as? NSNumber)?.int64Value ?? 0
            return (name, size)
        }
        let remove = Retention.logsToRemove(files, prefix: log.file.prefix, today: today, bytes: log.keptBytes)
        for name in remove { try? disk.remove(folder.appendingPathComponent(name)) }
        if !remove.isEmpty {
            system.notice("retention: removed \(remove.count, privacy: .public) file(s) of \(log.file.prefix, privacy: .public)…")
        }
    }
}
