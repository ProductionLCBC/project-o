import Foundation
import XCTest
import OCore
@testable import OApp

/// Spec 11 §13, "Area 14, the frame" and "the Cues page" — edit mode's model
/// over a store fed the engine's recorded answers: the ways in and out, the
/// lock, the Browser's choice, Fire, the Preview's picture, and each
/// control's edit with what comes back.
@MainActor
final class EditModelTests: XCTestCase {
    typealias Rig = ShowModelTests.Rig

    private func notes(_ rig: Rig) -> () -> [[String: JSONValue]] {
        final class Box { var notes: [[String: JSONValue]] = [] }
        let box = Box()
        rig.model.note = { fields, _ in box.notes.append(fields) }
        return { box.notes }
    }

    private func ok(_ rig: Rig, _ index: Int? = nil, warnings: [String] = []) {
        rig.answers[index ?? rig.answers.count - 1](.result(CommandOutcome(kind: .ok, warnings: warnings)))
    }

    private var edit: (Rig) -> EditModel { { $0.model.editing } }

    // MARK: - Opening it (Spec 11 §2)

    func test_modeEditOpensTheLastPageOnWhatShowModeHadInHand() throws {
        let rig = try Rig()
        let noted = notes(rig)
        XCTAssertEqual(rig.model.mode, .show)
        XCTAssertNil(rig.model.editing.cannotOpen)
        XCTAssertTrue(rig.model.editing.open())
        XCTAssertEqual(rig.model.mode, .edit)
        // "the list the grid browses, from its playlist ..., and the selected cue, else the live cue if it is in that list".
        let editing = rig.model.editing
        XCTAssertEqual(editing.page, .cues)
        XCTAssertEqual(editing.source, .playlist(Recorded.sunday))
        XCTAssertEqual(editing.listUuid, Recorded.list42)
        XCTAssertEqual(editing.grid.title, "Great Is Thy Faithfulness")
        XCTAssertEqual(editing.grid.headers.map(\.isLive), [true, false, false, false])
        XCTAssertEqual(editing.selection.ordered(in: Recorded.cues42), [Recorded.cues42[0]], "the live cue")
        // The row is the text channel's, where a song is mostly edited.
        XCTAssertEqual(editing.selection.row, .channel(2))
        // "The app notes `editMode` with `on` true when edit mode opens".
        XCTAssertEqual(noted().last, ["event": .string("editMode"), "on": .bool(true)])
        XCTAssertTrue(rig.changes.last?.contains(.layout) ?? false, "the window lays itself out again")
        XCTAssertTrue(rig.sent.isEmpty, "opening sends no command")
        // The crumb: "where the list came from and its title".
        XCTAssertEqual(editing.crumb, EditCrumb(source: "Sunday", title: "Great Is Thy Faithfulness"))
    }

    func test_editCueOpensTheCuesPageOnThatCue() throws {
        let rig = try Rig()
        rig.model.browse(.list(Recorded.list7))
        let (cell, section) = rig.cell(0, 2)
        rig.model.settings.editPage = .stacks
        // "a double-click on a cue that isn't a text cue, or Edit Cue in a cue's menu, opens the Cues page on that cue".
        XCTAssertTrue(rig.model.editing.open(cue: cell, in: section))
        let editing = rig.model.editing
        XCTAssertEqual(editing.page, .cues)
        XCTAssertEqual(editing.source, .list(Recorded.list7))
        XCTAssertEqual(editing.selectedCues.map(\.label), ["Out"])
        XCTAssertEqual(editing.crumb, EditCrumb(source: nil, title: "Doxology"), "from the Library window")
        XCTAssertTrue(rig.held.last?.contains(Recorded.list7) ?? false)
    }

    func test_withNothingInHandThePageOpensOnWhatViewSettingsRemember() throws {
        let rig = try Rig(connected: false)
        rig.model.settings.editList = Recorded.list7
        rig.model.settings.editCue = "66ff0000-0000-4000-8000-000000000002"
        rig.model.settings.editChannel = 1
        rig.store.connected(Hello.test())
        rig.store.apply(catalog: try RecordedAPI.load("catalog"))
        rig.store.apply(media: try RecordedAPI.load("media"))
        rig.store.apply(list: try RecordedAPI.load("list-7"))
        XCTAssertTrue(rig.model.editing.open())
        XCTAssertEqual(rig.model.editing.source, .list(Recorded.list7))
        XCTAssertEqual(rig.model.editing.selectedCues.map(\.label), ["Verse"])
        XCTAssertEqual(rig.model.editing.selection.row, .channel(1))
    }

    // MARK: - Leaving it (Spec 11 §2)

    func test_leavingReturnsTheGridToWhereTheListCameFromOnTheSelectedCueAndFiresNothing() throws {
        let rig = try Rig()
        let noted = notes(rig)
        var revealed: [String] = []
        rig.model.onRevealCue = { _, list, cue in revealed.append(list + "/" + cue) }
        rig.model.editing.open()
        rig.model.editing.choose(list: Recorded.list7, from: .list(Recorded.list7), item: nil)
        rig.model.editing.click(cue: 1, row: .header)
        XCTAssertTrue(rig.model.editing.leave())
        XCTAssertEqual(rig.model.mode, .show)
        XCTAssertEqual(rig.model.browse.shown, .list(Recorded.list7), "the grid browses where its list came from")
        XCTAssertEqual(revealed, [Recorded.list7 + "/66ff0000-0000-4000-8000-000000000002"], "and scrolls to it")
        XCTAssertTrue(rig.sent.isEmpty, "firing nothing")
        XCTAssertEqual(noted().last, ["event": .string("editMode"), "on": .bool(false)])
    }

    func test_aRefusedCommitKeepsEditModeUntilASecondTry() throws {
        let rig = try Rig()
        rig.model.editing.open()
        // "If the engine refuses that commit, edit mode stays on the field with the reason, and a second try leaves without it."
        XCTAssertFalse(rig.model.editing.leave(committing: { false }))
        XCTAssertEqual(rig.model.mode, .edit)
        XCTAssertTrue(rig.model.editing.leave(committing: { false }))
        XCTAssertEqual(rig.model.mode, .show)
        // A field that commits lets the first try through, and the count starts again each time.
        rig.model.editing.open()
        XCTAssertFalse(rig.model.editing.leave(committing: { false }))
        rig.model.editing.click(cue: 2, row: .header)
        XCTAssertFalse(rig.model.editing.leave(committing: { false }), "something else was done since: this is a first try again")
        XCTAssertTrue(rig.model.editing.leave(committing: { true }))
    }

    func test_leavingWaitsForTheEnginesAnswerToAnEditAndStaysWhenItIsRefused() throws {
        let rig = try Rig()
        rig.model.editing.open()
        // A field committed on the way out: its edit is with the engine. Applied, edit mode leaves.
        rig.model.editing.setLabel("Opening")
        XCTAssertFalse(rig.model.editing.leave(), "it waits for the answer")
        XCTAssertEqual(rig.model.mode, .edit)
        ok(rig)
        XCTAssertEqual(rig.model.mode, .show)
        // Refused, "edit mode stays on the field with the reason, and a second try leaves without it".
        rig.model.editing.open()
        rig.model.editing.setLabel("Again")
        XCTAssertFalse(rig.model.editing.leave())
        rig.answers[rig.answers.count - 1](.result(CommandOutcome(kind: .rejected, rejection: EngineRejection(code: "readOnlyLibrary", message: "no"))))
        XCTAssertEqual(rig.model.mode, .edit)
        XCTAssertEqual(rig.model.editing.notice, .rejected(EngineRejection(code: "readOnlyLibrary", message: "no")))
        XCTAssertTrue(rig.model.editing.leave())
        XCTAssertEqual(rig.model.mode, .show)
        // An edit the engine never answers doesn't hold the operator: the second try leaves.
        rig.model.editing.open()
        rig.model.editing.setLabel("Once more")
        XCTAssertFalse(rig.model.editing.leave())
        XCTAssertTrue(rig.model.editing.leave())
    }

    // MARK: - What is live (Spec 11 §2)

    func test_theThreeCuesAfterTheLiveCueShowAtOnceWhereAnOutputLooksAhead() throws {
        // "the three cues after the live cue, in playlist order; near a song's end they are the next song's first cues".
        XCTAssertEqual(EditOnAir.lookahead(isLive: true, isNext: false, liveIndex: 0, liveCount: 4), 1..<4)
        XCTAssertEqual(EditOnAir.lookahead(isLive: false, isNext: true, liveIndex: 2, liveCount: 4), 0..<2, "one cue is left of the live song")
        XCTAssertEqual(EditOnAir.lookahead(isLive: false, isNext: true, liveIndex: 0, liveCount: 4), 0..<0, "three are left: none of the next song's")
        XCTAssertEqual(EditOnAir.lookahead(isLive: false, isNext: false, liveIndex: 3, liveCount: 4), 0..<0)
        XCTAssertEqual(EditOnAir.lookahead(isLive: true, isNext: false, liveIndex: nil, liveCount: 0), 0..<0, "nothing is live")
        // The fixture's Preset 1 draws the next cue's text on stack 2, the confidence stack; output 1 shows stack 1.
        let catalog = try Recorded.catalog()
        let main = OutputDot(number: 1, label: "Main", stack: 1, state: .presenting, isBlackedOut: false)
        XCTAssertEqual(EditOnAir.lookaheadOutputs(catalog: catalog, dots: [main]), [])
        var confidence = OutputDot(number: 2, label: "Confidence", stack: 2, state: .presenting, isBlackedOut: false)
        XCTAssertEqual(EditOnAir.lookaheadOutputs(catalog: catalog, dots: [main, confidence]), [2])
        confidence.state = .lost
        XCTAssertEqual(EditOnAir.lookaheadOutputs(catalog: catalog, dots: [main, confidence]), [], "an output that isn't presenting shows nothing")
    }

    func test_theFirstEditToACueTheConfidenceScreenShowsSaysWhereItIsOnAir() throws {
        let rig = try Rig()
        // Output 1 switches to the confidence stack, whose layout draws the next cue's text.
        var output = try XCTUnwrap(try RecordedAPI.load("state").items("events")?.compactMap(\.objectValue).first { $0.text("topic") == "outputs" && $0["output"] != nil })
        output["stack"] = .number(2)
        rig.store.apply(event: "outputs", output, now: rig.clock.now)
        rig.model.editing.open()
        // The live cue itself shows its edit "at the cue's next fire (L3)": no note.
        rig.model.editing.setLabel("Opening")
        XCTAssertNil(rig.model.editing.notice)
        // Cue 2 is one of the three after it: "On air on outputs 1 and 2: this shows at once."
        rig.model.editing.click(cue: 1, row: .channel(2))
        rig.model.editing.setLabel("Next up")
        XCTAssertEqual(rig.model.editing.notice, .onAir(outputs: [1]))
        rig.model.editing.setNote("again")
        XCTAssertNil(rig.model.editing.notice, "only the first edit in a run says so")
        // A list that isn't live says nothing.
        rig.model.editing.choose(list: Recorded.list7, from: .list(Recorded.list7), item: nil)
        rig.model.editing.click(cue: 1, row: .header)
        rig.model.editing.setLabel("Elsewhere")
        XCTAssertNil(rig.model.editing.notice)
    }

    // MARK: - The lock (Spec 11 §2)

    func test_theLockDisablesEveryWayInAndClosesEditMode() throws {
        let rig = try Rig()
        var locked = 0
        rig.model.editing.onLocked = { locked += 1 }
        rig.model.editing.open()
        var engine = try RecordedAPI.event("engine")
        engine["lock"] = .bool(true)
        rig.store.apply(event: "engine", engine, now: rig.clock.now)
        // "When it comes on from elsewhere, edit mode closes to show mode on the same cue, and an open field's unsent text is offered".
        XCTAssertEqual(rig.model.mode, .show)
        XCTAssertEqual(locked, 1)
        // "While operator lock is on, Mode ▸ Edit, Edit in the top bar and every entry above are disabled with the reason".
        XCTAssertEqual(rig.model.editing.cannotOpen, .locked)
        XCTAssertFalse(rig.model.editing.open())
        let (cell, section) = rig.cell(1, 1)
        XCTAssertFalse(rig.model.editing.open(cue: cell, in: section))
        XCTAssertFalse(rig.model.editing.open(page: .stacks))
        XCTAssertEqual(rig.model.mode, .show)
    }

    // MARK: - The pages and the Browser (Spec 11 §2)

    func test_thePagePickerPicksThePagesAndTextWaits() throws {
        let rig = try Rig()
        rig.model.editing.open()
        rig.model.editing.show(page: .stacks)
        XCTAssertEqual(rig.model.editing.page, .stacks)
        XCTAssertEqual(rig.model.settings.editPage, .stacks, "kept for the next time")
        // "Text is disabled until Area 10 lands".
        rig.model.editing.show(page: .text)
        XCTAssertEqual(rig.model.editing.page, .stacks)
        // A page opened from show mode opens edit mode on it.
        rig.model.editing.leave()
        XCTAssertTrue(rig.model.editing.open(page: .objects))
        XCTAssertEqual(rig.model.mode, .edit)
        XCTAssertEqual(rig.model.editing.page, .objects)
    }

    func test_aListChosenInTheBrowserBecomesTheCuesPagesAndADoubleClickOpensThatPage() throws {
        let rig = try Rig()
        rig.model.editing.open()
        rig.model.editing.show(page: .channels)
        // "A click on a linked item or on a library list makes it the list the Cues and Text pages edit".
        rig.model.editing.choose(list: Recorded.list7, from: .list(Recorded.list7), item: nil)
        XCTAssertEqual(rig.model.editing.page, .channels, "the page in view stays")
        XCTAssertEqual(rig.model.editing.listUuid, Recorded.list7)
        XCTAssertEqual(rig.model.editing.selectedCues.map(\.label), ["Verse"], "its first cue")
        XCTAssertTrue(rig.held.last?.contains(Recorded.list7) ?? false, "the app holds the list")
        // "a double-click opens the Cues page on it from any page".
        rig.model.editing.choose(list: Recorded.list42, from: .playlist(Recorded.sundayNight), item: nil, opening: true)
        XCTAssertEqual(rig.model.editing.page, .cues)
        XCTAssertEqual(rig.model.editing.source, .playlist(Recorded.sundayNight))
        XCTAssertEqual(rig.model.editing.crumb, EditCrumb(source: "Sunday Night", title: "Great Is Thy Faithfulness"))
        // The Browser's tab and the media view are kept.
        rig.model.editing.show(tab: .media)
        rig.model.editing.show(mediaView: .list)
        XCTAssertEqual(rig.model.settings.browserTab, .media)
        XCTAssertEqual(rig.model.settings.mediaView, .list)
    }

    func test_theSelectionTheFoldsAndTheZoomAreKept() throws {
        let rig = try Rig()
        rig.model.editing.open()
        rig.model.editing.click(cue: 2, row: .channel(1))
        XCTAssertEqual(rig.model.settings.editList, Recorded.list42)
        XCTAssertEqual(rig.model.settings.editPlaylist, Recorded.sunday)
        XCTAssertEqual(rig.model.settings.editCue, Recorded.cues42[2])
        XCTAssertEqual(rig.model.settings.editChannel, 1)
        // ⇧ and ⌘, and the arrows.
        rig.model.editing.click(cue: 3, row: .channel(1), shift: true)
        XCTAssertEqual(rig.model.editing.selectedCues.count, 2)
        rig.model.editing.move(.left, extend: false)
        XCTAssertEqual(rig.model.editing.selectedCues.map { $0.uuid.uuidString.lowercased() }, [Recorded.cues42[2]])
        rig.model.editing.move(.up, extend: false)
        XCTAssertEqual(rig.model.editing.selection.row, .header)
        // "a row the operator folds or opens stays so".
        XCTAssertEqual(rig.model.editing.grid.rows.map(\.isFolded), [false, false, true])
        rig.model.editing.toggleFold(row: 2)
        rig.model.editing.toggleFold(row: 0)
        XCTAssertEqual(rig.model.editing.grid.rows.map(\.isFolded), [true, false, false])
        XCTAssertEqual(rig.model.settings.foldedRows, [1: true, 3: false])
        // The zoom, by slider and by pinch.
        rig.model.editing.zoom(to: 80)
        XCTAssertEqual(rig.model.settings.gridZoom, 80)
        rig.model.editing.pinch(by: 10)
        XCTAssertEqual(rig.model.settings.gridZoom, 480)
    }

    // MARK: - Hidden rows (Spec 11 §4, corrected 2026-11-24)

    /// "an eye that hides the channel from the Preview monitor's picture alone ... Hidden rows are kept by channel number
    /// for every list, in `view.json`"; Spec 11 §3 — the cue's render takes "optionally `hide`".
    func test_aHiddenRowLeavesItsChannelOutOfThePreviewAlone() throws {
        let rig = try Rig()
        rig.model.editing.open()
        rig.model.editing.previewWidth(640)
        rig.model.editing.click(cue: 1, row: .channel(1))
        let row = try XCTUnwrap(rig.model.editing.grid.rows.firstIndex { $0.channel == 2 })
        rig.model.editing.toggleHidden(row: row)
        XCTAssertEqual(rig.model.settings.hiddenRows, [2])
        XCTAssertTrue(rig.model.editing.grid.rows[row].isHidden)
        XCTAssertEqual(rig.model.editing.hiddenChannels, [2])
        let asked = try XCTUnwrap(rig.sent.last { $0.fields["what"] == .string("render") })
        XCTAssertEqual(asked.fields["subject"]?.objectValue?["hide"], .array([.number(2)]), "the Preview asks without it")
        XCTAssertEqual(rig.commands.filter { !$0.isEmpty }, [], "nothing goes to air")
        rig.model.editing.toggleHidden(row: row)
        XCTAssertEqual(rig.model.settings.hiddenRows, [])
        XCTAssertNil(rig.sent.last { $0.fields["what"] == .string("render") }?.fields["subject"]?.objectValue?["hide"])
    }

    // MARK: - The Live toggle (Spec 11 §2, corrected 2026-11-24)

    /// "Off, which edit mode always opens with, the arrows only select: nothing goes to air. On, they also fire each cue
    /// they move the selection onto, as Fire does (§4) ... A click in the grid only selects, on or off."
    func test_withLiveOnTheArrowsFireTheCueTheyLandOnAndEditModeOpensWithItOff() throws {
        let rig = try Rig()
        rig.model.editing.open()
        XCTAssertFalse(rig.model.editing.isLive)
        rig.model.editing.click(cue: 1, row: .channel(1))
        rig.model.editing.move(.right, extend: false)
        XCTAssertEqual(rig.commands, [], "off: the arrows only select")
        rig.model.editing.setLive(true)
        rig.model.editing.move(.right, extend: false)
        // Spec 11 §2 as corrected 2026-11-24 — "each cue the selection moves onto, by the arrow keys or a click, is
        // fired with `state` where Fire would fire it".
        XCTAssertEqual(rig.commands, [["item 2 cue 4 state"]], "Live: the cue the selection lands on, with its list's state before it")
        rig.model.editing.click(cue: 0, row: .header)
        XCTAssertEqual(rig.commands.last, ["item 2 cue 1 state"], "a click goes there too, wherever in the list")
        rig.model.editing.click(cue: 0, row: .channel(2))
        rig.model.editing.move(.down, extend: false)
        rig.model.editing.move(.right, extend: true)
        rig.model.editing.click(cue: 3, row: .header, shift: true)
        rig.model.editing.click(cue: 2, row: .header, command: true)
        XCTAssertEqual(rig.commands.count, 2, "the same cue's other row, a row's step, and ⇧ or ⌘ fire nothing")
        // Leaving and coming back opens with Live off again.
        rig.model.editing.leave()
        rig.model.editing.open()
        XCTAssertFalse(rig.model.editing.isLive)
    }

    // MARK: - Fire (Spec 11 §4)

    func test_fireSendsWhatAShowModeClickSendsWhereTheListCameFrom() throws {
        let rig = try Rig()
        rig.model.editing.open()
        rig.model.editing.click(cue: 2, row: .header)
        // In the live playlist: `item N cue M`.
        XCTAssertEqual(rig.model.editing.fireNote, .fires(in: "Sunday"))
        rig.model.editing.fire()
        XCTAssertEqual(rig.commands, [["item 2 cue 3"]])
        // In a playlist that isn't loaded: "after `playlist "TITLE"`". The same list chosen where
        // another playlist has it keeps its selected cue.
        rig.model.editing.choose(list: Recorded.list42, from: .playlist(Recorded.sundayNight), item: nil)
        XCTAssertEqual(rig.model.editing.fireNote, .fires(in: "Sunday Night"))
        rig.model.editing.fire()
        XCTAssertEqual(rig.commands.last, ["playlist \"Sunday Night\"", "item 2 cue 3"])
        // "or `list N cue M` from the Library window".
        rig.model.editing.choose(list: Recorded.list7, from: .list(Recorded.list7), item: nil)
        XCTAssertEqual(rig.model.editing.fireNote, .fires(in: nil))
        rig.model.editing.fire()
        XCTAssertEqual(rig.commands.last, ["list 7 cue 1"])
        // "disabled for ... a list its number doesn't reach ("Renumber to fire")": the local copy shares 42.
        rig.model.editing.choose(list: Recorded.localCopy, from: .list(Recorded.localCopy), item: nil)
        XCTAssertEqual(rig.model.editing.fireNote, .refused(.renumberToFire))
        let before = rig.sent.count
        rig.model.editing.fire()
        XCTAssertEqual(rig.sent.count, before)
    }

    // MARK: - The Preview monitor (Spec 11 §4)

    func test_thePreviewAsksRenderForTheSelectedCueOnThePickedStackAndAgainAfterALibraryEvent() throws {
        let rig = try Rig()
        rig.model.editing.open()
        rig.model.editing.previewWidth(712)
        var asked = rig.sent.filter { $0.fields["what"] == .string("render") }
        XCTAssertEqual(asked.count, 1)
        XCTAssertEqual(asked[0].fields["canvas"], .string("preview"))
        XCTAssertEqual(asked[0].fields["width"], .number(712))
        XCTAssertEqual(asked[0].fields["subject"], .object(["kind": .string("cue"), "listUuid": .string(Recorded.list42),
                                                            "cue": .string(Recorded.cues42[0]), "stack": .number(1)]))
        rig.answers[rig.answers.count - 1](.answer(["file": .string("thumbnails/render/c3-preview-9.png"), "width": .number(712), "height": .number(400)]))
        XCTAssertEqual(rig.model.editing.preview.file, "thumbnails/render/c3-preview-9.png")
        // Another cue, then another stack: asked again each time.
        rig.model.editing.click(cue: 1, row: .header)
        rig.model.change { $0.previewStack = 2 }
        asked = rig.sent.filter { $0.fields["what"] == .string("render") }
        XCTAssertEqual(asked.count, 3)
        XCTAssertEqual(asked[2].fields["subject"]?["stack"], .number(2))
        XCTAssertEqual(asked[2].fields["subject"]?["cue"], .string(Recorded.cues42[1]))
        // A newer request replaced the one waiting: its answer changes nothing.
        rig.answers[rig.answers.count - 2](.answer(["superseded": .bool(true)]))
        XCTAssertEqual(rig.model.editing.preview.file, "thumbnails/render/c3-preview-9.png", "the picture stays until its replacement is drawn")
        // "It is asked for again after each `library` event that names the list or anything it draws."
        rig.store.apply(list: try RecordedAPI.load("list-42"))
        XCTAssertEqual(rig.sent.filter { $0.fields["what"] == .string("render") }.count, 4)
        // The width is held to what `render` takes: 160 to 1920 pixels.
        rig.model.editing.previewWidth(4000)
        XCTAssertEqual(rig.sent.last?.fields["width"], .number(1920))
        // A local copy is named by `local`.
        rig.model.editing.choose(list: Recorded.localCopy, from: .list(Recorded.localCopy), item: nil)
        XCTAssertEqual(rig.sent.last?.fields["subject"]?["local"], .string(Recorded.localCopy))
        XCTAssertNil(rig.sent.last?.fields["subject"]?["listUuid"])
    }

    // MARK: - The controls (Spec 11 §4)

    func test_theChannelColumnsControlsSendTheirEdits() throws {
        let rig = try Rig()
        rig.model.editing.open()
        let c = Recorded.cues42
        // Clear, then Hold, on cue 1's text.
        rig.model.editing.set(.clear)
        XCTAssertEqual(rig.commands.last, ["edit list 42 cue \(c[0]) channel 2 clear"])
        rig.model.editing.set(.hold)
        XCTAssertEqual(rig.commands.last, ["edit list 42 cue \(c[0]) channel 2 hold"])
        // The content popover commits a write; a media item picked or dropped writes with its default grade.
        rig.model.editing.click(cue: 1, row: .channel(1))
        rig.model.editing.write(.text(fields: ["body": "Hello"]))
        XCTAssertEqual(rig.commands.last, ["edit list 42 cue \(c[1]) channel 1 write text \"Hello\""])
        let ocean = try XCTUnwrap(rig.store.media.first { $0.id.hasPrefix("sha256:9f2c") })
        rig.model.editing.pick(media: ocean.id, cue: 2, channel: 1)
        XCTAssertEqual(rig.commands.last, ["edit list 42 cue \(c[2]) channel 1 write media \(ocean.id) grade 1 once"])
        XCTAssertEqual(rig.model.settings.recentMedia.first, ocean.id)
        // A chip, on the selected cell.
        rig.model.editing.setChip(CueAttribute(kind: .grade, ref: 1, scope: .track, isRider: false))
        XCTAssertEqual(rig.commands.last, ["edit list 42 cue \(c[1]) channel 1 grade 1 hold"])
        rig.model.editing.click(cue: 3, row: .channel(1))
        rig.model.editing.removeChip(.gain)
        XCTAssertEqual(rig.commands.last, ["edit list 42 cue \(c[3]) channel 1 hold"])
        // Delete on a channel's row "returns the selected cells to Hold".
        rig.model.editing.click(cue: 0, row: .channel(1))
        rig.model.editing.click(cue: 1, row: .channel(1), shift: true)
        rig.model.editing.delete()
        XCTAssertEqual(rig.commands.last, ["edit list 42 cue \(c[0]) channel 1 hold"], "cue 2 holds it already")
    }

    func test_theCueColumnsAndTheCuesOwnEdits() throws {
        let rig = try Rig()
        rig.model.editing.open()
        let c = Recorded.cues42
        let fresh = try XCTUnwrap(UUID(uuidString: "c0c00000-0000-4000-8000-000000000001"))
        rig.model.editing.makeUuid = { fresh }
        rig.model.editing.click(cue: 3, row: .header)
        rig.model.editing.setLabel("Refrain")
        rig.model.editing.setSection("Bridge")
        rig.model.editing.setNote("Lights up")
        rig.model.editing.setTrigger(.time(ms: 2500))
        rig.model.editing.setAdvanceAfter(ms: nil)
        XCTAssertEqual(Array(rig.commands.suffix(4)), [
            ["edit list 42 cue \(c[3]) label \"Refrain\""], ["edit list 42 cue \(c[3]) section \"Bridge\""],
            ["edit list 42 cue \(c[3]) note \"Lights up\""], ["edit list 42 cue \(c[3]) trigger { \"ms\": 2500, \"type\": \"time\" }"],
        ], "an advance-after that is none already sends nothing")
        // New Cue After, with the app's uuid; the page selects it when the list arrives with it.
        rig.model.editing.newCue(atEnd: false)
        XCTAssertEqual(rig.commands.last, ["edit list 42 insert cues 4 { \"section\": \"Chorus\", \"uuid\": \"c0c00000-0000-4000-8000-000000000001\" }"])
        var list = try RecordedAPI.load("list-42")
        var document = try XCTUnwrap(list["list"]?.objectValue)
        var cues = try XCTUnwrap(document["cues"]?.arrayValue)
        cues.append(.object(["uuid": .string("c0c00000-0000-4000-8000-000000000001"), "label": .string(""), "section": .string("Chorus"),
                             "note": .string(""), "trigger": .object(["type": .string("go")]), "advanceAfterMs": .null, "commands": .array([])]))
        document["cues"] = .array(cues)
        list["list"] = .object(document)
        rig.store.apply(list: list)
        XCTAssertEqual(rig.model.editing.grid.cueCount, 5)
        XCTAssertEqual(rig.model.editing.selectedCues.map { $0.uuid }, [fresh])
        // Duplicate, Move Earlier, and Delete on the header row, which doesn't ask for a plain cue.
        rig.model.editing.duplicate()
        XCTAssertEqual(rig.commands.last, ["edit list 42 cue c0c00000-0000-4000-8000-000000000001 duplicate"])
        rig.model.editing.moveSelected(earlier: true)
        XCTAssertEqual(rig.commands.last, ["edit list 42 cue c0c00000-0000-4000-8000-000000000001 move 3"])
        rig.model.editing.delete()
        XCTAssertEqual(rig.commands.last, ["edit list 42 cue c0c00000-0000-4000-8000-000000000001 remove"])
        // The live cue asks first (choice A-11).
        var asked: [Confirmation] = []
        rig.model.confirm = { confirmation, answer in
            asked.append(confirmation)
            answer(true)
        }
        rig.model.editing.click(cue: 0, row: .header)
        rig.model.editing.delete()
        XCTAssertEqual(asked, [.deleteCues(count: 1, live: true, armed: false, edits: false)])
        XCTAssertEqual(rig.commands.last, ["edit list 42 cue \(c[0]) remove"])
    }

    func test_aRejectionShowsInTheNoticeLineAndAWarningStandsUntilTheNextEdit() throws {
        let rig = try Rig()
        rig.model.editing.open()
        rig.model.editing.set(.clear)
        rig.answers[rig.answers.count - 1](.result(CommandOutcome(kind: .rejected, rejection: EngineRejection(code: "readOnlyLibrary", message: "masters are read-only"))))
        XCTAssertEqual(rig.model.editing.notice, .rejected(EngineRejection(code: "readOnlyLibrary", message: "masters are read-only")))
        // "An applied edit's `warnings` (Spec 5 §6) show there in yellow until the object is next edited."
        rig.model.editing.set(.hold)
        ok(rig, warnings: ["channel 9 has no channel"])
        XCTAssertEqual(rig.model.editing.notice, .warnings(["channel 9 has no channel"]))
        rig.model.editing.setLabel("Again")
        XCTAssertNil(rig.model.editing.notice)
    }

    func test_aLocalCopyAndAListThatSharesItsNumberAreReadOnlyWithTheReason() throws {
        let rig = try Rig()
        rig.model.editing.open()
        XCTAssertNil(rig.model.editing.cannotEdit)
        // "A local item's list opens read-only with "Local copies are edited from v1.5" (L2)."
        rig.model.editing.choose(list: Recorded.localCopy, from: .list(Recorded.localCopy), item: nil)
        XCTAssertEqual(rig.model.editing.cannotEdit, .localCopy)
        let before = rig.sent.count
        rig.model.editing.set(.clear)
        rig.model.editing.setLabel("x")
        XCTAssertEqual(rig.sent.count, before, "nothing is sent for a list that can't be edited")
        XCTAssertEqual(rig.model.editing.notice, .notSent(.localCopy))
    }

    func test_ofTwoListsSharingANumberTheSecondIsReadOnlyAndOffersToRenumberTheFirst() throws {
        let rig = try Rig()
        // Another master takes Doxology's number 7; edits by that number reach the one that comes first (Spec 7 §2).
        var catalog = try RecordedAPI.load("catalog")
        var lists = try XCTUnwrap(catalog["lists"]?.arrayValue)
        let index = try XCTUnwrap(lists.firstIndex { $0["uuid"] == .string(Recorded.list7) })
        var doxology = try XCTUnwrap(lists[index].objectValue)
        doxology["named"] = .bool(false)
        lists[index] = .object(doxology)
        catalog["lists"] = .array(lists)
        rig.store.apply(catalog: catalog)
        rig.model.editing.open()
        rig.model.editing.choose(list: Recorded.list7, from: .list(Recorded.list7), item: nil)
        // "the other's opens read-only, offering to renumber the first".
        XCTAssertEqual(rig.model.editing.cannotEdit, .renumberToEdit)
        let before = rig.sent.count
        rig.model.editing.setLabel("x")
        XCTAssertEqual(rig.sent.count, before)
        rig.model.editing.renumberOther(to: 70)
        XCTAssertEqual(rig.commands.last, ["edit list 7 renumber 70"], "by the shared number, which names the first")
    }
}
