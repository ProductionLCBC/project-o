// OEngine — Spec 10 §2, the proof of the Mach call (Area 19's first stop for review).

@preconcurrency import Darwin
import Foundation
import IOSurface

/// Spec 10 §2 — "Area 19 proves the call on the dev Mac at its first stop for
/// review; if neither works there, a per-user launchd agent that declares the
/// name takes their place, and this section is corrected." Spec 10 §18 — "The
/// service named in `hello` resolves on the dev Mac (the first stop for
/// review), also from an app that didn't start the engine".
///
/// The proof is the Mach channel at its smallest: the serving side registers
/// a name and answers one message with one IOSurface sent as a Mach port; the
/// other side looks the name up, asks, and reads the surface's pixels. It
/// opens no screen, output or audio device. `oengine mach-proof` runs each
/// side in a process of its own, and `scripts/mach-proof.sh` the whole of it.
public enum MachProof {
    public static let surfaceWidth = 16
    public static let surfaceHeight = 9
    /// Every pixel of the proof's surface, as its bytes lie in memory: blue, green, red, alpha.
    public static let pixel: [UInt8] = [0x11, 0x22, 0x33, 0xFF]

    static let connectID: mach_msg_id_t = 0x4F01
    static let surfaceID: mach_msg_id_t = 0x4F02
    static let version: UInt32 = 1

    /// What the looking-up side read: which call registered the service, the
    /// surface's size and its first and last pixels, the serving process, and
    /// the process and user the serving side saw in the message's audit token.
    public struct Reading: Equatable, Sendable {
        public var call: MachRegistration.Call
        public var width: Int
        public var height: Int
        public var firstPixel: [UInt8]
        public var lastPixel: [UInt8]
        public var serverPID: pid_t
        public var seenPID: pid_t
        public var seenUID: uid_t
    }

    /// Who the serving side answered, from the kernel's audit token.
    public struct Caller: Equatable, Sendable {
        public var pid: pid_t
        public var uid: uid_t
    }

    public enum Failure: Error, Equatable, CustomStringConvertible {
        case noPort
        case noSurface
        case send(kern_return_t)
        case receive(kern_return_t)
        case malformed(String)

        public var description: String {
            switch self {
            case .noPort: return "the kernel gave no port"
            case .noSurface: return "no surface came through the port"
            case .send(let code): return "mach_msg send failed (\(code))"
            case .receive(let code): return code == MACH_RCV_TIMED_OUT ? "no answer in time" : "mach_msg receive failed (\(code))"
            case .malformed(let what): return "an unexpected message: \(what)"
            }
        }
    }

    /// The serving side: waits up to `timeoutMs` for one message on the
    /// service's port and answers it with a new surface, sent as a Mach port.
    @discardableResult
    public static func answerOne(on registration: MachRegistration, timeoutMs: UInt32) -> Result<Caller, Failure> {
        let message: MachMessage.Received
        switch MachMessage.receive(on: registration.port, timeoutMs: timeoutMs) {
        case .failure(let failure): return .failure(.receive(failure.code))
        case .success(let received): message = received
        }
        defer {
            MachPorts.release(message.reply)
            message.ports.forEach(MachPorts.release)
        }
        guard message.id == connectID, message.reply != MachPorts.null else { return .failure(.malformed("id \(message.id)")) }
        guard let surface = makeSurface() else { return .failure(.noSurface) }
        // The port holds the surface, so it outlives this function's own reference.
        let port = IOSurfaceCreateMachPort(surface)
        guard port != MachPorts.null else { return .failure(.noPort) }
        let payload = MachMessage.words([version, registration.call == .checkIn ? 1 : 2, UInt32(surfaceWidth), UInt32(surfaceHeight),
                                         UInt32(bitPattern: getpid()), UInt32(bitPattern: message.senderPID), message.senderUID])
        let code = MachMessage.send(to: message.reply, id: surfaceID, moving: [port], payload: payload, timeoutMs: 1000)
        guard code == KERN_SUCCESS else { return .failure(.send(code)) }
        return .success(Caller(pid: message.senderPID, uid: message.senderUID))
    }

    /// The looking-up side, as the operator app will do it: the name looked
    /// up in the bootstrap namespace, one message with a reply port, and the
    /// surface that comes back read through its Mach port.
    public static func lookUp(name: String, service: any MachService = BootstrapMachService(), timeoutMs: UInt32 = 5000) throws -> Reading {
        let remote = try service.lookUp(name: name)
        defer { MachPorts.release(remote) }
        guard let reply = MachPorts.makeReceive() else { throw Failure.noPort }
        defer { MachPorts.destroyReceive(reply) }

        let sent = MachMessage.send(to: remote, id: connectID, reply: reply, payload: MachMessage.words([version]), timeoutMs: timeoutMs)
        guard sent == KERN_SUCCESS else { throw Failure.send(sent) }
        let message: MachMessage.Received
        switch MachMessage.receive(on: reply, timeoutMs: timeoutMs) {
        case .failure(let failure): throw Failure.receive(failure.code)
        case .success(let received): message = received
        }
        defer {
            MachPorts.release(message.reply)
            message.ports.forEach(MachPorts.release)
        }
        guard message.id == surfaceID, let port = message.ports.first else { throw Failure.malformed("id \(message.id), \(message.ports.count) ports") }
        guard MachMessage.word(message.payload, 0) == version, let call = MachMessage.word(message.payload, 1),
              let serverPID = MachMessage.word(message.payload, 4), let seenPID = MachMessage.word(message.payload, 5),
              let seenUID = MachMessage.word(message.payload, 6) else { throw Failure.malformed("\(message.payload.count) bytes") }
        guard let surface = IOSurfaceLookupFromMachPort(port) else { throw Failure.noSurface }

        guard IOSurfaceLock(surface, .readOnly, nil) == KERN_SUCCESS else { throw Failure.noSurface }
        defer { IOSurfaceUnlock(surface, .readOnly, nil) }
        let width = IOSurfaceGetWidth(surface), height = IOSurfaceGetHeight(surface), rowBytes = IOSurfaceGetBytesPerRow(surface)
        guard width > 0, height > 0, rowBytes >= width * 4 else { throw Failure.noSurface }
        let base = IOSurfaceGetBaseAddress(surface)
        func pixel(_ x: Int, _ y: Int) -> [UInt8] {
            Array(UnsafeRawBufferPointer(start: base.advanced(by: y * rowBytes + x * 4), count: 4))
        }
        return Reading(call: call == 1 ? .checkIn : .register, width: width, height: height, firstPixel: pixel(0, 0),
                       lastPixel: pixel(width - 1, height - 1), serverPID: pid_t(bitPattern: serverPID),
                       seenPID: pid_t(bitPattern: seenPID), seenUID: seenUID)
    }

    /// A BGRA surface as the previews are (Spec 4 §10), every pixel `pixel`.
    static func makeSurface() -> IOSurfaceRef? {
        let properties: [IOSurfacePropertyKey: Any] = [
            .width: surfaceWidth,
            .height: surfaceHeight,
            .bytesPerElement: 4,
            .pixelFormat: UInt32(0x42475241),   // 'BGRA'
        ]
        guard let surface = IOSurface(properties: properties) else { return nil }
        guard IOSurfaceLock(surface, [], nil) == KERN_SUCCESS else { return nil }
        defer { IOSurfaceUnlock(surface, [], nil) }
        let base = IOSurfaceGetBaseAddress(surface), rowBytes = IOSurfaceGetBytesPerRow(surface)
        for y in 0..<surfaceHeight {
            for x in 0..<surfaceWidth {
                for (index, byte) in pixel.enumerated() {
                    base.storeBytes(of: byte, toByteOffset: y * rowBytes + x * 4 + index, as: UInt8.self)
                }
            }
        }
        return surface
    }
}
