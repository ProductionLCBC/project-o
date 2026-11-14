// OEngine — Spec 9 §4, the launch order.

import Foundation
import OCore

/// Spec 9 §4 — what a launch is given: the machine root its files go in,
/// whether the launch is a relaunch (Spec 10 §2: "a launch the app marks with
/// `--relaunch`, or one after a run that ended without a stop in this boot of
/// the Mac", which Area 19 works out and passes in), and the disk seam.
public struct LaunchOptions: Sendable {
    public var machineRoot: URL
    public var relaunch: Bool
    public var disk: Disk

    public init(machineRoot: URL, relaunch: Bool = false, disk: Disk = .live) {
        self.machineRoot = machineRoot
        self.relaunch = relaunch
        self.disk = disk
    }
}

/// What a launch did, for whoever started it.
public struct LaunchReport: Equatable, Sendable {
    /// Spec 9 §2 — the `start` note's `previous`: how the run before this one
    /// ended, `clean`, `unclean` or `none`.
    public var previous: String

    public init(previous: String = "none") {
        self.previous = previous
    }
}

extension Engine {
    /// Spec 9 §4 — "Launch order: 1. The roots load (Spec 1 §8) and the media
    /// walk starts (Spec 8 §4). 2. The `start` note (§2). 3. `last.json`
    /// written for this run, then the last state put back or not. 4. The
    /// launch snapshot (§3). 5. The startup macro, unless the last state was
    /// restored (choice G-2) or the launch is a relaunch (Spec 10 §2). 6. The
    /// retention pass (§7). The engine takes commands from step 5 on."
    ///
    /// Called once, after the roots are loaded and the documents and the
    /// media worker are attached, before the first tick: by the engine
    /// process, and by the tests that launch. An engine that is only built
    /// (the harness of every other test) goes through none of it.
    @discardableResult
    public func launch(_ options: LaunchOptions) -> LaunchReport {
        let variables = control.variables
        let machineUuid = machine.settings.uuid.uuidString.lowercased()
        let runUuid = run.uuidString.lowercased()

        // Step 2 — the logs open (Spec 9 §2), and the run's part of each begins with its start.
        let writer = LogWriter(folder: options.machineRoot.appendingPathComponent("logs"), run: run, disk: options.disk,
                               stamp: { variables.timestamp(at: $0) })
        logs = writer
        // "`start` (opening each run's part of the file, with the app version and the machine)".
        writer.engine(LogWriter.EngineRecord(at: variables.now(), kind: "start",
                                             fields: ["app": .string(OCore.appVersion), "machine": .string(machineUuid)]))
        // Spec 9 §8 — "`EngineLog` also writes its lines to the engine log", what it logged before the file opened included.
        log.attach { entry in
            if let record = entry.record {
                writer.engine(LogWriter.EngineRecord(at: entry.at, kind: record.kind, fields: record.fields))
            } else {
                writer.engine(LogWriter.EngineRecord(at: entry.at, kind: "log", fields: [
                    "level": .string(entry.level.rawValue), "category": .string(entry.category), "message": .string(entry.message),
                ]))
            }
        }
        control.commandLog.attach(sink: { writer.commands($0) })

        // Spec 9 §2 — `start`: "`run` (its uuid), `app`, `machine`, `previous` (`clean`, `unclean` or `none`)".
        var report = LaunchReport()
        if let last = machine.last { report.previous = last.clean == true ? "clean" : "unclean" }
        control.note("start", ["run": .string(runUuid), "app": .string(OCore.appVersion), "machine": .string(machineUuid),
                               "previous": .string(report.previous)],
                     text: "Engine \(OCore.appVersion) started")
        return report
    }
}
