import Foundation
import XCTest
import OCore
@testable import OApp

/// Spec 11 §8, "Moving" — "Dragging moves the box and the handles resize it. ... the arrows nudge the selected box by
/// one pixel of the stack, and with ⇧ by ten. ... Boxes snap to the canvas's edges and centre lines and to other boxes'
/// edges, not while ⌘ is held."
final class LayoutCanvasTests: XCTestCase {
    private func near(_ a: Frame, _ b: Frame, file: StaticString = #filePath, line: UInt = #line) {
        for (x, y) in [(a.x, b.x), (a.y, b.y), (a.w, b.w), (a.h, b.h)] { XCTAssertEqual(x, y, accuracy: 1e-9, "\(a) vs \(b)", file: file, line: line) }
    }

    func test_aDragMovesTheBoxAndAHandleResizesIt() {
        let frame = Frame(x: 0.2, y: 0.2, w: 0.4, h: 0.3)
        near(LayoutCanvasMath.dragged(frame, handle: .move, dx: 0.1, dy: -0.05), Frame(x: 0.3, y: 0.15, w: 0.4, h: 0.3))
        near(LayoutCanvasMath.dragged(frame, handle: .right, dx: 0.1, dy: 0.5), Frame(x: 0.2, y: 0.2, w: 0.5, h: 0.3))
        near(LayoutCanvasMath.dragged(frame, handle: .topLeft, dx: -0.1, dy: -0.1), Frame(x: 0.1, y: 0.1, w: 0.5, h: 0.4))
        // A handle dragged past the opposite edge stops a hundredth short of it.
        near(LayoutCanvasMath.dragged(frame, handle: .left, dx: 0.9, dy: 0), Frame(x: 0.59, y: 0.2, w: 0.01, h: 0.3))
    }

    func test_boxesSnapToTheEdgesTheCentreLinesAndOtherBoxesEdges() {
        // The box's centre comes within the threshold of the canvas's centre line.
        let moved = LayoutCanvasMath.snapped(Frame(x: 0.296, y: 0.1, w: 0.4, h: 0.2), handle: .move, others: [], threshold: 0.01)
        near(moved.frame, Frame(x: 0.3, y: 0.1, w: 0.4, h: 0.2))
        XCTAssertEqual(moved.xs, [0.5])
        XCTAssertEqual(moved.ys, [], "the top edge is 0.1 from the nearest line")
        // A right handle comes near another box's left edge.
        let other = Frame(x: 0.75, y: 0.6, w: 0.2, h: 0.2)
        let resized = LayoutCanvasMath.snapped(Frame(x: 0.1, y: 0.1, w: 0.645, h: 0.2), handle: .right, others: [other], threshold: 0.01)
        near(resized.frame, Frame(x: 0.1, y: 0.1, w: 0.65, h: 0.2))
        XCTAssertEqual(resized.xs, [0.75])
        // Beyond the threshold, nothing moves.
        near(LayoutCanvasMath.snapped(Frame(x: 0.33, y: 0.33, w: 0.1, h: 0.1), handle: .move, others: [], threshold: 0.01).frame, Frame(x: 0.33, y: 0.33, w: 0.1, h: 0.1))
    }

    func test_aNudgeIsAPixelOfTheStackAndAFrameStaysOnIt() {
        near(LayoutCanvasMath.nudged(Frame(x: 0.5, y: 0.5, w: 0.1, h: 0.1), dx: 10, dy: -1, width: 1920, height: 1080),
             Frame(x: 0.5 + 10.0 / 1920, y: 0.5 - 1.0 / 1080, w: 0.1, h: 0.1))
        near(LayoutCanvasMath.kept(Frame(x: 0.95, y: -0.1, w: 0.2, h: 1.4)), Frame(x: 0.8, y: 0, w: 0.2, h: 1))
        // The box under a point, top first.
        let frames = [Frame.full, Frame(x: 0.1, y: 0.1, w: 0.3, h: 0.3)]
        XCTAssertEqual(LayoutCanvasMath.box(at: 0.2, 0.2, in: frames), 1)
        XCTAssertEqual(LayoutCanvasMath.box(at: 0.8, 0.8, in: frames), 0)
        XCTAssertNil(LayoutCanvasMath.box(at: 0.8, 0.8, in: [frames[1]]))
    }
}
