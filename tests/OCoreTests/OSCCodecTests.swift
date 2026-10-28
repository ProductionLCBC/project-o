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

    func test_aMessageEncodesToTheOSC10Layout() {
        let message = OSCMessage("/o/channel/2/grade", [.int32(5)])
        XCTAssertEqual(bytes(message.encoded()),
                       Array("/o/channel/2/grade".utf8) + [0, 0]        // 18 + 2 NULs = 20
                       + Array(",i".utf8) + [0, 0]                       // 2 + 2 NULs = 4
                       + [0, 0, 0, 5])
        XCTAssertEqual(bytes(OSCMessage("/o/next").encoded()), Array("/o/next".utf8) + [0] + Array(",".utf8) + [0, 0, 0])
        XCTAssertEqual(bytes(OSCMessage("/o/stack/2/blackout", [.string("toggle")]).encoded()),
                       Array("/o/stack/2/blackout".utf8) + [0]            // 19 + 1
                       + Array(",s".utf8) + [0, 0]
                       + Array("toggle".utf8) + [0, 0])                  // 6 + 2
        XCTAssertEqual(bytes(OSCMessage("/o/channel/2/gain", [.float32(1.5)]).encoded()),
                       Array("/o/channel/2/gain".utf8) + [0, 0, 0]        // 17 + 3
                       + Array(",f".utf8) + [0, 0]
                       + [0x3F, 0xC0, 0x00, 0x00])
        XCTAssertEqual(bytes(OSCMessage("/o/x", [.blob(Data([1, 2, 3]))]).encoded()),
                       Array("/o/x".utf8) + [0, 0, 0, 0]
                       + Array(",b".utf8) + [0, 0]
                       + [0, 0, 0, 3, 1, 2, 3, 0])
        XCTAssertEqual(bytes(OSCMessage("/o/x", [.bool(true), .bool(false), .null, .impulse]).encoded()),
                       Array("/o/x".utf8) + [0, 0, 0, 0] + Array(",TFNI".utf8) + [0, 0, 0])
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
        let next = OSCMessage("/o/next").encoded()
        let clear = OSCMessage("/o/channel/1/clear").encoded()
        let innerData = Array("#bundle".utf8) + [0] + [0, 0, 0, 0, 0, 0, 0, 42] + [0, 0, 0, UInt8(next.count)] + bytes(next)
        XCTAssertEqual(bytes(data),
                       Array("#bundle".utf8) + [0] + [0, 0, 0, 0, 0, 0, 0, 1]
                       + [0, 0, 0, UInt8(clear.count)] + bytes(clear)
                       + [0, 0, 0, UInt8(innerData.count)] + innerData)
        XCTAssertEqual(OSCBundle().timetag, 1, "the immediate time tag")
        XCTAssertEqual(try OSCPacket.decode(data).get(), .bundle(bundle))
        XCTAssertEqual(try OSCPacket.decode(OSCBundle().encoded()).get(), .bundle(OSCBundle()))
    }

    func test_aMessageWithoutTypeTagsHasNoArguments() {
        // OSC 1.0 made the type tag string optional; old senders omit it.
        let data = Data(Array("/o/next".utf8) + [0])
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
        XCTAssertEqual(error([]), .empty)
        XCTAssertEqual(error(Array("o/next".utf8) + [0, 0]), .badAddress)
        XCTAssertEqual(error(Array("/o/next".utf8)), .truncated)                        // no terminator
        XCTAssertEqual(error(Array("/o/next".utf8) + [0] + Array("i".utf8) + [0, 0, 0]), .badTypeTags)
        XCTAssertEqual(error(Array("/o/next".utf8) + [0] + Array(",x".utf8) + [0, 0]), .unsupportedType("x"))
        XCTAssertEqual(error(Array("/o/next".utf8) + [0] + Array(",i".utf8) + [0, 0] + [0, 0]), .truncated)
        XCTAssertEqual(error(Array("/o/next".utf8) + [0] + Array(",s".utf8) + [0, 0] + Array("abc".utf8)), .truncated)
        XCTAssertEqual(error(Array("/o/next".utf8) + [0] + Array(",b".utf8) + [0, 0] + [0, 0, 0, 9, 1]), .truncated)
        XCTAssertEqual(error(Array("/o/next".utf8) + [0] + Array(",".utf8) + [0, 0, 0] + [7]), .trailingBytes)
        XCTAssertEqual(error(Array("#bundle".utf8) + [0] + [0, 0, 0, 0]), .truncated)
        XCTAssertEqual(error(Array("#bundle".utf8) + [0] + [0, 0, 0, 0, 0, 0, 0, 1] + [0, 0, 0, 9] + [0]), .truncated)
        XCTAssertEqual(error(Array("#bundle".utf8) + [0] + [0, 0, 0, 0, 0, 0, 0, 1] + [0, 0, 0, 2] + [0, 0]), .badBundle)
        XCTAssertEqual(error(Array("/o/next".utf8) + [0] + Array(",s".utf8) + [0, 0] + [0xFF, 0xFE, 0, 0]), .badString)

        // Nothing in a random packet may trap.
        var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
        func next() -> UInt8 {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return UInt8(truncatingIfNeeded: seed >> 33)
        }
        for _ in 0..<500 {
            let length = Int(next() % 64)
            var junk = (0..<length).map { _ in next() }
            if junk.first == 0x2F || junk.first == 0x23 { junk[0] = 0x2F }
            _ = OSCPacket.decode(Data(junk))
        }
    }
}
