import Foundation
import XCTest
import OCore
@testable import OApp

/// Spec 10 §15, "Localization" — "Keys are drawn as the current keyboard
/// layout labels them, though matched by position (§9)."
@MainActor
final class KeyDrawingTests: XCTestCase {
    override func setUp() async throws {
        try await MainActor.run { try CatalogFile.install() }
    }

    private func drawn(_ text: String, layout: (UInt16) -> String? = { _ in nil }) throws -> String {
        KeyWording.key(try XCTUnwrap(KeyName(text), text), layout: layout)
    }

    func test_aKeyIsDrawnWithItsModifiersSignsAsTheSpecWritesThem() throws {
        XCTAssertEqual(try drawn("space"), "Space")
        XCTAssertEqual(try drawn("right"), "→")
        XCTAssertEqual(try drawn("left"), "←")
        XCTAssertEqual(try drawn("shift+escape"), "⇧⎋")
        XCTAssertEqual(try drawn("ctrl+alt+f"), "⌃⌥F")
        XCTAssertEqual(try drawn("ctrl+alt+shift+return"), "⌃⌥⇧Return")
        XCTAssertEqual(try drawn("shift+tab"), "⇧Tab")
        XCTAssertEqual(try drawn("f12"), "F12")
        XCTAssertEqual(try drawn("pad4"), "Keypad 4")
        XCTAssertEqual(try drawn("padenter"), "Keypad Enter")
        XCTAssertEqual(try drawn("padplus"), "Keypad +")
        XCTAssertEqual(try drawn("padminus"), "Keypad −")
        XCTAssertEqual(try drawn("forwarddelete"), "Forward Delete")
        XCTAssertEqual(try drawn("pageup"), "Page Up")
        XCTAssertEqual(try drawn(";"), ";")
        XCTAssertEqual(try drawn("7"), "7")
    }

    /// A French keyboard prints A where a US one prints Q: the binding stays on the key, and the overlay draws what is printed there.
    func test_aCharacterKeyIsDrawnAsTheLayoutPrintsIt() throws {
        let french: (UInt16) -> String? = { code in [12: "a", 0: "q", 13: "z", 41: "m", 18: "&"][code] }
        XCTAssertEqual(try drawn("q", layout: french), "A")
        XCTAssertEqual(try drawn("ctrl+a", layout: french), "⌃Q")
        XCTAssertEqual(try drawn(";", layout: french), "M")
        XCTAssertEqual(try drawn("1", layout: french), "&")
        XCTAssertEqual(try drawn("b", layout: french), "B", "a key the layout says nothing of is drawn by its US name")
        XCTAssertEqual(try drawn("x", layout: { _ in "  " }), "X", "and one it gives no visible character for")
        XCTAssertEqual(try drawn("space", layout: { _ in " " }), "Space", "a named key is never the layout's")
        XCTAssertEqual(try drawn("pad1", layout: { _ in "9" }), "Keypad 1")
    }

    func test_everyKeyHasItsOwnDrawing() throws {
        let all = try KeyName.keys.map { try drawn($0) }
        XCTAssertFalse(all.contains(""), "none is drawn as nothing")
        XCTAssertEqual(Set(all).count, all.count, "no two keys are drawn alike")
    }
}

/// Spec 10 §15 — "A command's plain name, in the keys overlay and elsewhere,
/// comes from a table of one sentence with placeholders per command object
/// (Spec 2 §3), and a command without one shows its canonical text."
@MainActor
final class CommandPlainNameTests: XCTestCase {
    override func setUp() async throws {
        try await MainActor.run { try CatalogFile.install() }
    }

    /// The table: each command object the app has a sentence for, and the sentence.
    static let table: [(Command, String)] = [
        (.next, "Next cue"),
        (.previous, "Previous cue"),
        (.cue(14), "Go to cue 14"),
        (.itemCue(item: 2, cue: 3), "Fire cue 3 of item 2"),
        (.itemSection(item: 2, section: "Chorus"), "Go to “Chorus” in item 2"),
        (.listCue(list: 42, cue: 3), "Fire cue 3 of list 42"),
        (.playlistLoad(title: "Sunday"), "Make “Sunday” live"),
        (.disarm, "Hold the auto-advance"),
        (.systemClearAll, "Clear all channels (popups stay)"),
        (.systemPreflight, "Run the preflight check"),
        (.systemSnapshot, "Take a snapshot"),
        (.channelClear(channel: .number(2)), "Clear channel 2"),
        (.channelClear(channel: .all), "Clear every channel"),
        (.channelReset(channel: .number(2)), "Reset channel 2’s attributes"),
        (.channelReset(channel: .all), "Reset every channel’s attributes"),
        (.channelTransport(channel: .number(1), mode: .play), "Play channel 1"),
        (.channelTransport(channel: .number(1), mode: .pause), "Pause channel 1"),
        (.channelTransport(channel: .number(1), mode: .stop), "Stop channel 1"),
        (.channelTransport(channel: .all, mode: .play), "Play every channel"),
        (.channelTransport(channel: .all, mode: .pause), "Pause every channel"),
        (.channelTransport(channel: .all, mode: .stop), "Stop every channel"),
        (.channelEndBehavior(channel: .number(1), mode: .loop), "Channel 1 loops at its end"),
        (.channelEndBehavior(channel: .number(1), mode: .hold), "Channel 1 holds its last frame at its end"),
        (.channelEndBehavior(channel: .number(1), mode: .clear), "Channel 1 clears at its end"),
        (.channelLock(channel: .number(3), locked: true), "Lock channel 3"),
        (.channelLock(channel: .number(3), locked: false), "Unlock channel 3"),
        (.channelLock(channel: .all, locked: true), "Lock every channel"),
        (.channelLock(channel: .all, locked: false), "Unlock every channel"),
        (.channelFreeze(channel: .number(1), state: .on), "Freeze channel 1"),
        (.channelFreeze(channel: .number(1), state: .off), "Unfreeze channel 1"),
        (.channelFreeze(channel: .number(1), state: .toggle), "Freeze or unfreeze channel 1"),
        (.channelGrade(channel: .number(1), ref: 2, ms: nil), "Set channel 1’s grade to 2"),
        (.channelGrade(channel: .number(1), ref: 0, ms: nil), "Remove channel 1’s grade"),
        (.channelTransition(channel: .number(2), ref: 3, ms: nil), "Set channel 2’s transition to 3"),
        (.channelAudioTransition(channel: .number(2), ref: 3, ms: nil), "Set channel 2’s audio transition to 3"),
        (.outputStack(output: 2, stack: 1), "Switch output 2 to stack 1"),
        (.stackBlackout(stack: .number(1), state: .on), "Black out stack 1"),
        (.stackBlackout(stack: .number(1), state: .off), "End the blackout of stack 1"),
        (.stackBlackout(stack: .number(1), state: .toggle), "Blackout of stack 1 on or off"),
        (.stackBlackout(stack: .all, state: .on), "Black out every stack"),
        (.stackBlackout(stack: .all, state: .off), "End every stack’s blackout"),
        (.stackBlackout(stack: .all, state: .toggle), "Blackout of every stack on or off"),
        (.stackMute(stack: 2, channel: 3, state: .on), "Mute channel 3 in stack 2"),
        (.stackMute(stack: 2, channel: 3, state: .off), "Unmute channel 3 in stack 2"),
        (.stackMute(stack: 2, channel: 3, state: .toggle), "Mute or unmute channel 3 in stack 2"),
        (.timerStart(timer: 1), "Start timer 1"),
        (.timerPause(timer: 1), "Pause timer 1"),
        (.timerReset(timer: 1), "Reset timer 1"),
        (.popupSet(popup: 1, text: "Nursery: 14", clearAfterMs: nil), "Show “Nursery: 14” in popup 1"),
        (.popupClear(popup: 1), "Clear popup 1"),
        (.audioMute(audio: .number(1), state: .on), "Mute audio output 1"),
        (.audioMute(audio: .number(1), state: .off), "Unmute audio output 1"),
        (.audioMute(audio: .number(1), state: .toggle), "Mute or unmute audio output 1"),
        (.audioMute(audio: .all, state: .on), "Mute all audio"),
        (.audioMute(audio: .all, state: .off), "Unmute all audio"),
        (.audioMute(audio: .all, state: .toggle), "Mute or unmute all audio"),
        (.macro(2), "Run macro 2"),
        (.undo, "Undo the last change to the library"),
        (.redo, "Redo the last change undone"),
    ]

    func test_everySentenceOfTheTable() {
        for (command, sentence) in Self.table {
            XCTAssertEqual(KeyWording.plain(command), sentence, CommandText.print(command) ?? command.cmd)
        }
        XCTAssertEqual(Self.table.count, 59)
        XCTAssertEqual(Set(Self.table.map(\.1)).count, 59, "no two commands share a sentence")
    }

    /// "It names `system clearall` "Clear all channels (popups stay)"".
    func test_clearAllIsNamedAsTheSpecNamesIt() {
        XCTAssertEqual(KeyWording.plain(.systemClearAll), "Clear all channels (popups stay)")
    }

    /// Area 13 reading — a plain name never says less than the command
    /// does: a form the table has no sentence for shows its canonical text.
    func test_aCommandWithoutASentenceShowsItsCanonicalText() throws {
        let without: [Command] = [
            .channelGrade(channel: .number(1), ref: 2, ms: 2000),
            .channelGrade(channel: .all, ref: 2, ms: nil),
            .channelTransition(channel: .number(2), ref: 3, ms: 500),
            .channelEndBehavior(channel: .all, mode: .loop),
            .channelFreeze(channel: .all, state: .toggle),
            .channelGain(channel: .number(1), db: -6),
            .channelWrite(ChannelWrite(channel: .number(1), content: .input(1))),
            .popupSet(popup: 1, text: "Hi", clearAfterMs: 30_000),
            .timerSet(timer: 1, ms: 300_000),
            .historyJump(4),
            .systemRestoreList(list: 42, version: 16),
        ]
        for command in without {
            let canonical = try XCTUnwrap(CommandText.print(command))
            XCTAssertEqual(KeyWording.plain(command), canonical)
            XCTAssertFalse(canonical.isEmpty)
        }
        XCTAssertEqual(KeyWording.plain(.unknown(cmd: "lights.flash")), CommandText.print(.unknown(cmd: "lights.flash")) ?? "lights.flash",
                       "a command a newer build wrote shows as it can be shown, and never crashes the overlay")
    }
}

/// Spec 10 §9, "The keys overlay", and "Safeguards".
@MainActor
final class KeysOverlayTests: XCTestCase {
    override func setUp() async throws {
        try await MainActor.run { try CatalogFile.install() }
    }

    func test_theOverlayListsEveryBindingThenTheFixedKeys() throws {
        let overlay = KeysOverlay.make(table: BindingTable(try Recorded.catalog().keys), releaseKeyRegistered: true)
        XCTAssertEqual(overlay.bindings, [.init(key: "Space", what: "Next cue"), .init(key: "→", what: "Next cue"), .init(key: "←", what: "Previous cue"),
                                          .init(key: "⇧⎋", what: "Clear all channels (popups stay)")])
        XCTAssertEqual(overlay.fixed.map(\.key), ["⌃⌥⌘⎋", "⎋", "0–9, then Return", "⌘L", "⌥⌘M", "⌘1", "⌘2", "⌥-double-click"])
        XCTAssertEqual(overlay.fixed.map(\.what), ["Take every output off the screen this window is on",
                                                   "Leave a field, or close what is open. It never sends a command.",
                                                   "Go to that cue in the live list. Esc, or three seconds, clears the number.",
                                                   "Back to Live", "Multiviewer", "Show", "Edit", "Edit a cue without firing it"])
        XCTAssertEqual(overlay.warnings, [])
        XCTAssertEqual(overlay.ignored, [])
        // "says that in v1 undo changes the library, never the screens"; "An open menu takes every key ..., the keys overlay says so."
        XCTAssertEqual(overlay.notes, ["Undo changes the library, never what is on the screens.", "While a menu is open it takes every key, ⇧⎋ included."])
    }

    func test_theOverlayWarnsWhenNothingIsBoundToNextOrToClearAll() {
        let overlay = KeysOverlay.make(table: BindingTable(), releaseKeyRegistered: true)
        XCTAssertEqual(overlay.bindings, [])
        XCTAssertEqual(overlay.warnings, ["No key is bound to Next cue.", "No key is bound to Clear all channels."])
    }

    func test_theOverlayListsTheRowsTheAppLeavesOutAndSaysWhenTheReleaseKeyIsNotTheSystems() {
        let table = BindingTable(FirstRun.keys + [KeyBinding(device: "keyboard", key: "escape", command: .systemClearAll),
                                                  KeyBinding(device: "keyboard", key: "Enter", command: .next),
                                                  KeyBinding(device: "keyboard", key: "space", command: .previous)])
        let overlay = KeysOverlay.make(table: table, releaseKeyRegistered: false)
        XCTAssertEqual(overlay.ignored, ["“escape” is reserved, so its binding is ignored.", "“Enter” isn’t a key name, so its binding is ignored.",
                                         "“space” is bound twice. Only its first binding fires."])
        XCTAssertEqual(overlay.notes.count, 3)
        XCTAssertEqual(overlay.notes.last, "macOS didn’t give Project O the key ⌃⌥⌘⎋, so it works only while Project O is the active app. "
                       + "Help ▸ Release Output from This Screen does the same.")
    }

    /// Spec 10 §8 — the four lines, word for word.
    func test_whatTheTopBarSaysOverAField() {
        XCTAssertEqual(KeyWording.hint(.commandReturnSaves), "Editing: ⌘Return saves · Esc discards")
        XCTAssertEqual(KeyWording.hint(.textEditor), "Editing text: ⌥Return splits · Esc leaves")
        XCTAssertEqual(KeyWording.hint(.returnSaves), "Editing: Return saves · Esc discards")
        XCTAssertEqual(KeyWording.hint(.typing), "Typing: Esc for show keys")
    }
}

/// Spec 10 §9, "The command bar".
@MainActor
final class CommandBarTests: XCTestCase {
    override func setUp() async throws {
        try await MainActor.run { try CatalogFile.install() }
    }

    func test_asTheOperatorTypesItShowsTheCanonicalFormOrTheParsersError() {
        var bar = CommandBar()
        XCTAssertEqual(bar.preview, .empty)
        bar.type("NEXT")
        XCTAssertEqual(bar.preview, .canonical("next"), "any accepted spelling, shown as the canonical form (Spec 2 §4)")
        bar.type("Channel 2 Clear")
        XCTAssertEqual(bar.preview, .canonical("channel 2 clear"))
        bar.type("chanel 2 clear")
        guard case .error(let message) = bar.preview else { return XCTFail("\(bar.preview)") }
        XCTAssertFalse(message.isEmpty, "the parser's own sentence")
        bar.type("   ")
        XCTAssertEqual(bar.preview, .empty)
    }

    func test_returnTakesTheCommandEmptiesTheFieldAndRemembersIt() {
        var bar = CommandBar()
        bar.type("system clearall")
        XCTAssertEqual(bar.submit()?.command, .systemClearAll)
        XCTAssertEqual(bar.text, "")
        XCTAssertEqual(bar.preview, .empty)
        XCTAssertEqual(bar.last, "system clearall")
        XCTAssertEqual(bar.outcome, .sent)
        XCTAssertEqual(bar.history, ["system clearall"])
        // Text that isn't a command goes nowhere and stays, with its error.
        bar.type("nonsense here")
        XCTAssertNil(bar.submit())
        XCTAssertEqual(bar.text, "nonsense here")
        XCTAssertEqual(bar.history, ["system clearall"])
        bar.type("")
        XCTAssertNil(bar.submit(), "Return on an empty bar does nothing")
    }

    func test_theResultOrTheRejectionIsShownBesideIt() {
        var bar = CommandBar()
        XCTAssertNil(KeyWording.outcome(of: bar))
        bar.type("next")
        _ = bar.submit()
        XCTAssertEqual(KeyWording.outcome(of: bar), "next: sent")
        bar.answered(.result(CommandOutcome(kind: .ok)))
        XCTAssertEqual(KeyWording.outcome(of: bar), "next: done")
        bar.answered(.result(CommandOutcome(kind: .noop)))
        XCTAssertEqual(KeyWording.outcome(of: bar), "next: nothing changed")
        bar.answered(.result(CommandOutcome(kind: .blocked)))
        XCTAssertEqual(KeyWording.outcome(of: bar), "next: blocked by a lock")
        bar.answered(.result(CommandOutcome(kind: .steppedOn)))
        XCTAssertEqual(KeyWording.outcome(of: bar), "next: done, over a running transition")
        bar.answered(.result(CommandOutcome(kind: .rejected, rejection: EngineRejection(code: "noSuchTarget", message: "there is no channel 9"))))
        XCTAssertEqual(KeyWording.outcome(of: bar), "next: rejected. there is no channel 9")
        bar.answered(nil)
        XCTAssertEqual(KeyWording.outcome(of: bar), "Not sent: the engine is away")
    }

    /// "↑ and ↓ recall the last fifty commands of the run."
    func test_upAndDownRecallWhatWasSent() {
        var bar = CommandBar()
        for text in ["next", "previous", "cue 3"] {
            bar.type(text)
            _ = bar.submit()
        }
        bar.type("chan")
        bar.recall(earlier: true)
        XCTAssertEqual(bar.text, "cue 3")
        XCTAssertEqual(bar.preview, .canonical("cue 3"), "a recalled command is read like a typed one")
        bar.recall(earlier: true)
        bar.recall(earlier: true)
        XCTAssertEqual(bar.text, "next")
        bar.recall(earlier: true)
        XCTAssertEqual(bar.text, "next", "↑ at the oldest stays there")
        bar.recall(earlier: false)
        XCTAssertEqual(bar.text, "previous")
        bar.recall(earlier: false)
        bar.recall(earlier: false)
        XCTAssertEqual(bar.text, "chan", "↓ past the newest gives back what was being typed")
        bar.recall(earlier: false)
        XCTAssertEqual(bar.text, "chan")
        // Typing leaves the history where it was, and ↑ starts from the newest again.
        bar.recall(earlier: true)
        bar.type("cue 4")
        bar.recall(earlier: true)
        XCTAssertEqual(bar.text, "cue 3")
        var empty = CommandBar()
        empty.type("x")
        empty.recall(earlier: true)
        XCTAssertEqual(empty.text, "x", "with nothing sent there is nothing to recall")
    }

    func test_onlyTheLastFiftyAreKept() {
        var bar = CommandBar()
        for cue in 1...60 {
            bar.type("cue \(cue)")
            _ = bar.submit()
        }
        XCTAssertEqual(bar.history.count, 50)
        XCTAssertEqual(bar.history.first, "cue 11")
        XCTAssertEqual(bar.history.last, "cue 60")
    }

    /// Spec 2 §4 — "Hashes may be abbreviated to their first 12 hex characters in the command bar and are expanded on parse".
    func test_aMediaHashMayBeTypedByItsFirstTwelveCharacters() throws {
        let id = try XCTUnwrap(try Recorded.media().first?.id)
        let hex = try XCTUnwrap(id.split(separator: ":").last)
        var bar = CommandBar()
        bar.type("channel 1 write media sha256:\(hex.prefix(12))", mediaIDs: [id])
        XCTAssertEqual(bar.preview, .canonical("channel 1 write media \(id)"))
    }

    /// Through the keys model: "Return sends the command with source `commandbar`".
    func test_returnSendsTheCommandWithSourceCommandbarAndShowsItsResult() throws {
        let rig = try KeysRig()
        XCTAssertFalse(rig.keys.showsCommandBar, "off by default (`commandBar`)")
        rig.keys.typeInBar("stack 1 blackout toggle")
        rig.keys.submitBar()
        XCTAssertEqual(rig.show.commands, [["stack 1 blackout toggle"]])
        XCTAssertEqual(rig.sources, ["commandbar"])
        XCTAssertEqual(rig.keys.bar.outcome, .sent)
        rig.show.answers[0](.result(CommandOutcome(kind: .ok)))
        XCTAssertEqual(rig.keys.bar.outcome, .result(.ok))
        // A second command's answer is the one shown, even if the first's comes after it.
        rig.keys.typeInBar("next")
        rig.keys.submitBar()
        rig.keys.typeInBar("previous")
        rig.keys.submitBar()
        rig.show.answers[2](.result(CommandOutcome(kind: .noop)))
        rig.show.answers[1](.result(CommandOutcome(kind: .ok)))
        XCTAssertEqual(rig.keys.bar.outcome, .result(.noop))
        XCTAssertEqual(rig.keys.bar.last, "previous")
        rig.keys.recallInBar(earlier: true)
        XCTAssertEqual(rig.keys.bar.text, "previous")
    }

    func test_whileTheEngineIsAwayReturnSendsNothingAndTheTextStays() throws {
        let rig = try KeysRig()
        rig.show.store.disconnected()
        rig.keys.typeInBar("next")
        rig.keys.submitBar()
        XCTAssertEqual(rig.show.sent.count, 0)
        XCTAssertEqual(rig.keys.bar.text, "next")
        XCTAssertEqual(rig.keys.bar.history, [])
        XCTAssertEqual(rig.keys.bar.outcome, .engineAway)
    }

    func test_theMachinesSettingTurnsTheBarOn() throws {
        let rig = try KeysRig()
        var catalog = try RecordedAPI.load("catalog")
        var machine = try XCTUnwrap(catalog["machine"]?.objectValue)
        var settings = try XCTUnwrap(machine["settings"]?.objectValue)
        settings["commandBar"] = .bool(true)
        machine["settings"] = .object(settings)
        catalog["machine"] = .object(machine)
        rig.show.store.apply(catalog: catalog)
        XCTAssertTrue(rig.keys.showsCommandBar)
    }
}
