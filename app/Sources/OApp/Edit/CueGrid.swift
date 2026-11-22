// OApp — Spec 11 §4, the cue grid: a list's cues across and the channels down.

import Foundation
import OCore

/// Spec 11 §4, "Attribute chips" — one attribute a cue writes on a channel:
/// "On a write the chip is a rider; with Clear or Hold it is a standalone
/// attribute command, which is always `track` (Spec 1 §6)".
public struct CueAttribute: Equatable, Sendable {
    /// In the chips' order: "transition, audio transition (E9), grade and gain".
    public enum Kind: String, CaseIterable, Sendable {
        case transition, audioTransition, grade, gain
    }

    public var kind: Kind
    /// The transition, audio transition or grade it names.
    public var ref: Int?
    /// "a duration where the command takes one".
    public var ms: Int?
    /// "decibels for gain".
    public var db: Double?
    public var scope: Scope
    public var isRider: Bool

    public init(kind: Kind, ref: Int? = nil, ms: Int? = nil, db: Double? = nil, scope: Scope, isRider: Bool) {
        self.kind = kind
        self.ref = ref
        self.ms = ms
        self.db = db
        self.scope = scope
        self.isRider = isRider
    }
}

extension CueSays {
    /// What the cue writes of one attribute on the channel: the write's
    /// rider when it has one, else the last standalone command of that kind.
    public func attribute(_ kind: CueAttribute.Kind) -> CueAttribute? {
        if case .write(_, let riders) = state {
            switch kind {
            case .transition:
                if let r = riders.transition { return CueAttribute(kind: kind, ref: r.ref, ms: r.ms, scope: r.scope, isRider: true) }
            case .audioTransition:
                if let r = riders.audioTransition { return CueAttribute(kind: kind, ref: r.ref, ms: r.ms, scope: r.scope, isRider: true) }
            case .grade:
                if let r = riders.grade { return CueAttribute(kind: kind, ref: r.ref, ms: r.ms, scope: r.scope, isRider: true) }
            case .gain:
                if let r = riders.gain { return CueAttribute(kind: kind, db: r.db, scope: r.scope, isRider: true) }
            }
        }
        for command in attributes.reversed() {
            switch (kind, command) {
            case (.transition, .channelTransition(_, let ref, let ms)),
                 (.audioTransition, .channelAudioTransition(_, let ref, let ms)),
                 (.grade, .channelGrade(_, let ref, let ms)):
                return CueAttribute(kind: kind, ref: ref, ms: ms, scope: .track, isRider: false)
            case (.gain, .channelGain(_, let db)):
                return CueAttribute(kind: kind, db: db, scope: .track, isRider: false)
            default:
                continue
            }
        }
        return nil
    }

    /// Every attribute the cue writes on the channel, in the chips' order.
    public var written: [CueAttribute] {
        CueAttribute.Kind.allCases.compactMap(attribute)
    }
}

/// Spec 11 §4, "The channel rows" — "one per channel in number order, then
/// one for each channel number the list's cues write that no channel has
/// (E7), named "No channel 7"".
public struct CueGridRow: Equatable, Sendable {
    public var channel: Int
    /// The channel's label; empty for a channel number no channel has.
    public var label: String
    public var exists: Bool
    /// "a control that folds it to a thin strip".
    public var isFolded: Bool
}

/// What a tile shows, or what a channel holds at a cue.
public enum CueGridContent: Equatable, Sendable {
    /// "For media, the pool tile with the item's name along its foot, and the
    /// missing overlay when the item is missing or deleted". `tile` is nil
    /// for an id the pool doesn't know, which reads as missing.
    case media(id: String, tile: PoolTile?)
    /// "For text, the first lines of its body on black, or its first line
    /// alone, as the channel's `textThumbnail` says".
    case text(String)
    /// "For a slide or an input, its kind and reference, not editable in v1."
    case slide(ref: String)
    case input(Int)
}

/// Spec 11 §4, "A cell" — "one cue on one channel. It shows which of the UX
/// spec's three states the cue has there".
public struct CueGridCell: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        case write, hold, clear
    }

    public var state: State
    /// A write's tile; for a hold, what the channel holds there, nil for nothing.
    public var content: CueGridContent?
    /// For a hold, the number of the cue whose write the channel holds.
    public var heldFrom: Int?
    /// For a clear: "the bar ends at a cap", when the channel held something before.
    public var endsBar = false
    /// For a write: "When the next cue holds the channel, a short bar leaves the tile toward it."
    public var hasTail = false
    /// "A badge in the tile's corner gives the transition rider's duration".
    public var badgeMs: Int?
    /// Everything the cue writes of the channel's attributes, in the chips' order.
    public var attributes: [CueAttribute] = []

    /// "a bar through the cell while the channel holds something there, and nothing while it holds nothing".
    public var isHolding: Bool { state == .hold && content != nil }

    /// "a mark beside it says the write carries other riders"; "Attribute
    /// writes on a held or cleared cell show as a mark on the bar, or beside
    /// the cap".
    public var hasMark: Bool {
        switch state {
        case .write: return attributes.contains { !($0.kind == .transition && $0.isRider) }
        case .hold, .clear: return !attributes.isEmpty
        }
    }
}

/// Spec 11 §4, "The section band" — "over each run of cues that share a
/// section, the section's name under a rule of its colour".
public struct CueGridRun: Equatable, Sendable {
    public var name: String
    public var hue: Int?
    /// The run's first cue, from 0, and how many cues it spans.
    public var first: Int
    public var count: Int
}

/// Spec 11 §4, "The cue grid" — "the list's cues across, in order, and the
/// channels down, read from left to right as the list plays".
public struct CueGridModel: Equatable, Sendable {
    public var listUuid: String?
    public var listNumber: Int?
    /// "The workspace's header names the list, its cue count and its version".
    public var title = ""
    public var cueCount = 0
    public var version: Int?
    public var runs: [CueGridRun] = []
    /// One per cue: its number, label, trigger, thumbnail and live dot, as the show grid's cell has them (Spec 10 §6).
    public var headers: [CueCell] = []
    public var rows: [CueGridRow] = []
    /// One array per row, one cell per cue.
    public var cells: [[CueGridCell]] = []

    public init() {}

    public func row(of channel: Int) -> Int? { rows.firstIndex { $0.channel == channel } }
    public func cue(of uuid: String) -> Int? { headers.firstIndex { $0.uuid == uuid } }

    /// Builds the grid from the list the page edits, its section of the show
    /// grid's model (which carries the headers), and the folds `view.json`
    /// keeps: "a row the operator folds or opens stays so for every list, by
    /// channel number".
    public static func make(document: ListDocument?, section: GridSection?, catalog: Catalog, media: [MediaItem], folds: [Int: Bool]) -> CueGridModel {
        var model = CueGridModel()
        model.listUuid = document?.uuid ?? section?.listUuid
        model.listNumber = document?.list.number ?? section?.listNumber
        model.title = document?.list.title ?? section?.title ?? ""
        let channels = catalog.channels.sorted { $0.number < $1.number }
        guard let list = document?.list else {
            model.rows = channels.map { CueGridRow(channel: $0.number, label: $0.label, exists: true, isFolded: folds[$0.number] ?? true) }
            model.cells = model.rows.map { _ in [] }
            return model
        }
        model.cueCount = list.cues.count
        model.version = list.version
        model.headers = section?.cells ?? []
        model.runs = runs(of: list)

        // The rows: the channels, then the numbers the cues name that no channel has.
        let known = Set(channels.map(\.number))
        let named = Set(list.cues.flatMap { $0.commands.compactMap { $0.command.namedChannel } })
        let written = Set(list.cues.flatMap { $0.commands.compactMap { $0.command.contentChannel } })
        var rows = channels.map { channel in
            CueGridRow(channel: channel.number, label: channel.label, exists: true, isFolded: folds[channel.number] ?? !written.contains(channel.number))
        }
        rows += named.subtracting(known).sorted().map { CueGridRow(channel: $0, label: "", exists: false, isFolded: folds[$0] ?? false) }
        model.rows = rows

        let steps = CueFold.steps(of: list, catalog: catalog, media: media)
        let pool = Dictionary(media.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        func content(_ expression: ContentExpression, channel: Channel?) -> CueGridContent? {
            switch expression {
            case .media(let item): return .media(id: item.ref, tile: pool[item.ref].map(MediaPool.tile))
            case .text(let fields): return .text(text(fields["body"] ?? "", channel: channel))
            case .slide(let ref, _): return .slide(ref: ref)
            case .input(let input): return .input(input)
            case .empty: return nil
            }
        }
        func content(_ instance: ContentInstance, channel: Channel?) -> CueGridContent? {
            switch instance {
            case .media(let item): return .media(id: item.ref, tile: pool[item.ref].map(MediaPool.tile))
            case .text(let item): return .text(text(item.fields["body"] ?? "", channel: channel))
            case .slide(let item): return .slide(ref: item.ref)
            case .input(let item): return .input(item.input)
            case .empty: return nil
            }
        }

        model.cells = rows.map { row in
            let channel = channels.first { $0.number == row.channel }
            // What the cues' own commands leave on the channel, for a number no channel has: the fold has no state for it.
            var walked: (content: CueGridContent, from: Int)?
            var cells: [CueGridCell] = []
            for (index, cue) in list.cues.enumerated() {
                let says = CueSays.about(row.channel, in: cue)
                let before: CueGridContent?
                if row.exists {
                    before = index > 0 && index - 1 < steps.count ? steps[index - 1].state.channels[row.channel].flatMap { content($0.content, channel: channel) } : nil
                } else {
                    before = walked?.content
                }
                var cell = CueGridCell(state: .hold)
                cell.attributes = says.written
                switch says.state {
                case .write(let expression, let riders):
                    if let tile = content(expression, channel: channel) {
                        cell.state = .write
                        cell.content = tile
                        cell.badgeMs = riders.transition.map { rider in
                            rider.ms ?? catalog.transitions.first { $0.number == rider.ref }?.ms ?? 0
                        }
                        walked = (tile, index + 1)
                    } else {
                        // A write of `empty` empties the channel, as a clear does.
                        cell.state = .clear
                        cell.endsBar = before != nil
                        walked = nil
                    }
                case .clear:
                    cell.state = .clear
                    cell.endsBar = before != nil
                    walked = nil
                case .hold:
                    if row.exists {
                        let after = index < steps.count ? steps[index].state.channels[row.channel] : nil
                        cell.content = after.flatMap { content($0.content, channel: channel) }
                        if cell.content != nil, let from = after?.provenance?.cue { cell.heldFrom = list.position(of: from) }
                    } else {
                        cell.content = walked?.content
                        cell.heldFrom = walked?.from
                    }
                }
                cells.append(cell)
            }
            for index in cells.indices.dropLast() where cells[index].state == .write {
                cells[index].hasTail = cells[index + 1].state == .hold
            }
            return cells
        }
        return model
    }

    /// The text a tile shows: the body, or its first line (Spec 1 §3).
    private static func text(_ body: String, channel: Channel?) -> String {
        guard channel?.textThumbnail == .firstLine else { return body }
        return body.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? body
    }

    private static func runs(of list: List) -> [CueGridRun] {
        var runs: [CueGridRun] = []
        var open: String?
        for (index, cue) in list.cues.enumerated() {
            let section = cue.section.flatMap { $0.isEmpty ? nil : $0 }
            if let section, section == open, !runs.isEmpty {
                runs[runs.count - 1].count += 1
            } else if let section {
                runs.append(CueGridRun(name: section, hue: SectionHue.index(for: section), first: index, count: 1))
            }
            open = section
        }
        return runs
    }
}

extension Command {
    /// The one channel a channel command names by number, or nil.
    var namedChannel: Int? {
        switch self {
        case .channelWrite(let write):
            if case .number(let n) = write.channel { return n }
            return nil
        case .channelClear(.number(let n)), .channelTransition(.number(let n), _, _), .channelAudioTransition(.number(let n), _, _),
             .channelGrade(.number(let n), _, _), .channelGain(.number(let n), _):
            return n
        default:
            return nil
        }
    }

    /// The channel this command writes content to, when it is a write that isn't `empty`.
    var contentChannel: Int? {
        guard case .channelWrite(let write) = self, case .number(let n) = write.channel, write.content != .empty else { return nil }
        return n
    }
}

/// Spec 11 §4, "Zoom" — "The header's slider sets the width of a cue's
/// column, from 24 to 240 points, 140 at first, and a pinch on the grid does
/// the same."
public enum CueGridZoom {
    public static let range: ClosedRange<Double> = 24...240
    public static let standard: Double = 140
    /// "Below 96 points a header drops its trigger and its label, and a tile its name, its text and its badge".
    public static let textFloor: Double = 96

    /// A width within the range, in whole points.
    public static func clamped(_ column: Double) -> Double {
        guard column.isFinite else { return standard }
        return min(range.upperBound, max(range.lowerBound, column.rounded()))
    }

    public static func showsText(column: Double) -> Bool { column >= textFloor }

    /// "The rows' tiles keep their shape, so the whole grid grows and
    /// shrinks as a timeline does": a 16 by 9 tile inside the cell's padding.
    public static func rowHeight(column: Double) -> Double { (column - 12) * 9 / 16 + 12 }

    /// A pinch's magnification, as AppKit reports it (0.1 for a tenth wider), applied to the column.
    public static func pinched(_ column: Double, by magnification: Double) -> Double {
        clamped(column * (1 + magnification))
    }
}

/// Where the grid's parts sit, and what is under a point: the band and the
/// headers at the top and the channel column at the left "stay in place
/// while the grid scrolls" (Spec 11 §4).
public struct CueGridGeometry: Equatable, Sendable {
    /// What a point is over.
    public enum Hit: Equatable, Sendable {
        case corner
        case band(cue: Int)
        case header(cue: Int)
        /// "After the last cue, a + header adds a cue at the end."
        case add
        case channel(row: Int)
        case fold(row: Int)
        case cell(cue: Int, row: Int)
        case nothing
    }

    /// The channel column's width, the section band's height, a folded row's height and the + column's width, as drawn.
    public static let channelColumn: Double = 136
    public static let band: Double = 26
    public static let foldedRow: Double = 28
    public static let addColumn: Double = 60
    /// The fold control's width, at the channel column's left edge.
    public static let foldWidth: Double = 26

    public var column: Double
    public var cues: Int
    public var folded: [Bool]

    public init(column: Double, cues: Int, folded: [Bool]) {
        self.column = CueGridZoom.clamped(column)
        self.cues = max(0, cues)
        self.folded = folded
    }

    public var showsText: Bool { CueGridZoom.showsText(column: column) }

    /// A header's height: the line with its number and trigger, its
    /// thumbnail, and its label's line while the zoom shows text.
    public var header: Double {
        let thumbnail = (column - 16) * 9 / 16
        return 8 + 14 + 4 + thumbnail + (showsText ? 4 + 14 : 0) + 8
    }

    public func rowHeight(_ row: Int) -> Double {
        row < folded.count && folded[row] ? Self.foldedRow : CueGridZoom.rowHeight(column: column)
    }

    /// The whole grid's size, unscrolled.
    public var width: Double { Self.channelColumn + Double(cues) * column + Self.addColumn }
    public var height: Double { Self.band + header + folded.indices.reduce(0) { $0 + rowHeight($1) } }

    /// A cue's left edge and a row's top, in the grid's own space.
    public func x(cue: Int) -> Double { Self.channelColumn + Double(cue) * column }
    public func y(row: Int) -> Double { Self.band + header + (0..<max(0, min(row, folded.count))).reduce(0) { $0 + rowHeight($1) } }

    /// What is under a point of the view, with the grid scrolled by `scrollX` and `scrollY`.
    public func hit(x: Double, y: Double, scrollX: Double = 0, scrollY: Double = 0) -> Hit {
        guard x >= 0, y >= 0 else { return .nothing }
        let overChannels = x < Self.channelColumn
        let contentX = x - Self.channelColumn + scrollX
        let cue = contentX >= 0 ? Int(contentX / column) : -1
        if y < Self.band {
            if overChannels { return .corner }
            return cue >= 0 && cue < cues ? .band(cue: cue) : .nothing
        }
        if y < Self.band + header {
            if overChannels { return .corner }
            if cue >= 0, cue < cues { return .header(cue: cue) }
            return contentX < Double(cues) * column + Self.addColumn ? .add : .nothing
        }
        var top = Self.band + header - scrollY
        for row in folded.indices {
            let bottom = top + rowHeight(row)
            // A row scrolled under the headers isn't under the point.
            if y >= max(top, Self.band + header), y < bottom {
                if overChannels { return x < Self.foldWidth ? .fold(row: row) : .channel(row: row) }
                return cue >= 0 && cue < cues ? .cell(cue: cue, row: row) : .nothing
            }
            top = bottom
        }
        return .nothing
    }

    /// How far across the grid should be scrolled to bring a cue's column
    /// into view, moving "by the least amount": unchanged when it shows already.
    public func scrollX(toShow cue: Int, from scrollX: Double, viewWidth: Double) -> Double {
        let visible = max(0, viewWidth - Self.channelColumn)
        let left = Double(cue) * column
        let right = left + column
        if left < scrollX { return left }
        if right > scrollX + visible { return max(0, right - visible) }
        return scrollX
    }

    /// The same down the rows, under the band and the headers.
    public func scrollY(toShow row: Int, from scrollY: Double, viewHeight: Double) -> Double {
        let visible = max(0, viewHeight - Self.band - header)
        let top = y(row: row) - Self.band - header
        let bottom = top + rowHeight(row)
        if top < scrollY { return top }
        if bottom > scrollY + visible { return max(0, bottom - visible) }
        return scrollY
    }
}
