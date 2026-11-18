// OMach — Spec 10 §2, one message on the Mach channel, laid out by hand.

@preconcurrency import Darwin
import Foundation

/// Spec 10 §2 — "The Mach channel carries what is too frequent or too large
/// for the socket". A Mach message is a header, then (when it carries ports)
/// a count and one descriptor per port, then the message's own bytes. The
/// layout is written and read at fixed offsets in a raw buffer, never through
/// a Swift struct, so it is the kernel's layout whatever the compiler does.
///
/// Visible to this package's targets and to nothing outside it: the engine's
/// end of the channel (`MachChannel`, in OEngine) and the client's (here)
/// write and read the same layout through this one type.
package enum MachMessage {
    package static let headerSize = MemoryLayout<mach_msg_header_t>.size
    package static let countSize = MemoryLayout<mach_msg_body_t>.size
    package static let descriptorSize = MemoryLayout<mach_msg_port_descriptor_t>.size
    package static let trailerSize = MemoryLayout<mach_msg_audit_trailer_t>.size
    /// `MACH_MSGH_BITS_COMPLEX`: the message carries port descriptors.
    package static let complexBit: mach_msg_bits_t = 0x8000_0000
    /// `MACH_RCV_TRAILER_ELEMENTS(MACH_RCV_TRAILER_AUDIT)`: the kernel appends who sent the message.
    package static let auditTrailer: mach_msg_option_t = 3 << 24

    /// A message as it arrived: its id, the port to answer on, the ports it
    /// carried, its bytes, and the sender's process and user from the
    /// kernel's audit token, which a sender cannot forge.
    package struct Received {
        package var id: mach_msg_id_t
        /// A send right to the sender's reply port, or null; the receiver releases it.
        package var reply: mach_port_t
        /// The rights the message carried, in order; the receiver releases them.
        package var ports: [mach_port_t]
        package var payload: [UInt8]
        package var senderPID: pid_t
        package var senderUID: uid_t
    }

    /// Sends one message to `remote`: `id`, a reply port of the sender's own
    /// (the receiver gets a send right to it), the send rights in `moving`
    /// (handed over; given back here if the message doesn't go) and `payload`.
    /// It never waits longer than `timeoutMs` for room in the receiver's
    /// queue; zero means not at all. The kernel's code.
    package static func send(to remote: mach_port_t, id: mach_msg_id_t, reply: mach_port_t = MachPorts.null, moving ports: [mach_port_t] = [],
                     payload: [UInt8] = [], timeoutMs: mach_msg_timeout_t) -> kern_return_t {
        let descriptors = ports.isEmpty ? 0 : countSize + descriptorSize * ports.count
        let size = (headerSize + descriptors + payload.count + 3) & ~3
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 8)
        defer { buffer.deallocate() }
        buffer.initializeMemory(as: UInt8.self, repeating: 0, count: size)

        var header = mach_msg_header_t()
        // MACH_MSGH_BITS(remote, local): the destination as a copied send right, the reply port as a send right made from ours.
        header.msgh_bits = mach_msg_bits_t(MACH_MSG_TYPE_COPY_SEND)
            | (reply == MachPorts.null ? 0 : mach_msg_bits_t(MACH_MSG_TYPE_MAKE_SEND) << 8)
            | (ports.isEmpty ? 0 : complexBit)
        header.msgh_size = mach_msg_size_t(size)
        header.msgh_remote_port = remote
        header.msgh_local_port = reply
        header.msgh_id = id
        buffer.storeBytes(of: header, as: mach_msg_header_t.self)

        var offset = headerSize
        if !ports.isEmpty {
            buffer.storeBytes(of: UInt32(ports.count), toByteOffset: offset, as: UInt32.self)
            offset += countSize
            for port in ports {
                var descriptor = mach_msg_port_descriptor_t()
                descriptor.name = port
                descriptor.disposition = mach_msg_type_name_t(MACH_MSG_TYPE_MOVE_SEND)
                descriptor.type = mach_msg_descriptor_type_t(MACH_MSG_PORT_DESCRIPTOR)
                buffer.storeBytes(of: descriptor, toByteOffset: offset, as: mach_msg_port_descriptor_t.self)
                offset += descriptorSize
            }
        }
        payload.withUnsafeBytes { bytes in
            if let base = bytes.baseAddress { buffer.advanced(by: offset).copyMemory(from: base, byteCount: bytes.count) }
        }

        let code = mach_msg(buffer.assumingMemoryBound(to: mach_msg_header_t.self), MACH_SEND_MSG | MACH_SEND_TIMEOUT,
                            mach_msg_size_t(size), 0, MachPorts.null, timeoutMs, MachPorts.null)
        // A message that didn't go leaves its rights with the sender: give them back, or each failed send leaks a port.
        if code != KERN_SUCCESS { ports.forEach(MachPorts.release) }
        return code
    }

    /// Receives one message on `port`, waiting at most `timeoutMs`; a message
    /// larger than `maxSize` is an error. The kernel's code on failure.
    package static func receive(on port: mach_port_t, timeoutMs: mach_msg_timeout_t, maxSize: Int = 1024) -> Result<Received, MachReceiveFailure> {
        let capacity = ((maxSize + 3) & ~3) + trailerSize
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: 8)
        defer { buffer.deallocate() }
        buffer.initializeMemory(as: UInt8.self, repeating: 0, count: capacity)

        let code = mach_msg(buffer.assumingMemoryBound(to: mach_msg_header_t.self), MACH_RCV_MSG | MACH_RCV_TIMEOUT | auditTrailer,
                            0, mach_msg_size_t(capacity), port, timeoutMs, MachPorts.null)
        guard code == KERN_SUCCESS else { return .failure(MachReceiveFailure(code: code)) }

        let header = buffer.loadUnaligned(as: mach_msg_header_t.self)
        let size = Int(header.msgh_size)
        guard size >= headerSize, size + trailerSize <= capacity else { return .failure(MachReceiveFailure(code: MACH_RCV_TOO_LARGE)) }
        var offset = headerSize
        var ports: [mach_port_t] = []
        if header.msgh_bits & complexBit != 0, size >= offset + countSize {
            let count = Int(buffer.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
            offset += countSize
            for _ in 0..<count where size >= offset + descriptorSize {
                ports.append(buffer.loadUnaligned(fromByteOffset: offset, as: mach_msg_port_descriptor_t.self).name)
                offset += descriptorSize
            }
        }
        let payload = Array(UnsafeRawBufferPointer(start: buffer.advanced(by: offset), count: max(0, size - offset)))
        // The trailer follows the message, on a four-byte boundary. Its audit token holds the sender's
        // effective user at index 1 and its process at index 5 (bsm/libbsm.h).
        let trailer = buffer.loadUnaligned(fromByteOffset: (size + 3) & ~3, as: mach_msg_audit_trailer_t.self)
        return .success(Received(id: header.msgh_id, reply: header.msgh_remote_port, ports: ports, payload: payload,
                                 senderPID: pid_t(bitPattern: trailer.msgh_audit.val.5), senderUID: trailer.msgh_audit.val.1))
    }

    /// Little-endian 32-bit words, as every message's own bytes are written.
    package static func words(_ values: [UInt32]) -> [UInt8] {
        values.flatMap { value in (0..<4).map { UInt8(truncatingIfNeeded: value >> (8 * UInt32($0))) } }
    }

    /// The 32-bit word at `index` of a message's bytes, or nil past its end.
    package static func word(_ payload: [UInt8], _ index: Int) -> UInt32? {
        let start = index * 4
        guard start >= 0, payload.count >= start + 4 else { return nil }
        return (0..<4).reduce(UInt32(0)) { $0 | UInt32(payload[start + $1]) << (8 * UInt32($1)) }
    }
}

/// A receive that didn't produce a message: the kernel's code, such as
/// `MACH_RCV_TIMED_OUT`.
package struct MachReceiveFailure: Error, Equatable, CustomStringConvertible {
    package var code: kern_return_t

    package var timedOut: Bool { code == MACH_RCV_TIMED_OUT }

    package var description: String { "mach_msg receive failed (\(code))" }
}
