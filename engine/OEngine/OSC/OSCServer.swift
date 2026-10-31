// OEngine — Spec 2 §6, OSC on a socket; Spec 4 §3, "OSC and API I/O" on the
// control side.

import Foundation
import Darwin
import OCore
import Synchronization

/// An OSC peer: host and port.
public struct OSCPeer: Hashable, Sendable {
    public var host: String
    public var port: UInt16

    public init(host: String, port: UInt16) {
        self.host = host
        self.port = port
    }
}

public enum OSCServerError: Error, Equatable {
    case socket(String)
    case bind(UInt16, String)
}

/// Spec 2 §6 — the OSC server: commands in over UDP on the machine's
/// `oscInPort` (Spec 1 §3), decoded with the codec and the mapping of OCore,
/// landing as groups on the next tick (Spec 2 §8); `/o/register`,
/// `/o/subscribe`, `/o/unsubscribe` and `/o/query`; errors back to the sender
/// as `/o/error`; feedback "to every configured OSC target (machine
/// settings) and to any client that registers ..., which lasts 60 seconds and
/// is renewed by repeating it."
public final class OSCServer: @unchecked Sendable {
    public let requestedPort: UInt16
    public let targets: [OSCPeer]
    private let enqueue: @Sendable (CommandGroup) -> Void
    private let parseOptions: ParseOptions
    private let log: EngineLog
    private let now: @Sendable () -> MonotonicTime
    private var socket: Int32 = -1
    private var thread: Thread?
    private let running = Atomic<Bool>(false)
    private let lock = NSLock()
    private var registrations: [OSCPeer: MonotonicTime] = [:]
    private var subscriptions: [OSCPeer: Set<String>] = [:]
    public private(set) var boundPort: UInt16 = 0
    private let receivedCount = Atomic<Int64>(0)
    private let rejectedCount = Atomic<Int64>(0)
    private let sentCount = Atomic<Int64>(0)
    /// Spec 2 §6 — "Any client may ask for a current value with /o/query".
    public var queryHandler: (@Sendable (String) -> OSCMessage?)?

    public init(port: UInt16, targets: [OSCTarget], mediaIDs: Set<String>, log: EngineLog,
                now: @escaping @Sendable () -> MonotonicTime = { MonotonicClock.now() },
                enqueue: @escaping @Sendable (CommandGroup) -> Void) {
        requestedPort = port
        self.targets = targets.map { OSCPeer(host: $0.host, port: UInt16(clamping: $0.port)) }
        self.enqueue = enqueue
        parseOptions = ParseOptions(mediaIDs: mediaIDs)
        self.log = log
        self.now = now
    }

    public var received: Int64 { receivedCount.load(ordering: .relaxed) }
    public var rejected: Int64 { rejectedCount.load(ordering: .relaxed) }
    public var sent: Int64 { sentCount.load(ordering: .relaxed) }

    // MARK: - Lifecycle

    public func start() throws {
        guard !running.exchange(true, ordering: .acquiringAndReleasing) else { return }
        let fd = Darwin.socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else {
            running.store(false, ordering: .releasing)
            throw OSCServerError.socket(String(cString: strerror(errno)))
        }
        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = requestedPort.bigEndian
        address.sin_addr.s_addr = INADDR_ANY
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0 else {
            let reason = String(cString: strerror(errno))
            close(fd)
            running.store(false, ordering: .releasing)
            throw OSCServerError.bind(requestedPort, reason)
        }
        var actual = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &actual) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        boundPort = UInt16(bigEndian: actual.sin_port)
        socket = fd
        let thread = Thread { [self] in receiveLoop() }
        thread.name = "o.engine.osc"
        thread.qualityOfService = .userInteractive
        self.thread = thread
        thread.start()
        log.info("OSC listening on port \(boundPort)")
    }

    public func stop() {
        guard running.exchange(false, ordering: .acquiringAndReleasing) else { return }
        if socket >= 0 {
            shutdown(socket, SHUT_RDWR)
            close(socket)
        }
        socket = -1
        thread = nil
    }

    // MARK: - Receiving

    private func receiveLoop() {
        let capacity = 65_536
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
        defer { buffer.deallocate() }
        while running.load(ordering: .relaxed) {
            var from = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let count = withUnsafeMutablePointer(to: &from) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(socket, buffer, capacity, 0, $0, &length) }
            }
            guard count > 0 else {
                if !running.load(ordering: .relaxed) { break }
                continue
            }
            autoreleasepool {
                let data = Data(bytes: buffer, count: count)
                let peer = OSCPeer(host: String(cString: inet_ntoa(from.sin_addr)), port: UInt16(bigEndian: from.sin_port))
                handle(data, from: peer)
            }
        }
    }

    /// One datagram: a message or a bundle, from a peer.
    func handle(_ data: Data, from peer: OSCPeer) {
        receivedCount.add(1, ordering: .relaxed)
        switch OSCPacket.decode(data) {
        case .failure(let error):
            rejectedCount.add(1, ordering: .relaxed)
            send(OSCFeedback.error(address: "", reason: "malformed packet: \(error)"), to: peer)
        case .success(.message(let message)):
            if let request = OSCClientRequest(message) {
                handle(request, from: peer)
                return
            }
            switch OSCMapping.command(from: message, options: parseOptions) {
            case .success(let command):
                enqueue(CommandGroup(id: GroupID.random(), source: CommandSource(kind: .osc), commands: [command]))
            case .failure(let rejection):
                rejectedCount.add(1, ordering: .relaxed)
                send(OSCFeedback.error(address: message.address, reason: rejection.message), to: peer)
            }
        case .success(.bundle(let bundle)):
            // Spec 2 §6 — "Bundles run as one group, in order, and either all validate or none run."
            switch OSCMapping.commands(from: bundle, options: parseOptions) {
            case .success(let commands):
                enqueue(CommandGroup(id: GroupID.random(), source: CommandSource(kind: .osc), commands: commands))
            case .failure(let rejection):
                rejectedCount.add(1, ordering: .relaxed)
                send(OSCFeedback.error(address: "#bundle", reason: rejection.message), to: peer)
            }
        }
    }

    private func handle(_ request: OSCClientRequest, from peer: OSCPeer) {
        switch request {
        case .register(let host, let port):
            let client = OSCPeer(host: host.isEmpty ? peer.host : host, port: UInt16(clamping: port))
            lock.lock()
            registrations[client] = now().advanced(by: Int64(OSCClientRequest.registrationSeconds) * 1_000_000_000)
            lock.unlock()
        case .subscribe(let address):
            lock.lock()
            subscriptions[peer, default: []].insert(address)
            lock.unlock()
        case .unsubscribe(let address):
            lock.lock()
            subscriptions[peer]?.remove(address)
            lock.unlock()
        case .query(let address):
            if let reply = queryHandler?(address) {
                send(reply, to: peer)
            } else {
                send(OSCFeedback.error(address: address, reason: "nothing to query at that address"), to: peer)
            }
        }
    }

    // MARK: - Sending

    /// Spec 2 §6 — feedback to every target and every live registration.
    public func feedback(_ messages: [OSCMessage]) {
        guard !messages.isEmpty else { return }
        let current = now()
        lock.lock()
        registrations = registrations.filter { $0.value > current }
        let peers = Set(targets).union(registrations.keys)
        let subscribed = subscriptions
        lock.unlock()
        for message in messages {
            // Spec 2 §6 — "High-rate feedback is opt-in per address".
            let highRate = message.address.hasSuffix("/remaining")
            for peer in peers where !highRate || subscribed[peer]?.contains(message.address) == true {
                send(message, to: peer)
            }
        }
    }

    public func send(_ message: OSCMessage, to peer: OSCPeer) {
        guard socket >= 0 else { return }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = peer.port.bigEndian
        guard inet_pton(AF_INET, peer.host, &address.sin_addr) == 1 else { return }
        let data = message.encoded()
        let sentBytes = data.withUnsafeBytes { raw in
            withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(socket, raw.baseAddress, data.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        if sentBytes == data.count { sentCount.add(1, ordering: .relaxed) }
    }

    public var liveRegistrations: [OSCPeer] {
        let current = now()
        lock.lock()
        defer { lock.unlock() }
        return registrations.filter { $0.value > current }.keys.sorted { ($0.host, $0.port) < ($1.host, $1.port) }
    }
}

/// Spec 2 §6 — "Feedback addresses mirror state, not commands": the messages
/// the engine sends after a tick's commands ran, derived from the effects.
public enum OSCFeedbackDeriver {
    public static func messages(for executed: [ExecutedCommand], state: ShowState, library: Library, machine: Machine) -> [OSCMessage] {
        var out: [OSCMessage] = []
        for entry in executed {
            for effect in entry.effects {
                switch effect {
                case .pointer(_, let new, _):
                    guard let new, let cueUuid = new.cueUuid, let listUuid = new.listUuid else { continue }
                    let list = library.list(uuid: listUuid) ?? machine.localList(uuid: listUuid)
                    if let playlist = new.playlist.flatMap({ machine.playlist(uuid: $0) }) { out.append(OSCFeedback.livePlaylist(playlist.title)) }
                    if let item = new.item { out.append(OSCFeedback.liveItem(item)) }
                    if let list, let index = list.cues.firstIndex(where: { $0.uuid == cueUuid }) {
                        out.append(OSCFeedback.liveCue(index + 1))
                        out.append(OSCFeedback.liveLabel(list.cues[index].label))
                    }
                case .transition(let t):
                    out.append(OSCFeedback.channelContent(t.channel, kind: t.to.kind, label: label(of: t.to, library: library)))
                    out.append(OSCFeedback.channelState(t.channel, feedbackState(of: t.to)))
                case .applied(let command):
                    switch command {
                    case .channelTransport(let target, _), .channelEndBehavior(let target, _):
                        for number in numbers(target, state: state) {
                            if let content = state.channels[number]?.content { out.append(OSCFeedback.channelState(number, feedbackState(of: content))) }
                        }
                    case .channelLock(let target, let locked):
                        for number in numbers(target, state: state) { out.append(OSCFeedback.lock(number, locked: locked)) }
                    default:
                        break
                    }
                case .stackSwitch(let output, _, let new, _):
                    out.append(OSCFeedback.outputStack(output, stack: new))
                case .blackout(let stack, _, let new, _):
                    out.append(OSCFeedback.stackBlackout(stack, on: new))
                case .variable(let popup, let text, _):
                    out.append(OSCFeedback.popup(popup, text: text ?? ""))
                default:
                    break
                }
            }
        }
        return out
    }

    static func numbers(_ target: Target, state: ShowState) -> [Int] {
        switch target {
        case .number(let n): return [n]
        case .all: return state.channels.keys.sorted()
        }
    }

    /// Spec 2 §6 — `s:label`: the first line of text, the media item's name,
    /// the slide's or input's id.
    static func label(of content: ContentInstance, library: Library) -> String {
        switch content {
        case .empty: return ""
        case .text(let t): return String((t.fields["body"] ?? t.fields.values.sorted().first ?? "").split(separator: "\n").first ?? "")
        case .media(let m):
            let path = library.mediaIndex.entry(m.ref)?.path ?? m.ref
            return String(path.split(separator: "/").last ?? Substring(path))
        case .slide(let s): return s.ref
        case .input(let i): return "input \(i.input)"
        }
    }

    /// Spec 2 §6 — `/o/channel/N/state`: "empty, playing, paused, held, missing".
    static func feedbackState(of content: ContentInstance) -> ChannelFeedbackState {
        switch content {
        case .empty: return .empty
        case .media(let m):
            if m.missing { return .missing }
            switch m.transport {
            case .playing: return .playing
            case .paused: return .paused
            case .stopped: return .held
            }
        case .text, .slide, .input: return .held
        }
    }
}
