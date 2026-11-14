import Foundation
import OCore
import OFormats
import XCTest
@testable import OEngine

/// Spec 8 §2 — who may send the media commands, and what a holder's refusal
/// does. Spec 8 §11, Lock and held commands: "Operator lock refuses every
/// media command but `media rebuild`. Inside a cue or a scheduler entry, any
/// refusal of a media command, operator lock's or another such as
/// `unreadable` or `onAir`, is `blocked` and logged while the rest of the
/// group runs, and a held `media delete` applies after the rest of its
/// group." (`onAir` held, and the held delete after its group, are
/// MediaDeleteEngineTests'.)
final class MediaLockEngineTests: XCTestCase {
    typealias E = EngineFixtures

    func scheduler(_ media: MediaFixture, _ commands: [Command]) {
        media.engine.send(CommandGroup(id: GroupID.random(), source: CommandSource(kind: .scheduler), commands: commands))
        media.settle()
    }

    func test_operatorLockRefusesEveryMediaCommandButRebuild() throws {
        let media = try MediaFixture(configure: { $0.settings.operatorLock.enabled = true })
        let staged = try media.stage("Welcome.mov", "welcome")
        let record = MediaReplaceRecord()
        for text in ["media import \"\(staged.path)\"", "media replace \(E.mountains) \(E.dawn)", "media delete \(E.cross)",
                     "media undelete \(E.cross) {\"files\": []}",
                     CommandText.print(.media(.unreplace(old: E.mountains, new: E.dawn, record: record))) ?? ""] {
            XCTAssertEqual(media.run(text, source: .ui)?.reason, .operatorLock, text)
            XCTAssertEqual(media.run(text, source: .osc)?.reason, .operatorLock, "from every source: \(text)")
        }
        XCTAssertNil(media.run("media rebuild", source: .ui))
        XCTAssertEqual(media.control.commandLog.entries.last?.command, .media(.rebuild))
        XCTAssertEqual(media.trash.moveCount, 0)
        XCTAssertNil(media.control.library.mediaIndex.replaced[E.mountains])
    }

    /// Inside a scheduler entry: operator lock's refusal and `unreadable` are
    /// `blocked` and logged, and the rest of the group runs.
    func test_aHeldRefusalIsBlockedAndTheRestOfTheGroupRuns() throws {
        let locked = try MediaFixture(configure: { $0.settings.operatorLock.enabled = true })
        let write = Command.channelWrite(ChannelWrite(channel: .number(2), content: .media(MediaContent(ref: E.cross))))
        scheduler(locked, [.media(.delete(id: MediaFixture.announcement, files: nil)), write])
        let lines = locked.control.commandLog.entries.suffix(2)
        XCTAssertEqual(lines.map(\.result), [.blocked, .ok])
        XCTAssertEqual(locked.engine.state.channels[2]?.content.media?.ref, E.cross, "the rest of the group ran")
        XCTAssertTrue(locked.engine.log.contains("blocked scheduler edit media delete \(MediaFixture.announcement): operatorLock"))
        XCTAssertNil(locked.control.machine.mediaLocal.entry(MediaFixture.announcement)?.deletedAt)

        let media = try MediaFixture()
        let rewrite = Command.channelWrite(ChannelWrite(channel: .number(1), content: .media(MediaContent(ref: E.dawn))))
        scheduler(media, [.media(.importFile(path: "/no/such/folder/Welcome.mov")), rewrite])
        let held = media.control.commandLog.entries.suffix(2)
        XCTAssertEqual(held.map(\.result), [.blocked, .ok])
        XCTAssertEqual(media.engine.state.channels[1]?.content.media?.ref, E.dawn)
        XCTAssertTrue(media.engine.log.contains("unreadable"), "logged with its reason")
    }
}
