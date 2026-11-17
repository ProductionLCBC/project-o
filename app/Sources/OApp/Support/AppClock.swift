// OApp — time as the app's models read it, so a test can move it.

import Foundation

/// Something scheduled on the clock; cancelling it means it never runs.
@MainActor
public protocol ClockTask: AnyObject {
    func cancel()
}

/// The app's clock: now, in seconds that only go forward, and work to run
/// later on the main thread. Every wait in the app's models (the fifteen
/// seconds for the socket, the ping every two, the five before a restart,
/// the three a message stays) goes through it, so the tests move time
/// themselves and never wait for it.
@MainActor
public protocol AppClock: AnyObject {
    var now: TimeInterval { get }

    @discardableResult
    func after(_ seconds: TimeInterval, _ work: @escaping @MainActor () -> Void) -> any ClockTask
}

/// The live clock: the system's uptime, and the main queue.
@MainActor
public final class SystemAppClock: AppClock {
    public init() {}

    public var now: TimeInterval {
        TimeInterval(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
    }

    @discardableResult
    public func after(_ seconds: TimeInterval, _ work: @escaping @MainActor () -> Void) -> any ClockTask {
        let task = Task(work)
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            MainActor.assumeIsolated { task.run() }
        }
        return task
    }

    private final class Task: ClockTask {
        private var work: (@MainActor () -> Void)?

        init(_ work: @escaping @MainActor () -> Void) {
            self.work = work
        }

        func run() {
            let work = self.work
            self.work = nil
            work?()
        }

        func cancel() {
            work = nil
        }
    }
}

/// How work reaches the main thread from a connection's own thread: in
/// order, one after another. The live hop is the main queue; a test that
/// drives everything on its own thread runs the work at once.
public typealias MainHop = @Sendable (@escaping @MainActor @Sendable () -> Void) -> Void

public enum MainHops {
    /// The main queue, which keeps the order things were handed to it in.
    public static let live: MainHop = { work in
        DispatchQueue.main.async {
            MainActor.assumeIsolated { work() }
        }
    }
}
