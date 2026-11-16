import XCTest
import CoreGraphics
import ImageIO
import IOSurface
import OCore
@testable import OEngine

/// Spec 10 §3 — "LAN clients also have `preview`, which the app doesn't use:
/// a JPEG of each stack the client names when it subscribes (`"stacks": [1,
/// 2]`), 480 pixels wide, twice a second (Spec 4 §10)."
///
/// The engine is the headless one, whose backend draws nothing: the test
/// fills the stacks' preview surfaces, and what is sent of them, to whom and
/// how often is the engine's.
final class ApiPreviewTests: XCTestCase {
    var api: ApiFixture!
    var surfaces: TestSurfaces!

    /// An engine whose stack 1 previews are red and stack 2's green.
    func make() throws {
        api = try ApiFixture()
        let control = api.engine.control
        let surfaces = TestSurfaces(control)
        for handle in control.previewSurfaces[1] ?? [] { surfaces.fill(handle, blue: 20, green: 30, red: 220) }
        for handle in control.previewSurfaces[2] ?? [] { surfaces.fill(handle, blue: 20, green: 200, red: 30) }
        let find: @Sendable (TextureHandle) -> IOSurfaceRef? = { surfaces.find($0) }
        api.engine.engine.surfaceSource = find
        self.surfaces = surfaces
        api.tick(10)   // every surface has been planned a frame
    }

    /// A JPEG's size and its middle pixel, as red, green, blue.
    func decode(_ event: [String: JSONValue]) throws -> (width: Int, height: Int, middle: [Int]) {
        let data = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(event["jpeg"]?.stringValue)), "base64")
        XCTAssertEqual(Array(data.prefix(2)), [0xFF, 0xD8], "a JPEG")
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        var pixel = [UInt8](repeating: 0, count: 4)
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: space,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        // Draw so the image's middle lands on the one pixel.
        context.draw(image, in: CGRect(x: -image.width / 2, y: -image.height / 2, width: image.width, height: image.height))
        return (image.width, image.height, [Int(pixel[0]), Int(pixel[1]), Int(pixel[2])])
    }

    func test_aSubscriberGetsAJpegOfEachStackItNamesTwiceASecond() throws {
        try make()
        let remote = api.lan()
        remote.send("subscribe", ["topics": .array([.string("preview")]), "stacks": .array([.number(1)])])
        api.tick()        // the subscription is taken
        api.tick(120)     // two seconds at 60 Hz
        let events = remote.next().events("preview")
        XCTAssertEqual(events.count, 4, "twice a second")
        XCTAssertEqual(Set(events.compactMap { $0["stack"]?.intValue }), [1], "the stack it named, and not the other")
        let event = try XCTUnwrap(events.first)
        XCTAssertEqual(event["width"], .number(480))
        XCTAssertEqual(event["height"], .number(270))
        XCTAssertNotNil(event["seq"], "an event like any other")
        let picture = try decode(event)
        XCTAssertEqual(picture.width, 480, "480 pixels wide")
        XCTAssertEqual(picture.height, 270)
        XCTAssertEqual(Double(picture.middle[0]), 220, accuracy: 12, "the stack's picture: red")
        XCTAssertEqual(Double(picture.middle[1]), 30, accuracy: 12)
        XCTAssertEqual(Double(picture.middle[2]), 20, accuracy: 12)
    }

    func test_eachSubscriberGetsOnlyTheStacksItNamed() throws {
        try make()
        let one = api.lan()
        let both = api.lan()
        let none = api.lan()
        one.send("subscribe", ["topics": .array([.string("preview")]), "stacks": .array([.number(2)])])
        both.send("subscribe", ["topics": .array([.string("preview")]), "stacks": .array([.number(1), .number(2)])])
        none.send("subscribe", ["topics": .array([.string("preview")])])
        api.tick()
        api.tick(31)
        XCTAssertEqual(one.next().events("preview").compactMap { $0["stack"] }, [.number(2)])
        XCTAssertEqual(both.next().events("preview").compactMap { $0["stack"] }, [.number(1), .number(2)], "one event a stack")
        XCTAssertEqual(none.next().events("preview").count, 0, "a subscriber that names no stack gets none")
        let green = try decode(try XCTUnwrap(one.messages().events("preview").first))
        XCTAssertEqual(Double(green.middle[1]), 200, accuracy: 12, "stack 2's own picture")
    }

    func test_withNoSubscriberNothingIsCopiedOrEncoded() throws {
        try make()
        let other = api.lan()
        other.send("subscribe", ["topics": .array([.string("channels")])])
        api.tick(120)
        XCTAssertEqual(api.engine.engine.preview.copies, 0, "the work is done for someone or not at all")
        XCTAssertEqual(other.next().events("preview").count, 0)
    }

    /// Area 19 reading — any connection may subscribe, the local socket included.
    func test_theLocalSocketMaySubscribeToo() throws {
        try make()
        let app = api.local()
        app.send("subscribe", ["topics": .array([.string("preview")]), "stacks": .array([.number(1)])])
        api.tick()
        api.tick(31)
        XCTAssertEqual(app.next().events("preview").count, 1)
    }

    /// Area 19 reading — while the GPU is over budget the previews are being
    /// skipped (Spec 4 §4 step 5), and nothing is sent of a stack.
    func test_nothingIsSentWhileThePreviewsAreSkippedUnderPressure() throws {
        try make()
        let backend = try XCTUnwrap(api.engine.recording)
        let remote = api.lan()
        remote.send("subscribe", ["topics": .array([.string("preview")]), "stacks": .array([.number(1)])])
        api.tick()
        backend.simulatedGPUMilliseconds = 20
        api.tick(90)
        XCTAssertTrue(api.engine.renderLoop.isSkippingAux)
        XCTAssertLessThanOrEqual(remote.next().events("preview").count, 1, "at most the one from before the overrun was seen")
        backend.simulatedGPUMilliseconds = 3
        api.tick(90)
        XCTAssertGreaterThanOrEqual(remote.next().events("preview").count, 2, "and they come back")
    }

    // MARK: - The picture itself

    func pixels(width: Int, height: Int, blue: UInt8, green: UInt8, red: UInt8, alpha: UInt8) -> PreviewJPEG.Pixels {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for index in 0..<(width * height) {
            bytes[index * 4] = blue
            bytes[index * 4 + 1] = green
            bytes[index * 4 + 2] = red
            bytes[index * 4 + 3] = alpha
        }
        return PreviewJPEG.Pixels(data: Data(bytes), width: width, height: height, rowBytes: width * 4)
    }

    func test_aPreviewOfAnySizeIsScaledTo480Wide() throws {
        // A 3840 by 2160 stack's quarter-size preview is 960 by 540; a 1280 by 720 stack's is 320 by 180.
        for (width, height) in [(960, 540), (320, 180), (480, 270)] {
            let jpeg = try XCTUnwrap(PreviewJPEG.encode(pixels(width: width, height: height, blue: 200, green: 40, red: 40, alpha: 255), width: 480, quality: 0.7))
            XCTAssertEqual(jpeg.width, 480)
            XCTAssertEqual(jpeg.height, 270, "its shape kept")
            let picture = try decode(["jpeg": .string(jpeg.data.base64EncodedString())])
            XCTAssertEqual(picture.width, 480)
            XCTAssertEqual(Double(picture.middle[2]), 200, accuracy: 12, "from \(width) wide")
        }
        // Another shape keeps it: a 4:3 stack.
        let tall = try XCTUnwrap(PreviewJPEG.encode(pixels(width: 256, height: 192, blue: 0, green: 0, red: 0, alpha: 255), width: 480, quality: 0.7))
        XCTAssertEqual(tall.height, 360)
    }

    /// A stack is drawn over nothing; a JPEG has no alpha, so a clear stack reads black, as an output shows it.
    func test_aClearStackIsBlackAndATranslucentOneIsOverBlack() throws {
        let clear = try XCTUnwrap(PreviewJPEG.encode(pixels(width: 480, height: 270, blue: 0, green: 0, red: 0, alpha: 0), width: 480, quality: 0.7))
        XCTAssertEqual(try decode(["jpeg": .string(clear.data.base64EncodedString())]).middle.map { $0 < 8 }, [true, true, true])
        // Premultiplied white at half opacity is mid grey over black.
        let half = try XCTUnwrap(PreviewJPEG.encode(pixels(width: 480, height: 270, blue: 128, green: 128, red: 128, alpha: 128), width: 480, quality: 0.7))
        let picture = try decode(["jpeg": .string(half.data.base64EncodedString())])
        XCTAssertEqual(Double(picture.middle[0]), 128, accuracy: 12)
    }
}
