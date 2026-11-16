// OEngine — Spec 10 §2, the other end of the Mach channel.

@preconcurrency import Darwin
import Foundation
import IOSurface
import Synchronization

/// Spec 10 §2 — "the app looks it up": a client of the engine's Mach channel,
/// as the operator app will be one. It looks the service up by the name
/// `hello` gave, sends `connect` with a port of its own, and then keeps what
/// arrives: each stack's and each channel's three surfaces, which of them
/// holds the newest frame, and the meters.
///
/// The soak holds one (Spec 10 §18: "The soak scenario gains a client holding
/// the Mach channel, so the previews and the channel pictures count in its
/// GPU p99"), and the tests read the channel through one.
public final class MachClient: @unchecked Sendable {
    /// What the client has been sent, as it stands now.
    public struct State: @unchecked Sendable {
        /// Each stack's three preview surfaces, with their size.
        public var previews: [Int: MachSurfaceSet] = [:]
        /// Each channel's three picture surfaces.
        public var pictures: [Int: MachSurfaceSet] = [:]
        /// The surface (0 to 2) that holds each stack's newest preview frame, and each channel's newest picture.
        public var newestPreview: [Int: Int] = [:]
        public var newestPicture: [Int: Int] = [:]
        /// The frame messages so far, in order, as (number, surface): the last `historyLimit` of them.
        public var previewFrames: [(stack: Int, slot: Int)] = []
        public var pictureFrames: [(channel: Int, slot: Int)] = []
        /// How many frame messages have arrived for each stack and each channel, since the connect.
        public var previewCounts: [Int: Int] = [:]
        public var pictureCounts: [Int: Int] = [:]
        /// The last meters frame, and how many have arrived.
        public var meters: [MeterReading] = []
        public var meterFrames = 0
        /// How many times each kind of surface set has arrived.
        public var previewSets = 0
        public var pictureSets = 0
        public var removed: [Int] = []
        /// What went wrong, for whoever asks why a tile is empty: every message that arrived, surface messages
        /// whose ports did not all hold a surface, frames named for a stack or channel whose surfaces never came,
        /// messages of another version or shape, and receives the kernel failed.
        public var messages = 0
        public var setsRefused = 0
        public var framesWithoutSurfaces = 0
        public var messagesRefused = 0
        public var receiveFailures = 0
    }

    /// How many frame messages of each kind the history keeps; a client that runs for hours, as the soak's does,
    /// holds no more.
    static let historyLimit = 4096

    private let service: any MachService
    private let lock = NSLock()
    private var held = State()
    private var port = MachPorts.null
    private let running = Atomic<Bool>(false)

    public init(service: any MachService = BootstrapMachService()) {
        self.service = service
    }

    deinit {
        disconnect()
    }

    /// Looks the engine's service up and connects. The client's port takes a
    /// long queue, so a burst of frames while it is busy isn't lost.
    public func connect(name: String) throws {
        let remote = try service.lookUp(name: name)
        defer { MachPorts.release(remote) }
        guard let own = MachPorts.makeReceive() else { throw MachProof.Failure.noPort }
        var limits = mach_port_limits_t(mpl_qlimit: 1024)
        _ = withUnsafeMutablePointer(to: &limits) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: 1) {
                mach_port_set_attributes(mach_task_self_, own, MACH_PORT_LIMITS_INFO, $0, mach_msg_type_number_t(MemoryLayout<mach_port_limits_t>.size / MemoryLayout<integer_t>.size))
            }
        }
        let sent = MachMessage.send(to: remote, id: MachWire.connect, reply: own, payload: MachMessage.words([MachWire.version]), timeoutMs: 1000)
        guard sent == KERN_SUCCESS else {
            MachPorts.destroyReceive(own)
            throw MachProof.Failure.send(sent)
        }
        lock.lock()
        port = own
        lock.unlock()
        running.store(true, ordering: .releasing)
        let thread = Thread { [weak self] in
            while let self, self.running.load(ordering: .relaxed) {
                switch MachMessage.receive(on: own, timeoutMs: 100, maxSize: 4096) {
                case .success(let message):
                    self.take(message)
                case .failure(let failure):
                    // A wait that ran out, or the port going at disconnect, is the ordinary case; anything else is counted.
                    if failure.code != MACH_RCV_TIMED_OUT, self.running.load(ordering: .relaxed) { self.count { $0.receiveFailures += 1 } }
                }
            }
        }
        thread.name = "o.mach.client"
        thread.start()
    }

    /// Lets the channel go: the client's port dies, and the engine's next send finds it gone.
    public func disconnect() {
        running.store(false, ordering: .releasing)
        lock.lock()
        let own = port
        port = MachPorts.null
        lock.unlock()
        MachPorts.destroyReceive(own)
    }

    /// What has arrived so far.
    public var state: State {
        lock.lock()
        defer { lock.unlock() }
        return held
    }

    /// The bytes (blue, green, red, alpha) of one pixel of a stack's newest
    /// finished preview frame, or of a channel's newest picture; nil before a
    /// frame has been named.
    public func previewPixel(stack: Int, x: Int, y: Int) -> [UInt8]? {
        let state = self.state
        guard let slot = state.newestPreview[stack], let set = state.previews[stack], slot < set.surfaces.count else { return nil }
        return Self.pixel(of: set.surfaces[slot], x: x, y: y)
    }

    public func picturePixel(channel: Int, x: Int, y: Int) -> [UInt8]? {
        let state = self.state
        guard let slot = state.newestPicture[channel], let set = state.pictures[channel], slot < set.surfaces.count else { return nil }
        return Self.pixel(of: set.surfaces[slot], x: x, y: y)
    }

    /// How many of a surface's pixels, sampled on a grid, are brighter than near-black: whether a preview or a
    /// picture shows anything, for a check by hand or by the soak.
    static func litSamples(of surface: IOSurfaceRef, step: Int = 8) -> Int {
        guard IOSurfaceLock(surface, .readOnly, nil) == KERN_SUCCESS else { return 0 }
        defer { IOSurfaceUnlock(surface, .readOnly, nil) }
        let width = IOSurfaceGetWidth(surface), height = IOSurfaceGetHeight(surface), rowBytes = IOSurfaceGetBytesPerRow(surface)
        guard rowBytes >= width * 4, step > 0 else { return 0 }
        let base = IOSurfaceGetBaseAddress(surface)
        var lit = 0
        for y in stride(from: step / 2, to: height, by: step) {
            for x in stride(from: step / 2, to: width, by: step) {
                let p = base.advanced(by: y * rowBytes + x * 4)
                if Int(p.load(as: UInt8.self)) + Int(p.load(fromByteOffset: 1, as: UInt8.self)) + Int(p.load(fromByteOffset: 2, as: UInt8.self)) > 90 { lit += 1 }
            }
        }
        return lit
    }

    /// What the client holds, in lines: for a person at a terminal (`oengine mach-watch`).
    public func report(seconds: Double) -> [String] {
        let state = self.state
        var lines: [String] = []
        for stack in state.previews.keys.sorted() {
            guard let set = state.previews[stack] else { continue }
            let frames = state.previewCounts[stack] ?? 0
            var line = "stack \(stack): three surfaces of \(set.width) by \(set.height); \(frames) frames named (\(String(format: "%.1f", Double(frames) / max(0.001, seconds))) a second)"
            if let slot = state.newestPreview[stack], slot < set.surfaces.count {
                line += "; the newest is surface \(slot) with \(Self.litSamples(of: set.surfaces[slot])) lit samples"
            }
            lines.append(line)
        }
        for channel in state.pictures.keys.sorted() {
            guard let set = state.pictures[channel] else { continue }
            let frames = state.pictureCounts[channel] ?? 0
            var line = "channel \(channel): three picture surfaces of \(set.width) by \(set.height); \(frames) pictures named (\(String(format: "%.1f", Double(frames) / max(0.001, seconds))) a second)"
            if let slot = state.newestPicture[channel], slot < set.surfaces.count {
                line += "; the newest is surface \(slot) with \(Self.litSamples(of: set.surfaces[slot])) lit samples"
            }
            lines.append(line)
        }
        let levels = state.meters.map { "channel \($0.channel) peak \(String(format: "%.1f", $0.peak)) dBFS, RMS \(String(format: "%.1f", $0.rms)) dBFS" }
        lines.append("meters: \(state.meterFrames) frames (\(String(format: "%.1f", Double(state.meterFrames) / max(0.001, seconds))) a second)" + (levels.isEmpty ? "; no channel has sound" : "; " + levels.joined(separator: "; ")))
        if !state.removed.isEmpty { lines.append("channels removed: \(state.removed)") }
        lines.append("\(state.messages) messages arrived" + (state.setsRefused + state.framesWithoutSurfaces + state.messagesRefused + state.receiveFailures == 0 ? ""
            : ": \(state.setsRefused) surface messages whose ports held no surface, \(state.framesWithoutSurfaces) frames named without surfaces, \(state.messagesRefused) of another version or shape, \(state.receiveFailures) receives failed"))
        return lines
    }

    private func count(_ change: (inout State) -> Void) {
        lock.lock()
        change(&held)
        lock.unlock()
    }

    static func pixel(of surface: IOSurfaceRef, x: Int, y: Int) -> [UInt8]? {
        guard IOSurfaceLock(surface, .readOnly, nil) == KERN_SUCCESS else { return nil }
        defer { IOSurfaceUnlock(surface, .readOnly, nil) }
        let width = IOSurfaceGetWidth(surface), height = IOSurfaceGetHeight(surface), rowBytes = IOSurfaceGetBytesPerRow(surface)
        guard x >= 0, y >= 0, x < width, y < height, rowBytes >= width * 4 else { return nil }
        return Array(UnsafeRawBufferPointer(start: IOSurfaceGetBaseAddress(surface).advanced(by: y * rowBytes + x * 4), count: 4))
    }

    private func take(_ message: MachMessage.Received) {
        defer {
            MachPorts.release(message.reply)
            message.ports.forEach(MachPorts.release)
        }
        count { $0.messages += 1 }
        guard MachMessage.word(message.payload, 0) == MachWire.version, let number = MachMessage.word(message.payload, 1).map({ Int($0) }) else {
            count { $0.messagesRefused += 1 }
            return
        }
        switch message.id {
        case MachWire.previewSurfaces, MachWire.pictureSurfaces:
            // The surfaces come out of their ports here; the ports themselves are given back above.
            let surfaces = message.ports.compactMap { IOSurfaceLookupFromMachPort($0) }
            guard !surfaces.isEmpty, surfaces.count == message.ports.count, let width = MachMessage.word(message.payload, 2),
                  let height = MachMessage.word(message.payload, 3) else {
                count { $0.setsRefused += 1 }
                return
            }
            let set = MachSurfaceSet(number: number, width: Int(width), height: Int(height), surfaces: surfaces)
            lock.lock()
            if message.id == MachWire.previewSurfaces {
                held.previews[number] = set
                held.newestPreview[number] = nil
                held.previewSets += 1
            } else {
                held.pictures[number] = set
                held.newestPicture[number] = nil
                held.pictureSets += 1
            }
            lock.unlock()
        case MachWire.previewFrame, MachWire.pictureFrame:
            guard let slot = MachMessage.word(message.payload, 2).map({ Int($0) }) else { return }
            lock.lock()
            if (message.id == MachWire.previewFrame ? held.previews[number] : held.pictures[number]) == nil { held.framesWithoutSurfaces += 1 }
            if message.id == MachWire.previewFrame {
                held.newestPreview[number] = slot
                held.previewCounts[number, default: 0] += 1
                held.previewFrames.append((number, slot))
                if held.previewFrames.count > Self.historyLimit { held.previewFrames.removeFirst(Self.historyLimit / 2) }
            } else {
                held.newestPicture[number] = slot
                held.pictureCounts[number, default: 0] += 1
                held.pictureFrames.append((number, slot))
                if held.pictureFrames.count > Self.historyLimit { held.pictureFrames.removeFirst(Self.historyLimit / 2) }
            }
            lock.unlock()
        case MachWire.channelRemoved:
            lock.lock()
            held.pictures[number] = nil
            held.newestPicture[number] = nil
            held.removed.append(number)
            lock.unlock()
        case MachWire.meters:
            // Word 1 is the count here, then three words a channel.
            var readings: [MeterReading] = []
            for index in 0..<number {
                guard let channel = MachMessage.word(message.payload, 2 + index * 3), let peak = MachMessage.word(message.payload, 3 + index * 3),
                      let rms = MachMessage.word(message.payload, 4 + index * 3) else { break }
                readings.append(MeterReading(channel: Int(channel), peak: Float(bitPattern: peak), rms: Float(bitPattern: rms)))
            }
            lock.lock()
            held.meters = readings
            held.meterFrames += 1
            lock.unlock()
        default:
            break
        }
    }
}
