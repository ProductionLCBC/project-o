import Foundation
import XCTest
import OCore
@testable import OApp

/// Spec 11 §7 — the channel sheet as values: the channel list with the stacks
/// that hold each channel, the selected channel's holders and the others,
/// when it is on air, and every edit its controls send, against the recorded
/// fixture (channels 1 Background, 2 Foreground, 3 Clock; stack 1 holds 1 and
/// 2, stack 2 holds 2 and 3; output 1 shows stack 1).
final class ChannelPageTests: XCTestCase {
    private func text(_ sending: Sending?, file: StaticString = #filePath, line: UInt = #line) -> [String] {
        guard let sending else { return [] }
        for command in sending.commands {
            guard let printed = CommandText.print(command) else {
                XCTFail("\(command.cmd) doesn't print", file: file, line: line)
                continue
            }
            XCTAssertEqual(try? CommandText.parse(printed).get().command, command, printed, file: file, line: line)
        }
        return sending.text
    }

    private let dots = [OutputDot(number: 1, label: "Main", stack: 1, state: .presenting, isBlackedOut: false)]

    func test_theListNamesEachChannelAndTheStacksThatHoldIt() throws {
        let page = ChannelPage.make(catalog: try Recorded.catalog(), channel: 2, dots: dots, content: [])
        XCTAssertEqual(page.rows.map(\.number), [1, 2, 3])
        XCTAssertEqual(page.rows.map(\.label), ["Background", "Foreground", "Clock"])
        XCTAssertEqual(page.rows.map(\.stacks), [[1], [1, 2], [2]])
        XCTAssertEqual(page.channel?.label, "Foreground")
        XCTAssertEqual(page.holders.map(\.number), [1, 2])
        XCTAssertEqual(page.others.map(\.number), [])
        XCTAssertEqual(page.shownOn, [1])
        XCTAssertFalse(page.isOnAir, "no content")
        let clock = ChannelPage.make(catalog: try Recorded.catalog(), channel: 3, dots: dots, content: [3])
        XCTAssertEqual(clock.others.map(\.number), [1], "Add to Stack offers the others")
        XCTAssertEqual(clock.shownOn, [], "stack 2 is on no output")
        XCTAssertFalse(clock.isOnAir)
        // "the channel has content in a stack an output shows".
        XCTAssertTrue(ChannelPage.make(catalog: try Recorded.catalog(), channel: 1, dots: dots, content: [1]).isOnAir)
        XCTAssertNil(ChannelPage.make(catalog: try Recorded.catalog(), channel: 9, dots: dots, content: []).channel, "no such channel")
    }

    func test_eachControlSendsItsEdit() {
        XCTAssertEqual(text(ChannelEdits.set(channel: 2, "label", .string("Lyrics"))), ["edit channel 2 label \"Lyrics\""])
        XCTAssertEqual(text(ChannelEdits.set(channel: 2, "defaultPreset", .number(3))), ["edit channel 2 defaultPreset 3"])
        XCTAssertEqual(text(ChannelEdits.set(channel: 2, "defaults.transition", .number(2))), ["edit channel 2 defaults.transition 2"])
        XCTAssertEqual(text(ChannelEdits.set(channel: 2, "decoderCap", .number(3))), ["edit channel 2 decoderCap 3"])
        XCTAssertEqual(text(ChannelEdits.set(channel: 2, "decoderCap", .null)), ["edit channel 2 decoderCap null"])
        XCTAssertEqual(text(ChannelEdits.set(channel: 2, "usualContent", .string("text"))), ["edit channel 2 usualContent \"text\""])
        XCTAssertEqual(text(ChannelEdits.gain(channel: 2, decibels: -6.04)), ["edit channel 2 defaults.gain -6"])
        XCTAssertEqual(text(ChannelEdits.gain(channel: 2, decibels: 75)), ["edit channel 2 defaults.gain 60"], "within ±60")
        XCTAssertEqual(text(ChannelEdits.renumber(channel: 2, to: 5, swap: false)), ["edit channel 2 renumber 5"])
        XCTAssertEqual(text(ChannelEdits.renumber(channel: 2, to: 3, swap: true)), ["edit channel 2 swap 3"])
        XCTAssertEqual(text(ChannelEdits.create()), ["edit channel create"])
        XCTAssertEqual(text(ChannelEdits.duplicate(channel: 2)), ["edit channel 2 duplicate"])
        XCTAssertEqual(text(ChannelEdits.delete(channel: 2)), ["edit channel 2 delete"])
        // "Render size, largest, or a width and height".
        XCTAssertEqual(RenderSizeChoice.value(largest: true, width: "", height: ""), .string("largest"))
        XCTAssertEqual(RenderSizeChoice.value(largest: false, width: "1920", height: " 1080"), .object(["width": .number(1920), "height": .number(1080)]))
        XCTAssertNil(RenderSizeChoice.value(largest: false, width: "0", height: "1080"))
        XCTAssertNil(RenderSizeChoice.value(largest: false, width: "wide", height: "1080"))
    }
}
