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

/// What a launch did, for whoever started it (Spec 10 §3's `engine` topic
/// carries "the last state this run, put back with what didn't come back, or
/// skipped with Spec 9 §2's reason", which Area 19 publishes from this).
public struct LaunchReport: Equatable, Sendable {
    /// Spec 9 §4 — what became of the last state at this launch.
    public enum LastStateOutcome: Equatable, Sendable {
        /// Put back: when the file was written, and what was left out.
        case restored(writtenAt: String?, left: [LastState.Left])
        /// Not put back, with the reason the `lastStateSkipped` note gives.
        case skipped(reason: LastState.SkipReason, writtenAt: String?)
        /// Nothing to consider: no file, or the setting off and no relaunch.
        case none
    }

    /// Spec 9 §2 — the `start` note's `previous`: how the run before this one
    /// ended, `clean`, `unclean` or `none`.
    public var previous: String
    public var lastState: LastStateOutcome
    /// Spec 9 §4, step 5 — the startup macro this launch queued, if it ran one.
    public var startupMacro: Int?

    public init(previous: String = "none", lastState: LastStateOutcome = .none, startupMacro: Int? = nil) {
        self.previous = previous
        self.lastState = lastState
        self.startupMacro = startupMacro
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

        // Step 3 — "`last.json` written for this run, then the last state put back or not."
        report.lastState = restoreLastState(options)

        // Step 5 — "The startup macro, unless the last state was restored (choice G-2) or the launch is a relaunch
        // (Spec 10 §2)." Queued here, so it is the first group the first build runs: "The engine takes commands
        // from step 5 on." Spec 2 §5 — its own line has source `startup`.
        var restored = false
        if case .restored = report.lastState { restored = true }
        if !restored, !options.relaunch, let macro = machine.settings.startupMacro {
            control.enqueue(CommandGroup(id: GroupID.random(), source: CommandSource(kind: .startup), commands: [Command.macro(macro)]))
            report.startupMacro = macro
        }
        return report
    }

    /// Spec 9 §4 — "At launch the engine writes it before it does anything
    /// else with the last state: with its run's uuid, `clean: false`, and
    /// `restored: true` when it is about to put that state back (below). If
    /// it isn't putting a state back, the file holds the empty state it
    /// starts from." Then "When it comes back (choice G-1)": the state is
    /// put back, the way Spec 3 §8 replaces ShowState, and a
    /// `lastStateRestored` note carries it; or the launch starts empty, "and
    /// a `lastStateSkipped` note says why".
    private func restoreLastState(_ options: LaunchOptions) -> LaunchReport.LastStateOutcome {
        let variables = control.variables
        let keeper = LastStateKeeper(url: options.machineRoot.appendingPathComponent("state/last.json"), run: run, disk: options.disk,
                                     stamp: { variables.timestamp() })
        control.lastStateKeeper = keeper
        let now = clock.now()
        let last = machine.last
        let decision = LastState.decide(last, restoreLastState: machine.settings.restoreLastState, relaunch: options.relaunch,
                                        nowMs: variables.wallMilliseconds)
        let writtenAt: JSONValue = last?.writtenAt.map(JSONValue.string) ?? .null
        switch decision {
        case .restore:
            guard let last else { break }
            // The frame the first build is for: media "start again from their in-points" there.
            let frame = control.model.frame
            let restored = last.restored(library: library, machine: machine, frame: Int(frame), missing: control.missing)
            keeper.begin(state: restored.state, restoring: true, now: now)
            control.replaceState(restored.state, frame: frame)
            let state = (try? JSONCoding.encode(restored.state)) ?? .null
            let left = restored.left.isEmpty ? "" : "; \(restored.left.count) thing(s) didn't come back"
            control.note("lastStateRestored", ["writtenAt": writtenAt, "state": state, "left": .array(restored.left.map(\.json))],
                         text: "Picked up where the engine stopped" + (last.writtenAt.map { ", at \($0)" } ?? "") + left)
            for entry in restored.left { log.warning("the last state: \(entry.kind.rawValue) \(entry.number) is \(entry.why.rawValue)") }
            return .restored(writtenAt: last.writtenAt, left: restored.left)
        case .skip(let reason):
            keeper.begin(state: control.model.state, restoring: false, now: now)
            control.note("lastStateSkipped", ["writtenAt": writtenAt, "reason": .string(reason.rawValue)],
                         text: "The last state wasn't put back: \(reason.rawValue)")
            return .skipped(reason: reason, writtenAt: last?.writtenAt)
        case .none:
            break
        }
        keeper.begin(state: control.model.state, restoring: false, now: now)
        return .none
    }
}
