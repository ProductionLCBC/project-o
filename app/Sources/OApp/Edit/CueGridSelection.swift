// OApp — Spec 11 §4, "Selecting": what is selected in the cue grid.

import Foundation

/// Spec 11 §4, "Selecting" — "The selection is one cue or several, and one
/// row: a channel's, or the header row." Cues are named by uuid, so the
/// selection keeps its cues when others move around them.
public struct CueGridSelection: Equatable, Sendable {
    public enum Row: Equatable, Sendable {
        case header
        case channel(Int)
    }

    public enum Direction: Sendable {
        case left, right, up, down
    }

    public private(set) var cues: Set<String> = []
    /// Where a range began, and where it ends: ⇧ measures from the first to the second.
    public private(set) var anchor: String?
    public private(set) var lead: String?
    public private(set) var row: Row = .header
    /// The channel the inspector's Channel column shows: the last channel
    /// row selected, kept while the header row is ("the inspector keeps the
    /// channel it showed").
    public private(set) var channel: Int?

    public init() {}

    /// Spec 11 §2, "Opening it" — a page opened on a cue, on the row of the channel given.
    public init(cue: String?, channel: Int?) {
        if let cue {
            cues = [cue]
            anchor = cue
            lead = cue
        }
        self.channel = channel
        row = channel.map { .channel($0) } ?? .header
    }

    /// "several cues selected is multi-cue editing".
    public var isMulti: Bool { cues.count > 1 }

    /// The selected cues in the list's order.
    public func ordered(in order: [String]) -> [String] { order.filter(cues.contains) }

    /// "With several cues selected, the Preview monitor shows the first".
    public func first(in order: [String]) -> String? { order.first(where: cues.contains) }

    /// "A click on a cell selects its cue and its channel. A click on a header selects its cue and the header row".
    public mutating func click(cue: String, row: Row) {
        cues = [cue]
        anchor = cue
        lead = cue
        set(row)
    }

    /// Selects a row, keeping the cues.
    public mutating func set(_ row: Row) {
        self.row = row
        if case .channel(let number) = row { channel = number }
    }

    /// "⇧-click selects a range of cues": from where the range began to this cue.
    public mutating func extend(to cue: String, in order: [String]) {
        guard let end = order.firstIndex(of: cue) else { return }
        let start = anchor.flatMap { order.firstIndex(of: $0) } ?? end
        cues = Set(order[min(start, end)...max(start, end)])
        if anchor == nil { anchor = cue }
        lead = cue
    }

    /// "⌘-click adds or removes one". The last cue stays selected.
    public mutating func toggle(cue: String, in order: [String]) {
        guard order.contains(cue) else { return }
        if cues.contains(cue) {
            guard cues.count > 1 else { return }
            cues.remove(cue)
            if lead == cue || anchor == cue {
                let next = first(in: order)
                anchor = next
                lead = next
            }
        } else {
            cues.insert(cue)
            anchor = cue
            lead = cue
        }
    }

    /// "← and → move to the cue before and after, ⇧ with them extends the
    /// selection, and ↑ and ↓ move through the rows, the header row at the top".
    public mutating func move(_ direction: Direction, extend: Bool, order: [String], channels: [Int]) {
        switch direction {
        case .left, .right:
            guard !order.isEmpty else { return }
            let from = lead.flatMap { order.firstIndex(of: $0) } ?? first(in: order).flatMap { order.firstIndex(of: $0) } ?? 0
            let to = min(order.count - 1, max(0, from + (direction == .left ? -1 : 1)))
            if extend {
                self.extend(to: order[to], in: order)
            } else {
                cues = [order[to]]
                anchor = order[to]
                lead = order[to]
            }
        case .up, .down:
            // The rows in order: the header, then each channel.
            let rows: [Row] = [.header] + channels.map { .channel($0) }
            let from = rows.firstIndex(of: row) ?? 0
            set(rows[min(rows.count - 1, max(0, from + (direction == .up ? -1 : 1)))])
        }
    }

    /// Brings the selection in line with the list after it changed: cues
    /// that are gone leave it, and when none is left the cue now at the old
    /// place takes it. `was` is the order before the change, when it is known.
    public mutating func reconcile(order: [String], channels: [Int], was: [String]? = nil) {
        let place = lead.flatMap { was?.firstIndex(of: $0) }
        cues = cues.filter(order.contains)
        if cues.isEmpty, !order.isEmpty {
            let cue = order[min(order.count - 1, max(0, place ?? 0))]
            cues = [cue]
            anchor = cue
            lead = cue
        }
        if let current = anchor, !cues.contains(current) { anchor = first(in: order) }
        if let current = lead, !cues.contains(current) { lead = first(in: order) }
        if cues.isEmpty {
            anchor = nil
            lead = nil
        }
        if case .channel(let number) = row, !channels.contains(number) { row = .header }
        if let number = channel, !channels.contains(number) { channel = channels.first }
        if channel == nil { channel = channels.first }
    }
}
