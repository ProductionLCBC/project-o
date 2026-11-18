import Foundation
import XCTest
import OCore
@testable import OApp

/// A launcher with no process behind it: what was started is kept, and the
/// test ends each engine itself. Spec 10 §16 — no test starts an engine.
final class FakeLauncher: EngineLauncher, @unchecked Sendable {
    private let lock = NSLock()
    private var nextPID: Int32 = 100
    private var launchesHeld: [EngineLaunch] = []
    private var pidsHeld: [Int32] = []
    private var runningHeld: Set<Int32> = []
    private var watchers: [Int32: [Watch]] = [:]
    private var killsHeld: [Int32] = []
    private var pathsHeld: [Int32: String] = [:]
    private var failureHeld: EngineLaunchError?

    private final class Watch: ProcessWatch, @unchecked Sendable {
        var onExit: (@Sendable (EngineExit) -> Void)?

        init(_ onExit: @escaping @Sendable (EngineExit) -> Void) {
            self.onExit = onExit
        }

        func cancel() {
            onExit = nil
        }
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    /// Every engine started, in order.
    var launches: [EngineLaunch] { locked { launchesHeld } }
    /// The process ids given to them.
    var pids: [Int32] { locked { pidsHeld } }
    /// The processes ended with a kill.
    var kills: [Int32] { locked { killsHeld } }
    /// When set, the next start fails with it.
    var failure: EngineLaunchError? {
        get { locked { failureHeld } }
        set { locked { failureHeld = newValue } }
    }

    func start(_ launch: EngineLaunch) throws -> Int32 {
        lock.lock()
        defer { lock.unlock() }
        if let failureHeld { throw failureHeld }
        let pid = nextPID
        nextPID += 1
        launchesHeld.append(launch)
        pidsHeld.append(pid)
        runningHeld.insert(pid)
        pathsHeld[pid] = launch.executable.path
        return pid
    }

    func watch(pid: Int32, onExit: @escaping @Sendable (EngineExit) -> Void) -> any ProcessWatch {
        let watch = Watch(onExit)
        let gone = locked { () -> Bool in
            watchers[pid, default: []].append(watch)
            return !runningHeld.contains(pid)
        }
        if gone { watch.onExit?(.gone) }
        return watch
    }

    func isRunning(pid: Int32) -> Bool {
        locked { runningHeld.contains(pid) }
    }

    func executablePath(pid: Int32) -> String? {
        locked { runningHeld.contains(pid) ? pathsHeld[pid] : nil }
    }

    @discardableResult
    func kill(pid: Int32) -> Bool {
        let was = locked { () -> Bool in
            killsHeld.append(pid)
            return runningHeld.contains(pid)
        }
        // A kill is seen by whoever watches the process, as the kernel reports it.
        if was { exit(pid, .signaled(SIGKILL)) }
        return was
    }

    /// A process the launcher didn't start is running: an engine someone else started, or some other program.
    func running(pid: Int32, path: String) {
        locked {
            runningHeld.insert(pid)
            pathsHeld[pid] = path
        }
    }

    /// The process ends, and whoever watches it is told.
    func exit(_ pid: Int32, _ exit: EngineExit) {
        let watching = locked { () -> [Watch] in
            runningHeld.remove(pid)
            let all = watchers[pid] ?? []
            watchers[pid] = nil
            return all
        }
        for watch in watching { watch.onExit?(exit) }
    }

    /// The arguments the engine numbered `index` was started with.
    func arguments(_ index: Int = 0) -> [String] {
        let all = launches
        return index < all.count ? all[index].arguments : []
    }
}

/// A connector with no socket behind it: the test says whether an engine
/// answers, and holds the engine's end of each connection made.
final class FakeConnector: EngineConnector, @unchecked Sendable {
    private let lock = NSLock()
    private var answering = false
    private var failureHeld: ConnectFailure = .noSocket
    private var made: [FakeTransport] = []
    private var attemptsHeld = 0

    /// Whether something listens on the socket; when not, `failure` is why.
    var isListening: Bool {
        get { lock.lock(); defer { lock.unlock() }; return answering }
        set { lock.lock(); answering = newValue; lock.unlock() }
    }

    var failure: ConnectFailure {
        get { lock.lock(); defer { lock.unlock() }; return failureHeld }
        set { lock.lock(); failureHeld = newValue; lock.unlock() }
    }

    /// How often the socket has been tried.
    var attempts: Int { lock.lock(); defer { lock.unlock() }; return attemptsHeld }
    /// The connections made, in order: the engine's end of each.
    var connections: [FakeTransport] { lock.lock(); defer { lock.unlock() }; return made }
    /// The newest connection.
    var last: FakeTransport? { connections.last }

    func connect(to socket: URL) -> Result<any EngineTransport, ConnectFailure> {
        lock.lock()
        defer { lock.unlock() }
        attemptsHeld += 1
        guard answering else { return .failure(failureHeld) }
        let transport = FakeTransport()
        made.append(transport)
        return .success(transport)
    }
}
