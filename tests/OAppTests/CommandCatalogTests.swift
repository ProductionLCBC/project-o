import Foundation
import XCTest
import OCore
@testable import OApp

/// Spec 11 §4 and §9 as corrected 2026-11-25 (G-37) — the command browser's tree, a macro row's short tags, and the
/// stage's transition and audio previews, over the engine's recorded catalog.
@MainActor
final class CommandCatalogTests: XCTestCase {
    typealias Rig = ShowModelTests.Rig

    override func setUp() async throws {
        try await MainActor.run { try CatalogFile.install() }
    }

    /// "grouped by what they touch and offering only what exists ... and, in a macro (§9), Channels".
    func test_theTreeGroupsTheCommandsAndAMacrosAddsChannels() throws {
        let rig = try Rig()
        let catalog = try XCTUnwrap(rig.model.store.catalog)
        let cue = CommandCatalog.groups(catalog: catalog)
        XCTAssertEqual(cue.map(\.title), ["Playback", "Stacks and outputs", "Audio", "Macros", "Timers", "Popups", "System"])
        XCTAssertEqual(cue[0].leaves.map(\.title), ["Next", "Previous", "Go to Cue…", "Go to a List’s Cue…", "Go to an Item’s Cue…",
                                                    "Go to a Section…", "Load Playlist…", "Disarm"])
        XCTAssertEqual(cue.last?.leaves.map(\.title), ["Clear All", "Preflight", "Snapshot", "Undo", "Redo"])
        let macro = CommandCatalog.groups(catalog: catalog, macro: 1)
        XCTAssertEqual(macro.map(\.title), ["Playback", "Channels", "Stacks and outputs", "Audio", "Macros", "Timers", "Popups", "System"])
        XCTAssertEqual(macro[1].leaves.count, 12)
        // "one that would call the macro being edited again is marked Recursive and not offered".
        let macros = try XCTUnwrap(macro.first { $0.title == "Macros" })
        XCTAssertEqual(macros.leaves.map(\.refused), ["Recursive", nil], "macro 1 itself; Preshow doesn't call it")
        // The search: "case and accents ignored"; a group's name finds all of it.
        XCTAssertEqual(CommandCatalog.filter(macro, "TIMER").map(\.title), ["Timers"])
        XCTAssertEqual(CommandCatalog.filter(macro, "go cue").flatMap { $0.leaves.map(\.title) }, ["Go to Cue…", "Go to a List’s Cue…", "Go to an Item’s Cue…"])
        XCTAssertEqual(CommandCatalog.filter(macro, "zzz"), [])
    }

    /// Each leaf builds its command from its form, and nothing while a field it needs is missing.
    func test_eachLeafBuildsItsCommand() {
        func text(_ kind: CommandLeaf.Kind, _ values: [String: CommandValue]) -> String? {
            CommandCatalog.build(kind, values).flatMap { CommandText.print($0) }
        }
        XCTAssertEqual(text(.next, [:]), "next")
        XCTAssertEqual(text(.cue, ["cue": .int(4)]), "cue 4")
        XCTAssertNil(text(.cue, [:]))
        XCTAssertEqual(text(.listCue, ["list": .int(42), "cue": .int(3)]), "list 42 cue 3")
        XCTAssertEqual(text(.itemSection, ["item": .int(2), "section": .text("Chorus")]), "item 2 section \"Chorus\"")
        XCTAssertEqual(text(.writeText, ["channel": .int(2), "body": .text("Welcome")]), "channel 2 write text \"Welcome\"")
        XCTAssertEqual(text(.transport, ["channel": .int(1), "mode": .text("pause")]), "channel 1 pause")
        XCTAssertEqual(text(.endBehavior, ["channel": .int(1), "mode": .text("hold")]), CommandText.print(.channelEndBehavior(channel: .number(1), mode: .hold)))
        XCTAssertEqual(text(.lock, ["channel": .int(1), "locked": .bool(true)]), CommandText.print(.channelLock(channel: .number(1), locked: true)))
        XCTAssertEqual(text(.grade, ["channel": .int(1), "ref": .int(1), "ms": .int(500)]), CommandText.print(.channelGrade(channel: .number(1), ref: 1, ms: 500)))
        XCTAssertNil(text(.gain, ["channel": .int(1), "db": .text("90")]), "a gain is between -60 and 60 dB")
        XCTAssertEqual(text(.audioMute, ["audio": .int(1), "state": .text("toggle")]), CommandText.print(.audioMute(audio: .number(1), state: .toggle)))
        XCTAssertEqual(text(.timerSet, ["timer": .int(1), "duration": .int(300_000), "up": .bool(true)]), CommandText.print(.timerSet(timer: 1, ms: 300_000, up: true)))
        XCTAssertEqual(text(.macro(2), [:]), "macro 2")
        XCTAssertEqual(text(.undo, [:]), "undo")
    }

    /// "Recursive (it calls a macro that calls this one ...), Missing (it names ... that doesn't exist), Unknown ...,
    /// and Edits library".
    func test_aMacrosRowSaysWhatIsWrongInAShortTag() throws {
        let rig = try Rig()
        let catalog = try XCTUnwrap(rig.model.store.catalog)
        let media = rig.model.store.media
        let a = Macro(number: 7, commands: [GuardedCommand(.macro(8))])
        let b = Macro(number: 8, commands: [GuardedCommand(.macro(7))])
        XCTAssertTrue(MacroCheck.reaches(8, 7, macros: [a, b]))
        XCTAssertTrue(MacroCheck.reaches(7, 7, macros: [a]))
        XCTAssertFalse(MacroCheck.reaches(2, 1, macros: catalog.macros))
        XCTAssertEqual(MacroCheck.warning(.macro(1), in: 1, catalog: catalog, media: media), .recursive)
        XCTAssertEqual(MacroCheck.warning(.macro(9), in: 1, catalog: catalog, media: media), .missing)
        XCTAssertEqual(MacroCheck.warning(.channelClear(channel: .number(99)), in: 1, catalog: catalog, media: media), .missing)
        XCTAssertEqual(MacroCheck.warning(.channelGrade(channel: .number(1), ref: 0, ms: nil), in: 1, catalog: catalog, media: media), nil, "grade 0 is None")
        XCTAssertEqual(MacroCheck.warning(.channelWrite(ChannelWrite(channel: .number(1), content: .media(MediaContent(ref: "sha256:00")))), in: 1,
                                          catalog: catalog, media: media), .missing)
        XCTAssertEqual(MacroCheck.warning(.edit(EditCommand(.numbered(.grade, 1), .set(path: "hue", value: .number(0)))), in: 1, catalog: catalog, media: media),
                       .changesLibrary)
        XCTAssertEqual(MacroCheck.warning(.unknown(cmd: "future.thing"), in: 1, catalog: catalog, media: media), .keptVerbatim)
        XCTAssertEqual(MacroCheck.warning(.timerStart(timer: 1), in: 1, catalog: catalog, media: media), nil)
        XCTAssertEqual([CueCommandLine.Warning.recursive, .missing, .keptVerbatim, .changesLibrary].map(EditModeWording.warning),
                       ["Recursive", "Missing", "Unknown", "Edits library"])
        XCTAssertEqual(EditWording.rejection(code: "cycle"), "Recursive macro")
    }

    /// "a dissolve's mix by the eased progress, fade through a colour to the colour by the first half and from it by the
    /// second, a cut at the trigger".
    func test_theTransitionPreviewMixesAsTheChannelPassDoes() {
        func w(_ type: TransitionType, _ t: Double, _ easing: Easing = .linear) -> [Double] {
            let m = TransitionMix.weights(type, easing: easing, at: t)
            return [m.outgoing, m.color, m.incoming]
        }
        XCTAssertEqual(w(.cut, 0), [1, 0, 0])
        XCTAssertEqual(w(.cut, 0.01), [0, 0, 1])
        XCTAssertEqual(w(.dissolve, 0.25), [0.75, 0, 0.25])
        XCTAssertEqual(w(.dissolve, 0.5, .easeIn), [0.75, 0, 0.25], "eased")
        XCTAssertEqual(w(.fadeThroughColor, 0.25), [0.5, 0.5, 0])
        XCTAssertEqual(w(.fadeThroughColor, 0.5), [0, 1, 0])
        XCTAssertEqual(w(.fadeThroughColor, 0.75), [0, 0.5, 0.5])
        XCTAssertEqual(w(.fadeThroughColor, 1), [0, 0, 1])
    }

    /// "a J cut delays the picture transition, an L cut delays the audio transition" (UX spec); the gains as Spec 4
    /// §11 applies them, with the object's easing.
    func test_theAudioLanesFollowTheOffsetTheTypeAndTheEasing() {
        func t(_ type: AudioTransitionType, ms: Int = 1000, offset: Int = 0, easing: Easing = .linear) -> AudioTransition {
            AudioTransition(number: 1, type: type, ms: ms, offsetMs: offset, easing: easing)
        }
        XCTAssertTrue(AudioFade.starts(t(.crossfade, offset: 250)) == (250, 0), "an L cut: the sound starts later")
        XCTAssertTrue(AudioFade.starts(t(.crossfade, offset: -250)) == (0, 250), "a J cut: the picture starts later")
        XCTAssertTrue(AudioFade.gains(t(.crossfade), at: 500) == (0.5, 0.5))
        XCTAssertTrue(AudioFade.gains(t(.crossfade, offset: 500), at: 500) == (1, 0), "not yet started")
        XCTAssertTrue(AudioFade.gains(t(.crossfade, easing: .easeIn), at: 500) == (0.75, 0.25))
        XCTAssertTrue(AudioFade.gains(t(.fadeThroughSilence), at: 250) == (0.5, 0))
        XCTAssertTrue(AudioFade.gains(t(.fadeThroughSilence), at: 750) == (0, 0.5))
        XCTAssertTrue(AudioFade.gains(t(.cut, offset: 100), at: 99) == (1, 0))
        XCTAssertTrue(AudioFade.gains(t(.cut, offset: 100), at: 100) == (0, 1))
    }
}
