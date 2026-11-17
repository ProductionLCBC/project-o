// OApp — Spec 10 §2, the app's end of the engine's local socket.

import Darwin
import Foundation
import Synchronization

/// Spec 10 §2, "The local socket" — one connection to the engine: "one JSON
/// object per line", lines in on a thread of the connection's own and lines
/// out without the caller ever waiting. A seam, so the supervisor's tests
/// drive a connection with no socket behind it.
public protocol EngineTransport: AnyObject, Sendable {
    /// Starts reading. Each whole line goes to `onLine`, in order; `onClose`
    /// is called once, after the last line, when the engine closes the
    /// connection or ends, or after `close()`.
    func start(onLine: @escaping @Sendable (Data) -> Void, onClose: @escaping @Sendable () -> Void)

    /// Queues one line to be written. Spec 10 §1 — "The app never waits on
    /// the engine on its main thread": this returns at once. False once the
    /// connection has closed.
    @discardableResult
    func send(_ line: Data) -> Bool

    /// Ends the connection from this side.
    func close()
}

/// Spec 10 §2, "Starting" — why a connection to `engine.sock` wasn't made.
public enum ConnectFailure: Error, Equatable, Sendable {
    /// Nothing is at the path: no engine has this root.
    case noSocket
    /// A socket file is there and nothing listens on it: "A socket file left by a crash".
    case refused
    /// "The socket's path must fit macOS's limit of 103 bytes".
    case pathTooLong
    /// Anything else, with the call that failed and the system's error number.
    case system(call: String, code: Int32)
}

/// Spec 10 §2 — "The app connects to the engine's local socket,
/// `engine.sock` in the machine root. If an engine answers, the app uses it,
/// whoever started it."
public protocol EngineConnector: Sendable {
    func connect(to socket: URL) -> Result<any EngineTransport, ConnectFailure>
}

/// The live connector: a Unix domain socket.
public struct UnixEngineConnector: EngineConnector {
    public init() {}

    public func connect(to socket: URL) -> Result<any EngineTransport, ConnectFailure> {
        UnixEngineSocket.connect(to: socket).map { $0 as any EngineTransport }
    }
}

/// Spec 10 §2 — the socket's name in a machine root, and the limit its path must fit.
public enum EngineSocketPath {
    public static let fileName = "engine.sock"
    /// "macOS's limit of 103 bytes".
    public static let limit = 103

    public static func url(machineRoot: URL) -> URL {
        machineRoot.appendingPathComponent(fileName)
    }

    public static func fits(_ url: URL) -> Bool {
        url.path.utf8.count <= limit
    }
}

/// One connection over a Unix domain socket.
public final class UnixEngineSocket: EngineTransport, @unchecked Sendable {
    /// A line longer than this isn't one the app knows what to do with; the connection closes.
    public static let lineLimit = 64 * 1024 * 1024

    private let descriptor: Int32
    private let shut = Atomic<Bool>(false)
    private let started = Atomic<Bool>(false)
    private let writes = DispatchQueue(label: "o.app.engine.write", qos: .userInitiated)

    private init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    /// The descriptor is given back only when nothing holds the connection
    /// any more, so a write that races a close meets a shut socket, never a
    /// descriptor the system has handed to something else.
    deinit {
        Darwin.close(descriptor)
    }

    /// Connects without waiting: a local socket answers at once, there or not.
    public static func connect(to socket: URL) -> Result<UnixEngineSocket, ConnectFailure> {
        let path = socket.path
        guard EngineSocketPath.fits(socket) else { return .failure(.pathTooLong) }
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return .failure(.system(call: "socket", code: errno)) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: path.utf8.prefix($0.count - 1)) }
        // Not waiting is the rule (Spec 10 §1); a listener whose queue is full is treated as one that refused, and tried again.
        let flags = fcntl(descriptor, F_GETFL)
        _ = fcntl(descriptor, F_SETFL, flags | O_NONBLOCK)
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else {
            let code = errno
            Darwin.close(descriptor)
            switch code {
            case ENOENT, ENOTDIR: return .failure(.noSocket)
            case ECONNREFUSED, EINPROGRESS, EAGAIN: return .failure(.refused)
            default: return .failure(.system(call: "connect", code: code))
            }
        }
        _ = fcntl(descriptor, F_SETFL, flags & ~O_NONBLOCK)
        var on: Int32 = 1
        // An engine that has gone must not end the app with a signal when it is written to.
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        return .success(UnixEngineSocket(descriptor: descriptor))
    }

    public func start(onLine: @escaping @Sendable (Data) -> Void, onClose: @escaping @Sendable () -> Void) {
        guard !started.exchange(true, ordering: .acquiringAndReleasing) else { return }
        let thread = Thread { [self] in
            var pending = Data()
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            reading: while !shut.load(ordering: .relaxed) {
                let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { break }
                pending.append(contentsOf: buffer[0..<count])
                while let newline = pending.firstIndex(of: 0x0A) {
                    let line = pending[pending.startIndex..<newline]
                    pending = Data(pending[pending.index(after: newline)...])
                    if !line.isEmpty { onLine(Data(line)) }
                }
                if pending.count > Self.lineLimit { break reading }
            }
            close()
            onClose()
        }
        thread.name = "o.app.engine.read"
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    @discardableResult
    public func send(_ line: Data) -> Bool {
        guard !shut.load(ordering: .relaxed) else { return false }
        writes.async { [self] in
            guard !shut.load(ordering: .relaxed) else { return }
            var framed = line
            framed.append(0x0A)
            let whole = framed.withUnsafeBytes { raw -> Bool in
                var sent = 0
                while sent < raw.count {
                    let count = Darwin.write(descriptor, raw.baseAddress?.advanced(by: sent), raw.count - sent)
                    if count < 0, errno == EINTR { continue }
                    guard count > 0 else { return false }
                    sent += count
                }
                return true
            }
            // A line that didn't go whole leaves the engine with half a request: the connection is no use any more.
            if !whole { close() }
        }
        return true
    }

    public func close() {
        guard !shut.exchange(true, ordering: .acquiringAndReleasing) else { return }
        shutdown(descriptor, SHUT_RDWR)
    }
}
