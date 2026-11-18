import Foundation
import XCTest
import OCore
@testable import OApp

/// Spec 10 §18, "Area 13, commands" — "A table of every action in §5–§10 and
/// the command, group and source it sends": the edits' rows. Each edit is
/// read in the canonical text the log will hold (Spec 5 §4), from the
/// recorded fixture library: list 42 and the playlist Sunday.
final class EditCommandTableTests: XCTestCase {
    private let sunday = UUID(uuidString: "b1a70000-0000-4000-8000-000000000001")!
    private let item = UUID(uuidString: "ae3aafe3-0000-4000-8000-000000000000") ?? UUID()

    private func text(_ sending: Sending, file: StaticString = #filePath, line: UInt = #line) -> [String] {
        XCTAssertEqual(sending.source, .ui, file: file, line: line)
        XCTAssertEqual(sending.group, sending.commands.count > 1, file: file, line: line)
        // What is sent reads back as what was meant (`parse(print(x)) == x`).
        for command in sending.commands {
            guard let printed = CommandText.print(command) else {
                XCTFail("\(command.cmd) doesn't print", file: file, line: line)
                continue
            }
            XCTAssertEqual(try? CommandText.parse(printed).get().command, command, printed, file: file, line: line)
        }
        return sending.text
    }

    private func list42() throws -> List { try Recorded.list("list-42").list }

    private func cue(_ index: Int) throws -> Cue { try list42().cues[index] }

    // MARK: - Playlists (§5)

    func test_thePlaylistsEdits() throws {
        let playlist = try XCTUnwrap(try Recorded.catalog().playlist(uuid: Recorded.sunday)?.playlist)
        let p = "b1a70000-0000-4000-8000-000000000001"
        XCTAssertEqual(text(Edits.newPlaylist(title: "Christmas Eve")), ["edit playlist create \"Christmas Eve\""])
        XCTAssertEqual(text(Edits.rename(playlist: sunday, to: "Sunday AM")), ["edit playlist \(p) title \"Sunday AM\""])
        XCTAssertEqual(text(Edits.duplicate(playlist: sunday, title: "Sunday Night 2")), ["edit playlist \(p) duplicate \"Sunday Night 2\""])
        XCTAssertEqual(text(Edits.archiveCopy(playlist: sunday)), ["edit playlist \(p) archive"])
        XCTAssertEqual(text(Edits.archive(playlist: sunday, true)), ["edit playlist \(p) archived true"])
        XCTAssertEqual(text(Edits.archive(playlist: sunday, false)), ["edit playlist \(p) archived false"])
        XCTAssertEqual(text(Edits.delete(playlist: sunday)), ["edit playlist \(p) delete"])
        // "Date and Time… (a popover setting `serviceDate` and `serviceTime`, each with "None")": only what changed, both as one group.
        XCTAssertEqual(playlist.serviceDate, "2026-11-01")
        XCTAssertNil(playlist.serviceTime)
        XCTAssertEqual(text(Edits.schedule(playlist: playlist, date: "2026-11-08", time: nil)), ["edit playlist \(p) serviceDate \"2026-11-08\""])
        XCTAssertEqual(text(Edits.schedule(playlist: playlist, date: nil, time: "09:00")),
                       ["edit playlist \(p) serviceDate null", "edit playlist \(p) serviceTime \"09:00\""])
        XCTAssertEqual(Edits.schedule(playlist: playlist, date: "2026-11-01", time: nil).commands, [], "nothing changed, nothing sent")
        XCTAssertNil(Edits.schedule(playlist: playlist, date: "2026-11-01", time: nil).request)
    }

    func test_aPlaylistsItemsEdits() throws {
        let playlist = try XCTUnwrap(try Recorded.catalog().playlist(uuid: Recorded.sunday)?.playlist)
        let p = "b1a70000-0000-4000-8000-000000000001"
        let first = playlist.items[1]
        let i = first.uuid.uuidString.lowercased()
        XCTAssertEqual(text(Edits.remove(item: first.uuid, from: sunday)), ["edit playlist \(p) item \(i) remove"])
        XCTAssertEqual(text(Edits.move(item: first.uuid, in: sunday, to: 3)), ["edit playlist \(p) item \(i) move 3"])
        XCTAssertEqual(text(Edits.rename(header: playlist.items[0].uuid, in: sunday, to: "Gathering")),
                       ["edit playlist \(p) item \(playlist.items[0].uuid.uuidString.lowercased()) label \"Gathering\""])
        XCTAssertEqual(text(Edits.insertHeader("Offering", in: sunday, at: 3)),
                       ["edit playlist \(p) insert items 3 { \"kind\": \"header\", \"label\": \"Offering\" }"])
        // "naming the list by its uuid, since two lists can share a number".
        let list = try XCTUnwrap(try Recorded.catalog().list(uuid: Recorded.list7))
        XCTAssertEqual(text(Edits.insert(list: list, in: sunday, at: 5)),
                       ["edit playlist \(p) insert items 5 { \"kind\": \"linked\", \"list\": 7, \"listUuid\": \"\(Recorded.list7)\" }"])
    }

    // MARK: - The library (§5)

    func test_theLibrarysFolderAndListEdits() {
        XCTAssertEqual(text(Edits.rename(folder: "Hymns", to: "Old Hymns")), ["edit folder \"Hymns\" rename \"Old Hymns\""])
        XCTAssertEqual(text(Edits.rename(folder: "Worship/Hymns", to: "Songs")), ["edit folder \"Worship/Hymns\" rename \"Worship/Songs\""],
                       "a rename keeps the folder where it is")
        XCTAssertEqual(text(Edits.move(folder: "Hymns", into: "Christmas")), ["edit folder \"Hymns\" rename \"Christmas/Hymns\""],
                       "a folder dragged onto another: a rename with the new parent")
        XCTAssertEqual(text(Edits.move(folder: "Christmas/Hymns", into: "")), ["edit folder \"Christmas/Hymns\" rename \"Hymns\""])
        XCTAssertEqual(text(Edits.newFolder("Easter", in: "")), ["edit folder \"Easter\" create"])
        XCTAssertEqual(text(Edits.newFolder("Carols", in: "Christmas")), ["edit folder \"Christmas/Carols\" create"])
        XCTAssertEqual(text(Edits.delete(folder: "Christmas")), ["edit folder \"Christmas\" delete"])
        XCTAssertEqual(text(Edits.move(list: 42, toFolder: "Hymns")), ["edit list 42 folder \"Hymns\""])
        XCTAssertEqual(text(Edits.move(list: 42, toFolder: "")), ["edit list 42 folder \"\""], "onto the tree's empty space: the top")
        XCTAssertEqual(text(Edits.rename(list: 42, to: "Great Is Thy Faithfulness (key of D)")),
                       ["edit list 42 title \"Great Is Thy Faithfulness (key of D)\""])
        XCTAssertEqual(text(Edits.duplicate(list: 42)), ["edit list 42 duplicate"])
        XCTAssertEqual(text(Edits.delete(list: 42)), ["edit list 42 delete"])
        XCTAssertEqual(text(Edits.newList(in: "Hymns")), ["edit list create folder \"Hymns\""])
        XCTAssertEqual(text(Edits.newList(in: nil)), ["edit list create"])
        XCTAssertEqual(text(Edits.newList(in: "")), ["edit list create"])
    }

    // MARK: - A cue's menu (§6)

    func test_aCuesMenuEdits() throws {
        let cue = try cue(1)
        let c = cue.uuid.uuidString.lowercased()
        XCTAssertEqual(text(Edits.note("Wait for the pastor", list: 42, cue: cue.uuid)), ["edit list 42 cue \(c) note \"Wait for the pastor\""])
        XCTAssertEqual(text(Edits.trigger(.go, list: 42, cue: cue.uuid)), ["edit list 42 cue \(c) trigger { \"type\": \"go\" }"])
        XCTAssertEqual(text(Edits.trigger(.time(ms: 8000), list: 42, cue: cue.uuid)), ["edit list 42 cue \(c) trigger { \"ms\": 8000, \"type\": \"time\" }"])
        XCTAssertEqual(text(Edits.advanceAfter(ms: 12_000, list: 42, cue: cue.uuid)), ["edit list 42 cue \(c) advanceAfterMs 12000"])
        XCTAssertEqual(text(Edits.advanceAfter(ms: nil, list: 42, cue: cue.uuid)), ["edit list 42 cue \(c) advanceAfterMs null"])
        XCTAssertEqual(text(Edits.duplicateSection(list: 42, cue: cue.uuid)), ["edit list 42 cue \(c) section duplicate"])
    }

    // MARK: - What a cue says about a channel

    func test_whatACueSaysAboutAChannel() throws {
        let chorus = try cue(3)
        let two = CueSays.about(2, in: chorus)
        XCTAssertEqual(two.textBody, "Great is Thy faithfulness!\nGreat is Thy faithfulness!")
        XCTAssertTrue(two.writesContent)
        XCTAssertEqual(two.attributes, [])
        guard case .write(_, let riders) = two.state else { return XCTFail("\(two.state)") }
        XCTAssertEqual(riders.grade, GradeRider(ref: 1, ms: 2000, scope: .track))
        // Channel 1 has only a standalone gain there: the content holds.
        let one = CueSays.about(1, in: chorus)
        XCTAssertEqual(one.state, .hold)
        XCTAssertEqual(one.attributes, [.channelGain(channel: .number(1), db: -6)])
        XCTAssertNil(one.textBody)
        XCTAssertEqual(CueSays.about(3, in: chorus), CueSays(state: .hold, attributes: []))
        XCTAssertNil(CueSays.about(1, in: try cue(0)).textBody, "a media write has no body")
    }

    // MARK: - §10

    /// "A commit sends one `edit.cueChannel` for that cue and channel with
    /// the new body, keeping the write's other fields, its riders and the
    /// channel's attribute writes (Spec 5 §4)."
    func test_inPlaceTextSendsOneCueChannelEditThatKeepsTheRidersAndTheAttributeWrites() throws {
        let chorus = try cue(3)
        let c = chorus.uuid.uuidString.lowercased()
        let sending = try XCTUnwrap(Edits.text(body: "Great is Thy faithfulness!\nMorning by morning", cue: chorus, list: 42, channel: 2))
        XCTAssertEqual(text(sending), ["edit list 42 cue \(c) channel 2 write text \"Great is Thy faithfulness!\\nMorning by morning\" "
                                       + "audiotransition 2 once grade 1 2.0 track"])
        // Area 13 readings: an unchanged body sends nothing; an emptied one is a write with an empty body.
        XCTAssertNil(Edits.text(body: "Great is Thy faithfulness!\nGreat is Thy faithfulness!", cue: chorus, list: 42, channel: 2))
        XCTAssertEqual(text(try XCTUnwrap(Edits.text(body: "", cue: try cue(1), list: 42, channel: 2))),
                       ["edit list 42 cue \(try cue(1).uuid.uuidString.lowercased()) channel 2 write text \"\""])
        XCTAssertNil(Edits.text(body: "x", cue: chorus, list: 42, channel: 1), "channel 1 holds no text there")
        XCTAssertNil(Edits.text(body: "x", cue: try cue(0), list: 42, channel: 1), "nor is a media write text")
        XCTAssertEqual(try Recorded.catalog().textChannel, 2, "the lowest-numbered channel whose usual content is text")
    }

    /// "one `edit.cueChannel` writing the item on that channel: `write media
    /// sha256:…`, keeping the transition and audio-transition riders of what
    /// the cue wrote there before and the channel's attribute writes, with
    /// the item's default grade as a `grade G once` rider, or none".
    func test_aPoolTileDroppedOnACueWritesItThereKeepingTheTransitionRiders() throws {
        let media = try Recorded.media()
        let dawn = try XCTUnwrap(media.first { $0.entry.defaults.grade == nil })
        let ocean = try XCTUnwrap(media.first { $0.entry.defaults.grade == 1 })
        let verse = try cue(0)
        let v = verse.uuid.uuidString.lowercased()
        // Channel 1 of Verse 1 wrote media with `transition 2 1.0 once`: the transition stays, the old content's loop goes.
        XCTAssertEqual(text(Edits.write(media: ocean.id, defaultGrade: ocean.entry.defaults.grade, on: 1, cue: verse, list: 42)),
                       ["edit list 42 cue \(v) channel 1 write media \(ocean.id) transition 2 1.0 once grade 1 once"])
        XCTAssertEqual(text(Edits.write(media: dawn.id, defaultGrade: nil, on: 1, cue: verse, list: 42)),
                       ["edit list 42 cue \(v) channel 1 write media \(dawn.id) transition 2 1.0 once"])
        // On the chorus, channel 2 wrote text with an audio transition and a tracked grade: the audio transition stays,
        // the old grade rider gives way to the item's default, or to none.
        let chorus = try cue(3)
        let c = chorus.uuid.uuidString.lowercased()
        XCTAssertEqual(text(Edits.write(media: dawn.id, defaultGrade: nil, on: 2, cue: chorus, list: 42)),
                       ["edit list 42 cue \(c) channel 2 write media \(dawn.id) audiotransition 2 once"])
        // Channel 1 there has a standalone gain and no content: the gain is kept beside the new write.
        XCTAssertEqual(text(Edits.write(media: dawn.id, defaultGrade: nil, on: 1, cue: chorus, list: 42)),
                       ["edit list 42 cue \(c) channel 1 gain -6 write media \(dawn.id)"])
        // A channel the cue never mentioned.
        XCTAssertEqual(text(Edits.write(media: dawn.id, defaultGrade: nil, on: 3, cue: chorus, list: 42)),
                       ["edit list 42 cue \(c) channel 3 write media \(dawn.id)"])
    }

    /// "Grade for Channel N ▸ ... sets the grade of the first cue in that
    /// list that writes content to channel N: one `edit.cueChannel` giving
    /// that write a `grade G track` rider, or removing its grade rider for
    /// None (Spec 5 §5)."
    func test_theGradePickerSetsTheFirstWritingCuesTrackedGrade() throws {
        let list = try list42()
        XCTAssertEqual(Edits.gradeChannels(in: list), [1, 2], "one submenu per channel the list writes content to")
        let first = list.cues[0].uuid.uuidString.lowercased()
        XCTAssertEqual(Edits.gradeCue(channel: 2, in: list)?.uuid, list.cues[0].uuid)
        XCTAssertNil(Edits.trackedGrade(channel: 2, in: list), "the first cue that writes channel 2 has no grade rider")
        XCTAssertEqual(text(try XCTUnwrap(Edits.grade(3, channel: 2, in: list))),
                       ["edit list 42 cue \(first) channel 2 write text \"Great is Thy faithfulness,\\nO God my Father\" grade 3 track"])
        XCTAssertEqual(text(try XCTUnwrap(Edits.grade(1, channel: 1, in: list))).first?.hasSuffix("transition 2 1.0 once grade 1 track"), true,
                       "the write's other riders stay")
        // None removes the rider.
        var graded = list
        graded.cues[0].commands[1] = GuardedCommand(.channelWrite(ChannelWrite(channel: .number(2), content: .text(fields: ["body": "A"]),
                                                                              riders: Riders(grade: GradeRider(ref: 3, scope: .track)))))
        XCTAssertEqual(Edits.trackedGrade(channel: 2, in: graded), 3)
        XCTAssertEqual(text(try XCTUnwrap(Edits.grade(nil, channel: 2, in: graded))), ["edit list 42 cue \(first) channel 2 write text \"A\""])
        XCTAssertNil(Edits.grade(1, channel: 3, in: list), "no cue of the list writes content to channel 3")
    }

    func test_theMediaEditsAndCommands() throws {
        let id = try XCTUnwrap(try Recorded.media().first?.id)
        XCTAssertEqual(text(Edits.mediaDefault(id, field: "loop", value: .bool(false))), ["edit media \(id) defaults.loop false"])
        XCTAssertEqual(text(Edits.mediaDefault(id, field: "trimInMs", value: .number(1500))), ["edit media \(id) defaults.trimInMs 1500"])
        XCTAssertEqual(text(Edits.mediaDefault(id, field: "grade", value: .null)), ["edit media \(id) defaults.grade null"])
        XCTAssertEqual(text(Edits.mediaDefault(id, field: "defaultChannel", value: .number(1))), ["edit media \(id) defaults.defaultChannel 1"])
        XCTAssertEqual(text(Edits.deleteMedia(id)), ["media delete \(id)"])
        XCTAssertEqual(text(Edits.replaceMedia(old: id, new: "sha256:" + String(repeating: "ab", count: 32))),
                       ["media replace \(id) sha256:" + String(repeating: "ab", count: 32)])
        XCTAssertEqual(text(Edits.importMedia(path: "/tmp/o/machine/staging/Ocean loop.mov")), ["media import \"/tmp/o/machine/staging/Ocean loop.mov\""])
    }

    func test_undoRedoAndTheRestores() {
        XCTAssertEqual(text(Edits.undo()), ["undo"])
        XCTAssertEqual(text(Edits.redo()), ["redo"])
        XCTAssertEqual(text(Edits.restore(list: 42, version: 16)), ["system restore list 42 version 16"])
        XCTAssertEqual(text(Edits.restore(snapshot: "2026-11-08T08-59-00Z-launch")), ["system restore snapshot \"2026-11-08T08-59-00Z-launch\""])
        XCTAssertEqual(text(Edits.takeSnapshot()), ["system snapshot"])
    }

    /// Spec 10 §14 — "Set Timers Again, which sets each timer to its last
    /// value from the `timers` topic and starts those that were running."
    func test_setTimersAgainSetsEachTimerAndStartsThoseThatWereRunning() {
        let timers = [TimerStatus(slot: 2, state: "running", direction: "up", setMs: 0, valueMs: 95_000, text: "1:35"),
                      TimerStatus(slot: 1, state: "paused", direction: "down", setMs: 300_000, valueMs: 240_000, text: "4:00"),
                      TimerStatus(slot: 3, state: "unset", direction: nil, setMs: nil, valueMs: nil, text: "")]
        let sending = Edits.setTimersAgain(timers)
        XCTAssertEqual(text(sending), ["timer 1 set 4:00", "timer 2 set 1:35 up", "timer 2 start"])
        XCTAssertTrue(sending.group, "one group")
        XCTAssertNil(Edits.setTimersAgain([timers[2]]).request, "a timer that was never set is left alone")
    }
}
