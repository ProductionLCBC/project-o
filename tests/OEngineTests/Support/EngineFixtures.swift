import Foundation
import OCore
import OFormats
@testable import OEngine

/// The fixture library of Spec 1 §9 (`tests/fixtures/library-v1/`) as the engine
/// tests see it, plus machine roots built in code for the configurations Spec 4
/// §2 and §15 describe. The fixture's own machine root pairs a 60p display with
/// a 29.97 SDI output, which Spec 4 §2 rejects as a mixed rate family, so the
/// engine tests take its stacks and replace its outputs.
enum EngineFixtures {
    /// tests/OEngineTests/Support/EngineFixtures.swift -> repository root.
    static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Support
            .deletingLastPathComponent()   // OEngineTests
            .deletingLastPathComponent()   // tests
            .deletingLastPathComponent()   // root
    }

    static var fixtureRoot: URL { repoRoot.appendingPathComponent("tests/fixtures/library-v1") }
    static var libraryRoot: URL { fixtureRoot.appendingPathComponent("library") }
    static var machineRoot: URL { fixtureRoot.appendingPathComponent("machine") }
    static var mediaRoot: URL { libraryRoot.appendingPathComponent("media") }

    static func uuid(_ prefix: String, _ n: Int) -> UUID {
        let head = prefix.padding(toLength: 8, withPad: "0", startingAt: 0)
        let hex = String(n, radix: 16)
        let tail = String(repeating: "0", count: 12 - hex.count) + hex
        return UUID(uuidString: "\(head)-0000-4000-8000-\(tail)") ?? UUID()
    }

    static let dawn = "sha256:55c84469c37e1e6a72a9b8938422cd6536b302b583a5c127241c8304246f3527"
    static let cross = "sha256:eb6384847a49f7a4ef82aedb9e2019080777b8be748690c33d91bba67c32a3d2"
    static let mountains = "sha256:" + String(repeating: "9f2c6a1b", count: 8)
    static let list42Cues = [uuid("11aa", 1), uuid("22bb", 2), uuid("33cc", 3), uuid("44dd", 4)]
    static let list42 = uuid("a9f0", 42)

    /// The fixture library root, loaded through OFormats and the loader.
    static func library() throws -> Library {
        let snapshot = try LocalFiles.snapshot(ofRoot: libraryRoot)
        return Loader.library(from: snapshot).library
    }

    /// The fixture machine root as loaded, before any outputs are replaced.
    static func fixtureMachine() throws -> Machine {
        let snapshot = try LocalFiles.snapshot(ofRoot: machineRoot)
        return Loader.machine(from: snapshot).machine
    }

    /// Spec 4 §15 — the spike configuration: the fixture's two stacks (main:
    /// channels 1 and 2; confidence: channel 2 at offset 0 and +1 with the
    /// plain-text default preset and the static [Time] box), stack 1 on output
    /// 1 and stack 2 on output 2, both displays in the 60 family. `mainSize` is
    /// the main output's format; the spike wants 4096×2160 on the LED wall and
    /// the tests use 1920×1080 unless they say otherwise.
    static func spikeMachine(mainSize: Size = .hd, rate: FrameRate = .fps60) throws -> Machine {
        var machine = try fixtureMachine()
        machine.outputs = [
            Output(number: 1, defaultStack: 1, transitions: OutputTransitions(switch: 2, blackout: 3), label: "Main",
                   uuid: uuid("0d7d", 1), kind: .display, device: "display:main",
                   format: VideoFormat(width: mainSize.width, height: mainSize.height, rate: rate, interlaced: false)),
            Output(number: 2, defaultStack: 2, transitions: OutputTransitions(switch: 1, blackout: 2), label: "Confidence",
                   uuid: uuid("0d7d", 2), kind: .display, device: "display:confidence",
                   format: VideoFormat(width: 1920, height: 1080, rate: rate, interlaced: false)),
        ]
        return machine
    }

    /// Spec 4 §16, pacing: "a 60 Hz tick driving a 30 fps and an interlaced
    /// output". Output 1 is 60p, output 2 is 30p, output 3 is 1080i30 (60
    /// fields a second), all in the integer family.
    static func pacingMachine() throws -> Machine {
        var machine = try fixtureMachine()
        machine.outputs = [
            Output(number: 1, defaultStack: 1, label: "60p", uuid: uuid("0d7d", 1), kind: .display, device: "display:a",
                   format: VideoFormat(width: 1920, height: 1080, rate: FrameRate(num: 60), interlaced: false)),
            Output(number: 2, defaultStack: 2, label: "30p", uuid: uuid("0d7d", 2), kind: .display, device: "display:b",
                   format: VideoFormat(width: 1920, height: 1080, rate: FrameRate(num: 30), interlaced: false)),
            Output(number: 3, defaultStack: 1, label: "1080i30", uuid: uuid("0d7d", 3), kind: .sdi, device: "decklink:0",
                   format: VideoFormat(width: 1920, height: 1080, rate: FrameRate(num: 30), interlaced: true), genlock: .freeRun),
        ]
        return machine
    }
}
