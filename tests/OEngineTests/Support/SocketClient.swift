import Foundation
import XCTest
import OCore
@testable import OEngine

/// A client of the engine's local socket for the tests, as the operator app
/// will be: a Unix domain socket, one JSON object per line each way.
final class SocketClient {
    private let descriptor: Int32
    private var pending = Data()
    private var nextID = 0

    /// Connects to the socket at `path`, or returns nil with the reason.
    static func connect(to path: String) -> Result<SocketClient, SocketClientError> {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return .failure(SocketClientError(call: "socket", code: errno)) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            for (index, byte) in path.utf8.prefix(raw.count - 1).enumerated() { raw[index] = byte }
        }
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else {
            let code = errno
            close(descriptor)
            return .failure(SocketClientError(call: "connect", code: code))
        }
        return .success(SocketClient(descriptor: descriptor))
    }

    private init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    deinit {
        close(descriptor)
    }

    /// Sends one request with the next `id`, and returns that id.
    @discardableResult
    func send(_ type: String, _ fields: [String: JSONValue] = [:]) -> Int {
        nextID += 1
        var members = fields
        members["type"] = .string(type)
        members["id"] = .number(Double(nextID))
        send(raw: JSONCanonical.line(.object(members)))
        return nextID
    }

    func send(raw text: String) {
        let bytes = Array((text + "\n").utf8)
        _ = bytes.withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }
    }

    /// The next line the engine sent, as a JSON object; nil when none comes
    /// within `seconds` or the engine closed the connection.
    func next(seconds: Double = 5) -> [String: JSONValue]? {
        let deadline = Date(timeIntervalSinceNow: seconds)
        while true {
            if let newline = pending.firstIndex(of: 0x0A) {
                let line = pending[pending.startIndex..<newline]
                pending = Data(pending[pending.index(after: newline)...])
                return (try? JSONValue.parse(Data(line)))?.objectValue
            }
            let left = deadline.timeIntervalSinceNow
            guard left > 0 else { return nil }
            var descriptorSet = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            guard poll(&descriptorSet, 1, Int32(left * 1000)) > 0 else { return nil }
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            let count = buffer.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
            guard count > 0 else { return nil }
            pending.append(contentsOf: buffer[0..<count])
        }
    }

    /// Reads until the message that answers the request `id` (not an event), keeping nothing else.
    func answer(to id: Int, seconds: Double = 5) -> [String: JSONValue]? {
        let deadline = Date(timeIntervalSinceNow: seconds)
        while deadline.timeIntervalSinceNow > 0 {
            guard let message = next(seconds: deadline.timeIntervalSinceNow) else { return nil }
            if message["id"] == .number(Double(id)), message["type"] != .string("event") { return message }
        }
        return nil
    }

    /// True when the engine has closed its end: the next read ends with nothing.
    func isClosedByPeer(seconds: Double = 2) -> Bool {
        var descriptorSet = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
        guard poll(&descriptorSet, 1, Int32(seconds * 1000)) > 0 else { return false }
        var byte: UInt8 = 0
        return read(descriptor, &byte, 1) <= 0
    }
}

struct SocketClientError: Error, CustomStringConvertible {
    var call: String
    var code: Int32

    var description: String { "\(call) failed (\(String(cString: strerror(code))))" }
}

/// A folder with a path short enough for a socket inside it (Spec 10 §2:
/// "macOS's limit of 103 bytes"); the temporary folder's own path is not.
enum ShortFolder {
    static func make() throws -> URL {
        let url = URL(fileURLWithPath: "/tmp/os-\(UUID().uuidString.prefix(8).lowercased())", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
