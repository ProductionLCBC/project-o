import Foundation
import XCTest
@testable import OCore

/// Spec 1 §10 — Validation report: "Each broken-reference case in section 8
/// produces exactly the documented degrade and one report line; malformed JSON
/// and a too-new schema fail without touching the previous state."
final class ValidationReportTests: XCTestCase {
    typealias F = FixtureLibrary

    private func fresh() -> (Library, Machine) {
        let loaded = F.load()
        return (loaded.library, loaded.machine)
    }

    private func report(_ library: Library, _ machine: Machine?, environment: ValidationEnvironment = ValidationEnvironment()) -> ValidationReport {
        Validator.validate(library: library, machine: machine, environment: environment)
    }

    private func only(_ code: IssueCode, in report: ValidationReport, file: StaticString = #filePath, line: UInt = #line) -> ValidationIssue? {
        XCTAssertEqual(report.issues.map(\.code), [code], report.lines.joined(separator: "\n"), file: file, line: line)
        return report.issues.first
    }

    // MARK: - §8 reference checks

    /// "a cue writing a deleted channel" → one line; the projection already
    /// answers `noop` for an unknown channel (Spec 3 §6).
    func test_aCueWritingADeletedChannelIsReportedOnceAndIgnoredAtUse() {
        var (library, machine) = fresh()
        library.channels.removeAll { $0.number == 1 }
        // Keep one cue that writes the deleted channel; clear the other places that name channel 1.
        library.lists = library.lists.filter { $0.number == 42 }
        library.lists[0].cues = [library.lists[0].cues[0]]
        library.mediaIndex.entries = library.mediaIndex.entries.map { entry in
            var e = entry
            if e.defaults.defaultChannel == 1 { e.defaults.defaultChannel = nil }
            return e
        }
        let issue = only(.missingChannel, in: report(library, nil))
        XCTAssertEqual(issue?.subject, "list 42 cue 1")
        XCTAssertEqual(issue?.severity, .warning)
        XCTAssertTrue(issue?.message.contains("channel 1") == true)
        machine.localLists = []

        let context = ProjectionContext(frame: 1, library: library, machine: machine, source: CommandSource(kind: .ui))
        let (_, effects) = project(ShowState.fresh(library: library, machine: machine), [.listCue(list: 42, cue: 1)], context: context)
        XCTAssertTrue(effects.contains { if case .noop(.channelWrite) = $0 { return true } else { return false } }, "\(effects)")
    }

    /// "a slot naming a missing preset" → one line; degrade: Preset 1.
    func test_aSlotNamingAMissingPresetDegradesToPresetOne() {
        var (library, machine) = fresh()
        machine.stacks[1].slots[1].preset = 9
        let issue = only(.missingPreset, in: report(library, machine))
        XCTAssertEqual(issue?.subject, "stack 2 slot 2")
        XCTAssertEqual(library.resolvedPreset(9).number, 1)
        XCTAssertEqual(library.resolvedPreset(nil).number, 1)
        XCTAssertEqual(library.resolvedPreset(2).number, 2)
        library.presets.removeAll { $0.number == 1 }
        XCTAssertEqual(library.resolvedPreset(9), Preset.builtInDefault, "without a preset 1 on disk the built-in one applies")
        XCTAssertEqual(machine.stack(2)?.effectiveSlots(library: library)[1].preset, 9, "the slot itself is not rewritten")
    }

    /// Channel and stack default presets, and the built-in preset 1 missing.
    func test_defaultPresetsAreCheckedAndTheBuiltInIsExpected() {
        var (library, machine) = fresh()
        library.channels[0].defaultPreset = 7
        XCTAssertEqual(only(.missingPreset, in: report(library, machine))?.subject, "channel 1")
        library.channels[0].defaultPreset = 1
        machine.stacks[1].defaultPreset = 8
        XCTAssertEqual(only(.missingPreset, in: report(library, machine))?.subject, "stack 2")
        machine.stacks[1].defaultPreset = 2
        library.presets.removeAll { $0.number == 1 }
        XCTAssertEqual(only(.missingBuiltIn, in: report(library, machine))?.subject, "preset 1")
    }

    /// "duplicate channels in a stack" (the §9 rule: at each offset) → one
    /// line; degrade: an empty slot, which is the slot dropped from the
    /// effective list. Distinct offsets of one channel are accepted.
    func test_duplicateSlotsAreReportedOnceAndDroppedAtUse() {
        var (library, machine) = fresh()
        machine.stacks[0].slots.append(StackSlot(channel: 2, preset: 3, offset: 0, opacity: 0.5, mute: false))
        let issue = only(.duplicateSlot, in: report(library, machine))
        XCTAssertEqual(issue?.subject, "stack 1 slot 3")
        XCTAssertEqual(machine.stack(1)?.effectiveSlots(library: library).map(\.channel), [1, 2])
        XCTAssertEqual(machine.stack(2)?.effectiveSlots(library: library).count, 2, "offset slots of one channel are distinct")
    }

    /// "duplicate numbers within a type" → one line; lookup keeps the first.
    func test_duplicateNumbersAreReportedOnceAndTheFirstWins() {
        var (library, machine) = fresh()
        var copy = library.transitions[1]
        copy.label = "Dissolve again"
        copy.uuid = F.uuid("dead", 1)
        library.transitions.append(copy)
        let issue = only(.duplicateNumber, in: report(library, machine))
        XCTAssertEqual(issue?.subject, "transition 2")
        XCTAssertEqual(library.transition(2)?.label, "Dissolve")
    }

    /// "media ids with no path" → one line for an id in neither index.
    func test_anUnindexedMediaIdIsReportedOnce() {
        var (library, machine) = fresh()
        let ghost = "sha256:" + String(repeating: "ab", count: 32)
        library.lists[1].cues[1].commands.append(GuardedCommand(.channelWrite(ChannelWrite(channel: .number(1), content: .media(MediaContent(ref: ghost))))))
        let issue = only(.unknownMedia, in: report(library, machine))
        XCTAssertEqual(issue?.subject, "list 42 cue 2")
        XCTAssertTrue(issue?.message.contains(ghost) == true)
    }

    /// Spec 1 §7 — "Missing state is computed, never stored": with the file
    /// list in hand, an indexed id whose file is absent is listed once.
    func test_anIndexedIdWhoseFileIsAbsentIsListedByPreflight() {
        let (library, machine) = fresh()
        let environment = ValidationEnvironment(existingMediaPaths: F.existingMediaPaths)
        let issue = only(.missingMedia, in: report(library, machine, environment: environment))
        XCTAssertEqual(issue?.subject, F.mountains)
        XCTAssertTrue(issue?.message.contains("backgrounds/mountains.mp4") == true)
        XCTAssertEqual(MediaResolver.missingIds(library: library, machine: machine, existingPaths: F.existingMediaPaths), [F.mountains])
    }

    /// "fonts not installed" → one line per font, when the installed set is known.
    func test_fontsNotInstalledAreReportedOncePerFont() {
        let (library, machine) = fresh()
        let environment = ValidationEnvironment(installedFonts: ["HelveticaNeue", "HelveticaNeue-Bold"])
        let issue = only(.fontNotInstalled, in: report(library, machine, environment: environment))
        XCTAssertEqual(issue?.subject, "HelveticaNeue-Medium")
        let none = report(library, machine, environment: ValidationEnvironment(installedFonts: ["HelveticaNeue", "HelveticaNeue-Bold", "HelveticaNeue-Medium"]))
        XCTAssertEqual(none.issues, [])
    }

    /// A rider naming a missing transition → one line; degrade (Spec 1 §8,
    /// Adam's answer on the Area 2 brief): the channel's default transition as
    /// it is defined; when that is missing too, a zero-second cut.
    func test_aMissingTransitionIsReportedOnceAndPlaysAsTheChannelDefault() {
        var (library, machine) = fresh()
        library.lists[1].cues[0].commands[0].command.setRiders(Riders(transition: TransitionRider(ref: 9, ms: 1000, scope: .once)))
        let issue = only(.missingTransition, in: report(library, machine))
        XCTAssertEqual(issue?.subject, "list 42 cue 1")

        func effect(_ library: Library) -> TransitionEffect? {
            let context = ProjectionContext(frame: 100, library: library, machine: machine, source: CommandSource(kind: .ui))
            let (_, effects) = project(ShowState.fresh(library: library, machine: machine), [.listCue(list: 42, cue: 1)], context: context)
            return effects.compactMap(\.transitionEffect).first { $0.channel == 1 }
        }
        // Channel 1's default is transition 1, the cut.
        XCTAssertEqual(effect(library)?.transition, 1)
        XCTAssertEqual(effect(library)?.ms, 0)
        // With a dissolve as the channel default, the dissolve plays at its own duration, not the rider's.
        library.channels[0].defaults.transition = 2
        XCTAssertEqual(effect(library)?.transition, 2)
        XCTAssertEqual(effect(library)?.ms, 500)
        // With the channel default missing too: a zero-second cut, the ref as the cue asked for it.
        library.channels[0].defaults.transition = 8
        XCTAssertEqual(effect(library)?.transition, 9)
        XCTAssertEqual(effect(library)?.ms, 0)
        XCTAssertEqual(report(library, machine).issues.map(\.code), [.missingTransition, .missingTransition])

        library.lists[1].cues[0].commands[0].command.setRiders(Riders(transition: TransitionRider(ref: 2, ms: 1000, scope: .once)))
        XCTAssertEqual(only(.missingTransition, in: report(library, machine))?.subject, "channel 1")
    }

    func test_otherReferencesAreCheckedOnce() {
        var (library, machine) = fresh()
        machine.outputs[0].defaultStack = 5
        XCTAssertEqual(only(.missingStack, in: report(library, machine))?.subject, "output 1")
        machine.outputs[0].defaultStack = 1

        machine.settings.startupMacro = 9
        XCTAssertEqual(only(.missingMacro, in: report(library, machine))?.subject, "machine startupMacro")
        machine.settings.startupMacro = 2

        machine.playlists[0].items.append(PlaylistItem.linked(list: 99))
        XCTAssertEqual(only(.missingList, in: report(library, machine))?.subject, "playlist Sunday 2026-11-01 item 6")
        machine.playlists[0].items.removeLast()

        machine.audioOutputs[1].device = .sdiOutput(4)
        XCTAssertEqual(only(.missingOutput, in: report(library, machine))?.subject, "audio output 2")
        machine.audioOutputs[1].device = .sdiOutput(2)

        library.channels[1].audioOutputs = [1, 3]
        XCTAssertEqual(only(.missingAudioOutput, in: report(library, machine))?.subject, "channel 2")
        library.channels[1].audioOutputs = [1]

        library.channels[1].defaults.audioTransition = 6
        XCTAssertEqual(only(.missingAudioTransition, in: report(library, machine))?.subject, "channel 2")
        library.channels[1].defaults.audioTransition = 1

        library.presets[2].layouts[.any]?.boxes[0].grade = 4
        XCTAssertEqual(only(.missingGrade, in: report(library, machine))?.subject, "preset 3 layout * box 1")
        library.presets[2].layouts[.any]?.boxes[0].grade = 1

        library.presets[0].layouts[.any]?.boxes[1].textStyle?.fromStyle = 5
        XCTAssertEqual(only(.missingTextStyle, in: report(library, machine))?.subject, "preset 1 layout * box 2")
        library.presets[0].layouts[.any]?.boxes[1].textStyle?.fromStyle = 1

        library.presets[2].layouts[.stack(4)] = library.presets[2].layouts[.stack(2)]
        XCTAssertEqual(only(.missingStack, in: report(library, machine))?.subject, "preset 3 layout 4")
        library.presets[2].layouts[.stack(4)] = nil

        machine.stacks[0].slots[0].offset = 4
        XCTAssertEqual(only(.slotOutOfRange, in: report(library, machine))?.subject, "stack 1 slot 1")
        machine.stacks[0].slots[0].offset = 0

        machine.keys[0].command = .macro(7)
        XCTAssertEqual(only(.missingMacro, in: report(library, machine))?.subject, "key binding 1")
        machine.keys[0].command = .next

        library.lists[1].cues[0].commands.append(GuardedCommand(.channelWrite(ChannelWrite(channel: .number(1), content: .input(3)))))
        XCTAssertEqual(only(.missingInput, in: report(library, machine))?.subject, "list 42 cue 1")
        library.lists[1].cues[0].commands.removeLast()

        XCTAssertEqual(report(library, machine).issues, [])
        XCTAssertEqual(report(library, nil).issues, [], "a library validates on its own; machine references are met by number later")
    }

    /// Spec 2 §5 — "cycles are rejected at save": a cycle is one line naming it.
    func test_aMacroCycleIsReportedOnce() {
        var (library, machine) = fresh()
        library.macros[0].commands.append(GuardedCommand(.macro(2)))
        machine.macros[0].commands.append(GuardedCommand(.macro(1)))
        let issue = only(.macroCycle, in: report(library, machine))
        XCTAssertEqual(issue?.subject, "macro 1")
        XCTAssertTrue(issue?.message.contains("macro 1 → macro 2 → macro 1") == true, issue?.message ?? "")
    }

    /// Spec 1 §3 — "the pair of title and date must be unique on a machine (case-insensitive)".
    func test_aPlaylistNameClashIsReportedOnce() {
        var (library, machine) = fresh()
        var twin = machine.playlists[0]
        twin.uuid = F.uuid("b1a7", 2)
        twin.title = "SUNDAY"
        machine.playlists.append(twin)
        XCTAssertEqual(only(.playlistNameClash, in: report(library, machine))?.subject, "playlist SUNDAY 2026-11-01")
        machine.playlists[1].serviceDate = nil
        XCTAssertEqual(report(library, machine).issues, [], "a different date is a different name")
    }

    // MARK: - §6 commands

    /// Spec 1 §6 — "flags unknown commands or bad parameters on the cue rather
    /// than dropping them"; Spec 2 §7 — guards on cue commands are "rejected by
    /// the v1 validator, so the field exists without the behaviour".
    func test_unknownInvalidAndGuardedCueCommandsAreFlaggedOnTheCue() throws {
        var (library, machine) = fresh()
        let unknown = try JSONCoding.decode(GuardedCommand.self, from: .object(["cmd": .string("channel.teleport"), "channel": .number(2)]))
        let invalid = try JSONCoding.decode(GuardedCommand.self, from: .object(["cmd": .string("channel.clear"), "channel": .string("two")]))
        library.lists[1].cues[0].commands.append(unknown)
        library.lists[1].cues[1].commands.append(invalid)
        library.lists[1].cues[2].commands[0].when = Guard(variable: "Timer 1", op: .is, value: "0:00")
        let result = report(library, machine)
        XCTAssertEqual(result.issues.map(\.code), [.unknownCommand, .invalidCommand, .guardOnCue])
        XCTAssertEqual(result.issues.map(\.subject), ["list 42 cue 1 command 3", "list 42 cue 2 command 2", "list 42 cue 3 command 1"])
        XCTAssertTrue(result.issues[1].message.contains("channel"), result.issues[1].message)
        XCTAssertTrue(result.issues.allSatisfy { $0.severity == .warning })
    }

    // MARK: - §8 hard failures

    /// "Hard failures are only malformed JSON and a schema newer than the app
    /// can read. Both leave the previous good state in place and surface a plain
    /// message naming the file."
    func test_malformedJSONAndATooNewSchemaFailWithoutTouchingThePreviousState() throws {
        let good = F.load()
        var broken = F.librarySnapshot
        broken.files["channels.json"] = Data("{ \"channels\": [ ".utf8)
        var tooNew = try JSONValue.parse(try XCTUnwrap(F.librarySnapshot.files["transitions.json"]))
        tooNew = tooNew.setting("schema", to: .number(99))
        broken.files["transitions.json"] = JSONCanonical.data(tooNew)

        XCTAssertThrowsError(try Loader.document(path: "channels.json", data: try XCTUnwrap(broken.files["channels.json"]))) { error in
            guard case DocumentFailure.malformedJSON(let path, let line, _, _) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(path, "channels.json")
            XCTAssertEqual(line, 1)
        }
        XCTAssertThrowsError(try Loader.document(path: "transitions.json", data: try XCTUnwrap(broken.files["transitions.json"]))) { error in
            guard case DocumentFailure.schemaTooNew(let path, let found, let supported) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(path, "transitions.json")
            XCTAssertEqual(found, 99)
            XCTAssertEqual(supported, OCore.schemaVersion)
        }

        let reloaded = Loader.library(from: broken, previous: good.library)
        XCTAssertEqual(reloaded.library, good.library, "the previous good state stays in place")
        XCTAssertEqual(reloaded.report.issues.map(\.code), [.malformedJSON, .schemaTooNew])
        XCTAssertEqual(reloaded.report.issues.map(\.file), ["channels.json", "transitions.json"])
        XCTAssertTrue(reloaded.report.issues.allSatisfy { $0.severity == .error })

        let first = Loader.library(from: broken)
        XCTAssertEqual(first.library.channels, [], "with no previous state the document is simply absent")
        XCTAssertEqual(first.library.transitions, [])
        XCTAssertEqual(first.library.lists.map(\.number), [7, 42], "the rest of the root still loads")
    }

    /// A well-formed file of the wrong shape is unreadable; it names the path
    /// inside the file.
    func test_aDocumentOfTheWrongShapeIsUnreadableAndNamesWhere() throws {
        var tree = try JSONValue.parse(try XCTUnwrap(F.librarySnapshot.files["channels.json"]))
        var channels = tree["channels"]?.arrayValue ?? []
        channels[0] = channels[0].setting("number", to: .string("one"))
        tree = tree.setting("channels", to: .array(channels))
        XCTAssertThrowsError(try Loader.document(path: "channels.json", data: JSONCanonical.data(tree))) { error in
            guard case DocumentFailure.unreadable(let path, let message) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(path, "channels.json")
            XCTAssertTrue(message.contains("number"), message)
        }
        XCTAssertThrowsError(try Loader.document(path: "lists/042.json", data: try XCTUnwrap(F.librarySnapshot.files["channels.json"]))) { error in
            guard case DocumentFailure.unreadable = error else { return XCTFail("\(error)") }
        }
        XCTAssertThrowsError(try Loader.document(path: "x.json", data: Data("{\"a\": 1}".utf8))) { error in
            guard case DocumentFailure.notADocument = error else { return XCTFail("\(error)") }
        }
    }

    /// Spec 1 §5 — the loader ignores a sync tool's temporary and partial files
    /// (names beginning with a dot or ending in .tmp), and a file whose JSON
    /// does not parse yet is reported, not fatal.
    func test_temporaryAndStrayFilesAreIgnored() {
        var snapshot = F.librarySnapshot
        snapshot.files[".channels.json.sync-conflict"] = Data("garbage".utf8)
        snapshot.files["lists/042-great-is-thy-faithfulness.json.tmp"] = Data("{".utf8)
        snapshot.files["lists/.syncthing.042.json"] = Data("{".utf8)
        snapshot.files["notes.json"] = Data("{\"hello\": 1}".utf8)
        let loaded = Loader.library(from: snapshot)
        XCTAssertEqual(loaded.library, F.load().library)
        XCTAssertEqual(loaded.report.issues.map(\.code), [.ignoredFile])
        XCTAssertEqual(loaded.report.issues.first?.file, "notes.json")
        XCTAssertEqual(loaded.report.issues.first?.severity, .info)
        XCTAssertTrue(FileLayout.isIgnored(path: ".hidden.json"))
        XCTAssertTrue(FileLayout.isIgnored(path: "lists/.hidden.json"))
        XCTAssertTrue(FileLayout.isIgnored(path: "lists/042.json.tmp"))
        XCTAssertFalse(FileLayout.isIgnored(path: "lists/042.json"))
    }
}
