// OEngine — Spec 10 §2, the Mach channel: previews, channel pictures and meters for the operator app.

@preconcurrency import Darwin
import Foundation
import IOSurface
import OMach
import Synchronization

/// Spec 10 §2 — the engine's end of the Mach channel. The message ids and the
/// values both ends share (`MachWire`, `MachSurfaceSet`, `MeterReading`) are
/// OMach's, with the client's end, so the operator app links them without the
/// engine.
///
/// Two threads of its own. One reads the service's port: a `connect` from the
/// engine's own user adds a client. The other sends: each new client its
/// surfaces, then, as the render thread's notices come in and the GPU work
/// behind each has finished, the frame messages, and the meters 15 times a
/// second. A send never waits for a client: a full queue drops that message
/// (the next frame names a newer surface), and a client that is gone is
/// forgotten. Nothing here runs on the render thread or in the audio
/// callback.
public final class MachChannel: @unchecked Sendable {
    /// Spec 10 §2 (Area 19 reading) — the app, and the soak's stand-in for it, with room to spare.
    public static let maxClients = 4
    /// "Meters: 15 times a second".
    public static let meterIntervalNanoseconds: Int64 = 1_000_000_000 / 15
    /// A notice whose GPU work hasn't finished after this long is dropped.
    static let noticePatienceNanoseconds: Int64 = 1_000_000_000

    /// What the channel reads of the engine; a test stands in for any of it.
    public struct Source: Sendable {
        /// Every stack's three preview surfaces, as they are now.
        public var previews: @Sendable () -> [MachSurfaceSet]
        /// Every channel's three picture surfaces, as they are now.
        public var pictures: @Sendable () -> [MachSurfaceSet]
        /// Whether a tick's GPU work has finished: nil while in flight, false when it failed.
        public var finished: @Sendable (EncodeReceipt) -> Bool?
        /// The levels since the last call, for each channel whose content has sound.
        public var meters: @Sendable () -> [MeterReading]

        public init(previews: @escaping @Sendable () -> [MachSurfaceSet], pictures: @escaping @Sendable () -> [MachSurfaceSet],
                    finished: @escaping @Sendable (EncodeReceipt) -> Bool?, meters: @escaping @Sendable () -> [MeterReading]) {
            self.previews = previews
            self.pictures = pictures
            self.finished = finished
            self.meters = meters
        }
    }

    public let name: String
    private let service: any MachService
    private let notices: AuxNoticeRing
    private let source: Source
    private let log: EngineLog
    /// Spec 10 §2 (Area 19 reading) — who may connect: the engine's own user, as on the local socket.
    private let allows: @Sendable (uid_t) -> Bool
    /// Called when the number of clients changes, from the channel's threads.
    private let onClients: @Sendable (Int) -> Void

    private let lock = NSLock()
    private var registration: MachRegistration?
    private var clients: [mach_port_t] = []
    private var greet: [mach_port_t] = []
    private var resend = false
    private var removed: [Int] = []
    private let running = Atomic<Bool>(false)
    private let sentFrames = Atomic<Int64>(0)
    private let droppedMessages = Atomic<Int64>(0)
    private let refusedClients = Atomic<Int64>(0)

    public init(service: any MachService = BootstrapMachService(), name: String, notices: AuxNoticeRing, source: Source, log: EngineLog,
                allows: @escaping @Sendable (uid_t) -> Bool = { $0 == geteuid() }, onClients: @escaping @Sendable (Int) -> Void = { _ in }) {
        self.service = service
        self.name = name
        self.notices = notices
        self.source = source
        self.log = log
        self.allows = allows
        self.onClients = onClients
    }

    /// Registers the service under the name `hello` gives and starts the two threads.
    public func start() throws {
        guard !running.exchange(true, ordering: .acquiringAndReleasing) else { return }
        let registration: MachRegistration
        do {
            registration = try service.register(name: name)
        } catch {
            running.store(false, ordering: .releasing)
            throw error
        }
        lock.lock()
        self.registration = registration
        lock.unlock()
        log.info("the Mach channel is \(name) (\(registration.call == .checkIn ? "bootstrap_check_in" : "bootstrap_register"))")
        let receiver = Thread { [self] in receiveLoop(registration) }
        receiver.name = "o.engine.mach.receive"
        receiver.qualityOfService = .userInitiated
        receiver.start()
        let sender = Thread { [self] in sendLoop() }
        sender.name = "o.engine.mach.send"
        sender.qualityOfService = .userInitiated
        sender.start()
    }

    /// Stops both threads, lets the clients go and gives the service's port back.
    public func stop() {
        guard running.exchange(false, ordering: .acquiringAndReleasing) else { return }
        lock.lock()
        let held = clients + greet
        clients = []
        greet = []
        let registration = self.registration
        self.registration = nil
        lock.unlock()
        held.forEach(MachPorts.release)
        if let registration { MachPorts.destroyReceive(registration.port) }
        if !held.isEmpty { onClients(0) }
    }

    /// The clients holding the channel now, counting one being greeted.
    public var clientCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return clients.count + greet.count
    }

    /// Frame messages that reached a client, and messages a full queue dropped.
    public var framesSent: Int64 { sentFrames.load(ordering: .relaxed) }
    public var messagesDropped: Int64 { droppedMessages.load(ordering: .relaxed) }
    public var clientsRefused: Int64 { refusedClients.load(ordering: .relaxed) }

    /// Spec 10 §2 — the surfaces are sent "whenever a stack's surfaces are made
    /// again", "when a channel is added or renumbered, and whenever they are
    /// made again, as after a GPU reset (Spec 4 §12)": every client gets them
    /// all again.
    public func resendSurfaces() {
        lock.lock()
        resend = true
        lock.unlock()
    }

    /// Spec 10 §2 — "when a channel is removed, a message names it and the app drops its surfaces."
    public func channelRemoved(_ channel: Int) {
        lock.lock()
        removed.append(channel)
        lock.unlock()
    }

    // MARK: - Receiving

    private func receiveLoop(_ registration: MachRegistration) {
        while running.load(ordering: .relaxed) {
            guard case .success(let message) = MachMessage.receive(on: registration.port, timeoutMs: 250) else { continue }
            message.ports.forEach(MachPorts.release)
            let version = MachMessage.word(message.payload, 0)
            guard message.id == MachWire.connect, message.reply != MachPorts.null, version == MachWire.version else {
                MachPorts.release(message.reply)
                continue
            }
            guard allows(message.senderUID) else {
                refusedClients.add(1, ordering: .relaxed)
                log.warning("the Mach channel refused a client of another user")
                MachPorts.release(message.reply)
                continue
            }
            lock.lock()
            let room = clients.count + greet.count < Self.maxClients
            if room { greet.append(message.reply) }
            let count = clients.count + greet.count
            lock.unlock()
            if room {
                onClients(count)
            } else {
                MachPorts.release(message.reply)
            }
        }
    }

    // MARK: - Sending

    private func sendLoop() {
        var waiting: [(notice: AuxNotice, since: Int64)] = []
        var nextMeters = MonotonicClock.now().nanoseconds + Self.meterIntervalNanoseconds
        while running.load(ordering: .relaxed) {
            autoreleasepool {
                lock.lock()
                let greeting = greet
                greet = []
                clients += greeting
                let everyone = resend
                resend = false
                let gone = removed
                removed = []
                lock.unlock()

                // A new client's surfaces, or everyone's again.
                if everyone {
                    for client in currentClients() { sendSurfaces(to: client) }
                } else {
                    for client in greeting { sendSurfaces(to: client) }
                }
                for channel in gone {
                    broadcast(MachWire.channelRemoved, MachMessage.words([MachWire.version, UInt32(truncatingIfNeeded: channel)]))
                }

                // The frames the render thread drew whose GPU work has finished.
                let now = MonotonicClock.now().nanoseconds
                notices.drain { waiting.append(($0, now)) }
                var still: [(notice: AuxNotice, since: Int64)] = []
                for entry in waiting {
                    switch source.finished(entry.notice.receipt) {
                    case true?:
                        let id = entry.notice.kind == .preview ? MachWire.previewFrame : MachWire.pictureFrame
                        broadcast(id, MachMessage.words([MachWire.version, UInt32(bitPattern: entry.notice.number), UInt32(bitPattern: entry.notice.slot)]), counted: true)
                    case false?:
                        break   // the GPU work failed: the surface holds nothing new to name
                    case nil:
                        if now - entry.since < Self.noticePatienceNanoseconds { still.append(entry) }
                    }
                }
                waiting = still

                // "Meters: 15 times a second".
                if now >= nextMeters {
                    nextMeters = max(nextMeters + Self.meterIntervalNanoseconds, now)
                    sendMeters()
                }
            }
            Thread.sleep(forTimeInterval: 0.004)
        }
    }

    private func currentClients() -> [mach_port_t] {
        lock.lock()
        defer { lock.unlock() }
        return clients
    }

    /// Spec 10 §2 — "each stack's preview as three IOSurfaces, sent as Mach
    /// ports with the stack's number and size", and each channel's three
    /// picture surfaces "sent with the channel's number". These are sent with
    /// a short wait, since a client that misses them has nothing to read.
    private func sendSurfaces(to client: mach_port_t) {
        var sent: [Int] = []
        for (id, sets) in [(MachWire.previewSurfaces, source.previews()), (MachWire.pictureSurfaces, source.pictures())] {
            var count = 0
            for set in sets {
                let ports = set.surfaces.map { IOSurfaceCreateMachPort($0) }.filter { $0 != MachPorts.null }
                guard ports.count == set.surfaces.count, !ports.isEmpty else {
                    ports.forEach(MachPorts.release)
                    log.warning("the Mach channel could not make ports for the surfaces of \(id == MachWire.previewSurfaces ? "stack" : "channel") \(set.number)")
                    continue
                }
                let payload = MachMessage.words([MachWire.version, UInt32(truncatingIfNeeded: set.number), UInt32(truncatingIfNeeded: set.width),
                                                 UInt32(truncatingIfNeeded: set.height)])
                let code = MachMessage.send(to: client, id: id, moving: ports, payload: payload, timeoutMs: 250)
                if code != KERN_SUCCESS {
                    forget(client, code: code)
                    return
                }
                count += 1
            }
            sent.append(count)
        }
        // What went, in the log: an app whose tiles stay empty is told apart from an engine with nothing to send.
        let line = "a Mach client was sent the surfaces of \(sent.first ?? 0) stacks and \(sent.last ?? 0) channels"
        if sent.contains(0) { log.warning(line) } else { log.info(line) }
    }

    private func sendMeters() {
        let readings = source.meters()
        // "for each channel whose content has sound": with none, one empty frame says so, and then nothing.
        if readings.isEmpty {
            if metersWereEmpty { return }
            metersWereEmpty = true
        } else {
            metersWereEmpty = false
        }
        var words: [UInt32] = [MachWire.version, UInt32(readings.count)]
        for reading in readings.sorted(by: { $0.channel < $1.channel }) {
            words += [UInt32(truncatingIfNeeded: reading.channel), reading.peak.bitPattern, reading.rms.bitPattern]
        }
        broadcast(MachWire.meters, MachMessage.words(words))
    }
    private var metersWereEmpty = true

    /// One message to every client, without waiting for any of them.
    private func broadcast(_ id: mach_msg_id_t, _ payload: [UInt8], counted: Bool = false) {
        for client in currentClients() {
            let code = MachMessage.send(to: client, id: id, payload: payload, timeoutMs: 0)
            if code == KERN_SUCCESS {
                if counted { sentFrames.add(1, ordering: .relaxed) }
            } else if code == MACH_SEND_TIMED_OUT {
                // The client's queue is full: this message is dropped, and the next frame names a newer surface.
                droppedMessages.add(1, ordering: .relaxed)
            } else {
                forget(client, code: code)
            }
        }
    }

    /// A client whose port is dead, or that a send failed for: its right is given back and it is counted out.
    private func forget(_ client: mach_port_t, code: kern_return_t) {
        lock.lock()
        let had = clients.contains(client)
        clients.removeAll { $0 == client }
        let count = clients.count + greet.count
        lock.unlock()
        guard had else { return }
        // The engine hears first: with nobody left, the picture work stops with the next build.
        onClients(count)
        MachPorts.release(client)
        log.info("a Mach client went away (\(code)); \(count) left")
    }
}
