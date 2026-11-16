import Foundation
import XCTest
@testable import OCore

/// Spec 10 §3, the `devices` query, and Spec 10 §13, which reads the same
/// list at first run: the plain data both stand on.
final class DetectedDevicesTests: XCTestCase {
    /// Spec 1 §5 — "frame rates are `{num, den}` (so 59.94 is `{60000, 1001}`)".
    func test_aRefreshInHertzNamesItsRate() {
        XCTAssertEqual(FrameRate.nearest(hertz: 60), FrameRate(num: 60))
        XCTAssertEqual(FrameRate.nearest(hertz: 59.94), FrameRate(num: 60000, den: 1001))
        XCTAssertEqual(FrameRate.nearest(hertz: 59.940059), FrameRate(num: 60000, den: 1001), "as a screen reports it")
        XCTAssertEqual(FrameRate.nearest(hertz: 29.97), FrameRate(num: 30000, den: 1001))
        XCTAssertEqual(FrameRate.nearest(hertz: 23.976), FrameRate(num: 24000, den: 1001))
        XCTAssertEqual(FrameRate.nearest(hertz: 119.88), FrameRate(num: 120000, den: 1001))
        XCTAssertEqual(FrameRate.nearest(hertz: 120), FrameRate(num: 120))
        XCTAssertEqual(FrameRate.nearest(hertz: 50), FrameRate(num: 50))
        XCTAssertEqual(FrameRate.nearest(hertz: 74.97), FrameRate(num: 75), "not a broadcast rate: the nearest whole one")
        XCTAssertEqual(FrameRate.nearest(hertz: 0), .fps60, "a screen that reports nothing")
        XCTAssertEqual(FrameRate.nearest(hertz: .nan), .fps60)
    }

    /// Spec 4 §2 — "One rate family per machine ... integer (60, 30) or fractional (59.94, 29.97)".
    func test_aRatesFamily() {
        XCTAssertFalse(FrameRate(num: 60).isFractional)
        XCTAssertTrue(FrameRate(num: 60000, den: 1001).isFractional)
    }

    func test_aDisplayDeviceHoldsItsUuidInCapitals() {
        XCTAssertEqual(DetectedScreen.uuid(ofDevice: "display:37d8832a-2d66-02ca-b9f7-8f30a301b230"), "37D8832A-2D66-02CA-B9F7-8F30A301B230")
        XCTAssertNil(DetectedScreen.uuid(ofDevice: "decklink:8f3a21c0"))
        XCTAssertNil(DetectedScreen.uuid(ofDevice: ""))
        let screen = DetectedScreen(device: "display:AA", name: "Wall", frame: ScreenFrame(x: 0, y: 0, width: 1920, height: 1080), mode: VideoFormat())
        XCTAssertEqual(screen.uuid, "AA")
    }

    /// The `devices` answer is this value as JSON, so it reads back as itself.
    func test_theListRoundTripsAsJSON() throws {
        let list = DetectedDevices(
            screens: [DetectedScreen(device: "display:AA", name: "DELL U2720Q", frame: ScreenFrame(x: 1512, y: 0, width: 1920, height: 1080),
                                     mode: VideoFormat(width: 3840, height: 2160, rate: FrameRate(num: 60), interlaced: false), mirrored: false)],
            ports: [DetectedPort(device: "decklink:8f3a21c0", name: "DeckLink 8K Pro (1)",
                                 modes: [VideoFormat(width: 1920, height: 1080, rate: FrameRate(num: 60000, den: 1001), interlaced: false)])],
            audio: [DetectedAudioDevice(uid: "BuiltInSpeakerDevice", name: "Mac mini Speakers", channels: 2, isDefault: true)])
        let json = try JSONCoding.encode(list)
        XCTAssertEqual(try JSONCoding.decode(DetectedDevices.self, from: json), list)
        XCTAssertEqual(json.objectValue?["screens"]?.arrayValue?.first?.objectValue?["device"], .string("display:AA"))
        XCTAssertEqual(json.objectValue?["audio"]?.arrayValue?.first?.objectValue?["isDefault"], .bool(true))
    }
}
