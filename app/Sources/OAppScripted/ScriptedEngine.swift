// OAppScripted — Spec 10 §16, the scripted engine on a local socket that the app's tests drive.

import Darwin
import Foundation
import OCore

/// Spec 10 §16 — "Area 13's tests drive the app's models against a scripted
/// engine on a local socket, so no test needs the engine or a GPU."
///
/// It listens on a Unix domain socket as the engine does (Spec 10 §2: "one
/// JSON object per line"), sends each new connection what the test set as
/// `hello`, keeps every request it is sent, and answers with whatever the
/// test's `respond` returns. It knows nothing of what the messages mean and
/// shares no decoding code with the app, so the app's decoders are tested
/// against plain lines, as the engine writes them.
public final class ScriptedEngine: @unchecked Sendable {
    /// Why the socket couldn't be opened: the call that failed and the system's error number.
    public struct Failure: Error, Equatable, CustomStringConvertible {
        public var call: String
        public var code: Int32

        public var description: String { "\(call) failed (\(String(cString: strerror(code))))" }
    }

    /// Where it listens: `engine.sock` in the machine root, in the tests a short folder under `/tmp`.
    public let socketURL: URL

    private let lock = NSLock()
    private var listener: Int32 = -1
    private var connections: [Int32] = []
    private var received: [JSONValue] = []
    private var firstMessage: JSONValue?
    private var responder: (@Sendable (JSONValue) -> [JSONValue])?
    private let changed = NSCondition()

    public init(socketURL: URL) {
        self.socketURL = socketURL
    }

    deinit {
        stop()
    }

    /// Spec 10 §2 — "the engine's first message is `hello`": what each new
    /// connection is sent first. Nil sends nothing, as an engine that holds
    /// its root and never gets as far as taking commands.
    public var hello: JSONValue? {
        get { locked { firstMessage } }
        set { locked { firstMessage = newValue } }
    }

    /// Called with each request, on the connection's own thread; what it
    /// returns is sent back, in order. Nil answers nothing.
    public var respond: (@Sendable (JSONValue) -> [JSONValue])? {
        get { locked { responder } }
        set { locked { responder = newValue } }
    }

    /// Every request received so far, in the order it arrived.
    public var requests: [JSONValue] {
        locked { received }
    }

    /// The requests of one `type`, in order.
    public func requests(ofType type: String) -> [JSONValue] {
        requests.filter { $0.objectValue?["type"]?.stringValue == type }
    }

    /// How many clients are connected now.
    public var connectionCount: Int {
        locked { connections.count }
    }

    /// Opens the socket and starts accepting. A file left at the path is
    /// replaced, as the engine replaces a socket a crash left (Spec 10 §2).
    public func start() throws {
        let path = socketURL.path
        var address = sockaddr_un()
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard path.utf8.count < capacity else { throw Failure(call: "the socket path is over \(capacity - 1) bytes; bind", code: ENAMETOOLONG) }
        unlink(path)
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw Failure(call: "socket", code: errno) }
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: path.utf8)
        }
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0 else {
            let code = errno
            close(descriptor)
            throw Failure(call: "bind", code: code)
        }
        guard listen(descriptor, 8) == 0 else {
            let code = errno
            close(descriptor)
            throw Failure(call: "listen", code: code)
        }
        locked { listener = descriptor }
        let thread = Thread { [weak self] in
            while true {
                let client = accept(descriptor, nil, nil)
                guard client >= 0 else { return }
                guard let self else {
                    close(client)
                    return
                }
                self.serve(client)
            }
        }
        thread.name = "o.scripted.accept"
        thread.start()
    }

    /// Closes the socket and every connection and removes the socket's file:
    /// to a client, the engine has gone.
    public func stop() {
        let (descriptor, clients): (Int32, [Int32]) = locked {
            let taken = (listener, connections)
            listener = -1
            connections = []
            return taken
        }
        if descriptor >= 0 {
            // Closing alone leaves a thread inside accept() waiting; shutting the socket down wakes it.
            shutdown(descriptor, SHUT_RDWR)
            close(descriptor)
            unlink(socketURL.path)
        }
        for client in clients { shutdown(client, SHUT_RDWR) }
    }

    /// Drops every client and keeps listening, as the engine closes a client
    /// that fell too far behind (Spec 10 §3, Area 19 reading).
    public func closeConnections() {
        let clients = locked { connections }
        for client in clients { shutdown(client, SHUT_RDWR) }
    }

    /// Sends one message to every client connected now.
    public func send(_ message: JSONValue) {
        let clients = locked { connections }
        for client in clients { write(message, to: client) }
    }

    /// Sends one line as it is, without checking it is JSON: for the tests of what the app does with a bad line.
    public func send(rawLine: String) {
        let clients = locked { connections }
        for client in clients { write(Data((rawLine + "\n").utf8), to: client) }
    }

    /// Waits until a request that `matches` has arrived and returns the
    /// first such; nil when none has within `seconds`. It waits on the
    /// request itself, never on time alone.
    public func waitForRequest(seconds: TimeInterval = 5, where matches: (JSONValue) -> Bool) -> JSONValue? {
        let deadline = Date().addingTimeInterval(seconds)
        changed.lock()
        defer { changed.unlock() }
        while true {
            if let found = locked({ received.first(where: matches) }) { return found }
            guard changed.wait(until: deadline) else { return locked { received.first(where: matches) } }
        }
    }

    /// Waits until `count` clients are connected; false when they aren't within `seconds`.
    public func waitForConnections(_ count: Int, seconds: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        changed.lock()
        defer { changed.unlock() }
        while locked({ connections.count }) != count {
            guard changed.wait(until: deadline) else { return locked { connections.count } == count }
        }
        return true
    }

    // MARK: - One connection

    private func serve(_ client: Int32) {
        var on: Int32 = 1
        // A client that has gone must not end the test process with a signal when it is written to.
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        let first: JSONValue? = locked {
            connections.append(client)
            return firstMessage
        }
        if let first { write(first, to: client) }
        signalChange()
        let thread = Thread { [weak self] in
            var pending = Data()
            var buffer = [UInt8](repeating: 0, count: 65_536)
            while true {
                let count = read(client, &buffer, buffer.count)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { break }
                pending.append(contentsOf: buffer[0..<count])
                while let newline = pending.firstIndex(of: 0x0A) {
                    let line = pending.subdata(in: pending.startIndex..<newline)
                    pending.removeSubrange(pending.startIndex...newline)
                    guard !line.isEmpty, let self else { continue }
                    self.take(line, from: client)
                }
            }
            close(client)
            self?.forget(client)
        }
        thread.name = "o.scripted.connection"
        thread.start()
    }

    private func take(_ line: Data, from client: Int32) {
        guard let request = try? JSONValue.parse(line) else { return }
        let respond: (@Sendable (JSONValue) -> [JSONValue])? = locked {
            received.append(request)
            return responder
        }
        signalChange()
        for answer in respond?(request) ?? [] { write(answer, to: client) }
    }

    private func forget(_ client: Int32) {
        locked { connections.removeAll { $0 == client } }
        signalChange()
    }

    private func write(_ message: JSONValue, to client: Int32) {
        write(Data((JSONCanonical.line(message) + "\n").utf8), to: client)
    }

    private func write(_ data: Data, to client: Int32) {
        data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(client, bytes.baseAddress?.advanced(by: offset), bytes.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { return }
                offset += count
            }
        }
    }

    private func signalChange() {
        changed.lock()
        changed.broadcast()
        changed.unlock()
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

/// A folder under `/tmp` for a socket: "The socket's path must fit macOS's
/// limit of 103 bytes" (Spec 10 §2), which a test's temporary folder under
/// `/var/folders` doesn't.
public enum ShortSocketFolder {
    /// A new, empty folder, `/tmp/oa-xxxxxxxx`; the caller removes it.
    public static func make() throws -> URL {
        let name = "oa-" + UUID().uuidString.prefix(8).lowercased()
        let url = URL(fileURLWithPath: "/tmp").appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return url
    }
}
