import Foundation
import XCTest
import OCore
@testable import OApp

/// Spec 11 §13, "Area 10, the text editor" — the document: "For a fixture
/// list: a chunk for every cue in each state (a write, a clear, held text,
/// held media, holding nothing, other content)", with the sections in the
/// margin, the thumbnails beside each chunk and the channel picker's order.
@MainActor
final class TextDocumentTests: XCTestCase {
    /// The fixture's dawn loop, which list 42's first cue writes on channel 1.
    nonisolated static let dawn = "sha256:55c84469c37e1e6a72a9b8938422cd6536b302b583a5c127241c8304246f3527"

    /// A fixture list with its cues changed, as the store would hold it after an edit.
    static func list(_ name: String, _ change: (inout List) -> Void = { _ in }) throws -> ListDocument {
        var document = try Recorded.list(name)
        change(&document.list)
        return document
    }

    /// Takes a cue's commands on a channel away, so that it holds the channel.
    nonisolated static func hold(_ list: inout List, cue index: Int, channel: Int) {
        list.cues[index].commands.removeAll { $0.command.namedChannel == channel }
    }

    /// A cue the fixture doesn't have, with a uuid that reads in a failure.
    nonisolated static func cue(_ n: Int, _ label: String, _ commands: [Command] = []) -> Cue {
        Cue(uuid: UUID(uuidString: String(format: "eeee%04d-0000-4000-8000-000000000000", n)) ?? UUID(), label: label,
            commands: commands.map { GuardedCommand($0) })
    }

    nonisolated static func write(_ channel: Int, _ content: ContentExpression, riders: Riders = .none) -> Command {
        .channelWrite(ChannelWrite(channel: .number(channel), content: content, riders: riders))
    }

    /// One chunk's state, short enough to read a whole list's at a glance.
    nonisolated static func state(_ chunk: TextChunk) -> String {
        switch chunk.kind {
        case .write(let body): return "write: " + (body.split(separator: "\n").first.map(String.init) ?? "")
        case .clear: return "clear"
        case .heldText(_, let from, _, _): return "held text from \(from.map(String.init) ?? "-")"
        case .heldOther(.media(let id, _)): return "held media " + (id == dawn ? "dawn" : id)
        case .heldOther(let other): return "held \(other)"
        case .holdsNothing: return "holds nothing"
        case .other(.media(let id, _)): return "other: media " + (id == dawn ? "dawn" : id)
        case .other(let other): return "other: \(other)"
        }
    }

    private func document(_ list: ListDocument, channel: Int = 2, thumbnails: [String: String] = [:]) throws -> TextDocument {
        TextDocument.make(list: list.list, channel: channel, catalog: try Recorded.catalog(), media: try Recorded.media(), thumbnails: thumbnails)
    }

    // MARK: - A chunk shows (Spec 11 §5)

    func test_theFixtureListsChunksAreTheirTextWritesAndClear() throws {
        let hymn = try document(try Self.list("list-42"))
        XCTAssertEqual(hymn.chunks.map(Self.state), ["write: Great is Thy faithfulness,", "write: There is no shadow", "write: Thou changest not,",
                                                     "write: Great is Thy faithfulness!"])
        XCTAssertEqual(hymn.chunks.map(\.number), [1, 2, 3, 4])
        XCTAssertEqual(hymn.chunks.map(\.cue), Recorded.cues42, "a chunk is bound to its cue by the cue's uuid")
        XCTAssertEqual(hymn.chunks[1].text, "There is no shadow\nof turning with Thee", "the body whole, with its line breaks")
        XCTAssertTrue(hymn.chunks.allSatisfy(\.isEditable))
        // Doxology's last cue clears channel 2 and runs a macro: "A clear: an empty chunk, with "Clears" as its placeholder".
        let doxology = try document(try Self.list("list-7"))
        XCTAssertEqual(doxology.chunks.map(Self.state), ["write: Praise God, from whom all blessings flow;", "write: Praise Him above, ye heavenly host;", "clear"])
        XCTAssertEqual(doxology.chunks[2].text, "", "a clear counts as empty text")
    }

    func test_aChunkForEveryCueInEachStateACueCanLeaveTheChannelIn() throws {
        // List 42 changed so channel 2 goes through every state: nothing yet, a write, its text held, media written
        // there, the media held, a clear.
        let varied = try Self.list("list-42") { list in
            Self.hold(&list, cue: 0, channel: 2)
            Self.hold(&list, cue: 2, channel: 2)
            Self.hold(&list, cue: 3, channel: 2)
            list.cues[3].commands.append(GuardedCommand(Self.write(2, .media(MediaContent(ref: Self.dawn)))))
            list.cues.append(Self.cue(5, "Media held"))
            list.cues.append(Self.cue(6, "Out", [.channelClear(channel: .number(2))]))
        }
        let text = try document(varied)
        XCTAssertEqual(text.chunks.map(Self.state), ["holds nothing", "write: There is no shadow", "held text from 2", "other: media dawn",
                                                     "held media dawn", "clear"],
                       "every cue a chunk, even one that writes nothing on this channel (E2)")
        XCTAssertEqual(text.chunks[2].heldBody, "There is no shadow\nof turning with Thee", "the line the channel holds at that cue")
        XCTAssertEqual(text.chunks[2].text, "", "held text is the cue before's, not this cue's own")
        XCTAssertFalse(text.chunks[3].isEditable, "a row of other content is not editable")
        XCTAssertTrue(text.chunks[4].isEditable && text.chunks[0].isEditable && text.chunks[5].isEditable)
        // Channel 1 on the same list: media written, then held.
        let background = try document(varied, channel: 1)
        XCTAssertEqual(background.chunks.prefix(2).map(Self.state), ["other: media dawn", "held media dawn"])
    }

    func test_heldTextCarriesTheHeldWriteWholeForItsCopy() throws {
        let riders = Riders(transition: TransitionRider(ref: 2, ms: 500, scope: .once), grade: GradeRider(ref: 1, scope: .track))
        let varied = try Self.list("list-7") { list in
            // Doxology's first cue writes a title as well as the body: give it riders, and let cue 2 hold it.
            guard case .channelWrite(var write) = list.cues[0].commands[1].command else { return }
            write.riders = riders
            list.cues[0].commands[1] = GuardedCommand(.channelWrite(write))
            Self.hold(&list, cue: 1, channel: 2)
        }
        let held = try document(varied).chunks[1]
        guard case .heldText(let body, let from, let fields, let had) = held.kind else { return XCTFail("cue 2 holds cue 1's text") }
        XCTAssertEqual(body, "Praise God, from whom all blessings flow;\nPraise Him, all creatures here below;")
        XCTAssertEqual(from, 1)
        XCTAssertEqual(fields["title"], "Doxology", "the held write's other fields")
        XCTAssertEqual(had, riders, "and its riders")
    }

    // MARK: - The margin and the thumbnails (Spec 11 §5, "The document")

    func test_theMarginShowsEachRunsSectionAtItsFirstChunkInItsColor() throws {
        let hymn = try document(try Self.list("list-42"))
        XCTAssertEqual(hymn.chunks.map(\.startsRun), [true, false, false, true])
        XCTAssertEqual(hymn.chunks.map(\.section), ["Verse 1", "Verse 1", "Verse 1", "Chorus"])
        XCTAssertEqual(hymn.chunks.map(\.hue), [SectionHue.index(for: "Verse 1"), nil, nil, SectionHue.index(for: "Chorus")])
        // A cue with no section starts no run, and the run after it starts again.
        let varied = try document(try Self.list("list-42") { $0.cues[1].section = nil })
        XCTAssertEqual(varied.chunks.map(\.startsRun), [true, false, true, true])
    }

    func test_eachChunkCarriesItsCuesThumbnail() throws {
        // "the cue's thumbnail on the thumbnail stack, the engine's file": as the `thumbnails` topic names them (the
        // recorded answer is the headless engine's, which draws none).
        let files = [Recorded.cues42[0]: "thumbnails/1/\(Recorded.cues42[0])-a1.png", Recorded.cues42[2]: "thumbnails/1/\(Recorded.cues42[2])-c3.png"]
        let hymn = try document(try Self.list("list-42"), thumbnails: files)
        XCTAssertEqual(hymn.chunks.map(\.thumbnail), [files[Recorded.cues42[0]], nil, files[Recorded.cues42[2]], nil])
    }

    // MARK: - Which text (Spec 11 §5)

    func test_thePickerListsTheTextChannelsFirst() throws {
        let catalog = try Recorded.catalog()
        XCTAssertEqual(TextDocument.pickerChannels(catalog).map(\.number), [2, 1, 3], "Foreground is the fixture's one text channel")
        XCTAssertEqual(catalog.textChannel, 2, "the page opens on the lowest-numbered text channel")
    }
}
