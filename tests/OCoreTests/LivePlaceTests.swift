import Foundation
import XCTest
@testable import OCore

/// Spec 7 §4 — the pointer's place, the kept copies and everything that
/// reads them; Spec 7 §10, "The pointer" and "The armed trigger". On the
/// fixture's "Sunday Night": 1 the header "Evening", 2 list 42, 3 list 7,
/// 4 list 42 again. List 42's cues are 11aa, 22bb, 33cc (a Time trigger of
/// 8 s) and 44dd, the first three in the section "Verse 1"; list 7's are
/// 55ee, 66ff and 77aa. Commands and edits go through the runner, which keeps
/// the copies as the engine does; a reload changes the roots and refreshes
/// the copies as the engine does after one.
final class LivePlaceTests: XCTestCase {
    typealias F = FixtureLibrary
    static func u(_ uuid: UUID) -> String { uuid.uuidString.lowercased() }
    static let n = u(F.sundayNightUuid)
    static let c = F.list42Cues
    static let d = F.list7Cues

    struct Show {
        var library: Library
        var machine: Machine
        var state: ShowState
        var kept = KeptCopies()
        var frame = 1000
        var executed: [ExecutedCommand] = []

        init() {
            let (library, machine, _) = F.load()
            self.library = library
            self.machine = machine
            self.machine.settings.libraryMode = .writable
            state = ShowState.fresh(library: library, machine: machine)
        }

        var context: ProjectionContext {
            ProjectionContext(frame: frame, library: library, machine: machine, source: CommandSource(kind: .ui), kept: kept)
        }

        /// Sunday Night's items by position, as the playlist is now (or as it was, once deleted).
        var items: [UUID] {
            (machine.playlist(uuid: F.sundayNightUuid) ?? kept.playlist)?.items.map(\.uuid) ?? []
        }

        /// Commands in their text forms as one group, through the runner.
        @discardableResult
        mutating func run(_ texts: String..., file: StaticString = #filePath, line: UInt = #line) -> Rejection? {
            var commands: [GuardedCommand] = []
            for text in texts {
                switch CommandText.parse(text, options: ParseOptions(library: library, machine: machine)) {
                case .success(let command): commands.append(command)
                case .failure(let rejection):
                    XCTFail("\(text): \(rejection.message)", file: file, line: line)
                    return rejection
                }
            }
            return run(commands)
        }

        @discardableResult
        mutating func run(_ commands: [GuardedCommand]) -> Rejection? {
            let group = CommandGroup(id: GroupID("g-00000000"), source: CommandSource(kind: .ui), commands: commands)
            switch CommandRunner.run(group, state: state, context: context, editing: EditContext(today: "2026-11-08"),
                                     makeGroupID: { GroupID("g-00000001") }) {
            case .success(let outcome):
                state = outcome.state
                library = outcome.library
                machine = outcome.machine
                kept = outcome.kept
                executed = outcome.executed
                return nil
            case .failure(let rejection):
                return rejection
            }
        }

        /// A change that arrives by reload (Spec 5 §10): the roots change and
        /// the engine refreshes its copies.
        mutating func reload(_ change: (inout Library, inout Machine) -> Void) {
            change(&library, &machine)
            kept = kept.refreshed(for: state.pointer, library: library, machine: machine)
        }

        var reading: LiveSnapshot { LiveSnapshot.reading(state: state, library: library, machine: machine, kept: kept) }
        /// What `next` and `previous` would fire, without firing it.
        var next: LivePointer? { project(state, [.next], context: context).0.pointer }
        var previous: LivePointer? { project(state, [.previous], context: context).0.pointer }
        /// Lookahead's first cue (Spec 3 §7).
        var ahead: LivePointer? { lookahead(state, steps: 1, context: context)?.pointer }
        var liveTitle: String? { Fold(state: state, context: context).value(of: "Live Title") }
    }

    func live(item: Int, cue: Int) -> Show {
        var show = Show()
        XCTAssertNil(show.run("playlist \"Sunday Night\"", "item \(item) cue \(cue)"))
        return show
    }

    func pointer(_ show: Show, item: Int, cue: UUID, list: Int = 42) -> LivePointer {
        LivePointer(playlist: F.sundayNightUuid, itemUuid: show.items[item - 1], listUuid: F.listUuid(list), cueUuid: cue)
    }

    // MARK: - The place (Spec 7 §4)

    /// "Inserting, removing or moving other items or cues changes nothing,
    /// and a song linked twice stays on the right copy. Moving the live cue
    /// or the live item takes the place with it."
    func test_otherItemsAndCuesLeaveThePlaceAloneAndTheLiveCueTakesItWithIt() {
        var show = live(item: 4, cue: 2)
        let pointer = show.state.pointer
        show.run("edit playlist \(Self.n) insert items 0 { \"kind\": \"header\", \"label\": \"Prelude\" }")
        show.run("edit list 42 insert cues 0 { \"label\": \"Intro\" }")
        XCTAssertEqual(show.state.pointer, pointer, "an edit never moves the pointer")
        XCTAssertEqual(show.reading.itemPosition, 5)
        XCTAssertEqual(show.reading.cuePosition, 3)
        XCTAssertEqual(show.next, LivePointer(playlist: F.sundayNightUuid, itemUuid: pointer?.itemUuid, listUuid: F.listUuid(42), cueUuid: Self.c[2]),
                       "the second copy of list 42 goes on in that copy")
        show.run("edit list 42 cue \(Self.u(Self.c[1])) move 1")
        XCTAssertEqual(show.reading.cuePosition, 2)
        XCTAssertEqual(show.next?.cueUuid, Self.c[0], "the place moved with the cue")
        XCTAssertTrue(show.reading.gone.isEmpty)
    }

    /// "With the live cue removed, by a delete or a merge, `next` and
    /// `previous` fire its old neighbours."
    func test_withTheLiveCueRemovedNextAndPreviousFireItsOldNeighbours() {
        var show = live(item: 2, cue: 2)
        show.run("edit list 42 cue \(Self.u(Self.c[1])) remove")
        XCTAssertEqual(show.reading.gone, ["cue"])
        XCTAssertEqual(show.next, pointer(show, item: 2, cue: Self.c[2]))
        XCTAssertEqual(show.previous, pointer(show, item: 2, cue: Self.c[0]))
        XCTAssertEqual(show.ahead, show.next, "lookahead's first cue is the cue next fires")
        // Spec 7 §6 — "the number of the cue just before its place ... and that cue's label".
        XCTAssertEqual(show.reading.cuePosition, 1)
        XCTAssertEqual(show.reading.label, "Verse 1")

        // A merge: the text joined on the first cue, the live one removed, one group.
        var merged = live(item: 2, cue: 2)
        merged.run("edit list 42 cue \(Self.u(Self.c[0])) channel 2 write text \"Joined\"", "edit list 42 cue \(Self.u(Self.c[1])) remove")
        XCTAssertEqual(merged.next?.cueUuid, Self.c[2])
        XCTAssertEqual(merged.previous?.cueUuid, Self.c[0])
    }

    /// "after a section remove that takes the neighbours too, they fire the
    /// nearest cues that remain, and with every cue before it gone, the place
    /// is the top."
    func test_aSectionRemoveThatTakesTheNeighboursLeavesThePlaceAtTheTop() {
        var show = live(item: 4, cue: 2)
        show.run("edit list 42 cue \(Self.u(Self.c[1])) section remove")
        XCTAssertEqual(show.library.list(number: 42)?.cues.map(\.uuid), [Self.c[3]])
        XCTAssertEqual(show.next, pointer(show, item: 4, cue: Self.c[3]), "the first cue after the top")
        XCTAssertEqual(show.previous, pointer(show, item: 3, cue: Self.d[2], list: 7), "the last cue of the item before")
        XCTAssertEqual(show.reading.cuePosition, 0)
        XCTAssertEqual(show.reading.label, "")
        XCTAssertEqual(show.ahead, show.next)
    }

    /// "The same holds when the change arrives by reload".
    func test_theSameHoldsWhenTheRemovalArrivesByReload() {
        var show = live(item: 2, cue: 2)
        show.reload { library, _ in
            let index = library.lists.firstIndex { $0.number == 42 }!
            library.lists[index].cues.remove(at: 1)
        }
        XCTAssertEqual(show.next?.cueUuid, Self.c[2])
        XCTAssertEqual(show.previous?.cueUuid, Self.c[0])
        XCTAssertEqual(show.reading.gone, ["cue"])
    }

    /// "and when other cues or items were moved or inserted between the fire
    /// and the removal": the copy is the last version that held the cue.
    func test_cuesMovedOrInsertedBeforeTheRemovalDontMoveThePlace() {
        var show = live(item: 2, cue: 3)
        show.run("edit list 42 insert cues 0 { \"label\": \"Intro\" }")
        show.run("edit list 42 cue \(Self.u(Self.c[0])) move 4")
        show.run("edit list 42 cue \(Self.u(Self.c[2])) remove")
        XCTAssertEqual(show.next?.cueUuid, Self.c[3], "what followed it")
        XCTAssertEqual(show.previous?.cueUuid, Self.c[1], "what came before it")
    }

    /// "With the live item removed, the song finishes, and `next` then goes
    /// on to the item that followed it". Spec 7 §6 — "item 0 and the live
    /// cue's own number".
    func test_withTheLiveItemRemovedTheSongFinishesThenGoesOn() {
        var show = live(item: 2, cue: 3)
        let gone = show.items[1]
        show.run("edit playlist \(Self.n) item \(Self.u(gone)) remove")
        XCTAssertEqual(show.reading.gone, ["item"])
        XCTAssertEqual(show.reading.itemPosition, 0)
        XCTAssertEqual(show.reading.cuePosition, 3)
        XCTAssertEqual(show.next, LivePointer(playlist: F.sundayNightUuid, itemUuid: gone, listUuid: F.listUuid(42), cueUuid: Self.c[3]),
                       "the song finishes in its own item")
        show.run("next")
        XCTAssertEqual(show.state.pointer?.cueUuid, Self.c[3])
        XCTAssertEqual(show.next?.cueUuid, Self.d[0], "then the item that followed it")
        XCTAssertEqual(show.next?.itemUuid, show.items[1])
        XCTAssertEqual(show.reading.nextTitle, "Doxology")
        XCTAssertEqual(show.ahead, show.next)
    }

    /// "... also when the item before it was moved since": the move comes
    /// before the removal, so the copy holds it.
    func test_theItemThatFollowedItWhenTheItemBeforeItMovedSince() {
        var show = live(item: 2, cue: 4)
        let header = show.items[0]
        let gone = show.items[1]
        show.run("edit playlist \(Self.n) item \(Self.u(header)) move 3")
        show.run("edit playlist \(Self.n) item \(Self.u(gone)) remove")
        XCTAssertEqual(show.items.count, 3)
        XCTAssertEqual(show.next?.cueUuid, Self.d[0], "list 7, which followed it, not nothing after the moved header")
    }

    /// "With the live list ... deleted, the kept copy runs on for `next`,
    /// `cue N`, lookahead and `[Live Title]`, with any edit made to it before
    /// the delete."
    func test_withTheLiveListDeletedTheKeptCopyRunsOn() {
        var show = live(item: 2, cue: 2)
        show.run("edit list 42 title \"Faithfulness\"")
        show.run("edit list 42 delete")
        XCTAssertNil(show.library.list(number: 42))
        XCTAssertEqual(show.reading.gone, ["list"], "the cues live on in the copy; the list is what's gone")
        XCTAssertEqual(show.liveTitle, "Faithfulness")
        XCTAssertEqual(show.reading.listTitle, "Faithfulness")
        XCTAssertEqual(show.next?.cueUuid, Self.c[2])
        XCTAssertEqual(show.ahead, show.next)
        XCTAssertNil(show.run("cue 4"), "cue N reads the copy")
        XCTAssertEqual(show.state.pointer?.cueUuid, Self.c[3])
        XCTAssertEqual(show.next, pointer(show, item: 3, cue: Self.d[0], list: 7), "then on into the next song")
        XCTAssertEqual(show.reading.nextTitle, "Doxology")
    }

    /// "With the live ... playlist deleted, the kept copy runs on", and
    /// "firing into the next song is a boundary, so a tracked grade from the
    /// song on air resets".
    func test_withTheLivePlaylistDeletedTheKeptCopyRunsOnAndTheNextSongIsABoundary() {
        var show = live(item: 3, cue: 3)
        show.run("edit playlist \(Self.n) delete")
        XCTAssertNil(show.machine.playlist(uuid: F.sundayNightUuid))
        XCTAssertEqual(show.reading.gone, ["playlist"])
        XCTAssertEqual(show.reading.playlistTitle, "Sunday Night")
        XCTAssertEqual(show.ahead?.cueUuid, Self.c[0])
        show.run("next")
        XCTAssertEqual(show.state.pointer, pointer(show, item: 4, cue: Self.c[0]))
        XCTAssertTrue(show.executed.flatMap(\.effects).contains(.boundary(list: F.listUuid(42), reset: true)),
                      "list 42 doesn't track through, so the tracked attributes reset")
        XCTAssertNil(show.run("item 2 cue 2"), "item N cue M reads the copy")
        XCTAssertEqual(show.state.pointer?.itemUuid, show.items[1])
    }

    /// "Applying the removal's logged inverse puts the pointer back on the
    /// cue without firing it."
    func test_theRemovalsInversePutsThePointerBackWithoutFiringIt() throws {
        var show = live(item: 2, cue: 2)
        let channels = show.state.channels
        show.run("edit list 42 cue \(Self.u(Self.c[1])) remove")
        let inverse = try XCTUnwrap(show.executed.first?.inverse)
        show.run([GuardedCommand(inverse)])
        XCTAssertTrue(show.reading.gone.isEmpty)
        XCTAssertEqual(show.reading.cuePosition, 2)
        XCTAssertEqual(show.state.channels, channels, "nothing fired")
        XCTAssertEqual(show.next?.cueUuid, Self.c[2])
    }

    /// "After a relaunch with the live cue gone, `next` and `previous` do
    /// nothing": the copies were taken after it had gone. `cue N` works while
    /// the live list can be found.
    func test_afterARelaunchWithTheLiveCueGoneNextAndPreviousDoNothing() {
        var show = live(item: 2, cue: 2)
        show.reload { library, _ in
            let index = library.lists.firstIndex { $0.number == 42 }!
            library.lists[index].cues.remove(at: 1)
        }
        show.kept = KeptCopies()
        let pointer = show.state.pointer
        XCTAssertEqual(show.next, pointer)
        XCTAssertEqual(show.previous, pointer)
        XCTAssertNil(show.ahead, "lookahead shows nothing")
        XCTAssertNil(show.run("cue 3"))
        XCTAssertEqual(show.state.pointer?.cueUuid, Self.c[3], "cue 3 of the list as it is now")

        // An older state file's pointer names no item: the engine can't place it in its playlist.
        var old = Show()
        old.state.pointer = LivePointer(playlist: F.sundayNightUuid, listUuid: F.listUuid(42), cueUuid: Self.c[1])
        XCTAssertEqual(old.next, old.state.pointer)
    }

    /// Spec 7 §4 — what reads the pointer, before a cue fires.
    func test_whatReadsThePointerBeforeACueFires() {
        var show = Show()
        XCTAssertNil(show.next)
        XCTAssertEqual(show.reading.playlistTitle, "")
        XCTAssertEqual(show.reading.itemPosition, 0)
        XCTAssertEqual(show.reading.cuePosition, 0)
        XCTAssertEqual(show.reading.label, "")
        XCTAssertNil(show.reading.nextTitle)
        XCTAssertEqual(show.run("cue 1")?.reason, .noSuchTarget, "no list is live")
        show.run("playlist \"Sunday Night\"")
        XCTAssertEqual(show.reading.playlistTitle, "Sunday Night")
        XCTAssertEqual(show.reading.nextTitle, "Great Is Thy Faithfulness", "the first list's title")
        XCTAssertEqual(show.next, pointer(show, item: 2, cue: Self.c[0]))
        XCTAssertNil(show.previous.flatMap(\.cueUuid))
        XCTAssertEqual(show.run("cue 1")?.reason, .noSuchTarget, "no list is live until a cue fires")
    }

    /// Spec 6 §5 and interpretation 24 — `[Next Title]` is the next list
    /// after the item's place, the list `next` fires where it leaves the song;
    /// empty after the last list or with no playlist.
    func test_nextTitleNamesTheNextListAfterTheItemsPlace() {
        var show = live(item: 2, cue: 1)
        XCTAssertEqual(show.reading.nextTitle, "Doxology")
        show.run("item 4 cue 1")
        XCTAssertNil(show.reading.nextTitle, "after the last list")
        show.run("list 42 cue 1")
        XCTAssertNil(show.reading.nextTitle, "a library list has no playlist")
    }

    // MARK: - The armed trigger (Spec 7 §4)

    /// "The trigger is live while its cue is still the one `next` would
    /// fire ... a cue put between the live one and the armed one ... makes
    /// the countdown lapse ... An edit that makes it next again before its
    /// time brings the countdown back."
    func test_aCueInsertedBetweenLapsesTheCountdownAndRemovingItBringsItBack() throws {
        var show = live(item: 2, cue: 2)
        let armed = try XCTUnwrap(show.state.armed)
        XCTAssertEqual(armed.cueUuid, Self.c[2])
        XCTAssertEqual(show.state.liveArmed(library: show.library, machine: show.machine, kept: show.kept), armed)
        XCTAssertEqual(show.reading.armed?.cuePosition, 3)
        XCTAssertEqual(show.reading.armed?.itemPosition, 2)

        show.run("edit list 42 insert cues 2 { \"label\": \"Bridge\", \"uuid\": \"b0b00000-0000-4000-8000-000000000001\" }")
        XCTAssertEqual(show.state.armed, armed, "the trigger stays in ShowState")
        XCTAssertNil(show.state.liveArmed(library: show.library, machine: show.machine, kept: show.kept), "but it has lapsed")
        XCTAssertNil(show.reading.armed)

        show.run("edit list 42 cue b0b00000-0000-4000-8000-000000000001 remove")
        XCTAssertEqual(show.state.liveArmed(library: show.library, machine: show.machine, kept: show.kept), armed, "back")
        show.run("edit playlist \(Self.n) insert items 0 { \"kind\": \"header\", \"label\": \"Prelude\" }")
        XCTAssertEqual(show.reading.armed?.itemPosition, 3, "its positions follow an edit")
    }

    /// Spec 7 §6 — "`item` is 0 ... for a cue in a gone item": the countdown
    /// in a song whose item was removed still fires its cue.
    func test_aCountdownInAGoneItemStaysLive() {
        var show = live(item: 2, cue: 2)
        show.run("edit playlist \(Self.n) item \(Self.u(show.items[1])) remove")
        XCTAssertNotNil(show.state.liveArmed(library: show.library, machine: show.machine, kept: show.kept))
        XCTAssertEqual(show.reading.armed?.itemPosition, 0)
        XCTAssertEqual(show.reading.armed?.cuePosition, 3)
    }

    /// "An edit to a trigger or an advance-after takes effect the next time a
    /// trigger arms."
    func test_aChangedTriggerCountsFromTheNextArming() {
        var show = live(item: 2, cue: 2)
        let armed = show.state.armed
        XCTAssertEqual(armed?.atFrame, 1000 + 480)
        show.run("edit list 42 cue \(Self.u(Self.c[2])) trigger { \"ms\": 2000, \"type\": \"time\" }")
        XCTAssertEqual(show.state.armed, armed)
        show.frame = 2000
        show.run("cue 2")
        XCTAssertEqual(show.state.armed?.atFrame, 2000 + 120)
    }
}
