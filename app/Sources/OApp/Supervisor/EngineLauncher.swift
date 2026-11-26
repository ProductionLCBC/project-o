// OApp — Spec 10 §2, starting, watching and ending the engine process: the seam.

import Foundation

/// Spec 10 §2, "Starting" — what the app starts: "`oengine run --library
/// <root> --machine <root> --operator-screen display:<uuid>` in a session of
/// its own, so the engine outlives the app", with "`machine/logs/engine-
/// console.log` for appending as the engine's standard output and error".
public struct EngineLaunch: Equatable, Sendable {
    /// `Contents/Helpers/oengine` in the app's bundle.
    public var executable: URL
    /// Everything after the executable's own name.
    public var arguments: [String]
    /// The file the engine's standard output and error are appended to.
    public var consoleLog: URL

    public init(executable: URL, arguments: [String], consoleLog: URL) {
        self.executable = executable
        self.arguments = arguments
        self.consoleLog = consoleLog
    }
}

/// Spec 10 §2 — how an engine process ended, as far as the app can tell.
public enum EngineExit: Equatable, Sendable {
    /// It returned this status. "An engine that exits with status 3 found
    /// another engine holding the root".
    case exited(status: Int32)
    /// A signal ended it, as the app's own kill does.
    case signaled(Int32)
    /// A process the app didn't start has gone; its status isn't the app's to read.
    case gone
}

/// Spec 10 §2 — why an engine couldn't be started at all.
public enum EngineLaunchError: Error, Equatable, CustomStringConvertible {
    /// The console log couldn't be opened for appending; the system's error number.
    case consoleLog(path: String, errno: Int32)
    /// The system refused to start the process; `posix_spawn`'s error number.
    case spawn(path: String, errno: Int32)

    public var description: String {
        switch self {
        case .consoleLog(let path, let code): return "the console log \(path) couldn't be opened (\(String(cString: strerror(code))))"
        case .spawn(let path, let code): return "\(path) couldn't be started (\(String(cString: strerror(code))))"
        }
    }
}

/// A watch on one process; canceling it stops the report, not the process.
public protocol ProcessWatch: AnyObject, Sendable {
    func cancel()
}

/// Spec 10 §2 — the engine as a process, as the app deals with it: started
/// in a session of its own, watched for its end whether the app started it
/// or found it running, and ended only "by its `pid` with a kill, never a
/// terminate signal". One live implementation, `PosixEngineLauncher`; the
/// supervisor's tests use a fake, so no test starts an engine.
public protocol EngineLauncher: Sendable {
    /// Spec 10 §2 — starts the engine and returns its process id.
    func start(_ launch: EngineLaunch) throws -> Int32

    /// Spec 10 §2, "When the engine stops" — calls `onExit` once, on a
    /// thread of the launcher's own, when the process with this id ends. For
    /// a process this launcher started the report carries its status; for
    /// one it didn't, `.gone`. A process already gone is reported at once.
    func watch(pid: Int32, onExit: @escaping @Sendable (EngineExit) -> Void) -> any ProcessWatch

    /// Whether a process with this id exists now.
    func isRunning(pid: Int32) -> Bool

    /// The path of the executable the process with this id runs, or nil when
    /// it can't be read. Spec 10 §2 (Area 13 reading) — "finding the engine
    /// by the process id in `.engine.lock`": the file outlives its engine, so
    /// before a kill the app checks the id still names an `oengine`.
    func executablePath(pid: Int32) -> String?

    /// Spec 10 §2 — "It ends the engine by its `pid` with a kill, never a
    /// terminate signal, so the shutdown macro doesn't run and the run
    /// doesn't count as clean". False when the system refused.
    @discardableResult
    func kill(pid: Int32) -> Bool
}
