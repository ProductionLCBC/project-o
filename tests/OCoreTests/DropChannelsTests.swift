import Foundation
import XCTest
@testable import OCore

/// Spec 8 §8 — "`dropChannels` is a new machine setting (M8): `{video,
/// image, audio}`, each a channel number or null. An item's
/// `defaults.defaultChannel` overrides it. ... First run writes `{"video": 1,
/// "image": 1, "audio": null}`". Spec 8 §11 — "Drop channels. `dropChannels`
/// loads, round-trips and is written on first run as §8 says." (Area 19's
/// first-run writer takes `DropChannels.firstRun`.)
final class DropChannelsTests: XCTestCase {
    typealias F = FixtureLibrary

    func test_theFixtureLoadsItsDropChannels() {
        let (_, machine, report) = F.load()
        XCTAssertEqual(machine.settings.dropChannels, DropChannels(video: 1, image: 1, audio: nil))
        XCTAssertEqual(report.issues, [])
    }

    func test_dropChannelsRoundTripWithNullsWritten() throws {
        let drops = DropChannels(video: 2, image: nil, audio: 4)
        let tree = try JSONCoding.encode(drops)
        XCTAssertEqual(JSONCanonical.line(tree), #"{ "audio": 4, "image": null, "video": 2 }"#)
        XCTAssertEqual(try JSONCoding.decode(DropChannels.self, from: tree), drops)
    }

    /// A `machine.json` from before Spec 8 has no `dropChannels`: it reads as
    /// none (the pool asks for every kind) and is written back without the key.
    func test_aMachineWithoutDropChannelsRoundTripsWithoutThem() throws {
        var settings = F.load().machine.settings
        settings.dropChannels = nil
        let tree = try JSONCoding.encode(settings)
        XCTAssertNil(tree["dropChannels"])
        XCTAssertNil(try JSONCoding.decode(MachineSettings.self, from: tree).dropChannels)
    }

    func test_firstRunWritesSpec8Values() throws {
        XCTAssertEqual(JSONCanonical.line(try JSONCoding.encode(DropChannels.firstRun)), #"{ "audio": null, "image": 1, "video": 1 }"#)
    }

    /// "An item's `defaults.defaultChannel` overrides it"; null means the pool asks.
    func test_theChannelForADrop() {
        let drops = DropChannels.firstRun
        XCTAssertEqual(drops.channel(for: .video, defaultChannel: nil), 1)
        XCTAssertEqual(drops.channel(for: .image, defaultChannel: nil), 1)
        XCTAssertNil(drops.channel(for: .audio, defaultChannel: nil), "the pool asks")
        XCTAssertEqual(drops.channel(for: .audio, defaultChannel: 3), 3)
        XCTAssertEqual(drops.channel(for: .video, defaultChannel: 2), 2)
        XCTAssertNil(drops.channel(for: .slide, defaultChannel: nil), "slides have no drop channel until the slide designer")
    }
}
