// OApp — Spec 11 §8, "The canvas": moving and resizing a box, its snapping and its nudges, in the stack's normalized
// space (Spec 1 §2: a frame is x, y, width and height as fractions of the stack).

import Foundation
import OCore

/// Where a press on a box takes hold: its body, which moves it, or one of the eight handles, which resize it.
public enum CanvasHandle: CaseIterable, Sendable {
    case move, topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left

    var movesLeft: Bool { [.topLeft, .left, .bottomLeft].contains(self) }
    var movesRight: Bool { [.topRight, .right, .bottomRight].contains(self) }
    var movesTop: Bool { [.topLeft, .top, .topRight].contains(self) }
    var movesBottom: Bool { [.bottomLeft, .bottom, .bottomRight].contains(self) }
}

/// Spec 11 §8, "Moving" — "Dragging moves the box and the handles resize it. ... the arrows nudge the selected box by
/// one pixel of the stack, and with ⇧ by ten. ... Boxes snap to the canvas's edges and centre lines and to other boxes'
/// edges, not while ⌘ is held."
public enum LayoutCanvasMath {
    /// The smallest a box gets: a hundredth of the stack each way.
    public static let smallest = 0.01

    /// The frame a drag of `dx`, `dy` (fractions of the stack) from `handle` makes of `frame`.
    public static func dragged(_ frame: Frame, handle: CanvasHandle, dx: Double, dy: Double) -> Frame {
        if handle == .move { return Frame(x: frame.x + dx, y: frame.y + dy, w: frame.w, h: frame.h) }
        var left = frame.x, right = frame.x + frame.w, top = frame.y, bottom = frame.y + frame.h
        if handle.movesLeft { left = min(left + dx, right - smallest) }
        if handle.movesRight { right = max(right + dx, left + smallest) }
        if handle.movesTop { top = min(top + dy, bottom - smallest) }
        if handle.movesBottom { bottom = max(bottom + dy, top + smallest) }
        return Frame(x: left, y: top, w: right - left, h: bottom - top)
    }

    /// The frame snapped to the canvas's edges and centre lines and to `others`' edges, when an edge that moves comes
    /// within `threshold` of one; the lines it snapped to, for the canvas to draw.
    public static func snapped(_ frame: Frame, handle: CanvasHandle, others: [Frame], threshold: Double) -> (frame: Frame, xs: [Double], ys: [Double]) {
        let xTargets: [Double] = [0, 0.5, 1] + others.flatMap { [$0.x, $0.x + $0.w] }
        let yTargets: [Double] = [0, 0.5, 1] + others.flatMap { [$0.y, $0.y + $0.h] }
        /// The nearest target to any of `lines`, as the shift that lands on it, within the threshold.
        func nearest(_ lines: [Double], _ targets: [Double]) -> (shift: Double, at: Double)? {
            var best: (shift: Double, at: Double)?
            for line in lines {
                for target in targets {
                    let shift = target - line
                    if abs(shift) <= threshold, abs(shift) < abs(best?.shift ?? .infinity) { best = (shift, target) }
                }
            }
            return best
        }
        var result = frame
        var xs: [Double] = []
        var ys: [Double] = []
        if handle == .move {
            if let x = nearest([frame.x, frame.x + frame.w / 2, frame.x + frame.w], xTargets) {
                result.x += x.shift
                xs.append(x.at)
            }
            if let y = nearest([frame.y, frame.y + frame.h / 2, frame.y + frame.h], yTargets) {
                result.y += y.shift
                ys.append(y.at)
            }
            return (result, xs, ys)
        }
        if handle.movesLeft, let x = nearest([frame.x], xTargets), frame.w - x.shift >= smallest {
            result.x += x.shift
            result.w -= x.shift
            xs.append(x.at)
        }
        if handle.movesRight, let x = nearest([frame.x + frame.w], xTargets), frame.w + x.shift >= smallest {
            result.w += x.shift
            xs.append(x.at)
        }
        if handle.movesTop, let y = nearest([frame.y], yTargets), frame.h - y.shift >= smallest {
            result.y += y.shift
            result.h -= y.shift
            ys.append(y.at)
        }
        if handle.movesBottom, let y = nearest([frame.y + frame.h], yTargets), frame.h + y.shift >= smallest {
            result.h += y.shift
            ys.append(y.at)
        }
        return (result, xs, ys)
    }

    /// A nudge of `dx`, `dy` pixels of a stack `width` by `height`.
    public static func nudged(_ frame: Frame, dx: Int, dy: Int, width: Int, height: Int) -> Frame {
        Frame(x: frame.x + Double(dx) / Double(max(1, width)), y: frame.y + Double(dy) / Double(max(1, height)), w: frame.w, h: frame.h)
    }

    /// A frame kept within the stack, as an edit sends it: a box moved past an edge stops at it.
    public static func kept(_ frame: Frame) -> Frame {
        let w = min(1, max(smallest, frame.w))
        let h = min(1, max(smallest, frame.h))
        return Frame(x: min(1 - w, max(0, frame.x)), y: min(1 - h, max(0, frame.y)), w: w, h: h)
    }

    /// The box under a point (fractions of the stack), top first: `frames` run bottom to top as the layout's do.
    public static func box(at x: Double, _ y: Double, in frames: [Frame]) -> Int? {
        frames.indices.reversed().first { index in
            let f = frames[index]
            return x >= f.x && x <= f.x + f.w && y >= f.y && y <= f.y + f.h
        }
    }
}
