import Foundation
import XCTest
import OCore
@testable import OApp

/// Spec 11 §2, §4 and §10 — edit mode's models in the spec's own words,
/// every one from the string catalog.
@MainActor
final class EditModeWordingTests: XCTestCase {
    private let english = Locale(identifier: "en_US")

    override func setUp() async throws {
        try await MainActor.run { try CatalogFile.install() }
    }

    func test_theTopBarAndTheMonitors() throws {
        // "where the list came from and its title, "Sunday 9:00 › Amazing Grace", or "Library › Amazing Grace"".
        XCTAssertEqual(EditModeWording.crumb(EditCrumb(source: "Sunday 9:00", title: "Amazing Grace")), "Sunday 9:00 › Amazing Grace")
        XCTAssertEqual(EditModeWording.crumb(EditCrumb(source: nil, title: "Amazing Grace")), "Library › Amazing Grace")
        XCTAssertEqual(EditPage.allCases.map { EditModeWording.page($0) }, ["Cues", "Text", "Stacks", "Channels", "Presets", "Objects"])
        XCTAssertEqual(BrowserTab.allCases.map { EditModeWording.tab($0) }, ["Playlists", "Library", "Media"])
        // "with a pill naming those outputs, "On air · Out 1, 2"; ... the pill says "Preview only"".
        XCTAssertEqual(EditModeWording.pill(ProgramPanel(stack: 1, outputs: [1, 2], isBlackedOut: false), locale: english), "On air · Out 1, 2")
        XCTAssertEqual(EditModeWording.pill(ProgramPanel(stack: 3, outputs: [], isBlackedOut: false), locale: english), "Preview only")
        // "the monitors say what they show ("Preview: cue 3 on stack 1 Main"; "Program: stack 1 Main, on air on outputs 1 and 2")".
        XCTAssertEqual(EditModeWording.previewSpoken(cue: 3, stack: 1, label: "Main"), "Preview: cue 3 on stack 1 Main")
        XCTAssertEqual(EditModeWording.programSpoken(ProgramPanel(stack: 1, outputs: [1, 2], isBlackedOut: false), label: "Main", locale: english),
                       "Program: stack 1 Main, on air on outputs 1 and 2")
        XCTAssertEqual(EditModeWording.programSpoken(ProgramPanel(stack: 2, outputs: [], isBlackedOut: false), label: "Confidence", locale: english),
                       "Program: stack 2 Confidence, on no output")
        XCTAssertEqual(EditModeWording.stack(number: 1, label: "Main"), "Stack 1 · Main")
        XCTAssertEqual(EditModeWording.meta(cues: 14, version: 17), "14 cues · version 17")
        XCTAssertEqual(EditModeWording.meta(cues: 1, version: 2), "1 cue · version 2")
    }

    func test_theInspectorsHeaderFireAndThePairWarning() {
        var inspector = CueInspector()
        XCTAssertEqual(EditModeWording.title(inspector), "No cue selected")
        inspector.number = 3
        inspector.count = 14
        inspector.selected = 1
        // "Its header says "Cue 3 of 14"".
        XCTAssertEqual(EditModeWording.title(inspector), "Cue 3 of 14")
        inspector.selected = 4
        XCTAssertEqual(EditModeWording.title(inspector), "4 cues of 14")
        // "The inspector's header says which ("Fires in Sunday")", "("Rename to fire")", "("Renumber to fire")".
        XCTAssertEqual(EditModeWording.fire(.fires(in: "Sunday")), "Fires in Sunday")
        XCTAssertEqual(EditModeWording.fire(.fires(in: nil)), "Fires from the Library")
        XCTAssertEqual(EditModeWording.fire(.refused(.renameToFire)), "Rename to fire")
        XCTAssertEqual(EditModeWording.fire(.refused(.renumberToFire)), "Renumber to fire")
        XCTAssertNil(EditModeWording.fire(.unavailable))
        // "Cue 2's advance-after (8 s) and this cue's Time (12 s) both arm this cue; 8 s wins."
        let warning = PairWarning(advanceCue: 2, advanceMs: 8000, timeCue: 3, timeMs: 12000)
        XCTAssertEqual(EditModeWording.pair(warning, selected: 3, locale: english),
                       "Cue 2’s advance-after (8 s) and this cue’s Time (12 s) both arm this cue; 8 s wins.")
        XCTAssertEqual(EditModeWording.pair(warning, selected: 2, locale: english),
                       "Cue 2’s advance-after (8 s) and cue 3’s Time (12 s) both arm cue 3; 8 s wins.")
    }

    func test_aChipSaysItsValueAndItsScope() throws {
        let catalog = try Recorded.catalog()
        // "each showing its value and its scope, "this cue only" (`once`) or "from here on" (`track`)".
        let transition = AttributeChip(kind: .transition, value: .same(CueAttribute(kind: .transition, ref: 2, ms: 500, scope: .once, isRider: true)),
                                       scope: .once, offersScope: true)
        XCTAssertEqual(EditModeWording.chip(transition, catalog: catalog, locale: english).title, "Dissolve 0.5 s · this cue only")
        // VoiceOver: "a chip is a button whose label says its value and scope ("Grade 3, from here on")".
        let grade = AttributeChip(kind: .grade, value: .same(CueAttribute(kind: .grade, ref: 3, scope: .track, isRider: false)), scope: .track, offersScope: false)
        XCTAssertEqual(EditModeWording.chip(grade, catalog: catalog, locale: english).spoken, "Grade 3, from here on")
        // A grade the library has reads by its label; a gain in decibels; a transition with its own duration by its label alone.
        let warm = AttributeChip(kind: .grade, value: .same(CueAttribute(kind: .grade, ref: 1, scope: .track, isRider: true)), scope: .track, offersScope: true)
        XCTAssertEqual(EditModeWording.chip(warm, catalog: catalog, locale: english).title, "Warm · from here on")
        let gain = AttributeChip(kind: .gain, value: .same(CueAttribute(kind: .gain, db: -6, scope: .track, isRider: false)), scope: .track, offersScope: false)
        XCTAssertEqual(EditModeWording.chip(gain, catalog: catalog, locale: english).title, "-6 dB · from here on")
        let plain = AttributeChip(kind: .audioTransition, value: .same(CueAttribute(kind: .audioTransition, ref: 2, scope: .once, isRider: true)),
                                  scope: .once, offersScope: true)
        XCTAssertTrue(EditModeWording.chip(plain, catalog: catalog, locale: english).title.hasSuffix(" · this cue only"))
        // "a faint + and its name for one the cue doesn't write"; "Mixed".
        let unset = AttributeChip(kind: .audioTransition, value: .same(nil), scope: .track, offersScope: true)
        XCTAssertEqual(EditModeWording.chip(unset, catalog: catalog, locale: english).title, "+ Audio transition")
        XCTAssertFalse(EditModeWording.chip(unset, catalog: catalog, locale: english).isSet)
        let mixed = AttributeChip(kind: .grade, value: .mixed, scope: .track, offersScope: true)
        XCTAssertEqual(EditModeWording.chip(mixed, catalog: catalog, locale: english).title, "Mixed")
        // The badge on a tile: its transition's duration.
        XCTAssertEqual(EditModeWording.badge(ms: 500, locale: english), "0.5 s")
    }

    func test_aCellSaysWhatTheCueDoesThere() throws {
        let catalog = try Recorded.catalog()
        let row = CueGridRow(channel: 2, label: "Foreground", exists: true, isFolded: false)
        // ""Cue 3, channel 2 Foreground: writes text, That saved a wretch like me, dissolve 0.5 seconds"".
        var write = CueGridCell(state: .write)
        write.content = .text("That saved a wretch like me")
        write.attributes = [CueAttribute(kind: .transition, ref: 2, ms: 500, scope: .once, isRider: true)]
        XCTAssertEqual(EditModeWording.cell(write, cue: 3, row: row, catalog: catalog, locale: english),
                       "Cue 3, channel 2 Foreground: writes text, That saved a wretch like me, Dissolve 0.5 seconds")
        // ""holds Amber Haze from cue 1"; "clears"".
        var hold = CueGridCell(state: .hold)
        hold.content = .media(id: "sha256:x", tile: PoolTile(id: "sha256:x", name: "Amber Haze", kind: .video, durationMs: 30000, tile: nil, overlay: .none, isOnThisMac: false))
        hold.heldFrom = 1
        let background = CueGridRow(channel: 1, label: "Background", exists: true, isFolded: false)
        XCTAssertEqual(EditModeWording.cell(hold, cue: 2, row: background, catalog: catalog, locale: english), "Cue 2, channel 1 Background: holds Amber Haze from cue 1")
        XCTAssertEqual(EditModeWording.cell(CueGridCell(state: .clear), cue: 4, row: row, catalog: catalog, locale: english), "Cue 4, channel 2 Foreground: clears")
        XCTAssertEqual(EditModeWording.cell(CueGridCell(state: .hold), cue: 4, row: row, catalog: catalog, locale: english), "Cue 4, channel 2 Foreground: holds nothing")
        // "with its attribute writes after it".
        var marked = CueGridCell(state: .hold)
        marked.attributes = [CueAttribute(kind: .gain, db: -6, scope: .track, isRider: false)]
        XCTAssertEqual(EditModeWording.cell(marked, cue: 4, row: background, catalog: catalog, locale: english),
                       "Cue 4, channel 1 Background: holds nothing, -6 dB")
        // A row for a channel number no channel has.
        XCTAssertEqual(EditModeWording.row(CueGridRow(channel: 7, label: "", exists: false, isFolded: false)), "No channel 7")
        XCTAssertEqual(EditModeWording.row(row), "Foreground")
        // "The three-way control is a segmented control that names its state ("Channel 2 Foreground: write, text")".
        XCTAssertEqual(EditModeWording.stateSpoken(channel: 2, label: "Foreground", state: .write, content: .text("x")), "Channel 2 Foreground: write, text")
        XCTAssertEqual(EditModeWording.stateSpoken(channel: 2, label: "Foreground", state: .hold, content: nil), "Channel 2 Foreground: hold")
    }

    func test_theNoticeLineAndTheReadOnlyReasons() {
        XCTAssertEqual(EditModeWording.notice(.skipped(2)), "Skipped 2 cues that hold or clear this channel: there it would stay from here on")
        XCTAssertEqual(EditModeWording.notice(.warnings(["a", "b"])), "a · b")
        // "naming where it shows: "On air on outputs 1 and 2: this shows at once."".
        XCTAssertEqual(EditModeWording.notice(.onAir(outputs: [1, 2]), locale: english), "On air on outputs 1 and 2: this shows at once.")
        XCTAssertEqual(EditModeWording.notice(.onAir(outputs: [3]), locale: english), "On air on output 3: this shows at once.")
        XCTAssertEqual(EditModeWording.notice(.notSent(.localCopy)), "Local copies are edited from v1.5")
        XCTAssertEqual(EditModeWording.notice(.notSent(.unavailable(.locked))), EditWording.reason(.unavailable(.locked)))
        XCTAssertEqual(EditModeWording.notice(.rejected(EngineRejection(code: "readOnlyLibrary", message: "x"))),
                       EditWording.rejection(EngineRejection(code: "readOnlyLibrary", message: "x")))
        // "A local item's list opens read-only with "Local copies are edited from v1.5" (L2)."
        XCTAssertEqual(EditModeWording.readOnly(.localCopy), "Local copies are edited from v1.5")
        XCTAssertEqual(EditModeWording.readOnly(.renumberToEdit), EditWording.reason(.renumberToEdit))
        // "that list's page says "Another list shares number 57"".
        XCTAssertEqual(EditModeWording.sharedNumber(57), "Another list shares number 57")
        // "An empty list shows ... "No cues yet. Add one with +, or paste the song's text in the text editor"".
        XCTAssertEqual(Strings.text(.editCuesEmpty), "No cues yet. Add one with +, or paste the song’s text in the text editor")
    }
}
