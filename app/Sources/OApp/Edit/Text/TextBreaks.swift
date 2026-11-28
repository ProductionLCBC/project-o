// OApp — Spec 11 §5, "Breaks": split, merge and moved breaks, each one group of Spec 5 edits.

import Foundation
import OCore

/// One chunk as a break sees it: the chunk, its cue as the store holds it (with
/// what this editor sent and hasn't heard back), and its own text, the caret's
/// as typed. Spec 11 §5, "What joins" — "a clear or a hold counting as empty
/// text": held text not typed into is the cue before's, so its own text is empty.
public struct TextSide: Equatable, Sendable {
    public var chunk: TextChunk
    public var cue: Cue
    public var text: String
    /// Held text typed into in this visit: its write is "a copy of the held write".
    public var typed: Bool

    public init(chunk: TextChunk, cue: Cue, text: String, typed: Bool = false) {
        self.chunk = chunk
        self.cue = cue
        self.text = text
        self.typed = typed
    }

    /// The lines of its own text, which a moved break moves between chunks.
    public var lines: [String] { TextBreaks.lines(text) }
}

/// Spec 11 §5, "Breaks" (E2) — "A chunk is bound to its cue by the cue's
/// uuid, not by its place, so typing in a chunk changes only that cue's text
/// write and never moves another cue's commands." Each break is one group
/// (Spec 5 §5): one undo takes it back. Every function is pure; nil when
/// there is nothing to send.
public enum TextBreaks {
    /// A text's lines; an empty text has none.
    public static func lines(_ text: String) -> [String] {
        text.isEmpty ? [] : text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    /// The other fields of the write a side's text came from: its text write's,
    /// or the held write's it was typed into; none for a clear or a hold.
    public static func fields(of side: TextSide, channel: Int) -> [String: String] {
        var fields: [String: String] = [:]
        if case .write(.text(let had), _) = CueSays.about(channel, in: side.cue).state {
            fields = had
        } else if side.typed, case .heldText(_, _, let held, _) = side.chunk.kind {
            fields = held
        }
        fields["body"] = nil
        return fields
    }

    /// The edit that gives a side a new body. Spec 11 §5 — "a clear or a hold
    /// counting as empty text, which becomes a write when text moves into it,
    /// with the other fields of the write the text came from" (`from`); a
    /// write keeps its fields and riders, as typing does; held text typed into
    /// is "a copy of the held write"; and "A chunk left empty is a clear ...
    /// never ... an empty text write". Nil when the cue says that already.
    static func body(_ body: String, of side: TextSide, from: [String: String] = [:], list: Int, channel: Int) -> Sending? {
        let says = CueSays.about(channel, in: side.cue)
        if body.isEmpty {
            if case .write(.text, _) = says.state { return TextEdits.emptied(cue: side.cue, list: list, channel: channel) }
            return nil
        }
        if case .write(.text, _) = says.state {
            return TextEdits.typing(body, chunk: side.chunk, cue: side.cue, list: list, channel: channel)
        }
        if side.typed, case .heldText = side.chunk.kind {
            return TextEdits.typing(body, chunk: side.chunk, cue: side.cue, list: list, channel: channel)
        }
        var fields = from
        fields["body"] = body
        return CueEdits.write(.text(fields: fields), riders: .none, channel: channel, cue: side.cue, list: list)
    }

    // MARK: - Split

    /// What a split sends, and where the text went.
    public struct Split: Equatable, Sendable {
        public var sending: Sending
        public var cue: Cue
        public var above: String
        public var below: String
    }

    /// Spec 11 §5, "Split" — "⌥Return, or Edit ▸ Split Cue, at the caret. The
    /// text above stays with the cue; a new cue right after it takes the text
    /// below, in a write with the other fields of the one it was split from and
    /// none of its riders, with every other channel held and the label and
    /// section copied. One group: `edit.cueChannel`, then `edit.insert` with a
    /// uuid the app makes ... At the end of a chunk the new cue's chunk is
    /// empty, which is a clear until something is typed into it."
    ///
    /// `location` is the caret's place in the side's text, in UTF-16 units as
    /// a text view counts them; `index` is the cue's place in the list, from 0.
    /// Area 10 readings: the line break at the caret goes with the split, so
    /// neither part begins or ends with an empty line; the new cue has a Go
    /// trigger, an empty note and no advance-after; the text above left empty
    /// clears the cue, as an emptied chunk does.
    public static func split(_ side: TextSide, at location: Int, index: Int, uuid: UUID, list: Int, channel: Int) -> Split {
        let text = side.text as NSString
        let at = max(0, min(location, text.length))
        var above = text.substring(to: at)
        var below = text.substring(from: at)
        if above.hasSuffix("\n") { above.removeLast() }
        if below.hasPrefix("\n") { below.removeFirst() }
        let first = body(above, of: side, list: list, channel: channel)
        let write: ChannelWrite?
        if below.isEmpty {
            write = nil
        } else {
            var fields = Self.fields(of: side, channel: channel)
            fields["body"] = below
            write = ChannelWrite(channel: .number(channel), content: .text(fields: fields))
        }
        var cue = TextEdits.newCue(uuid: uuid, label: side.cue.label, section: side.cue.section, write: write)
        if write == nil { cue.commands = [GuardedCommand(.channelClear(channel: .number(channel)))] }
        let commands = (first?.commands ?? []) + [TextEdits.insert(cue, at: index + 1, list: list)]
        return Split(sending: Sending(commands), cue: cue, above: above, below: below)
    }

    // MARK: - Merge

    /// What a merge sends, the joined text and where the two texts meet in it.
    public struct Merge: Equatable, Sendable {
        public var sending: Sending
        public var joined: String
        /// The place in `joined`, in UTF-16 units, where the lower chunk's text begins.
        public var joinAt: Int
    }

    /// Spec 11 §5, "Merge" — "Backspace at the start of a chunk joins it to the
    /// chunk above, and forward Delete at the end of a chunk joins the one
    /// below to it. The first cue keeps its commands and the joined text, and
    /// the second cue is removed ... One group, `edit.cueChannel` then
    /// `edit.remove`." Area 10 reading: the texts join as lines, one after the
    /// other; no `edit.cueChannel` goes when the first text doesn't change.
    public static func merge(upper: TextSide, lower: TextSide, list: Int, channel: Int) -> Merge {
        let joined = [upper.text, lower.text].filter { !$0.isEmpty }.joined(separator: "\n")
        let upperLength = (upper.text as NSString).length
        let joinAt = upper.text.isEmpty ? 0 : upperLength + (lower.text.isEmpty ? 0 : 1)
        let first = body(joined, of: upper, from: fields(of: lower, channel: channel), list: list, channel: channel)
        let remove = Command.edit(EditCommand(.cue(list: list, cue: lower.cue.uuid), .remove(path: nil, at: nil)))
        return Merge(sending: Sending((first?.commands ?? []) + [remove]), joined: joined, joinAt: joinAt)
    }

    // MARK: - A moved break

    /// What a moved break sends and the two texts it leaves.
    public struct Move: Equatable, Sendable {
        public var sending: Sending
        public var upper: String
        public var lower: String
    }

    /// Spec 11 §5, "Moving a break" — "a break drags to another line boundary,
    /// moving those lines from one chunk to its neighbor: one group of two
    /// `edit.cueChannel` edits. A break never passes a chunk's last line." And
    /// from the keyboard (G-48), Move Line to Previous Cue and Next Cue, a line
    /// at a time. `lines` is how far the break moves: down (positive), the
    /// lower chunk's first lines going up to the upper's end; up (negative), the
    /// upper chunk's last lines going down to the lower's start. Nil when it
    /// would take a chunk's last line, or moves nothing.
    public static func move(_ lines: Int, upper: TextSide, lower: TextSide, list: Int, channel: Int) -> Move? {
        guard lines != 0 else { return nil }
        let up = upper.lines
        let low = lower.lines
        let newUpper: [String]
        let newLower: [String]
        let giver: TextSide
        let receiver: TextSide
        if lines > 0 {
            guard lines < low.count else { return nil }
            newUpper = up + low.prefix(lines)
            newLower = Array(low.dropFirst(lines))
            giver = lower
            receiver = upper
        } else {
            guard -lines < up.count else { return nil }
            newUpper = Array(up.dropLast(-lines))
            newLower = up.suffix(-lines) + low
            giver = upper
            receiver = lower
        }
        let upperText = newUpper.joined(separator: "\n")
        let lowerText = newLower.joined(separator: "\n")
        let from = fields(of: giver, channel: channel)
        let giverText = giver.cue.uuid == upper.cue.uuid ? upperText : lowerText
        let receiverText = receiver.cue.uuid == upper.cue.uuid ? upperText : lowerText
        let giverEdit = body(giverText, of: giver, list: list, channel: channel)
        let receiverEdit = body(receiverText, of: receiver, from: from, list: list, channel: channel)
        let commands = (giverEdit?.commands ?? []) + (receiverEdit?.commands ?? [])
        guard !commands.isEmpty else { return nil }
        return Move(sending: Sending(commands), upper: upperText, lower: lowerText)
    }
}

/// Spec 11 §5, "Merge" — "The editor asks first when the second cue has
/// anything beyond its text on this channel (other commands, riders or
/// attribute writes on this channel, a trigger other than Go, an
/// advance-after or a note), or is the live or the armed cue: "Cue 5 also
/// writes channel 1 and runs macro 3. Merging removes them." Merge is never
/// the sheet's default."
public struct MergeQuestion: Equatable, Sendable {
    public enum Reason: Equatable, Sendable {
        case live
        case armed
        /// Writes or changes other channels, by number.
        case writes([Int])
        /// Runs macros, by number.
        case runs([Int])
        /// How many other commands it has: a stack, an output, a timer, a popup, the system.
        case otherCommands(Int)
        /// Riders or attribute writes on the editor's channel.
        case changes(channel: Int)
        case trigger
        case advanceAfter
        case note
    }

    /// The second cue's number, and the first's, which it is merged into.
    public var cue: Int
    public var into: Int
    public var reasons: [Reason]

    public init(cue: Int, into: Int, reasons: [Reason]) {
        self.cue = cue
        self.into = into
        self.reasons = reasons
    }

    /// The question a merge of `lower` into `into` asks on `channel`, or nil when it asks none.
    public static func of(_ lower: TextChunk, cue: Cue, into: Int, channel: Int) -> MergeQuestion? {
        var reasons: [Reason] = []
        if lower.isLive { reasons.append(.live) }
        if lower.isArmed { reasons.append(.armed) }
        var channels = Set<Int>()
        var macros: [Int] = []
        var others = 0
        for entry in cue.commands {
            let command = entry.command
            if let named = command.namedChannel {
                if named != channel { channels.insert(named) }
            } else if case .macro(let number) = command {
                if !macros.contains(number) { macros.append(number) }
            } else {
                others += 1
            }
        }
        if !channels.isEmpty { reasons.append(.writes(channels.sorted())) }
        if !macros.isEmpty { reasons.append(.runs(macros)) }
        if others > 0 { reasons.append(.otherCommands(others)) }
        let says = CueSays.about(channel, in: cue)
        var riders = Riders.none
        if case .write(_, let had) = says.state { riders = had }
        if riders != .none || !says.attributes.isEmpty { reasons.append(.changes(channel: channel)) }
        if cue.trigger.kind != .go { reasons.append(.trigger) }
        if cue.advanceAfterMs != nil { reasons.append(.advanceAfter) }
        if !cue.note.isEmpty { reasons.append(.note) }
        return reasons.isEmpty ? nil : MergeQuestion(cue: lower.number, into: into, reasons: reasons)
    }
}
