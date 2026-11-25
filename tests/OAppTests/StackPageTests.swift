import Foundation
import XCTest
import OCore
@testable import OApp

/// Spec 11 §6 — the stack editor as values: the slot list top first with each
/// slot's resolved preset, the outputs and the stacks no output shows, the
/// channels it holds, and every edit its controls send, against the recorded
/// fixture (stack 1 Main holds channels 1 and 2, stack 2 Confidence 2 and 3;
/// output 1 shows stack 1).
final class StackPageTests: XCTestCase {
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

    func test_theSlotsTopFirstWithTheirResolvedPresets() throws {
        let page = StackPage.make(catalog: try Recorded.catalog(), stack: 2, dots: dots)
        XCTAssertEqual(page.stack?.label, "Confidence")
        // "below, its slots as a vertical list, the bottom slot at the bottom": stack 2's slots run 2 then 3, bottom first.
        XCTAssertEqual(page.slots.map(\.channel), [3, 2])
        XCTAssertEqual(page.slots.map(\.label), ["Clock", "Foreground"])
        XCTAssertEqual(page.slots.map(\.index), [1, 0])
        // "None, which means the stack's default, else the channel's, else Preset 1": Clock defaults to preset 2.
        XCTAssertEqual(page.slots.map(\.preset), [nil, nil])
        XCTAssertEqual(page.slots.map(\.resolved), [2, 1])
        XCTAssertEqual(page.slots.map(\.opacity), [1, 1])
        // A drop above the top row is the top of `slots`; below the last row, its bottom.
        XCTAssertEqual(page.slotIndex(droppedAt: 0), 2)
        XCTAssertEqual(page.slotIndex(droppedAt: 1), 1)
        XCTAssertEqual(page.slotIndex(droppedAt: 2), 0)
    }

    func test_theOutputsTheStacksNoneShowsTheChannelsAndWhereTheStackIsOnAir() throws {
        let page = StackPage.make(catalog: try Recorded.catalog(), stack: 1, dots: dots)
        XCTAssertEqual(page.outputs, [StackOutputRow(number: 1, label: "Main", liveStack: 1, defaultStack: 1, state: .presenting)])
        // "then, under "Not on an output", the stacks no output shows".
        XCTAssertEqual(page.unshown.map(\.number), [2])
        XCTAssertEqual(page.shownOn, [1], "adding or removing a slot asks first")
        // "the library's channels ... those the selected stack holds marked".
        XCTAssertEqual(page.channels.map(\.number), [1, 2, 3])
        XCTAssertEqual(page.channels.map(\.isHeld), [true, true, false])
        XCTAssertEqual(page.audioOutputs.map(\.number), [1, 2])
        XCTAssertEqual(page.channels.first?.audioOutputs, [1])
        XCTAssertEqual(StackPage.make(catalog: try Recorded.catalog(), stack: 2, dots: dots).shownOn, [])
        XCTAssertNil(StackPage.make(catalog: try Recorded.catalog(), stack: 9, dots: dots).stack, "no such stack")
    }

    func test_eachControlSendsItsEdit() {
        XCTAssertEqual(text(StackEdits.slotPreset(stack: 1, channel: 2, preset: 3)), ["edit stack 1 slot 2 preset 3"])
        XCTAssertEqual(text(StackEdits.slotPreset(stack: 1, channel: 2, preset: nil)), ["edit stack 1 slot 2 preset null"])
        XCTAssertEqual(text(StackEdits.slotOpacity(stack: 1, channel: 2, opacity: 0.8)), ["edit stack 1 slot 2 opacity 0.8"])
        XCTAssertEqual(text(StackEdits.slotOpacity(stack: 1, channel: 2, opacity: 1.4)), ["edit stack 1 slot 2 opacity 1"], "held to 100%")
        XCTAssertEqual(text(StackEdits.moveSlot(stack: 1, channel: 2, to: 0)), ["edit stack 1 slot 2 move 0"])
        XCTAssertEqual(text(StackEdits.removeSlot(stack: 1, channel: 2)), ["edit stack 1 slot 2 remove"])
        XCTAssertEqual(text(StackEdits.insertSlot(stack: 1, channel: 3, at: 2)),
                       ["edit stack 1 insert slots 2 { \"channel\": 3, \"mute\": false, \"opacity\": 1, \"preset\": null }"])
        XCTAssertEqual(text(StackEdits.set(stack: 1, "label", .string("Wall"))), ["edit stack 1 label \"Wall\""])
        XCTAssertEqual(text(StackEdits.set(stack: 1, "gammaBlend", .bool(true))), ["edit stack 1 gammaBlend true"])
        XCTAssertEqual(text(StackEdits.create()), ["edit stack create"])
        XCTAssertEqual(text(StackEdits.duplicate(stack: 1)), ["edit stack 1 duplicate"])
        XCTAssertEqual(text(StackEdits.renumber(stack: 1, to: 4, swap: false)), ["edit stack 1 renumber 4"])
        XCTAssertEqual(text(StackEdits.renumber(stack: 1, to: 2, swap: true)), ["edit stack 1 swap 2"])
        XCTAssertEqual(text(StackEdits.delete(stack: 2)), ["edit stack 2 delete"])
        XCTAssertEqual(text(StackEdits.output(1, "defaultStack", 2)), ["edit output 1 defaultStack 2"])
        XCTAssertEqual(text(StackEdits.output(1, "transitions.switch", 3)), ["edit output 1 transitions.switch 3"])
        // "keeping the numbers this machine has no audio output for".
        XCTAssertEqual(text(StackEdits.audioOutputs(channel: 1, current: [1, 7], output: 2, on: true)), ["edit channel 1 audioOutputs [1, 2, 7]"])
        XCTAssertEqual(text(StackEdits.audioOutputs(channel: 1, current: [1, 7], output: 1, on: false)), ["edit channel 1 audioOutputs [7]"])
        XCTAssertNil(StackEdits.audioOutputs(channel: 1, current: [1], output: 1, on: true), "as it is")
    }
}
