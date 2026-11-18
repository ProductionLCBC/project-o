import Foundation
import XCTest
import OCore
@testable import OApp

/// Spec 10 §5–§8 and §15 — the window's models in the spec's own words,
/// every one from the string catalog.
@MainActor
final class ShowWordingTests: XCTestCase {
    private let english = Locale(identifier: "en_US")

    override func setUp() async throws {
        try await MainActor.run { try CatalogFile.install() }
    }

    func test_theLivePositionReadsAsTheSpecWritesIt() {
        XCTAssertEqual(ShowWording.position(.cue(playlist: "Sunday", list: "Great Is Thy Faithfulness", number: 3, label: "Verse 2")),
                       "Sunday · Great Is Thy Faithfulness · 3 Verse 2")
        XCTAssertEqual(ShowWording.position(.ready(playlist: "Sunday")), "Sunday · ready")
        XCTAssertEqual(ShowWording.position(.library(list: "Great Is Thy Faithfulness", number: 3, label: "Verse 2")),
                       "Library · Great Is Thy Faithfulness · 3 Verse 2")
        XCTAssertEqual(ShowWording.position(.nothing(hint: false)), "Nothing live")
        XCTAssertEqual(ShowWording.position(.nothing(hint: true)), "Nothing live · Click a cue, or choose Make Live")
        XCTAssertEqual(ShowWording.countdown(ms: 7_200), "Auto in 0:08")
    }

    func test_anOutputReadsItsNumberLabelAndStackOrItsStateInAWord() {
        XCTAssertEqual(ShowWording.output(OutputDot(number: 1, label: "Main", stack: 1, state: .presenting, isBlackedOut: false)), "1 Main · stack 1")
        XCTAssertEqual(ShowWording.output(OutputDot(number: 1, label: "Main", stack: 1, state: .lost, isBlackedOut: false)), "1 Main · lost")
        XCTAssertEqual(ShowWording.output(OutputDot(number: 3, label: "Lobby", stack: 2, state: .released, isBlackedOut: false)), "3 Lobby · released")
        XCTAssertEqual(ShowWording.output(OutputDot(number: 3, label: "Lobby", stack: 2, state: .absent, isBlackedOut: false)), "3 Lobby · absent")
        XCTAssertEqual(ShowWording.output(OutputDot(number: 2, label: "Confidence", stack: 2, state: .presenting, isBlackedOut: true)),
                       "2 Confidence · stack 2 · Blackout")
    }

    func test_theTagsAndTheOutputsNote() {
        // Spec 10 §14 — "amber "Unsaved (3)" ..., amber "Disk low", and red "Disk full: changes not saved"".
        XCTAssertEqual([TopBarTag.audioMuted, .audioLost, .popup(1), .engine(badges: 1), .engine(badges: 2), .saving(.unsaved(3)), .saving(.diskLow),
                        .saving(.diskFull)].map(ShowWording.tag),
                       ["Audio muted", "Audio lost", "Popup 1", "1 engine notice", "2 engine notices", "Unsaved (3)", "Disk low", "Disk full: changes not saved"])
        XCTAssertEqual(ShowWording.note(.noOutputs), "No outputs")
        XCTAssertEqual(ShowWording.note(.mirrored), "Screens are mirrored: the room sees this window")
    }

    private func cell(trigger: CueTrigger.Kind = .go, advance: Int? = nil, armed: Bool = false, live: Bool = false, label: String = "Verse 2") -> CueCell {
        CueCell(uuid: "c", number: 3, label: label, note: "", section: nil, hue: nil, trigger: trigger, advanceAfterMs: advance, chips: [], text: nil,
                thumbnail: nil, isLive: live, isArmed: armed, missingMedia: false, keptUnknown: false, matchesSearch: false)
    }

    func test_theTriggerReadsGoATimeAnAdvanceOrTheCountdown() {
        XCTAssertEqual(ShowWording.trigger(cell(), locale: english), "Go")
        XCTAssertEqual(ShowWording.trigger(cell(trigger: .time(ms: 8000)), locale: english), "+8 s")
        XCTAssertEqual(ShowWording.trigger(cell(trigger: .time(ms: 2500)), locale: english), "+2.5 s")
        XCTAssertEqual(ShowWording.trigger(cell(trigger: .time(ms: 90_000)), locale: english), "+1:30", "a clock from a minute")
        XCTAssertEqual(ShowWording.trigger(cell(advance: 12_000), locale: english), "adv 12 s")
        XCTAssertEqual(ShowWording.trigger(cell(trigger: .time(ms: 8000), advance: 12_000), locale: english), "+8 s · adv 12 s", "a cue with both shows both")
        XCTAssertEqual(ShowWording.trigger(cell(trigger: .time(ms: 8000), armed: true), armedMs: 7_100, locale: english), "Auto 0:08", "on the cue armed to fire next")
    }

    func test_aChipSaysItsChannelItsStateAndTheAttributesItAlsoWrites() {
        XCTAssertEqual(ShowWording.chip(CueChip(channel: 2, state: .new), label: "Foreground"), "2 Foreground: new")
        XCTAssertEqual(ShowWording.chip(CueChip(channel: 3, state: .held), label: "Clock"), "3 Clock: held")
        XCTAssertEqual(ShowWording.chip(CueChip(channel: 1, state: .clear), label: "Background"), "1 Background: cleared")
        XCTAssertEqual(ShowWording.chip(CueChip(channel: 1, state: .redundant), label: "Background"), "1 Background: redundant, it writes what is already there")
        let written = CueChip(channel: 2, state: .new, attributes: [.init(attribute: .grade, value: .grade(1), isRedundant: false),
                                                                    .init(attribute: .audioTransition, value: .audioTransition(TransitionSetting(ref: 2)), isRedundant: false)])
        XCTAssertEqual(ShowWording.chip(written, label: "Foreground"), "2 Foreground: new · also writes grade and audio transition")
    }

    func test_aCueAndTheGridsCountForVoiceOverAndTheHeader() throws {
        XCTAssertEqual(ShowWording.cue(cell()), "Cue 3, Verse 2")
        XCTAssertEqual(ShowWording.cue(cell(live: true)), "Cue 3, Verse 2, live", "colour is never the only signal")
        XCTAssertEqual(ShowWording.cue(cell(label: "")), "Cue 3")
        XCTAssertEqual(ShowWording.count(GridModel.make(try Recorded.inputs(.playlist(Recorded.sunday)))), "3 lists")
        XCTAssertEqual(ShowWording.count(GridModel.make(try Recorded.inputs(.list(Recorded.list42)))), "4 cues")
        XCTAssertEqual(ShowWording.refusal(.renameToFire), "Rename to fire")
        XCTAssertEqual(ShowWording.refusal(.renumberToFire), "Renumber to fire")
    }

    func test_aPlaylistsDateIsMonthAndDayWithTheYearWhenItIsNotThisYears() throws {
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-17T12:00:00Z"))
        XCTAssertEqual(ShowWording.serviceDate("2026-11-01", now: now, locale: english), "Nov 1")
        XCTAssertEqual(ShowWording.serviceDate("2025-12-24", now: now, locale: english), "Dec 24, 2025")
        XCTAssertNil(ShowWording.serviceDate(nil, now: now, locale: english))
        XCTAssertNil(ShowWording.serviceDate("soon", now: now, locale: english), "a date that doesn't read shows nothing")
    }

    func test_whyNothingHappenedInPlainWords() {
        XCTAssertEqual([WhyNothing.endOfPlaylist, .endOfLibraryList, .noCue(number: 14, title: "Great Is Thy Faithfulness"), .nothingLive, .pickUp, .startOfPlaylist]
            .map(ShowWording.why),
                       ["End of the playlist", "End of this song: it was fired from the library", "No cue 14 in Great Is Thy Faithfulness", "Nothing is live",
                        "Click a cue to pick up where you were", "Start of the playlist"])
    }

    func test_theClearsTilesAndThePopupsTimes() {
        XCTAssertEqual([ClearsTile.Kind.clearAll, .blackoutStack(1), .blackoutAll, .muteAllAudio, .resetChannels, .clearPopups].map(ShowWording.tile),
                       ["Clear All", "Blackout Stack 1", "Blackout All", "Mute All Audio", "Reset Channels", "Clear Popups"])
        XCTAssertEqual(PopupClearAfter.choices.map(ShowWording.clearAfter), ["Stays", "15 s", "30 s", "1 min", "2 min", "5 min"])
    }

    func test_anOutputsDetailsReadAsAVideoEngineerNamesThem() {
        let sixty = VideoFormat(width: 1920, height: 1080, rate: FrameRate(num: 60), interlaced: false)
        let interlaced = VideoFormat(width: 1920, height: 1080, rate: FrameRate(num: 30000, den: 1001), interlaced: true)
        XCTAssertEqual(ShowWording.format(sixty, locale: english), "1920 × 1080 · 60p")
        XCTAssertEqual(ShowWording.format(interlaced, locale: english), "1920 × 1080 · 59.94i", "an interlaced format by its fields a second")
        XCTAssertEqual(ShowWording.format(VideoFormat(width: 3840, height: 2160, rate: FrameRate(num: 30), interlaced: false), locale: english), "3840 × 2160 · 30p")
        let sdi = OutputDetails(number: 2, label: "Program SDI", device: "DeckLink Duo (1)", format: interlaced, reference: "locked", state: .presenting,
                                stack: 1, isBlackedOut: true, presented: 12_601, late: 3, dropped: 0)
        XCTAssertEqual(ShowWording.rows(sdi, locale: english).map { "\($0.name): \($0.value)" },
                       ["Device: DeckLink Duo (1)", "Format: 1920 × 1080 · 59.94i", "Reference: locked", "State: presenting · Blackout", "Presented: 12,601",
                        "Late: 3", "Dropped: 0"])
        let display = OutputDetails(number: 1, label: "Main", device: "V247Y E", format: sixty, reference: nil, state: .lost, stack: 1, isBlackedOut: false)
        XCTAssertEqual(ShowWording.rows(display, locale: english).map { "\($0.name): \($0.value)" },
                       ["Device: V247Y E", "Format: 1920 × 1080 · 60p", "State: lost", "Presented: not yet", "Late: not yet", "Dropped: not yet"],
                       "a display has no reference, and the counts wait for the engine's first metrics")
        XCTAssertEqual(ShowWording.reference("freeRun"), "free-running")
    }

    func test_aStripCellsWords() {
        XCTAssertEqual(ShowWording.remaining(.loops), "loops")
        XCTAssertEqual(ShowWording.remaining(.paused(ms: 83_000)), "paused 1:23")
        XCTAssertEqual(ShowWording.remaining(.counting(ms: 41_200)), "−0:42")
        XCTAssertEqual(ShowWording.origin(.cue(label: "Verse 2", list: "Great Is Thy Faithfulness")), "from Verse 2 · Great Is Thy Faithfulness")
        XCTAssertEqual(ShowWording.origin(.cue(label: nil, list: "Doxology")), "from Doxology")
        XCTAssertEqual(ShowWording.origin(.cue(label: nil, list: nil)), "from a cue")
        XCTAssertEqual(ShowWording.origin(.restored), "restored")
        XCTAssertEqual(["ui", "osc", "macro", "key", "api", "scheduler"].map { ShowWording.origin(.source($0)) },
                       ["from the UI", "from OSC", "from a macro", "from a key", "from the API", "from scheduler"])
        XCTAssertEqual(ShowWording.dot(StackDot(stack: 2, label: "Confidence", state: .showing)), "Stack 2 Confidence: showing")
        XCTAssertEqual(ShowWording.dot(StackDot(stack: 2, label: "Confidence", state: .muted)), "Stack 2 Confidence: muted")
        XCTAssertEqual(ShowWording.dot(StackDot(stack: 1, label: "Main", state: .absent)), "Stack 1 Main: not in this stack")
        XCTAssertEqual([StripCell.Kind.empty, .text, .video, .image, .audio, .slide, .input, .other("x")].map(ShowWording.kind),
                       ["Empty", "Text", "Video", "Image", "Audio", "Slide", "Input", "Media"])
    }
}
