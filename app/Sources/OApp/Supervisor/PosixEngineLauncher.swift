// OApp — Spec 10 §2, the engine process started, watched and ended with the system's own calls.

import Darwin
import Foundation

/// Spec 10 §2, "Starting" — the live `EngineLauncher`. The engine is started
/// with `posix_spawn` and the set-session flag, so it leads a session of its
/// own and a signal sent to the app's group never reaches it: "the engine
/// outlives the app". It inherits nothing of the app's but the console log,
/// as its standard output and error, and a short list of environment values.
public struct PosixEngineLauncher: EngineLauncher {
    public init() {}

    /// The environment values an engine is started with: the user's own, and
    /// nothing a debugger, a test runner or a dynamic-library override put in
    /// the app's environment.
    public static func environment(from parent: [String: String]) -> [String: String] {
        let kept: Set<String> = ["HOME", "PATH", "TMPDIR", "USER", "LOGNAME", "SHELL", "LANG", "__CF_USER_TEXT_ENCODING"]
        return parent.filter { name, _ in kept.contains(name) || name.hasPrefix("LC_") }
    }

    public func start(_ launch: EngineLaunch) throws -> Int32 {
        // "The app opens `machine/logs/engine-console.log` for appending as the engine's standard output and error".
        let logPath = launch.consoleLog.path
        let log = open(logPath, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        guard log >= 0 else { throw EngineLaunchError.consoleLog(path: logPath, errno: errno) }
        defer { close(log) }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, log, 1)
        posix_spawn_file_actions_adddup2(&actions, log, 2)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // A session of its own; every descriptor but the three above closed; every signal at its default and none blocked.
        let flags = POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK
        posix_spawnattr_setflags(&attributes, Int16(truncatingIfNeeded: flags))
        var defaults = sigset_t()
        sigfillset(&defaults)
        posix_spawnattr_setsigdefault(&attributes, &defaults)
        var unblocked = sigset_t()
        sigemptyset(&unblocked)
        posix_spawnattr_setsigmask(&attributes, &unblocked)

        let path = launch.executable.path
        let arguments = [path] + launch.arguments
        let environment = Self.environment(from: ProcessInfo.processInfo.environment).map { "\($0.key)=\($0.value)" }.sorted()
        var argv: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) } + [nil]
        var envp: [UnsafeMutablePointer<CChar>?] = environment.map { strdup($0) } + [nil]
        defer {
            for pointer in argv { free(pointer) }
            for pointer in envp { free(pointer) }
        }
        var pid: pid_t = 0
        let code = posix_spawn(&pid, path, &actions, &attributes, &argv, &envp)
        guard code == 0 else { throw EngineLaunchError.spawn(path: path, errno: code) }
        return pid
    }

    public func watch(pid: Int32, onExit: @escaping @Sendable (EngineExit) -> Void) -> any ProcessWatch {
        let watch = Watch(pid: pid, onExit: onExit)
        watch.start()
        return watch
    }

    public func isRunning(pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        // Signal 0 sends nothing: it asks whether the process is there. One that exists but isn't ours answers EPERM.
        return Darwin.kill(pid, 0) == 0 || errno == EPERM
    }

    public func executablePath(pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }

    @discardableResult
    public func kill(pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        return Darwin.kill(pid, SIGKILL) == 0
    }

    /// One process's end, reported once: by the kernel's process event, or at
    /// once when the process had already gone before the event was armed.
    private final class Watch: ProcessWatch, @unchecked Sendable {
        private let pid: pid_t
        private let onExit: @Sendable (EngineExit) -> Void
        private let queue = DispatchQueue(label: "o.app.engine.watch")
        private var source: DispatchSourceProcess?
        private var reported = false

        init(pid: pid_t, onExit: @escaping @Sendable (EngineExit) -> Void) {
            self.pid = pid
            self.onExit = onExit
        }

        func start() {
            queue.sync {
                let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
                source.setEventHandler { [weak self] in self?.ended() }
                self.source = source
                source.resume()
                // The process may have ended before the event was armed: a child of ours then waits to be read, and
                // any other process is simply not there.
                if let exit = Self.reap(pid, wait: false) {
                    report(exit)
                } else if Darwin.kill(pid, 0) != 0, errno == ESRCH {
                    report(.gone)
                }
            }
        }

        func cancel() {
            queue.sync {
                reported = true
                source?.cancel()
                source = nil
            }
        }

        /// On the watch's queue: the kernel says the process has exited.
        private func ended() {
            report(Self.reap(pid, wait: true) ?? .gone)
        }

        private func report(_ exit: EngineExit) {
            guard !reported else { return }
            reported = true
            source?.cancel()
            source = nil
            onExit(exit)
        }

        /// The status of a child of this process that has ended, or nil: when
        /// it hasn't ended yet (`wait` false), or when the process isn't a
        /// child of ours, whose status only its own parent can read.
        private static func reap(_ pid: pid_t, wait: Bool) -> EngineExit? {
            var status: Int32 = 0
            var result: pid_t
            repeat {
                result = waitpid(pid, &status, wait ? 0 : WNOHANG)
            } while result == -1 && errno == EINTR
            guard result == pid else { return nil }
            // The C macros WIFEXITED, WEXITSTATUS and WTERMSIG, which Swift doesn't import.
            let signal = status & 0x7f
            if signal == 0 { return .exited(status: (status >> 8) & 0xff) }
            return .signaled(signal)
        }
    }
}
