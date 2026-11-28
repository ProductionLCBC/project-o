import Foundation
import XCTest
@testable import OCore

/// Spec 10 §13, "The engine writes the defaults" and "Which screens become
/// outputs" (S3); Spec 6 §9, the first-run library and stacks; Spec 10 §9,
/// the default keys. Spec 10 §18, Area 19, first run: "The engine writes
/// §13's defaults once and never over existing files; a fake device list
/// yields the outputs and stacks S3 describes; the operator's screen is never
/// an output; one screen, or mirrored screens, yields none". The documents
/// are worked out by a pure builder from plain values, so §13's table is
/// tested here as a table; the writing is `FirstRunWriterTests`'.
final class FirstRunDocumentTests: XCTestCase {
    typealias F = FixtureLibrary

    /// Uuids in a known order, so a test can tell a made one from a fixed one.
    final class Counter {
        var made: [UUID] = []
        func next() -> UUID {
            let uuid = F.uuid("f125", made.count + 1)
            made.append(uuid)
            return uuid
        }
    }

    // MARK: - The library

    func test_theFirstRunLibraryHoldsTheFixtureLibrarysValues() throws {
        let counter = Counter()
        let library = FirstRun.library(name: "Manheim Library", uuid: counter.next)
        let fixture = F.load().library

        XCTAssertEqual(library.info.name, "Manheim Library")
        XCTAssertNotEqual(library.info.uuid, fixture.info.uuid, "a library of its own")

        // "Spec 1 §2's built-in transitions 1 to 3 ...; audio transitions 1 to 3": the fixture's, uuids and all.
        XCTAssertEqual(library.transitions, fixture.transitions)
        XCTAssertEqual(library.transitions.map(\.type), [.cut, .dissolve, .fadeThroughColor])
        XCTAssertEqual(library.transitions.map(\.builtIn), [true, true, true])
        XCTAssertEqual(library.audioTransitions, fixture.audioTransitions)
        XCTAssertEqual(library.audioTransitions.map(\.type), [.cut, .crossfade, .fadeThroughSilence])

        // "Presets 1 and 2": the built-in one as it is in code, and the Clock with the fixture's values.
        XCTAssertEqual(library.presets.map(\.number), [1, 2])
        XCTAssertEqual(library.presets.first, Preset.builtInDefault)
        XCTAssertEqual(library.presets.first, fixture.preset(1))
        var clock = try XCTUnwrap(fixture.preset(2))
        clock.uuid = try XCTUnwrap(library.preset(2)).uuid
        XCTAssertEqual(library.preset(2), clock, "Clock, value for value")

        // "text styles 1 and 2".
        var styles = Array(fixture.textStyles.prefix(2))
        for index in styles.indices { styles[index].uuid = library.textStyles[index].uuid }
        XCTAssertEqual(library.textStyles, styles)

        // "Spec 6 §9's channels 1 to 3", with the one value that isn't the fixture's: channel 2's render size.
        var channels = fixture.channels
        XCTAssertEqual(channels[1].renderSize, .size(width: 1920, height: 1080), "the fixture's channel 2 is a fixed size")
        channels[1].renderSize = .largest
        for index in channels.indices { channels[index].uuid = library.channels[index].uuid }
        XCTAssertEqual(library.channels, channels)
        XCTAssertEqual(library.channels.map(\.renderSize), [.largest, .largest, .largest], "as Spec 1 §9 shows them")
        XCTAssertEqual(library.channels.map(\.audioOutputs), [[1], [1], [1]], "all three are routed to audio output 1")

        // "empty grades and macros; an empty media index", and no lists.
        XCTAssertEqual(library.grades, [])
        XCTAssertEqual(library.macros, [])
        XCTAssertEqual(library.lists, [])
        XCTAssertEqual(library.mediaIndex, MediaIndex())
    }

    func test_theBuiltInsKeepTheirUuidsAndEverythingElseGetsANewOne() throws {
        let counter = Counter()
        let library = FirstRun.library(name: "x", uuid: counter.next)
        let fixed = library.transitions.map(\.uuid) + library.audioTransitions.map(\.uuid) + [try XCTUnwrap(library.preset(1)).uuid]
        XCTAssertTrue(Set(fixed).isDisjoint(with: counter.made), "the built-ins' are the fixtures'")
        XCTAssertEqual(fixed.first, F.uuid("7a11", 1))
        let made = [library.info.uuid] + library.channels.map(\.uuid) + library.textStyles.map(\.uuid) + [try XCTUnwrap(library.preset(2)).uuid]
        XCTAssertEqual(Set(made), Set(counter.made), "the library, its channels, its text styles and the Clock preset")
        XCTAssertEqual(Set(made).count, made.count, "each its own")
        // Two first runs make two libraries.
        let other = FirstRun.library(name: "x", uuid: { UUID() })
        XCTAssertNotEqual(other.info.uuid, library.info.uuid)
        XCTAssertNotEqual(other.channels.map(\.uuid), library.channels.map(\.uuid))
    }

    func test_theFirstRunLibraryWritesTheFixturesBytesAndLoadsBackClean() throws {
        let library = FirstRun.library(name: "Manheim Library", uuid: Counter().next)
        let written = Writer.snapshot(of: library)
        XCTAssertEqual(written.files.keys.sorted(), ["audio-transitions.json", "channels.json", "grades.json", "library.json", "media-index.json",
                                                    "presets/001-default.json", "presets/002-clock.json", "text-styles.json", "transitions.json"])
        let fixture = F.librarySnapshot
        for path in ["audio-transitions.json", "transitions.json", "presets/001-default.json"] {
            let expected = try XCTUnwrap(fixture.files[path]), actual = try XCTUnwrap(written.files[path])
            XCTAssertEqual(actual, expected, "\(path): \(ByteDiff.describe(expected: expected, actual: actual))")
        }
        let loaded = Loader.library(from: written)
        XCTAssertEqual(loaded.report.issues, [], "nothing to report")
        XCTAssertEqual(loaded.library.channels, library.channels)
        XCTAssertEqual(loaded.library.presets, library.presets)
        XCTAssertEqual(loaded.library.textStyles, library.textStyles)
    }

    func test_theLibraryIsNamedForItsCampus() {
        XCTAssertEqual(FirstRun.libraryName(campus: "Manheim"), "Manheim Library")
        XCTAssertEqual(FirstRun.libraryName(campus: ""), "Library")
    }

    // MARK: - The machine: settings

    func request(_ devices: DetectedDevices = DetectedDevices(), operatorScreen: String? = "display:OP") -> FirstRun.MachineRequest {
        FirstRun.MachineRequest(campus: "Manheim", timeZone: "America/Chicago", mediaRoot: "../library/media", devices: devices, operatorScreen: operatorScreen)
    }

    func test_theSettingsAreSpecOnesValuesWithTheCampusTheTimeZoneAndAWritableLibrary() throws {
        let counter = Counter()
        let machine = FirstRun.machine(request(), uuid: counter.next)
        let settings = machine.settings
        XCTAssertEqual(settings.uuid, counter.made.first, "a new uuid")
        XCTAssertEqual(settings.campusName, "Manheim", "the campus name from --campus")
        XCTAssertEqual(settings.timeZone, "America/Chicago", "the Mac's time zone")
        XCTAssertEqual(settings.libraryMode, .writable, "choice U-10, E-2")
        XCTAssertEqual(settings.dropChannels, .firstRun, "as Spec 8 §8 has them")
        XCTAssertEqual(settings.mediaRoot, "../library/media")
        // Everything else is Spec 1 §9's, which the fixture's machine.json shows.
        var fixture = F.load().machine.settings
        fixture.uuid = settings.uuid
        fixture.timeZone = "America/Chicago"
        fixture.libraryMode = .writable
        fixture.network.oscOutTargets = []
        fixture.startupMacro = nil
        XCTAssertEqual(settings, fixture)
        XCTAssertEqual(settings.network.apiToken, "keychain", "the token itself is the Keychain's (Spec 10 §12)")

        // "`mediaRoot` the path from the machine root to the library root's `media/`", whatever it is.
        var elsewhere = request()
        elsewhere.mediaRoot = "/Users/Shared/Central Library/media"
        XCTAssertEqual(FirstRun.machine(elsewhere, uuid: { UUID() }).settings.mediaRoot, "/Users/Shared/Central Library/media")
    }

    func test_theRestOfTheMachineIsEmpty() {
        let machine = FirstRun.machine(request(), uuid: { UUID() })
        XCTAssertEqual(machine.inputs, [], "inputs.json empty")
        XCTAssertEqual(machine.clocks, .object(["clocks": .array([])]), "clocks.json empty")
        XCTAssertEqual(machine.playlists, [], "no playlists")
        XCTAssertEqual(machine.macros, [], "no macros")
        XCTAssertEqual(machine.localLists, [])
        XCTAssertEqual(machine.mediaLocal, MediaLocalIndex())
        XCTAssertNil(machine.lastState)
    }

    /// Spec 10 §9, Defaults (R1).
    func test_theKeysAreTheDefaults() {
        let keys = FirstRun.machine(request(), uuid: { UUID() }).keys
        XCTAssertEqual(keys.map(\.device), ["keyboard", "keyboard", "keyboard", "keyboard"])
        XCTAssertEqual(keys.map(\.key), ["space", "right", "left", "shift+escape"])
        XCTAssertEqual(keys.map(\.command), [.next, .next, .previous, .systemClearAll], "Space and → send next, ← previous, ⇧⎋ clear all")
        XCTAssertFalse(keys.contains { $0.key == "escape" }, "plain Escape is never bound")
        // The fixture's keyboard bindings are these defaults (its clear-all moved to ⇧⎋ with this area).
        XCTAssertEqual(F.load().machine.keys.filter { $0.device == "keyboard" }, keys)
    }

    // MARK: - The machine: which screens become outputs (S3)

    static let hd60 = VideoFormat(width: 1920, height: 1080, rate: FrameRate(num: 60), interlaced: false)
    static let hd5994 = VideoFormat(width: 1920, height: 1080, rate: FrameRate(num: 60_000, den: 1001), interlaced: false)

    func screen(_ id: String, _ name: String, x: Double, y: Double = 0, mode: VideoFormat = hd60, mirrored: Bool = false) -> DetectedScreen {
        DetectedScreen(device: "display:" + id, name: name, frame: ScreenFrame(x: x, y: y, width: 1920, height: 1080), mode: mode, mirrored: mirrored)
    }

    var laptop: DetectedScreen { screen("OP", "Built-in Retina Display", x: 0, mode: VideoFormat(width: 3024, height: 1964, rate: FrameRate(num: 120))) }
    let ports = [DetectedPort(device: "decklink:8f3a21c0:out1", name: "DeckLink Duo 2 (1)"), DetectedPort(device: "decklink:8f3a21c0:out2", name: "DeckLink Duo 2 (2)")]
    let speakers = DetectedAudioDevice(uid: "BuiltInSpeakerDevice", name: "MacBook Pro Speakers", channels: 2, isDefault: true)

    func machine(screens: [DetectedScreen] = [], ports: [DetectedPort] = [], audio: [DetectedAudioDevice] = [], operatorScreen: String? = "display:OP") -> Machine {
        FirstRun.machine(request(DetectedDevices(screens: screens, ports: ports, audio: audio), operatorScreen: operatorScreen), uuid: { UUID() })
    }

    /// "A Mac with one screen and no card gets no outputs ...: stack 1 shows in the preview".
    func test_oneScreenAndNoCardGetsNoOutputsAndTheTwoStacks() {
        let machine = machine(screens: [laptop], audio: [speakers])
        XCTAssertEqual(machine.outputs, [], "the only screen holds the app's window")
        XCTAssertEqual(machine.stacks.map(\.number), [1, 2])
        XCTAssertEqual(machine.stacks.map(\.label), ["Main", "Confidence"])
        XCTAssertEqual(machine.stacks.map { $0.slots.map(\.channel) }, [[1, 2], [2, 3]])
        XCTAssertEqual(machine.stacks.map(\.defaultPreset), [nil, nil], "no default preset (Spec 6 §9)")
    }

    /// "and neither does one whose screens are mirrored, which macOS reports as one screen".
    func test_mirroredScreensAreOneScreenAndGetNoOutputs() {
        var mirrored = laptop
        mirrored.mirrored = true
        XCTAssertEqual(machine(screens: [mirrored]).outputs, [])
    }

    func test_aSecondScreenBecomesOutputOneInItsCurrentMode() throws {
        let wall = screen("AA", "DELL U2720Q", x: 1512, mode: VideoFormat(width: 3840, height: 2160, rate: FrameRate(num: 60), interlaced: false))
        let machine = machine(screens: [laptop, wall], audio: [speakers])
        XCTAssertEqual(machine.outputs.count, 1, "the operator's screen is never an output")
        let output = try XCTUnwrap(machine.outputs.first)
        XCTAssertEqual(output.number, 1)
        XCTAssertEqual(output.kind, .display)
        XCTAssertEqual(output.device, "display:AA")
        XCTAssertEqual(output.label, "DELL U2720Q", "labels are the devices' names")
        XCTAssertEqual(output.format, VideoFormat(width: 3840, height: 2160, rate: FrameRate(num: 60), interlaced: false), "its current mode")
        XCTAssertEqual(output.colorRange, .full)
        XCTAssertNil(output.genlock, "SDI only")
        XCTAssertEqual(output.defaultStack, 1, "output 1 is the main look")
        XCTAssertEqual(output.transitions, OutputTransitions(switch: 1, blackout: 2), "cut for switches, dissolve for blackout")
        XCTAssertEqual(machine.stacks.map(\.number), [1, 2], "one output: no further stack")
    }

    /// "screens left to right, top to bottom where two share a left edge"; "then one stack per further output with
    /// channels 1 and 2, output N's being stack N + 1, labeled like its output".
    func test_screensAreNumberedLeftToRightThenTopToBottomAndEachFurtherOutputHasItsStack() {
        let machine = machine(screens: [
            screen("CC", "Right", x: 3432),
            screen("BB", "Lower left", x: -1920, y: 1080),
            laptop,
            screen("AA", "Upper left", x: -1920, y: 0),
        ])
        XCTAssertEqual(machine.outputs.map(\.label), ["Upper left", "Lower left", "Right"], "by left edge, then by top edge; the list's own order doesn't matter")
        XCTAssertEqual(machine.outputs.map(\.number), [1, 2, 3])
        XCTAssertEqual(machine.outputs.map(\.defaultStack), [1, 3, 4], "output N's being stack N + 1")
        XCTAssertEqual(machine.stacks.map(\.number), [1, 2, 3, 4])
        XCTAssertEqual(machine.stacks.map(\.label), ["Main", "Confidence", "Lower left", "Right"], "labeled like its output")
        XCTAssertEqual(machine.stacks.map { $0.slots.map(\.channel) }, [[1, 2], [2, 3], [1, 2], [1, 2]])
        XCTAssertFalse(machine.outputs.contains { $0.defaultStack == 2 }, "stack 2, Confidence, is on no output")
        XCTAssertEqual(Set(machine.outputs.map(\.uuid)).count, 3)
    }

    /// "Every DeckLink output port, then every screen ...: ports in the order the driver lists them".
    func test_deckLinkPortsComeFirstAt1080ProgressiveLimitedAndFreeRunning() throws {
        let machine = machine(screens: [laptop, screen("AA", "Lobby", x: 1512)], ports: ports, audio: [speakers])
        XCTAssertEqual(machine.outputs.map(\.kind), [.sdi, .sdi, .display])
        XCTAssertEqual(machine.outputs.map(\.label), ["DeckLink Duo 2 (1)", "DeckLink Duo 2 (2)", "Lobby"])
        XCTAssertEqual(machine.outputs.map(\.device), ["decklink:8f3a21c0:out1", "decklink:8f3a21c0:out2", "display:AA"])
        let port = try XCTUnwrap(machine.outputs.first)
        XCTAssertEqual(port.format, Self.hd60, "1920 by 1080, progressive, 60 beside 60 Hz screens")
        XCTAssertEqual(port.colorRange, .limited)
        XCTAssertEqual(port.genlock, .freeRun)
        XCTAssertEqual(port.transitions, OutputTransitions(switch: 1, blackout: 2))
        XCTAssertEqual(machine.outputs.map(\.defaultStack), [1, 3, 4])
        XCTAssertEqual(machine.stacks.map(\.label), ["Main", "Confidence", "DeckLink Duo 2 (2)", "Lobby"])
    }

    /// "in the displays' rate family: 60 beside 60 Hz screens, 59.94 beside 59.94 Hz screens or with no screen
    /// output (choice U-11, Spec 4 §2)".
    func test_aPortTakesTheScreensRateFamily() {
        let fractional = FrameRate(num: 60_000, den: 1001)
        XCTAssertEqual(machine(screens: [laptop, screen("AA", "Lobby", x: 1512, mode: Self.hd5994)], ports: ports).outputs.first?.format.rate, fractional,
                       "59.94 beside a 59.94 Hz screen")
        XCTAssertEqual(machine(screens: [laptop], ports: ports).outputs.first?.format.rate, fractional, "59.94 with no screen output: the laptop's 120 Hz doesn't count")
        XCTAssertEqual(machine(ports: ports, operatorScreen: nil).outputs.first?.format.rate, fractional, "and with no screen at all")
        XCTAssertEqual(machine(screens: [laptop, screen("AA", "Wall", x: 1512, mode: VideoFormat(width: 2560, height: 1440, rate: FrameRate(num: 144)))],
                               ports: ports).outputs.first?.format.rate, FrameRate(num: 60), "a whole-number rate is the 60 family")
        // Area 19 reading: with screens of both families, the first screen output's.
        let both = machine(screens: [laptop, screen("BB", "Right", x: 3432), screen("AA", "Left", x: -1920, mode: Self.hd5994)], ports: ports)
        XCTAssertEqual(both.outputs.first?.format.rate, fractional, "the leftmost screen output is the 59.94 one")
        XCTAssertEqual(both.outputs.suffix(2).map(\.format.rate), [fractional, FrameRate(num: 60)], "and each screen keeps its own mode")
    }

    func test_aScreensOutputIsProgressiveWhateverItsModeSays() {
        var mode = Self.hd60
        mode.interlaced = true
        XCTAssertEqual(machine(screens: [laptop, screen("AA", "Old TV", x: 1512, mode: mode)]).outputs.first?.format.interlaced, false)
    }

    /// Area 19 reading — when the app named its screen and that screen isn't
    /// among the Mac's, no screen becomes an output: any might be the app's.
    func test_whenTheOperatorsScreenIsNotAmongTheScreensNoScreenBecomesAnOutput() {
        let machine = machine(screens: [screen("AA", "Left", x: 0), screen("BB", "Right", x: 1920)], ports: ports, operatorScreen: "display:GONE")
        XCTAssertEqual(machine.outputs.map(\.kind), [.sdi, .sdi], "the card's ports are no one's window")
        // The name is matched as a display's uuid, whatever its case.
        let lower = self.machine(screens: [screen("AA", "Left", x: 0), screen("BB", "Right", x: 1920)], operatorScreen: "display:aa")
        XCTAssertEqual(lower.outputs.map(\.label), ["Right"])
        // With no screen named at all, every screen is an output.
        let unnamed = self.machine(screens: [screen("AA", "Left", x: 0), screen("BB", "Right", x: 1920)], operatorScreen: nil)
        XCTAssertEqual(unnamed.outputs.map(\.label), ["Left", "Right"])
    }

    // MARK: - The machine: audio outputs

    /// "Audio output 1, the system's default output device at first run, by its UID, with its first two channels;
    /// then one per DeckLink output's embedded audio, which no channel feeds until someone routes one".
    func test_audioOutputOneIsTheDefaultDeviceAndEachSdiOutputHasItsEmbeddedAudio() throws {
        let other = DetectedAudioDevice(uid: "BlackHole2ch_UID", name: "BlackHole 2ch", channels: 2)
        let machine = machine(screens: [laptop, screen("AA", "Lobby", x: 1512)], ports: ports, audio: [other, speakers])
        XCTAssertEqual(machine.audioOutputs.map(\.number), [1, 2, 3])
        let first = try XCTUnwrap(machine.audioOutputs.first)
        XCTAssertEqual(first.kind, .device)
        XCTAssertEqual(first.device, .uid("BuiltInSpeakerDevice"), "the default device, by its UID")
        XCTAssertEqual(first.channels, [0, 1], "its first two channels")
        XCTAssertEqual(first.label, "MacBook Pro Speakers")
        XCTAssertEqual(first.delayMs, 0)
        XCTAssertNil(first.fallbackDevice)
        XCTAssertEqual(machine.audioOutputs.dropFirst().map(\.kind), [.sdiEmbedded, .sdiEmbedded])
        XCTAssertEqual(machine.audioOutputs.dropFirst().map(\.device), [.sdiOutput(1), .sdiOutput(2)], "each SDI output's own")
        XCTAssertEqual(machine.audioOutputs.dropFirst().map(\.label), ["DeckLink Duo 2 (1) embedded", "DeckLink Duo 2 (2) embedded"])
        // "which no channel feeds": the first-run channels are routed to audio output 1 alone.
        let library = FirstRun.library(name: "x", uuid: { UUID() })
        XCTAssertEqual(Set(library.channels.flatMap(\.audioOutputs)), [1])
    }

    /// Area 19 readings — no default device: no audio output 1, and the
    /// embedded ones still start at 2, so the channels feed none of them.
    func test_withNoDefaultDeviceThereIsNoAudioOutputOneAndTheEmbeddedOnesKeepTheirNumbers() {
        let machine = machine(ports: ports, audio: [DetectedAudioDevice(uid: "X", name: "Not default", channels: 2)], operatorScreen: nil)
        XCTAssertEqual(machine.audioOutputs.map(\.number), [2, 3])
        XCTAssertEqual(self.machine().audioOutputs, [], "no device, no card: none")
        // A device with one channel is given the one it has.
        let mono = self.machine(audio: [DetectedAudioDevice(uid: "M", name: "Mono", channels: 1, isDefault: true)])
        XCTAssertEqual(mono.audioOutputs.first?.channels, [0])
    }

    // MARK: - The whole of it

    /// What first run writes refers only to what it writes: the library and
    /// the machine check against each other with nothing to report, whatever
    /// the Mac has, and the machine's documents load back as they were made.
    func test_theFirstRunRootsValidateCleanAndRoundTrip() throws {
        let library = FirstRun.library(name: "Manheim Library", uuid: { UUID() })
        let lists: [(String, Machine)] = [
            ("a laptop alone", machine(screens: [laptop], audio: [speakers])),
            ("a laptop and a wall", machine(screens: [laptop, screen("AA", "Wall", x: 1512)], audio: [speakers])),
            ("a card and two screens", machine(screens: [laptop, screen("AA", "Wall", x: 1512), screen("BB", "Lobby", x: 3432)], ports: ports, audio: [speakers])),
        ]
        for (name, machine) in lists {
            let report = Validator.validate(library: library, machine: machine)
            XCTAssertEqual(report.issues, [], name)
            let written = Writer.snapshot(of: machine)
            XCTAssertEqual(written.files.keys.sorted(), ["audio-outputs.json", "clocks.json", "inputs.json", "keys.json", "machine.json", "media-local.json",
                                                        "outputs.json", "stacks.json"], name)
            let loaded = Loader.machine(from: written)
            XCTAssertEqual(loaded.report.issues, [], name)
            XCTAssertEqual(loaded.machine.settings, machine.settings, name)
            XCTAssertEqual(loaded.machine.outputs, machine.outputs, name)
            XCTAssertEqual(loaded.machine.stacks, machine.stacks, name)
            XCTAssertEqual(loaded.machine.audioOutputs, machine.audioOutputs, name)
            XCTAssertEqual(loaded.machine.keys, machine.keys, name)
        }
    }
}
