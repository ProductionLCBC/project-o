// OApp — Spec 10 §7, the right column: the next row, the tabbed panel and the channel strip, before any view.

import Foundation
import OCore

// MARK: - The next row

/// Spec 10 §7, "Why nothing happened" — "When a command from a key, a button
/// or the go-to field comes back `noop` or `rejected`, the row says why for
/// three seconds, in plain words".
public enum WhyNothing: Equatable, Sendable {
    /// "End of the playlist".
    case endOfPlaylist
    /// `previous` before the first cue (Area 13 reading: the spec names the end and not the start).
    case startOfPlaylist
    /// "End of this song: it was fired from the library".
    case endOfLibraryList
    /// "No cue 14 in Great Is Thy Faithfulness".
    case noCue(number: Int, title: String)
    /// "Nothing is live".
    case nothingLive
    /// "after a restore that couldn't place the pointer (Spec 7 §4), "Click a cue to pick up where you were"".
    case pickUp
}

/// Spec 10 §7 — the result of a navigation command carries no reason when it
/// is `noop`, so the row works the sentence out from what was sent and what
/// is live.
public enum WhyLine {
    /// "for three seconds".
    public static let seconds: TimeInterval = 3

    /// The reason to show, or nil when the command did something or isn't one the row explains.
    public static func reason(for command: Command, result: ResultKind, live: LiveStatus) -> WhyNothing? {
        guard result == .noop || result == .rejected else { return nil }
        switch command {
        case .next, .previous, .cue:
            break
        default:
            return nil
        }
        guard live.isSomethingLive else { return .nothingLive }
        // What the pointer stood on is gone, so there is nothing to step from (Spec 7 §4).
        if live.gone.contains("cue") || live.gone.contains("list") { return .pickUp }
        switch command {
        case .next: return live.isLibraryList ? .endOfLibraryList : .endOfPlaylist
        case .previous: return .startOfPlaylist
        case .cue(let number): return .noCue(number: number, title: live.listTitle)
        default: return nil
        }
    }
}

/// Spec 10 §7, "The next row" — "Last (`previous`), a large Next (`next`)
/// and the go-to field".
public struct NextRow: Equatable, Sendable {
    /// "While nothing is live, with no playlist loaded and no list fired
    /// from the library (Spec 7 §4), Next is disabled, as Space's `next`
    /// does nothing then (choice U-15)."
    public var nextEnabled: Bool
    public var lastEnabled: Bool
    public var goToEnabled: Bool
    /// "While a trigger is armed, Hold appears beside Next".
    public var showsHold: Bool
    /// "while digits wait, it shows the live list's title".
    public var goToTitle: String
    /// Why the row can't send, shown on its disabled controls (Spec 10 §1).
    public var unavailable: Unavailable?

    public static func make(live: LiveStatus, cannotSend: Unavailable?) -> NextRow {
        let ready = cannotSend == nil && live.isSomethingLive
        return NextRow(nextEnabled: ready, lastEnabled: ready && live.hasFired, goToEnabled: ready && live.listUuid != nil,
                       showsHold: cannotSend == nil && live.armed != nil, goToTitle: live.listTitle, unavailable: cannotSend)
    }
}

// MARK: - The tabbed panel

/// Spec 10 §7, Transport — "for the selected channels".
public enum TransportPanel: Equatable, Sendable {
    /// "Anything else shows "No transport"."
    case none
    /// "One channel with timed media shows its position and remaining time
    /// as a bar, Play, Pause and Stop ..., and its end behaviour as Loop,
    /// Hold and Clear."
    case one(channel: Int, positionMs: Int, durationMs: Int, isPlaying: Bool, endBehavior: String)
    /// "Several channels show Play, Pause and Stop for all of them, as one group."
    case several([Int])

    /// `elapsedMs` is how long ago each channel's status arrived, on the app's clock.
    public static func make(selection: Set<Int>, channels: [Int: ChannelStatus], elapsedMs: (Int) -> Int = { _ in 0 }) -> TransportPanel {
        let chosen = selection.sorted()
        if chosen.count > 1 { return .several(chosen) }
        guard let number = chosen.first, let status = channels[number], let content = status.content, content.isTimed,
              let duration = content.durationMs, case .media(_, _, _, let endBehavior) = content.kind else { return .none }
        let playing = status.state == "playing"
        return .one(channel: number, positionMs: position(of: content, playing: playing, elapsedMs: elapsedMs(number)), durationMs: duration,
                    isPlaying: playing, endBehavior: endBehavior)
    }

    /// Spec 10 §3 — the events come once a second, and the app counts on its
    /// own clock between them: the position now, held inside the media's
    /// length, and round again from the start for a loop.
    public static func position(of content: ChannelContent, playing: Bool, elapsedMs: Int) -> Int {
        guard let duration = content.durationMs, duration > 0 else { return content.positionMs ?? 0 }
        let reported = content.positionMs ?? 0
        guard playing else { return min(reported, duration) }
        let now = reported + max(0, elapsedMs)
        if case .media(_, _, let loop, _) = content.kind, loop { return now % duration }
        return min(now, duration)
    }
}

/// Spec 10 §7, Clears — "tiles that each send one command (choice U-4)".
public struct ClearsTile: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case clearAll
        case blackoutStack(Int)
        case blackoutAll
        case muteAllAudio
        case resetChannels
        case clearPopups
    }

    /// "A tile lights red while all its targets are on, and shows a red outline while only some are."
    public enum Lit: Equatable, Sendable {
        case off
        case some
        case all
    }

    public var kind: Kind
    public var lit: Lit
    /// Area 13 reading — a tile with no targets is unlit and disabled.
    public var isEnabled: Bool
    public var sending: Sending

    /// The six tiles, in the spec's order. A tile that only fires (Clear
    /// All, Reset Channels, Clear Popups) is never lit (Area 13 reading).
    public static func all(previewStack: Int, stacks: [Stack], stackStatus: [Int: StackStatus], audioOutputs: [AudioOutput], audio: [Int: AudioStatus],
                           channels: Int, popupSlots: Int, cannotSend: Unavailable?) -> [ClearsTile] {
        let can = cannotSend == nil
        func lit(_ states: [Bool]) -> Lit {
            guard !states.isEmpty, states.contains(true) else { return .off }
            return states.allSatisfy { $0 } ? .all : .some
        }
        let blackouts = stacks.map { stackStatus[$0.number]?.blackout ?? false }
        let mutes = audioOutputs.map { audio[$0.number]?.muted ?? false }
        let hasPreview = stacks.contains { $0.number == previewStack }
        return [
            ClearsTile(kind: .clearAll, lit: .off, isEnabled: can && channels > 0, sending: Actions.clearAll()),
            ClearsTile(kind: .blackoutStack(previewStack), lit: hasPreview ? lit([stackStatus[previewStack]?.blackout ?? false]) : .off,
                       isEnabled: can && hasPreview, sending: Actions.blackout(stack: previewStack)),
            ClearsTile(kind: .blackoutAll, lit: lit(blackouts), isEnabled: can && !stacks.isEmpty, sending: Actions.blackoutAll()),
            ClearsTile(kind: .muteAllAudio, lit: lit(mutes), isEnabled: can && !audioOutputs.isEmpty, sending: Actions.muteAllAudio()),
            ClearsTile(kind: .resetChannels, lit: .off, isEnabled: can && channels > 0, sending: Actions.resetChannels()),
            ClearsTile(kind: .clearPopups, lit: .off, isEnabled: can && popupSlots > 0, sending: Actions.clearPopups(slots: popupSlots)),
        ]
    }
}

/// Spec 10 §7, Popups — "a clear-after choice (stays, 15 s, 30 s, 1 min, 2 min, 5 min)", in seconds; nil stays.
public enum PopupClearAfter {
    public static let choices: [Int?] = [nil, 15, 30, 60, 120, 300]
}

// MARK: - The channel strip

/// Spec 10 §7, "The header" — "the view: all channels in number order, or
/// one stack's channels in that stack's order, top layer first, keeping
/// their numbers (UX spec)".
public enum StripView: Equatable, Sendable {
    case all
    case stack(Int)

    /// The channels the strip shows, in its order.
    public func channels(_ channels: [Channel], stacks: [Stack]) -> [Int] {
        switch self {
        case .all:
            return channels.map(\.number).sorted()
        case .stack(let number):
            guard let stack = stacks.first(where: { $0.number == number }) else { return [] }
            // Spec 1 §3 — slots are "bottom to top", and "the engine uses the first slot for a channel".
            var seen: Set<Int> = []
            let bottomUp = stack.slots.map(\.channel).filter { seen.insert($0).inserted }
            return bottomUp.reversed()
        }
    }
}

/// Spec 10 §7, "Selection" — "needs no modifier keys: the number badge
/// toggles a channel in or out, and a click on the thumbnail selects that
/// channel alone (UX spec). Selection belongs to the window and is never sent".
public struct StripSelection: Equatable, Sendable {
    public private(set) var channels: Set<Int> = []

    public init(_ channels: Set<Int> = []) {
        self.channels = channels
    }

    /// The number badge.
    public mutating func toggle(_ channel: Int) {
        if channels.contains(channel) { channels.remove(channel) } else { channels.insert(channel) }
    }

    /// A click on the thumbnail, and Select Only This Channel.
    public mutating func selectOnly(_ channel: Int) {
        channels = [channel]
    }

    /// All and None, of the channels the strip shows.
    public mutating func selectAll(_ shown: [Int]) {
        channels = Set(shown)
    }

    public mutating func selectNone() {
        channels = []
    }

    /// Area 13 reading — a channel the view no longer shows drops out of
    /// the selection, so Clear Selected never clears what can't be seen.
    public mutating func keep(only shown: [Int]) {
        channels.formIntersection(shown)
    }
}

/// Spec 10 §7, "Stack dots" — "A dot is filled while its stack shows the
/// channel, hollow amber while that stack mutes it, and hollow grey and
/// inert where the stack doesn't hold the channel."
public struct StackDot: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        case showing
        case muted
        case absent
    }

    public var stack: Int
    public var label: String
    public var state: State
}

/// Spec 10 §7, "A cell shows" — one channel's cell, before any wording.
public struct StripCell: Equatable, Sendable {
    /// "its picture (choice U-3)".
    public enum Picture: Equatable, Sendable {
        /// "for pixel content the channel's live picture from the Mach channel (§2)".
        case live
        /// "for text the text as the channel's `textThumbnail` says (the body, or its first line, Spec 1 §3)".
        case text(String)
        /// "for audio alone the kind glyph".
        case audio
        /// "nothing when empty".
        case none
    }

    public enum Kind: Equatable, Sendable {
        case empty, text, video, image, audio, slide, input
        /// Media the pool no longer lists, or a kind this build doesn't know: named by the engine's word.
        case other(String)
    }

    /// "the remaining time on timed media ("loops", or "paused 1:23")".
    public enum Remaining: Equatable, Sendable {
        case counting(ms: Int)
        case loops
        case paused(ms: Int)
    }

    /// "Buttons: media shows Play or Pause, Stop and Clear; text shows Clear; an empty channel shows nothing."
    public enum Button: Equatable, Sendable {
        case play, pause, stop, clear
    }

    /// "what put the content there" (Spec 10 §7, "Provenance").
    public enum Origin: Equatable, Sendable {
        /// "from Verse 2 · Great Is Thy Faithfulness"; either may be unknown when the app doesn't hold the list.
        case cue(label: String?, list: String?)
        /// "restored".
        case restored
        /// "the source ("from the UI", "from OSC", "from a macro")", by Spec 2's source name.
        case source(String)
    }

    public var number: Int
    public var label: String
    public var isSelected: Bool
    public var picture: Picture
    public var kind: Kind
    /// The content's own label: a file's name, a slide's title.
    public var contentLabel: String
    /// "tags for locked, the grade in use, and missing".
    public var isLocked: Bool
    public var grade: String?
    public var isMissing: Bool
    public var remaining: Remaining?
    /// "the meter when its content has sound".
    public var hasMeter: Bool
    public var dots: [StackDot]
    public var buttons: [Button]
    public var origin: Origin?

    /// Builds the strip's cells in the view's order. `elapsedMs` is how long ago a channel's status arrived.
    public static func cells(view: StripView, selection: StripSelection, catalog: Catalog, channels: [Int: ChannelStatus], stackStatus: [Int: StackStatus],
                             media: [MediaItem], lists: [String: ListDocument], elapsedMs: (Int) -> Int = { _ in 0 }) -> [StripCell] {
        let stacks = catalog.stacks.sorted { $0.number < $1.number }
        return view.channels(catalog.channels, stacks: stacks).compactMap { number in
            guard let channel = catalog.channels.first(where: { $0.number == number }) else { return nil }
            let status = channels[number] ?? ChannelStatus(number: number)
            let content = status.content
            var cell = StripCell(number: number, label: channel.label, isSelected: selection.channels.contains(number), picture: .none, kind: .empty,
                                 contentLabel: content?.label ?? "", isLocked: status.lock, grade: nil, isMissing: status.state == "missing",
                                 remaining: nil, hasMeter: content?.hasAudio ?? false, dots: [], buttons: [], origin: nil)
            if let content {
                switch content.kind {
                case .text(let fields):
                    cell.kind = .text
                    let body = fields["body"] ?? fields.sorted { $0.key < $1.key }.map(\.value).joined(separator: "\n")
                    cell.picture = .text(channel.textThumbnail == .firstLine ? String(body.split(separator: "\n", omittingEmptySubsequences: true).first ?? "") : body)
                    cell.buttons = [.clear]
                case .media(let ref, let missing, let loop, _):
                    let entry = media.first { $0.id == ref }?.entry
                    switch entry?.kind {
                    case .video: cell.kind = .video
                    case .image: cell.kind = .image
                    case .audio, .audioSet: cell.kind = .audio
                    default: cell.kind = .other("media")
                    }
                    cell.isMissing = cell.isMissing || missing
                    cell.picture = content.hasPicture ? .live : (content.hasAudio ? .audio : .none)
                    cell.buttons = [status.state == "playing" ? .pause : .play, .stop, .clear]
                    if content.isTimed, let duration = content.durationMs {
                        let playing = status.state == "playing"
                        let left = max(0, duration - TransportPanel.position(of: content, playing: playing, elapsedMs: elapsedMs(number)))
                        cell.remaining = loop ? .loops : (status.state == "paused" ? .paused(ms: left) : .counting(ms: left))
                    }
                case .slide:
                    cell.kind = .slide
                    cell.picture = content.hasPicture ? .live : .none
                    cell.buttons = [.clear]
                case .input:
                    cell.kind = .input
                    cell.picture = content.hasPicture ? .live : .none
                    cell.buttons = [.clear]
                case .other(let word):
                    cell.kind = .other(word)
                    cell.picture = content.hasPicture ? .live : .none
                    cell.buttons = [.clear]
                }
            }
            if let grade = status.attributes["grade"]?.value.intValue, grade != 0 {
                cell.grade = catalog.grades.first { $0.number == grade }?.label ?? String(grade)
            }
            cell.dots = stacks.map { stack in
                let holds = stack.slots.contains { $0.channel == number }
                let muted = stackStatus[stack.number]?.muted.contains(number) ?? false
                return StackDot(stack: stack.number, label: stack.label, state: !holds ? .absent : (muted ? .muted : .showing))
            }
            cell.origin = origin(of: status.provenance, lists: lists, catalog: catalog)
            return cell
        }
    }

    static func origin(of provenance: Provenance?, lists: [String: ListDocument], catalog: Catalog) -> Origin? {
        guard let provenance else { return nil }
        switch provenance {
        case .cue(let cue, let list):
            let listUuid = list?.uuidString.lowercased()
            let document = listUuid.flatMap { lists[$0] }
            let label = document?.list.cues.first { $0.uuid == cue }?.label
            return .cue(label: label.flatMap { $0.isEmpty ? nil : $0 }, list: document?.list.title ?? listUuid.flatMap { catalog.list(uuid: $0)?.title })
        case .restored:
            return .restored
        case .source(let kind):
            return .source(kind.rawValue)
        }
    }
}

/// Spec 10 §7 — "the meter when its content has sound, from the Mach
/// channel, green below −12 dBFS, amber to −3 and red above".
public enum MeterZone: Equatable, Sendable {
    case green
    case amber
    case red

    public static func of(dBFS: Double) -> MeterZone {
        if dBFS < -12 { return .green }
        return dBFS <= -3 ? .amber : .red
    }
}

/// Spec 10 §7, "Drops" — "a cell takes the tile only once it has hovered
/// there for 0.3 seconds, showing the live red and "Goes live on 2
/// Foreground" meanwhile, so a drag that overshoots a cue doesn't go to air."
public struct DropHover: Equatable, Sendable {
    /// "0.3 seconds".
    public static let wait: TimeInterval = 0.3

    public private(set) var channel: Int?
    private var since: TimeInterval = 0

    public init() {}

    /// The drag is over `channel`'s cell at `now`, or over none. Entering a
    /// cell starts its wait again (Area 13 reading).
    public mutating func over(_ channel: Int?, at now: TimeInterval) {
        guard channel != self.channel else { return }
        self.channel = channel
        since = now
    }

    /// Whether a drop on `channel` at `now` is taken: it goes live only then.
    public func takes(_ channel: Int, at now: TimeInterval) -> Bool {
        self.channel == channel && now - since >= Self.wait
    }
}
