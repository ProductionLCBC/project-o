import Foundation
import XCTest
@testable import OCore

/// Spec 1 §10 — Round trip: "Load every fixture document, write it back, and
/// diff: byte-identical output, including unknown keys and key order." Also
/// §8, "every object keeps an opaque bag of keys it did not recognise and
/// writes them back unchanged", and the fixture library itself (§10).
final class FormatRoundTripTests: XCTestCase {
    typealias F = FixtureLibrary

    /// Every document of both roots as (root-prefixed path, bytes).
    private var fixtureDocuments: [(root: String, path: String, data: Data)] {
        F.documents(under: F.libraryRoot).map { ("library", $0.path, $0.data) }
            + F.documents(under: F.machineRoot).map { ("machine", $0.path, $0.data) }
    }

    func test_everyFixtureDocumentRoundTripsByteForByte() throws {
        let documents = fixtureDocuments
        XCTAssertGreaterThan(documents.count, 20, "the fixture library is missing")
        for (root, path, data) in documents {
            let loaded = try Loader.document(path: path, data: data)
            let written = Writer.data(for: loaded)
            XCTAssertEqual(written, data, "\(root)/\(path): " + ByteDiff.describe(expected: data, actual: written))
        }
    }

    /// Spec 1 §8 — unknown keys are preserved on every object that has fields
    /// of its own. The exceptions are the fixed value shapes (colours, frames,
    /// sizes, rates, outline, shadow, mask), the plain maps (layouts, fields,
    /// variations, overrides, replaced), non-media content, and the ShowState
    /// in `state/last.json`, which Spec 3 owns.
    func test_unknownKeysSurviveARoundTripAtEveryObject() throws {
        for (root, path, data) in fixtureDocuments {
            let tree = try JSONValue.parse(data)
            let injected = UnknownKeyInjector.inject(tree, under: nil)
            XCTAssertNotEqual(injected, tree, "\(path): nothing was injected")
            let canonical = JSONCanonical.data(injected)
            let loaded = try Loader.document(path: path, data: canonical)
            let written = Writer.data(for: loaded)
            XCTAssertEqual(written, canonical, "\(root)/\(path): " + ByteDiff.describe(expected: canonical, actual: written))
        }
    }

    /// Spec 1 §5 — the writer stamps the header: `{ "schema": 1, "app": "0.1.0", "kind": ... }`.
    func test_writerStampsTheHeaderOfEveryDocument() throws {
        let data = Writer.data(for: .library(LibraryInfo(uuid: F.libraryUuid, name: "x")))
        let tree = try JSONValue.parse(data)
        XCTAssertEqual(tree["schema"], .number(Double(OCore.schemaVersion)))
        XCTAssertEqual(tree["app"], .string(OCore.appVersion))
        XCTAssertEqual(tree["kind"], .string("library"))
        XCTAssertEqual(OCore.appVersion, "0.1.0")
    }

    /// Spec 1 §10 — the fixture library is complete and loads with nothing to
    /// report, from either root, with every object in number order.
    func test_theFixtureLibraryLoadsWithACleanReport() {
        let (library, machine, report) = F.load()
        XCTAssertEqual(report.issues, [])
        XCTAssertEqual(library.info.uuid, F.libraryUuid)
        XCTAssertEqual(library.info.name, "LCBC Library")
        XCTAssertEqual(library.channels.map(\.number), [1, 2])
        XCTAssertEqual(library.textStyles.map(\.number), [1, 2])
        XCTAssertEqual(library.grades.map(\.number), [1])
        XCTAssertEqual(library.transitions.map(\.number), [1, 2, 3])
        XCTAssertEqual(library.audioTransitions.map(\.number), [1, 2, 3])
        XCTAssertEqual(library.presets.map(\.number), [1, 2, 3])
        XCTAssertEqual(library.macros.map(\.number), [1])
        XCTAssertEqual(library.lists.map(\.number), [7, 42])
        XCTAssertEqual(library.mediaIndex.entries.map(\.id), [F.dawn, F.mountains, F.cross, F.welcomeSlide].sorted())
        XCTAssertEqual(machine.settings.uuid, F.machineUuid)
        XCTAssertEqual(machine.settings.campusName, "Manheim")
        XCTAssertEqual(machine.stacks.map(\.number), [1, 2])
        XCTAssertEqual(machine.outputs.map(\.number), [1, 2])
        XCTAssertEqual(machine.audioOutputs.map(\.number), [1, 2])
        XCTAssertEqual(machine.inputs.map(\.number), [1])
        XCTAssertEqual(machine.keys.count, 6)
        XCTAssertEqual(machine.macros.map(\.number), [2])
        XCTAssertEqual(machine.playlists.map(\.uuid), [F.playlistUuid])
        XCTAssertEqual(machine.localLists.map(\.uuid), [F.localCopyUuid])
        XCTAssertEqual(machine.mediaLocal.entries.map(\.id), [F.announcement])
        XCTAssertEqual(machine.mediaLocal.overrides, [F.cross: "local/cross-fast.png"])
        XCTAssertEqual(machine.lastState?.channels.count, 2)

        let validation = Validator.validate(library: library, machine: machine)
        XCTAssertEqual(validation.issues, [])
    }

    /// The loaded roots write back to the same files at the same paths: the
    /// writer's naming (§5) agrees with the fixture's, and nothing is lost
    /// between the documents and the in-memory roots. Previous versions are
    /// not loaded, so they are not written either.
    func test_theLoadedRootsWriteBackToTheSameSnapshot() {
        let (library, machine, _) = F.load()
        let expectedLibrary = F.librarySnapshot.files.filter { !$0.key.hasPrefix("versions/") }
        let writtenLibrary = Writer.snapshot(of: library).files
        XCTAssertEqual(Set(writtenLibrary.keys), Set(expectedLibrary.keys))
        for (path, data) in expectedLibrary {
            XCTAssertEqual(writtenLibrary[path], data, path + ": " + ByteDiff.describe(expected: data, actual: writtenLibrary[path] ?? Data()))
        }
        let expectedMachine = F.machineSnapshot.files
        let writtenMachine = Writer.snapshot(of: machine).files
        XCTAssertEqual(Set(writtenMachine.keys), Set(expectedMachine.keys))
        for (path, data) in expectedMachine {
            XCTAssertEqual(writtenMachine[path], data, path + ": " + ByteDiff.describe(expected: data, actual: writtenMachine[path] ?? Data()))
        }
    }

    /// Spec 1 §2 — the worked example of §9 reads as the objects the spec names.
    func test_theWorkedExamplesLoadAsTheSpecDescribesThem() {
        let (library, machine, _) = F.load()
        let background = library.channel(1)
        XCTAssertEqual(background?.label, "Background")
        XCTAssertEqual(background?.defaults, ChannelDefaults(transition: 1, audioTransition: 1, gain: 0))
        XCTAssertEqual(background?.renderSize, .largest)
        XCTAssertEqual(library.channel(2)?.renderSize, .size(width: 1920, height: 1080))
        XCTAssertEqual(background?.usualContent, .media)

        let preset = library.preset(1)
        XCTAssertEqual(preset?.builtIn, true)
        XCTAssertEqual(preset?.layouts.keys.sorted(), [.any])
        XCTAssertEqual(preset?.layouts[.any]?.boxes.count, 2)
        XCTAssertEqual(preset?.layouts[.any]?.boxes[0].binding.kind, .pixels)
        XCTAssertEqual(preset?.layouts[.any]?.boxes[1].binding.kind, .field(name: "body"))
        XCTAssertEqual(preset?.layouts[.any]?.boxes[1].fallback, true)
        XCTAssertEqual(preset?.layouts[.any]?.boxes[1].textStyle?.fromStyle, 1)
        XCTAssertEqual(preset?.layouts[.any]?.boxes[1].textStyle?.values.size, TextSize(value: 72, unit: .pt))
        XCTAssertEqual(library.preset(3)?.layouts.keys.sorted(), [.any, .stack(2)])

        let list = library.list(number: 42)
        XCTAssertEqual(list?.title, "Great Is Thy Faithfulness")
        XCTAssertEqual(list?.version, 17)
        XCTAssertEqual(list?.cues.map(\.uuid), F.list42Cues)
        XCTAssertEqual(list?.cues[0].commands.count, 2)
        XCTAssertEqual(list?.cues[0].commands[0].command,
                       .channelWrite(ChannelWrite(channel: .number(1), content: .media(MediaContent(ref: F.dawn, loop: true)),
                                                  riders: Riders(transition: TransitionRider(ref: 2, ms: 1000, scope: .once)))))
        XCTAssertEqual(list?.cues[2].trigger, .time(ms: 8000))
        XCTAssertEqual(list?.cues[2].advanceAfterMs, 12000)
        XCTAssertEqual(library.list(number: 7)?.cues[0].trigger, .timecode("01:00:10:00"))
        XCTAssertEqual(library.list(number: 7)?.trackThrough, true)

        let confidence = machine.stack(2)
        XCTAssertEqual(confidence?.defaultPreset, 2)
        XCTAssertEqual(confidence?.slots, [StackSlot(channel: 2, preset: nil, offset: 0, opacity: 1, mute: false),
                                           StackSlot(channel: 2, preset: 3, offset: 1, opacity: 1, mute: false)])
        XCTAssertEqual(machine.settings.libraryMode, .readOnlyMasters)
        XCTAssertEqual(machine.settings.network.oscInPort, 8000)
        XCTAssertEqual(machine.settings.startupMacro, 2)
        XCTAssertEqual(machine.localLists.first?.provenance,
                       LocalProvenance(masterUuid: F.listUuid(42), masterVersion: 16, detachedAt: "2026-10-25T14:03:22Z"))
        XCTAssertEqual(machine.playlists.first?.items.map(\.kind),
                       [.header(label: "Welcome"), .linked(list: 42), .local(F.localCopyUuid), .header(label: "Response"), .linked(list: 7)])
    }
}

/// Adds `"zzUnknown": { ... }` to every object the format promises to round-trip.
enum UnknownKeyInjector {
    static let payload: JSONValue = .object(["nested": .array([.number(1), .string("two"), .null]), "flag": .bool(true)])

    /// Keys whose values are fixed value shapes or plain maps: not injected, not descended.
    static let skipped: Set<String> = [
        "color", "tint", "frame", "rate", "fps", "size", "renderSize", "outline", "shadow", "mask",
        "fields", "variations", "overrides", "replaced", "state",
    ]
    /// Keys whose values are maps of objects: descended into, not injected.
    static let maps: Set<String> = ["layouts"]

    static func inject(_ value: JSONValue, under key: String?) -> JSONValue {
        switch value {
        case .object(let members):
            if let key, skipped.contains(key) { return value }
            if key == "content", members["kind"] != .string("media") { return value }
            var out: [String: JSONValue] = [:]
            for (k, v) in members { out[k] = inject(v, under: k) }
            if let key, maps.contains(key) { return .object(out) }
            out["zzUnknown"] = payload
            return .object(out)
        case .array(let items):
            if let key, skipped.contains(key) { return value }
            return .array(items.map { inject($0, under: key) })
        default:
            return value
        }
    }
}
