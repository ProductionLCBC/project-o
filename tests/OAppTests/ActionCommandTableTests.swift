import Foundation
import XCTest
import OCore
@testable import OApp

/// Spec 10 §18, "Area 13, commands" — "A table of every action in §5–§10
/// and the command, group and source it sends, including selection expansion
/// in number order, a fire in a playlist that isn't loaded, Next disabled
/// while nothing is live and enabled for a list fired from the library,
/// Hold, the Clears tiles, the pool's live writes ...".
///
/// Each row is an action, the commands it sends in canonical text (Spec 2
/// §4), whether they go as one group, and the source. The edits of §10 join
/// the table when they are built.
final class ActionCommandTableTests: XCTestCase {
    private struct Row {
        var action: String
        var sending: Sending
        var text: [String]
        var group: Bool
        var source: AppSource = .ui
    }

    private let dawn = "sha256:55c84469c37e1e6a72a9b8938422cd6536b302b583a5c127241c8304246f3527"

    private var rows: [Row] {
        [
            // §6, clicking a cue
            Row(action: "a cue in the live playlist", sending: Actions.fire(item: 2, cue: 3), text: ["item 2 cue 3"], group: false),
            Row(action: "a cue in a playlist that isn't loaded", sending: Actions.fire(loading: "Sunday Night", item: 2, cue: 1),
                text: ["playlist \"Sunday Night\"", "item 2 cue 1"], group: true),
            Row(action: "a cue in a list from the library", sending: Actions.fire(list: 42, cue: 2), text: ["list 42 cue 2"], group: false),
            // §5, a playlist's menu
            Row(action: "Make Live", sending: Actions.makeLive(title: "Sunday"), text: ["playlist \"Sunday\""], group: false),
            // §7, the next row
            Row(action: "Next", sending: Actions.next(), text: ["next"], group: false),
            Row(action: "Last", sending: Actions.previous(), text: ["previous"], group: false),
            Row(action: "the go-to field, 14 and Return", sending: Actions.goTo(cue: 14), text: ["cue 14"], group: false),
            Row(action: "Hold", sending: Actions.hold(), text: ["disarm"], group: false),
            // §7, Transport
            Row(action: "Play, one channel", sending: Actions.transport(.play, channels: [1]), text: ["channel 1 play"], group: false),
            Row(action: "Pause, several channels", sending: Actions.transport(.pause, channels: [3, 1]), text: ["channel 1 pause", "channel 3 pause"], group: true),
            Row(action: "Stop, one channel", sending: Actions.transport(.stop, channels: [1]), text: ["channel 1 stop"], group: false),
            Row(action: "end behavior Loop", sending: Actions.end(.loop, channel: 1), text: ["channel 1 end loop"], group: false),
            Row(action: "end behavior Hold", sending: Actions.end(.hold, channel: 1), text: ["channel 1 end hold"], group: false),
            Row(action: "end behavior Clear", sending: Actions.end(.clear, channel: 1), text: ["channel 1 end clear"], group: false),
            // §7, Clears (choice U-4)
            Row(action: "Clear All", sending: Actions.clearAll(), text: ["system clearall"], group: false),
            Row(action: "Blackout Stack 2", sending: Actions.blackout(stack: 2), text: ["stack 2 blackout toggle"], group: false),
            Row(action: "Blackout All", sending: Actions.blackoutAll(), text: ["stack all blackout toggle"], group: false),
            Row(action: "Mute All Audio", sending: Actions.muteAllAudio(), text: ["audio all mute toggle"], group: false),
            Row(action: "Reset Channels", sending: Actions.resetChannels(), text: ["channel all reset"], group: false),
            Row(action: "Clear Popups, two slots", sending: Actions.clearPopups(slots: 2), text: ["popup 1 clear", "popup 2 clear"], group: true),
            Row(action: "Clear Popups, one slot", sending: Actions.clearPopups(slots: 1), text: ["popup 1 clear"], group: false),
            // §7, Macros
            Row(action: "a macro tile", sending: Actions.macro(3), text: ["macro 3"], group: false),
            // §7, Popups and timers
            Row(action: "Send, stays", sending: Actions.popupSend(slot: 1, text: "Car lights on", clearAfterSeconds: nil),
                text: ["popup 1 set \"Car lights on\""], group: false),
            Row(action: "Send, 30 s", sending: Actions.popupSend(slot: 2, text: "Child 214", clearAfterSeconds: 30),
                text: ["popup 2 set \"Child 214\" clearafter 30"], group: false),
            Row(action: "a popup's Clear", sending: Actions.popupClear(slot: 1), text: ["popup 1 clear"], group: false),
            Row(action: "a timer's Set, down", sending: Actions.timerSet(slot: 1, ms: 300_000, up: false), text: ["timer 1 set 5:00"], group: false),
            Row(action: "a timer's Set, up", sending: Actions.timerSet(slot: 1, ms: 5_000, up: true), text: ["timer 1 set 0:05 up"], group: false),
            Row(action: "a timer's Start", sending: Actions.timerStart(slot: 1), text: ["timer 1 start"], group: false),
            Row(action: "a timer's Pause", sending: Actions.timerPause(slot: 1), text: ["timer 1 pause"], group: false),
            Row(action: "a timer's Reset", sending: Actions.timerReset(slot: 1), text: ["timer 1 reset"], group: false),
            // §7, the strip
            Row(action: "Clear Selected, in number order", sending: Actions.clearSelected([5, 2]), text: ["channel 2 clear", "channel 5 clear"], group: true),
            Row(action: "Clear Selected, one channel", sending: Actions.clearSelected([2]), text: ["channel 2 clear"], group: false),
            Row(action: "a cell's Clear", sending: Actions.clear(channel: 2), text: ["channel 2 clear"], group: false),
            Row(action: "a stack dot", sending: Actions.stackMute(stack: 2, channel: 3), text: ["stack 2 mute 3 toggle"], group: false),
            Row(action: "Lock", sending: Actions.lock(channel: 3, true), text: ["channel 3 lock"], group: false),
            Row(action: "Unlock", sending: Actions.lock(channel: 3, false), text: ["channel 3 unlock"], group: false),
            Row(action: "Reset Attributes", sending: Actions.resetAttributes(channel: 1), text: ["channel 1 reset"], group: false),
            Row(action: "Grade ▸ a grade", sending: Actions.grade(channel: 1, grade: 4), text: ["channel 1 grade 4"], group: false),
            Row(action: "Grade ▸ None", sending: Actions.grade(channel: 1, grade: 0), text: ["channel 1 grade 0"], group: false),
            Row(action: "Transition ▸ a transition", sending: Actions.transition(channel: 1, transition: 2), text: ["channel 1 transition 2"], group: false),
            // §6, live writes from the pool
            Row(action: "a pool item, live", sending: Actions.liveWrite(media: dawn, channel: 1, defaultGrade: nil),
                text: ["channel 1 write media \(dawn)"], group: false),
            Row(action: "a pool item with a default grade, live", sending: Actions.liveWrite(media: dawn, channel: 1, defaultGrade: 4),
                text: ["channel 1 write media \(dawn) grade 4 once"], group: false),
            // §8, an output's details
            Row(action: "Stack ▸ a stack", sending: Actions.outputStack(output: 1, stack: 2), text: ["output 1 stack 2"], group: false),
        ]
    }

    func test_everyActionSendsItsCommandsItsGroupAndItsSource() {
        for row in rows {
            XCTAssertEqual(row.sending.text, row.text, row.action)
            XCTAssertEqual(row.sending.group, row.group, "\(row.action): group")
            XCTAssertEqual(row.sending.source, row.source, "\(row.action): source")
        }
    }

    func test_everyCommandPrintsAndParsesBack() {
        // CLAUDE.md — "Commands are stored as objects, printed and parsed in canonical text; `parse(print(x)) == x`."
        for row in rows {
            for command in row.sending.commands {
                let text = try? XCTUnwrap(CommandText.print(command), row.action)
                guard let text else { continue }
                guard case .success(let parsed) = CommandText.parse(text) else {
                    XCTFail("\(row.action): \(text) doesn't parse")
                    continue
                }
                XCTAssertEqual(parsed.command, command, row.action)
            }
        }
    }

    func test_oneCommandGoesAloneAndSeveralGoAsOneGroup() throws {
        // Spec 2 §5 — "the UI expands it to one command per selected channel ... and submits them as a group".
        let one = try XCTUnwrap(Actions.clear(channel: 2).request)
        XCTAssertEqual(one.type, "command")
        XCTAssertEqual(one.fields["source"], .string("ui"))
        let several = try XCTUnwrap(Actions.clearSelected([5, 2]).request)
        XCTAssertEqual(several.type, "commands")
        XCTAssertEqual(several.fields["group"], .bool(true))
        XCTAssertEqual(several.fields["commands"]?.arrayValue?.count, 2)
        XCTAssertNil(Actions.clearSelected([]).request, "nothing selected, nothing sent")
    }

    func test_aKeySendsTheSameCommandWithItsOwnSource() {
        // Spec 10 §9 — "the app maps keys to commands sent with source `key`".
        XCTAssertEqual(Actions.next(source: .key).source, .key)
        XCTAssertEqual(Actions.goTo(cue: 3, source: .key).text, ["cue 3"])
    }

    // MARK: - Fires from the grid (Spec 10 §6, "Clicking")

    private func playlist(_ title: String, uuid: Int, named: Bool = true) -> CatalogPlaylist {
        CatalogPlaylist(playlist: Playlist(uuid: UUID(uuidString: "00000000-0000-0000-0000-00000000000\(uuid)") ?? UUID(), title: title, items: []), named: named)
    }

    func test_aFireInTheLivePlaylistNamesTheItemAndTheCue() {
        let sunday = playlist("Sunday", uuid: 1)
        var live = LiveStatus()
        live.playlist = "00000000-0000-0000-0000-000000000001"
        XCTAssertEqual(try? GridFire.playlistCue(sunday, item: 2, cue: 3, live: live).get().text, ["item 2 cue 3"])
    }

    func test_aFireInAPlaylistThatIsNotLoadedLoadsItAndFiresInOneGroup() {
        let night = playlist("Sunday Night", uuid: 2)
        var live = LiveStatus()
        live.playlist = "00000000-0000-0000-0000-000000000001"
        let sending = try? GridFire.playlistCue(night, item: 2, cue: 1, live: live).get()
        XCTAssertEqual(sending?.text, ["playlist \"Sunday Night\"", "item 2 cue 1"])
        XCTAssertEqual(sending?.group, true, "one group that lands on one frame (Spec 2 §8)")
        XCTAssertEqual(try? GridFire.playlistCue(night, item: 2, cue: 1, live: LiveStatus()).get().text, ["playlist \"Sunday Night\"", "item 2 cue 1"],
                       "with nothing live too")
    }

    func test_aPlaylistWhoseTitleAnotherSharesFiresOnlyIfItsTitleLoadsIt() {
        // Spec 10 §6 — "the other's cells, its Make Live and the restore banner's Fire Again (§14) are disabled with "Rename to fire"."
        let twin = playlist("Sunday", uuid: 3, named: false)
        XCTAssertEqual(GridFire.playlistCue(twin, item: 1, cue: 1, live: LiveStatus()), .failure(.renameToFire))
        XCTAssertEqual(GridFire.makeLive(twin), .failure(.renameToFire))
        XCTAssertEqual(try? GridFire.makeLive(playlist("Sunday", uuid: 1)).get().text, ["playlist \"Sunday\""])
        // The twin that is live was loaded some other way: its cues fire by item, which needs no title.
        var live = LiveStatus()
        live.playlist = "00000000-0000-0000-0000-000000000003"
        XCTAssertEqual(try? GridFire.playlistCue(twin, item: 1, cue: 1, live: live).get().text, ["item 1 cue 1"])
    }

    func test_aLibraryListFiresByItsNumberUnlessAnotherSharesIt() {
        let list = ListSummary(number: 42, uuid: "a9f0", title: "Great Is Thy Faithfulness")
        XCTAssertEqual(try? GridFire.libraryCue(list, cue: 2).get().text, ["list 42 cue 2"])
        var twin = list
        twin.named = false
        XCTAssertEqual(GridFire.libraryCue(twin, cue: 2), .failure(.renumberToFire), "Spec 7 §2: disabled the same way, with \"Renumber to fire\"")
    }
}
