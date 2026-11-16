// OEngine — Spec 10 §2, the engine's local socket.

import Darwin
import Foundation
import Synchronization

/// Spec 10 §2, "The local socket" (R2) — "A Unix domain socket that only its
/// owner can open (mode 0600), and the engine closes any connection whose
/// peer, by `getpeereid`, is another user. It carries Spec 2 §9's messages,
/// one JSON object per line." "A socket file left by a crash is removed by
/// the next engine before it listens." "The socket's path must fit macOS's
/// limit of 103 bytes".
public final class LocalSocket: @unchecked Sendable {
    /// Spec 10 §2 — "`engine.sock` in the machine root".
    public static let fileName = "engine.sock"
    /// "macOS's limit of 103 bytes": the path, without its end.
    public static let pathLimit = 103

    public enum Failure: Error, Equatable, CustomStringConvertible {
        case pathTooLong(path: String, bytes: Int)
        case notASocket(path: String)
        case system(call: String, code: Int32)

        public var description: String {
            switch self {
            case .pathTooLong(let path, let bytes):
                return "the socket's path is \(bytes) bytes and macOS allows \(LocalSocket.pathLimit): \(path)"
            case .notASocket(let path): return "\(path) is in the way and isn't a socket"
            case .system(let call, let code): return "the local socket's \(call) failed (\(String(cString: strerror(code))))"
            }
        }
    }

    /// What the socket asks of the system, so a test can stand in for it.
    public struct Seams: Sendable {
        /// The user at the other end of a connection, by `getpeereid`; nil when it can't be read.
        public var peerUser: @Sendable (Int32) -> uid_t?

        public init(peerUser: @escaping @Sendable (Int32) -> uid_t?) {
            self.peerUser = peerUser
        }

        public static let live = Seams(peerUser: { descriptor in
            var user = uid_t(0), group = gid_t(0)
            return getpeereid(descriptor, &user, &group) == 0 ? user : nil
        })
    }

    public let url: URL
    private let seams: Seams
    private let log: EngineLog
    private let onConnection: @Sendable (SocketTransport) -> Void
    private let listening = Atomic<Int32>(-1)
    private let refused = Atomic<Int>(0)

    public init(url: URL, seams: Seams = .live, log: EngineLog, onConnection: @escaping @Sendable (SocketTransport) -> Void) {
        self.url = url
        self.seams = seams
        self.log = log
        self.onConnection = onConnection
    }

    /// Spec 10 §2 — the socket's place in a machine root.
    public static func url(machineRoot: URL) -> URL {
        machineRoot.appendingPathComponent(fileName)
    }

    /// Spec 10 §2, §13 — whether a machine root's socket path fits, before anything is written there.
    public static func check(path: String) -> Failure? {
        let bytes = path.utf8.count
        return bytes > pathLimit ? .pathTooLong(path: path, bytes: bytes) : nil
    }

    /// Connections from another user closed since the socket started.
    public var refusedConnections: Int { refused.load(ordering: .relaxed) }

    /// Binds, restricts and listens. The file is made by `bind`, set to mode
    /// 0600 at once, and only then listened on: a connection to a socket that
    /// isn't listening yet is refused whatever its mode, so nobody but the
    /// owner can ever connect. A socket file a crashed engine left is removed
    /// first; the caller holds the root's lock, so no live engine owns it.
    public func start() throws {
        let path = url.path
        if let failure = Self.check(path: path) { throw failure }
        var status = stat()
        if lstat(path, &status) == 0 {
            guard status.st_mode & S_IFMT == S_IFSOCK else { throw Failure.notASocket(path: path) }
            unlink(path)
        }
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw Failure.system(call: "socket", code: errno) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            for (index, byte) in path.utf8.prefix(capacity - 1).enumerated() { raw[index] = byte }
        }
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0 else {
            let code = errno
            close(descriptor)
            throw Failure.system(call: "bind", code: code)
        }
        guard chmod(path, 0o600) == 0 else {
            let code = errno
            close(descriptor)
            unlink(path)
            throw Failure.system(call: "chmod", code: code)
        }
        guard listen(descriptor, 8) == 0 else {
            let code = errno
            close(descriptor)
            unlink(path)
            throw Failure.system(call: "listen", code: code)
        }
        listening.store(descriptor, ordering: .releasing)
        let thread = Thread { [self] in acceptLoop(descriptor) }
        thread.name = "o.engine.api.socket"
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    /// Stops listening and removes the socket's file. Connections already open are the hub's to close.
    public func stop() {
        let descriptor = listening.exchange(-1, ordering: .acquiringAndReleasing)
        guard descriptor >= 0 else { return }
        close(descriptor)
        unlink(url.path)
    }

    private func acceptLoop(_ descriptor: Int32) {
        while listening.load(ordering: .relaxed) == descriptor {
            let connection = accept(descriptor, nil, nil)
            guard connection >= 0 else {
                if errno == EINTR { continue }
                return
            }
            // "the engine closes any connection whose peer, by `getpeereid`, is another user".
            guard let user = seams.peerUser(connection), user == geteuid() else {
                refused.add(1, ordering: .relaxed)
                log.warning("the local socket closed a connection from another user")
                close(connection)
                continue
            }
            var on: Int32 = 1
            setsockopt(connection, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            onConnection(SocketTransport(descriptor: connection))
        }
    }
}

/// One connection of the local socket: lines in on a reader thread, lines
/// out from the connection's writer. "one JSON object per line".
public final class SocketTransport: ApiTransport, @unchecked Sendable {
    /// A line longer than this is not a request the engine knows; the connection closes.
    public static let lineLimit = 1024 * 1024

    private let descriptor: Int32
    private let shut = Atomic<Bool>(false)

    init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    /// The descriptor is given back only when nothing holds the transport any
    /// more, so a write that races a close meets a shut socket, never a
    /// descriptor the system has handed to something else.
    deinit {
        Darwin.close(descriptor)
    }

    /// Starts reading: each whole line goes to `onLine`, and `onClose` is
    /// called once, when the client goes or the connection is closed.
    public func read(onLine: @escaping @Sendable (Data) -> Void, onClose: @escaping @Sendable () -> Void) {
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
        thread.name = "o.engine.api.reader"
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    public func write(_ line: Data) -> Bool {
        guard !shut.load(ordering: .relaxed) else { return false }
        var framed = line
        framed.append(0x0A)
        return framed.withUnsafeBytes { raw -> Bool in
            var sent = 0
            while sent < raw.count {
                let count = Darwin.write(descriptor, raw.baseAddress?.advanced(by: sent), raw.count - sent)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { return false }
                sent += count
            }
            return true
        }
    }

    /// Ends both directions; the reader thread wakes and reports the close.
    public func close() {
        guard !shut.exchange(true, ordering: .acquiringAndReleasing) else { return }
        shutdown(descriptor, SHUT_RDWR)
    }
}
