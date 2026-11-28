// OApp — Spec 11 §5, the text editor's document: one list's text on one channel, a chunk per cue.

import Foundation
import OCore

/// Spec 11 §5, "A chunk shows" — "what the cue does on the channel, from the
/// app's own fold of the list from its top (Spec 10 §6)".
public struct TextChunk: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// "A text write: its body, editable."
        case write(body: String)
        /// "A clear: an empty chunk, with "Clears" as its placeholder (R5)."
        case clear
        /// "Hold: the line the channel holds at that cue, grayed ... Typing into
        /// a held text turns it into a write: a copy of the held write with the
        /// typing in its body (R5)." The held body; the cue that wrote it, by
        /// number, when a cue of this list did; and the held write's fields and
        /// riders, which the copy keeps (Area 10 reading: "a copy of the held
        /// write" whole; a line a macro wrote copies its fields alone).
        case heldText(body: String, from: Int?, fields: [String: String], riders: Riders)
        /// "Over held media ("Holds Video: Ocean loop") ... the write is only what was typed."
        case heldOther(CueGridContent)
        /// "or "Holds nothing"".
        case holdsNothing
        /// "Other content written on this channel (media, a slide, an input): a
        /// row naming it ("Video: Ocean loop"), not editable."
        case other(CueGridContent)
    }

    /// The cue's uuid, in lower case: "A chunk is bound to its cue by the cue's uuid, not by its place".
    public var cue: String
    /// The cue's number in the list, from 1.
    public var number: Int
    public var label: String
    public var section: String?
    /// "In the left margin, the section's label at the first chunk of each run of cues that share it".
    public var startsRun: Bool
    /// The section's place in Spec 10 §6's palette, at the first chunk of a run.
    public var hue: Int?
    public var kind: Kind
    public var isLive = false
    public var isArmed = false
    /// Spec 11 §5, "Near the live cue" — one of the three cues after the live
    /// one while an output shows a box at +1 to +3 (G-49): it sends when the
    /// caret leaves it, and says "On the confidence screen".
    public var holdsBack = false
    /// "the cue's thumbnail on the thumbnail stack, the engine's file", relative to the machine root.
    public var thumbnail: String?

    public init(cue: String, number: Int, label: String = "", section: String? = nil, startsRun: Bool = false, hue: Int? = nil, kind: Kind) {
        self.cue = cue
        self.number = number
        self.label = label
        self.section = section
        self.startsRun = startsRun
        self.hue = hue
        self.kind = kind
    }

    /// Whether the chunk takes typing: every chunk but a row of other content.
    public var isEditable: Bool {
        if case .other = kind { return false }
        return true
    }

    /// The chunk's own text: a write's body, and nothing for a clear or a hold
    /// ("a clear or a hold counting as empty text"); held text is the cue
    /// before's, shown grayed.
    public var text: String {
        if case .write(let body) = kind { return body }
        return ""
    }

    /// The grayed line a hold shows, or nil.
    public var heldBody: String? {
        if case .heldText(let body, _, _, _) = kind { return body }
        return nil
    }
}

/// Spec 11 §5 — "The Text page shows one list's text on one channel as a
/// single scrolling document, cue breaks as rules between chunks".
public struct TextDocument: Equatable, Sendable {
    /// Spec 11 §5, "Which text" — "It edits the `body` field of that channel's text writes".
    public var channel: Int
    public var listUuid: String?
    public var listNumber: Int?
    /// "One chunk per cue, in the list's order, every cue a chunk, even one that writes nothing on this channel (E2)."
    public var chunks: [TextChunk]

    public init(channel: Int, listUuid: String? = nil, listNumber: Int? = nil, chunks: [TextChunk] = []) {
        self.channel = channel
        self.listUuid = listUuid
        self.listNumber = listNumber
        self.chunks = chunks
    }

    /// What around the list is live: the live and the armed cue, and the cues
    /// whose chunks hold their typing back.
    public struct Live: Equatable, Sendable {
        public var cue: String?
        public var armed: String?
        public var holdsBack: Set<String>

        public init(cue: String? = nil, armed: String? = nil, holdsBack: Set<String> = []) {
            self.cue = cue
            self.armed = armed
            self.holdsBack = holdsBack
        }
    }

    /// The chunk of a cue, by its uuid.
    public func chunk(_ cue: String) -> TextChunk? {
        chunks.first { $0.cue == cue }
    }

    /// The place of a cue's chunk, from 0.
    public func index(of cue: String) -> Int? {
        chunks.firstIndex { $0.cue == cue }
    }

    /// Spec 11 §5, "Which text" — "The header's channel picker lists the
    /// channels, those whose `usualContent` is text first", each group in
    /// number order.
    public static func pickerChannels(_ catalog: Catalog) -> [Channel] {
        let sorted = catalog.channels.sorted { $0.number < $1.number }
        return sorted.filter { $0.usualContent == .text } + sorted.filter { $0.usualContent != .text }
    }

    /// Spec 11 §5, "The document" and "A chunk shows" — the chunks of `list`
    /// on `channel`, from the fold of the list from its top (`steps`, as
    /// `CueFold.steps` gives them) and what each cue's own commands say.
    public static func make(list: List, channel: Int, catalog: Catalog, media: [MediaItem], steps: [CueView.Step]? = nil,
                            thumbnails: [String: String] = [:], live: Live = Live()) -> TextDocument {
        let steps = steps ?? CueFold.steps(of: list, catalog: catalog, media: media)
        let pool = Dictionary(media.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        func content(_ expression: ContentExpression) -> CueGridContent? {
            switch expression {
            case .media(let item): return .media(id: item.ref, tile: pool[item.ref].map(MediaPool.tile))
            case .text(let fields): return .text(fields["body"] ?? "")
            case .slide(let ref, _): return .slide(ref: ref)
            case .input(let input): return .input(input)
            case .empty: return nil
            }
        }
        func content(_ instance: ContentInstance) -> CueGridContent? {
            switch instance {
            case .media(let item): return .media(id: item.ref, tile: pool[item.ref].map(MediaPool.tile))
            case .text(let item): return .text(item.fields["body"] ?? "")
            case .slide(let item): return .slide(ref: item.ref)
            case .input(let item): return .input(item.input)
            case .empty: return nil
            }
        }
        var chunks: [TextChunk] = []
        var open: String?
        for (index, cue) in list.cues.enumerated() {
            let uuid = cue.uuid.uuidString.lowercased()
            let section = cue.section.flatMap { $0.isEmpty ? nil : $0 }
            let starts = section != nil && section != open
            open = section
            let kind: TextChunk.Kind
            switch CueSays.about(channel, in: cue).state {
            case .write(.text(let fields), _):
                kind = .write(body: fields["body"] ?? "")
            case .write(.empty, _), .clear:
                kind = .clear
            case .write(let expression, _):
                kind = content(expression).map(TextChunk.Kind.other) ?? .clear
            case .hold:
                let after = index < steps.count ? steps[index].state.channels[channel] : nil
                let from = after?.provenance?.cue
                switch after?.content {
                case .text(let held)?:
                    if from == cue.uuid {
                        // Written by this cue, through a macro it runs: the text lives in the macro, not here.
                        kind = .other(.text(held.fields["body"] ?? ""))
                    } else {
                        let position = from.flatMap { list.position(of: $0) }
                        var riders = Riders()
                        var fields = held.fields
                        if let position, let source = list.cue(at: position),
                           case .write(.text(let written), let had) = CueSays.about(channel, in: source).state {
                            riders = had
                            fields = written
                        }
                        kind = .heldText(body: held.fields["body"] ?? "", from: position, fields: fields, riders: riders)
                    }
                case let instance?:
                    if let shown = content(instance) {
                        kind = from == cue.uuid ? .other(shown) : .heldOther(shown)
                    } else {
                        kind = .holdsNothing
                    }
                case nil:
                    kind = .holdsNothing
                }
            }
            var chunk = TextChunk(cue: uuid, number: index + 1, label: cue.label, section: section, startsRun: starts,
                                  hue: starts ? section.map(SectionHue.index) : nil, kind: kind)
            chunk.isLive = live.cue == uuid
            chunk.isArmed = live.armed == uuid
            chunk.holdsBack = live.holdsBack.contains(uuid)
            chunk.thumbnail = thumbnails[uuid]
            chunks.append(chunk)
        }
        return TextDocument(channel: channel, listUuid: list.uuid.uuidString.lowercased(), listNumber: list.number, chunks: chunks)
    }
}
