// OCore — Spec 2 §6, OSC on the wire: the OSC 1.0 packet codec as pure
// functions over bytes. The socket is the engine's (Spec 4); nothing here
// reads or writes one.

import Foundation

/// Why bytes did not decode. Unknown input is an error value, never a trap
/// (CLAUDE.md, hard rules).
public enum OSCDecodeError: Error, Equatable, Sendable {
    case empty
    case truncated
    case badAddress
    case badTypeTags
    case unsupportedType(String)
    case badString
    case badBundle
    case trailingBytes
}

extension OSCMessage {
    /// The OSC 1.0 bytes: the address, the type tag string, the arguments,
    /// each padded to four bytes, numbers big-endian.
    public func encoded() -> Data {
        var out: [UInt8] = []
        OSCWire.write(self, into: &out)
        return Data(out)
    }
}

extension OSCBundle {
    /// `#bundle`, the time tag, then each element with its size in front.
    public func encoded() -> Data {
        var out: [UInt8] = []
        OSCWire.write(self, into: &out)
        return Data(out)
    }
}

extension OSCPacket {
    public func encoded() -> Data {
        switch self {
        case .message(let message): return message.encoded()
        case .bundle(let bundle): return bundle.encoded()
        }
    }

    /// The packet in `data`, or why there is none.
    public static func decode(_ data: Data) -> Result<OSCPacket, OSCDecodeError> {
        var reader = OSCReader(bytes: [UInt8](data))
        do {
            let packet = try reader.readPacket()
            guard reader.atEnd else { return .failure(.trailingBytes) }
            return .success(packet)
        } catch let error as OSCDecodeError {
            return .failure(error)
        } catch {
            return .failure(.truncated)
        }
    }
}

enum OSCWire {
    static func pad(_ out: inout [UInt8]) {
        while out.count % 4 != 0 { out.append(0) }
    }

    static func writeString(_ s: String, into out: inout [UInt8]) {
        out.append(contentsOf: Array(s.utf8))
        out.append(0)
        pad(&out)
    }

    static func writeUInt32(_ value: UInt32, into out: inout [UInt8]) {
        out.append(UInt8(truncatingIfNeeded: value >> 24))
        out.append(UInt8(truncatingIfNeeded: value >> 16))
        out.append(UInt8(truncatingIfNeeded: value >> 8))
        out.append(UInt8(truncatingIfNeeded: value))
    }

    static func writeUInt64(_ value: UInt64, into out: inout [UInt8]) {
        writeUInt32(UInt32(truncatingIfNeeded: value >> 32), into: &out)
        writeUInt32(UInt32(truncatingIfNeeded: value), into: &out)
    }

    static func tag(_ argument: OSCArgument) -> Character {
        switch argument {
        case .int32: return "i"
        case .float32: return "f"
        case .string: return "s"
        case .blob: return "b"
        case .int64: return "h"
        case .double: return "d"
        case .timetag: return "t"
        case .bool(let b): return b ? "T" : "F"
        case .null: return "N"
        case .impulse: return "I"
        }
    }

    static func write(_ message: OSCMessage, into out: inout [UInt8]) {
        writeString(message.address, into: &out)
        writeString("," + String(message.arguments.map(tag)), into: &out)
        for argument in message.arguments {
            switch argument {
            case .int32(let n): writeUInt32(UInt32(bitPattern: n), into: &out)
            case .float32(let x): writeUInt32(x.bitPattern, into: &out)
            case .string(let s): writeString(s, into: &out)
            case .blob(let data):
                writeUInt32(UInt32(truncatingIfNeeded: data.count), into: &out)
                out.append(contentsOf: [UInt8](data))
                pad(&out)
            case .int64(let n): writeUInt64(UInt64(bitPattern: n), into: &out)
            case .double(let x): writeUInt64(x.bitPattern, into: &out)
            case .timetag(let t): writeUInt64(t, into: &out)
            case .bool, .null, .impulse: break
            }
        }
    }

    static func write(_ bundle: OSCBundle, into out: inout [UInt8]) {
        writeString("#bundle", into: &out)
        writeUInt64(bundle.timetag, into: &out)
        for element in bundle.elements {
            var inner: [UInt8] = []
            switch element {
            case .message(let message): write(message, into: &inner)
            case .bundle(let nested): write(nested, into: &inner)
            }
            writeUInt32(UInt32(truncatingIfNeeded: inner.count), into: &out)
            out.append(contentsOf: inner)
        }
    }
}

/// A bounds-checked cursor over the bytes of one packet.
struct OSCReader {
    let bytes: [UInt8]
    var index = 0

    var atEnd: Bool { index >= bytes.count }
    var remaining: Int { bytes.count - index }

    mutating func readPacket() throws -> OSCPacket {
        guard !bytes.isEmpty else { throw OSCDecodeError.empty }
        if bytes[index] == UInt8(ascii: "#") {
            return .bundle(try readBundle())
        }
        return .message(try readMessage())
    }

    mutating func readMessage() throws -> OSCMessage {
        let address = try readString()
        guard address.hasPrefix("/") else { throw OSCDecodeError.badAddress }
        guard !atEnd else { return OSCMessage(address) }
        let tags = try readString()
        guard tags.hasPrefix(",") else { throw OSCDecodeError.badTypeTags }
        var arguments: [OSCArgument] = []
        for tag in tags.dropFirst() {
            switch tag {
            case "i": arguments.append(.int32(Int32(bitPattern: try readUInt32())))
            case "f": arguments.append(.float32(Float(bitPattern: try readUInt32())))
            case "s": arguments.append(.string(try readString()))
            case "b": arguments.append(.blob(try readBlob()))
            case "h": arguments.append(.int64(Int64(bitPattern: try readUInt64())))
            case "d": arguments.append(.double(Double(bitPattern: try readUInt64())))
            case "t": arguments.append(.timetag(try readUInt64()))
            case "T": arguments.append(.bool(true))
            case "F": arguments.append(.bool(false))
            case "N": arguments.append(.null)
            case "I": arguments.append(.impulse)
            default: throw OSCDecodeError.unsupportedType(String(tag))
            }
        }
        return OSCMessage(address, arguments)
    }

    mutating func readBundle() throws -> OSCBundle {
        let header: [UInt8] = Array("#bundle".utf8) + [0]
        guard remaining >= header.count, Array(bytes[index..<(index + header.count)]) == header else {
            throw OSCDecodeError.badBundle
        }
        index += header.count
        let timetag = try readUInt64()
        var elements: [OSCPacket] = []
        while !atEnd {
            let size = Int(Int32(bitPattern: try readUInt32()))
            guard size >= 0, size <= remaining else { throw OSCDecodeError.truncated }
            var inner = OSCReader(bytes: Array(bytes[index..<(index + size)]))
            guard let packet = try? inner.readPacket(), inner.atEnd else { throw OSCDecodeError.badBundle }
            elements.append(packet)
            index += size
        }
        return OSCBundle(timetag: timetag, elements: elements)
    }

    // MARK: - Primitives

    mutating func skipPadding() throws {
        while index % 4 != 0 {
            guard index < bytes.count else { throw OSCDecodeError.truncated }
            index += 1
        }
    }

    mutating func readString() throws -> String {
        guard let terminator = bytes[index...].firstIndex(of: 0) else { throw OSCDecodeError.truncated }
        guard let string = String(bytes: bytes[index..<terminator], encoding: .utf8) else { throw OSCDecodeError.badString }
        index = terminator + 1
        try skipPadding()
        return string
    }

    mutating func readUInt32() throws -> UInt32 {
        guard remaining >= 4 else { throw OSCDecodeError.truncated }
        var value: UInt32 = 0
        for _ in 0..<4 {
            value = (value << 8) | UInt32(bytes[index])
            index += 1
        }
        return value
    }

    mutating func readUInt64() throws -> UInt64 {
        let high = UInt64(try readUInt32())
        let low = UInt64(try readUInt32())
        return (high << 32) | low
    }

    mutating func readBlob() throws -> Data {
        let size = Int(Int32(bitPattern: try readUInt32()))
        guard size >= 0, size <= remaining else { throw OSCDecodeError.truncated }
        let data = Data(bytes[index..<(index + size)])
        index += size
        try skipPadding()
        return data
    }
}
