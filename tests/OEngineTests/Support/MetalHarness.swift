import Foundation
import XCTest
import OCore
@testable import OEngine

/// A Metal backend for the tests that need a GPU, or a skip where there is none.
enum MetalHarness {
    /// CLAUDE.md — "The self-hosted bench Mac runs golden-image tests and the
    /// soak scenario". The hosted runner's virtual GPU and media engine stall
    /// about one run in four in a state the runner cannot kill, so with
    /// `O_HOSTED_RUNNER` set (the CI workflow sets it) the tests that need the
    /// GPU or a video encoder and decoder skip, and the bench runs them.
    static var hostedRunner: Bool { ProcessInfo.processInfo.environment["O_HOSTED_RUNNER"] != nil }

    static func skipOnHostedRunner(_ what: String) throws {
        if hostedRunner { throw XCTSkip("hosted runner: \(what) run on the bench Mac") }
    }

    static func backend() throws -> MetalBackend {
        try skipOnHostedRunner("Metal tests")
        guard MetalBackend.isAvailable else { throw XCTSkip("no Metal device on this machine") }
        return try MetalBackend(log: EngineLog(category: "test-metal"))
    }

    /// The golden folder of the repository: tests/goldens/<group>.
    static func goldens(_ group: String) -> GoldenStore {
        let folder = EngineFixtures.repoRoot.appendingPathComponent("tests/goldens").appendingPathComponent(group)
        return GoldenStore(folder: folder, update: GoldenStore.updateRequested)
    }

    /// Run one channel pass through the backend and read the target back.
    static func render(_ pass: ChannelPass, picks: PickedFrames = PickedFrames(capacity: 4), backend: MetalBackend,
                       tick: Int64 = 0, options: EncodeOptions = EncodeOptions()) -> CapturedFrame? {
        let plan = FramePlan(frame: tick, channelPasses: [pass])
        backend.prepare(plan)
        let time = TickTime(tick: tick, reference: .zero, wake: .zero)
        let receipt = backend.encode(time, plan: plan, picks: picks, options: options)
        backend.waitForCompletion(of: receipt)
        return backend.readback(pass.target)
    }

    /// Run one stack pass through the backend and read the target back.
    static func render(_ pass: StackPass, backend: MetalBackend, tick: Int64 = 0) -> CapturedFrame? {
        let plan = FramePlan(frame: tick, stackPasses: [pass])
        backend.prepare(plan)
        let time = TickTime(tick: tick, reference: .zero, wake: .zero)
        let receipt = backend.encode(time, plan: plan, picks: PickedFrames(capacity: 4), options: EncodeOptions())
        backend.waitForCompletion(of: receipt)
        return backend.readback(pass.target)
    }

    /// A horizontal gradient from `from` to `to` with full alpha.
    static func gradient(width: Int, height: Int, from: LinearPixel, to: LinearPixel) -> CapturedFrame {
        var frame = CapturedFrame(width: width, height: height)
        for y in 0..<height {
            for x in 0..<width {
                let t = Float(x) / Float(max(1, width - 1))
                frame[x, y] = LinearPixel.lerp(from, to, t)
            }
        }
        return frame
    }

    static func solid(width: Int, height: Int, _ pixel: LinearPixel) -> CapturedFrame {
        var frame = CapturedFrame(width: width, height: height)
        for i in 0..<frame.pixels.count { frame.pixels[i] = pixel }
        return frame
    }

    static func assertGolden(_ store: GoldenStore, _ name: String, _ frame: CapturedFrame, tolerance: GoldenTolerance? = nil,
                             file: StaticString = #filePath, line: UInt = #line) throws {
        switch try store.check(name, frame, tolerance: tolerance) {
        case .matched, .written:
            break
        case .missing:
            XCTFail("golden \(name) is missing: run scripts/golden.sh --update", file: file, line: line)
        case .mismatch(let diff, let path):
            XCTFail("golden \(name) differs: max \(diff.maxCodeDifference) codes at \(diff.worstPixel), mean \(diff.meanCodeDifference); diff at \(path)",
                    file: file, line: line)
        }
    }

    static func assertPixel(_ p: LinearPixel, _ expected: LinearPixel, accuracy: Float = 0.004, _ message: String = "",
                            file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(p.r, expected.r, accuracy: accuracy, "r " + message, file: file, line: line)
        XCTAssertEqual(p.g, expected.g, accuracy: accuracy, "g " + message, file: file, line: line)
        XCTAssertEqual(p.b, expected.b, accuracy: accuracy, "b " + message, file: file, line: line)
        XCTAssertEqual(p.a, expected.a, accuracy: accuracy, "a " + message, file: file, line: line)
    }
}

/// The synthetic clips the decode tests read, written once per test run.
enum ClipFixtures {
    static let folder: URL = {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("oengine-clips-\(ProcessInfo.processInfo.processIdentifier)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    nonisolated(unsafe) private static var written: [String: Result<URL, Error>] = [:]
    private static let lock = NSLock()

    static func url(for clip: FixtureMedia.Clip) throws -> URL {
        try MetalHarness.skipOnHostedRunner("video encode and decode tests")
        lock.lock()
        defer { lock.unlock() }
        if let result = written[clip.name] { return try result.get() }
        let url = folder.appendingPathComponent(clip.name + ".mov")
        let result = Result { try FixtureMedia.write(clip, to: url); return url }
        written[clip.name] = result
        return try result.get()
    }

    static let h264 = FixtureMedia.Clip(name: "h264-2s", codec: .h264, seconds: 2)
    static let h264Loop = FixtureMedia.Clip(name: "h264-1s", codec: .h264, seconds: 1)
    static let h264LongGOP = FixtureMedia.Clip(name: "h264-4s-gop60", codec: .h264, seconds: 4, keyframeInterval: 60)
    static let hevc = FixtureMedia.Clip(name: "hevc-2s", codec: .hevc, seconds: 2)
    static let hevc10 = FixtureMedia.Clip(name: "hevc10-2s", codec: .hevc10, seconds: 2)
    static let proRes = FixtureMedia.Clip(name: "prores-2s", codec: .proRes422Proxy, seconds: 2)
    static let proRes4444 = FixtureMedia.Clip(name: "prores4444-2s", codec: .proRes4444, seconds: 2)
    static let clapper = FixtureMedia.Clip(name: "clapper", codec: .h264, seconds: 3, audio: .click(atMs: 1000), flashFrame: 30)
}

extension XCTestCase {
    /// Wait for a condition on another thread, polling.
    func waitUntil(_ timeout: TimeInterval = 10, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.005)
        }
        return condition()
    }
}
