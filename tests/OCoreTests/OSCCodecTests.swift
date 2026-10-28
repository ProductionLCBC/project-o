import Foundation
import XCTest
@testable import OCore

/// Spec 2 §6 — OSC on the wire, as pure functions (no sockets in `core/`):
/// OSC 1.0 messages (address, type tags, 4-byte aligned arguments, big-endian)
/// and bundles (`#bundle`, a time tag, size-prefixed elements). Decoding
/// never traps on bad bytes: unknown input is a rejection and a log line
/// (CLAUDE.md, hard rules).
final class OSCCodecTests: XCTestCase {
    func bytes(_ data: Data) -> [UInt8] { [UInt8](data) }

    /// A string as OSC writes it: UTF-8, a NUL, padded to four bytes.
    func padded(_ s: String) -> [UInt8] {
        var out: [UInt8] = Array(s.utf8)
        out.append(0)
        while out.count % 4 != 0 { out.append(0) }
        return out
    }

    func test_aMessageEncodesToTheOSC10Layout() {
        let message = OSCMessage("/o/channel/2/grade", [.int32(5)])
        let grade: [UInt8] = padded("/o/channel/2/grade") + padded(",i") + [0, 0, 0, 5]
        XCTAssertEqual(padded("/o/channel/2/grade").count, 20, "18 characters, a NUL, one pad byte")
        XCTAssertEqual(bytes(message.encoded()), grade)
        let next: [UInt8] = padded("/o/next") + padded(",")
        XCTAssertEqual(bytes(OSCMessage("/o/next").encoded()), next)
        let blackout: [UInt8] = padded("/o/stack/2/blackout") + padded(",s") + padded("toggle")
        XCTAssertEqual(bytes(OSCMessage("/o/stack/2/blackout", [.string("toggle")]).encoded()), blackout)
        let gain: [UInt8] = padded("/o/channel/2/gain") + padded(",f") + [0x3F, 0xC0, 0x00, 0x00]
        XCTAssertEqual(bytes(OSCMessage("/o/channel/2/gain", [.float32(1.5)]).encoded()), gain)
        let blob: [UInt8] = padded("/o/x") + padded(",b") + [0, 0, 0, 3, 1, 2, 3, 0]
        XCTAssertEqual(bytes(OSCMessage("/o/x", [.blob(Data([1, 2, 3]))]).encoded()), blob)
        let flags: [UInt8] = padded("/o/x") + padded(",TFNI")
        XCTAssertEqual(bytes(OSCMessage("/o/x", [.bool(true), .bool(false), .null, .impulse]).encoded()), flags)
    }

    func test_everyArgumentTypeRoundTrips() {
        let message = OSCMessage("/o/everything", [
            .int32(-5), .float32(0.25), .string("héllo"), .blob(Data([9, 8, 7, 6, 5])), .int64(1 << 40),
            .double(-6.1), .timetag(0x0123_4567_89AB_CDEF), .bool(true), .bool(false), .null, .impulse, .string(""),
        ])
        XCTAssertEqual(try OSCPacket.decode(message.encoded()).get(), .message(message))
        XCTAssertEqual(try OSCPacket.decode(OSCPacket.message(message).encoded()).get(), .message(message))
    }

    func test_bundlesEncodeAndDecode() {
        let inner = OSCBundle(timetag: 42, elements: [.message(OSCMessage("/o/next"))])
        let bundle = OSCBundle(elements: [.message(OSCMessage("/o/channel/1/clear")), .bundle(inner)])
        let data = bundle.encoded()
        let next = bytes(OSCMessage("/o/next").encoded())
        let clear = bytes(OSCMessage("/o/channel/1/clear").encoded())
        let header: [UInt8] = padded("#bundle")
        XCTAssertEqual(header.count, 8)
        var innerData: [UInt8] = header + [0, 0, 0, 0, 0, 0, 0, 42]
        innerData += [0, 0, 0, UInt8(next.count)] + next
        var expected: [UInt8] = header + [0, 0, 0, 0, 0, 0, 0, 1]
        expected += [0, 0, 0, UInt8(clear.count)] + clear
        expected += [0, 0, 0, UInt8(innerData.count)] + innerData
        XCTAssertEqual(bytes(data), expected)
        XCTAssertEqual(OSCBundle().timetag, 1, "the immediate time tag")
        XCTAssertEqual(try OSCPacket.decode(data).get(), .bundle(bundle))
        XCTAssertEqual(try OSCPacket.decode(OSCBundle().encoded()).get(), .bundle(OSCBundle()))
    }

    func test_aMessageWithoutTypeTagsHasNoArguments() {
        // OSC 1.0 made the type tag string optional; old senders omit it.
        let data = Data(padded("/o/next"))
        XCTAssertEqual(try OSCPacket.decode(data).get(), .message(OSCMessage("/o/next")))
    }

    func test_badBytesAreErrorsNotTraps() {
        func error(_ bytes: [UInt8], file: StaticString = #filePath, line: UInt = #line) -> OSCDecodeError? {
            switch OSCPacket.decode(Data(bytes)) {
            case .success(let packet):
                XCTFail("\(bytes) decoded as \(packet)", file: file, line: line)
                return nil
            case .failure(let error):
                return error
            }
        }
        let next: [UInt8] = padded("/o/next")
        let bundle: [UInt8] = padded("#bundle")
        let immediately: [UInt8] = [0, 0, 0, 0, 0, 0, 0, 1]
        XCTAssertEqual(error([]), .empty)
        XCTAssertEqual(error(padded("o/next")), .badAddress)
        XCTAssertEqual(error(Array("/o/next".utf8)), .truncated)                        // no terminator
        XCTAssertEqual(error(next + padded("i")), .badTypeTags)
        XCTAssertEqual(error(next + padded(",x")), .unsupportedType("x"))
        XCTAssertEqual(error(next + padded(",i") + [0, 0]), .truncated)
        XCTAssertEqual(error(next + padded(",s") + Array("abc".utf8)), .truncated)
        XCTAssertEqual(error(next + padded(",b") + [0, 0, 0, 9, 1]), .truncated)
        XCTAssertEqual(error(next + padded(",") + [7]), .trailingBytes)
        XCTAssertEqual(error(bundle + [0, 0, 0, 0]), .truncated)
        XCTAssertEqual(error(bundle + immediately + [0, 0, 0, 9] + [0]), .truncated)
        XCTAssertEqual(error(bundle + immediately + [0, 0, 0, 2] + [0, 0]), .badBundle)
        XCTAssertEqual(error(next + padded(",s") + [0xFF, 0xFE, 0, 0]), .badString)

        // Nothing in a random packet may trap.
        var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
        func randomByte() -> UInt8 {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return UInt8(truncatingIfNeeded: seed >> 33)
        }
        for _ in 0..<500 {
            let length = Int(randomByte() % 64)
            var junk = (0..<length).map { _ in randomByte() }
            if junk.first == 0x2F || junk.first == 0x23 { junk[0] = 0x2F }
            _ = OSCPacket.decode(Data(junk))
        }
    }
}
