import Foundation
import XCTest
import OCore
@testable import OApp

/// Spec 11 §13, "Area 10, the text editor" — what the text editor sends,
/// against the real engine's API (the headless engine on a copy of the
/// fixture roots, no GPU, over a real local socket): "a second of it undoes
/// as one step", and the clear an emptied chunk sends keeps its `track`
/// riders as the engine stores them. The model tests prove what is sent;
/// these prove the engine takes it as Spec 5 §5 says.
final class TextEngineTests: XCTestCase {
    private var engine: RealEngine!
    private var client: LinkedClient!

    override func setUpWithError() throws {
        engine = try RealEngine()
        client = try LinkedClient(socket: engine.socketURL)
    }

    override func tearDown() {
        client.link.close()
        engine.stop()
    }

    private func list42() throws -> List {
        let reply = try client.ask(.query("list", ["listUuid": .string(Recorded.list42)]))
        let answer = try XCTUnwrap(reply.answer, "the list was refused: \(reply.outcome?.rejection?.message ?? "")")
        return try XCTUnwrap(ListDocument(answer: answer)).list
    }

    @discardableResult
    private func send(_ sending: Sending?, file: StaticString = #filePath, line: UInt = #line) throws -> CommandOutcome {
        let request = try XCTUnwrap(sending?.request, "nothing to send", file: file, line: line)
        let outcome = try XCTUnwrap(client.ask(request).outcome, file: file, line: line)
        XCTAssertEqual(outcome.kind, .ok, "\(sending?.text ?? []): \(outcome.rejection?.message ?? "")", file: file, line: line)
        return outcome
    }

    private func chunk(_ list: List, _ index: Int) throws -> TextChunk {
        let catalog = try Recorded.catalog()
        return try XCTUnwrap(TextDocument.make(list: list, channel: 2, catalog: catalog, media: []).chunks[index])
    }

    func test_aSecondOfTypingUndoesAsOneStep() throws {
        var list = try list42()
        let original = "There is no shadow\nof turning with Thee"
        XCTAssertEqual(try chunk(list, 1).text, original)
        // Three sends of the chunk's whole body, a quarter second apart at most, as the cadence paces them.
        var groups: [String?] = []
        for body in [original + "!", original + "!!", original + "!!!"] {
            list = try list42()
            let sending = TextEdits.typing(body, chunk: try chunk(list, 1), cue: list.cues[1], list: 42, channel: 2)
            groups.append(try send(sending).group)
        }
        XCTAssertEqual(try chunk(try list42(), 1).text, original + "!!!", "every send applies at once")
        XCTAssertEqual(Set(groups.compactMap { $0 }).count, 1, "the run comes back under one group, which the editor keeps as its own")
        // One undo takes the whole run back: "the engine folds a second of it into one edit and one undo step".
        try send(Sending([.undo]))
        XCTAssertEqual(try chunk(try list42(), 1).text, original)
    }

    /// Spec 5 §5 — "The edits in a group share one log group id, one `library` event and one undo step": a split,
    /// a merge and a moved break each apply whole and come back whole with one undo.
    func test_aSplitAMergeAndAMovedBreakEachUndoAsOneStep() throws {
        let original = try list42()
        func side(_ list: List, _ index: Int) throws -> TextSide {
            let chunk = try chunk(list, index)
            return TextSide(chunk: chunk, cue: list.cues[index], text: chunk.text)
        }
        let made = try XCTUnwrap(UUID(uuidString: "eeee0020-0000-4000-8000-000000000000"))
        // Split cue 2 after its first line.
        let split = TextBreaks.split(try side(original, 1), at: ("There is no shadow\n" as NSString).length, index: 1, uuid: made, list: 42, channel: 2)
        try send(split.sending)
        var after = try list42()
        XCTAssertEqual(after.cues.map(\.uuid), [original.cues[0].uuid, original.cues[1].uuid, made, original.cues[2].uuid, original.cues[3].uuid])
        XCTAssertEqual(try chunk(after, 1).text, "There is no shadow")
        XCTAssertEqual(try chunk(after, 2).text, "of turning with Thee")
        XCTAssertEqual(after.cues[2].label, "Verse 1")
        try send(Sending([.undo]))
        XCTAssertEqual(try list42().cues, original.cues, "one undo takes the split back")
        // Merge cue 2 into cue 1.
        let merge = TextBreaks.merge(upper: try side(original, 0), lower: try side(original, 1), list: 42, channel: 2)
        try send(merge.sending)
        after = try list42()
        XCTAssertEqual(after.cues.count, 3)
        XCTAssertEqual(try chunk(after, 0).text, "Great is Thy faithfulness,\nO God my Father\nThere is no shadow\nof turning with Thee")
        try send(Sending([.undo]))
        XCTAssertEqual(try list42().cues, original.cues, "one undo takes the merge back")
        // Move cue 2's first line up to cue 1.
        let move = try XCTUnwrap(TextBreaks.move(1, upper: try side(original, 0), lower: try side(original, 1), list: 42, channel: 2))
        try send(move.sending)
        after = try list42()
        XCTAssertEqual(try chunk(after, 0).text, "Great is Thy faithfulness,\nO God my Father\nThere is no shadow")
        XCTAssertEqual(try chunk(after, 1).text, "of turning with Thee")
        try send(Sending([.undo]))
        XCTAssertEqual(try list42().cues, original.cues, "one undo takes the moved break back")
    }

    func test_anEmptiedChunksClearKeepsItsTrackRiderAsTheEngineStoresIt() throws {
        let list = try list42()
        try send(TextEdits.emptied(cue: list.cues[3], list: 42, channel: 2))
        let after = try list42()
        let says = CueSays.about(2, in: after.cues[3])
        XCTAssertEqual(says.state, .clear)
        XCTAssertEqual(says.attributes, [.channelGrade(channel: .number(2), ref: 1, ms: 2000)],
                       "the grade tracks on as a standalone write; the once audio transition went with the write")
        XCTAssertTrue(after.cues[3].commands.contains { $0.command == .channelGain(channel: .number(1), db: -6) }, "channel 1's gain stays")
        XCTAssertEqual(try chunk(after, 3).kind, .clear)
    }
}
