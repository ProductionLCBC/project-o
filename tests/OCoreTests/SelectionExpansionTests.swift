import Foundation
import XCTest
@testable import OCore

/// Spec 2 §10 — Selection expansion: "A UI action on channels {2, 5} produces
/// exactly `channel 2 ...` and `channel 5 ...` in one group, in number order."
/// Spec 2 §5 — "`selected` is a UI token, never a command argument ... the UI
/// expands it to one command per selected channel at that moment ... and
/// submits them as a group." Stack selection follows the same rule.
final class SelectionExpansionTests: XCTestCase {
    func test_channelsExpandInNumberOrderIntoOneGroup() {
        let commands = Selection.expand([5, 2]) { Command.channelClear(channel: .number($0)) }
        XCTAssertEqual(commands, [.channelClear(channel: .number(2)), .channelClear(channel: .number(5))])
        XCTAssertEqual(commands.compactMap { CommandText.print($0) }, ["channel 2 clear", "channel 5 clear"])

        let group = Selection.group(GroupID("g-ui"), source: CommandSource(kind: .ui), selected: [5, 2, 5]) {
            Command.channelTransport(channel: .number($0), mode: .pause)
        }
        XCTAssertEqual(group.id, GroupID("g-ui"))
        XCTAssertEqual(group.source.kind, .ui)
        XCTAssertEqual(group.commands.map(\.command), [.channelTransport(channel: .number(2), mode: .pause),
                                                        .channelTransport(channel: .number(5), mode: .pause)])
        XCTAssertTrue(group.commands.allSatisfy { $0.when == nil })
        XCTAssertNil(group.fire)
    }

    func test_stacksExpandTheSameWay() {
        let commands = Selection.expand(Set([2, 1])) { Command.stackBlackout(stack: $0, state: .on) }
        XCTAssertEqual(commands, [.stackBlackout(stack: 1, state: .on), .stackBlackout(stack: 2, state: .on)])
    }

    func test_anEmptySelectionIsAnEmptyGroup() {
        XCTAssertEqual(Selection.expand([Int]()) { Command.channelClear(channel: .number($0)) }, [])
        let group = Selection.group(GroupID("g-empty"), source: CommandSource(kind: .ui), selected: [Int]()) {
            Command.channelClear(channel: .number($0))
        }
        XCTAssertTrue(group.commands.isEmpty)
    }

    /// Spec 2 §9 — `"group": "g-7f1a"`; the engine supplies ids, and the
    /// helper makes them from a UUID with eight hex characters.
    func test_groupIds() {
        let uuid = UUID(uuidString: "7f1a2b3c-0000-4000-8000-000000000001")!
        XCTAssertEqual(GroupID(uuid: uuid), GroupID("g-7f1a2b3c"))
        XCTAssertEqual(GroupID("g-7f1a").rawValue, "g-7f1a")
        XCTAssertNotEqual(GroupID.random(), GroupID.random())
        XCTAssertTrue(GroupID.random().rawValue.hasPrefix("g-"))
        XCTAssertEqual(GroupID.random().rawValue.count, 10)
        XCTAssertEqual(try JSONCoding.encode(GroupID("g-7f1a")), .string("g-7f1a"))
        XCTAssertEqual(try JSONCoding.decode(GroupID.self, from: .string("g-7f1a")), GroupID("g-7f1a"))
    }
}
