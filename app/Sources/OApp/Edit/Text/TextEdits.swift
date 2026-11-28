// OApp — Spec 11 §5, what the text editor's typing sends.

import Foundation
import OCore

/// Spec 11 §5 — the text editor's edits, each one function returning one
/// edit or one group, source `ui`, as Spec 11 §1 has every page's: "A
/// control sends one Spec 5 edit, or one group of them, when it commits; the
/// app writes nothing in the roots". Nil when there is nothing to send.
public enum TextEdits {
    /// Spec 11 §5, "Typing" — "one `edit.cueChannel` for that cue and
    /// channel: the chunk's whole body, with the rest of what the cue says
    /// about the channel (its other fields, its riders, its attribute writes)
    /// as the latest `library` event left it ... never ... an empty text
    /// write". On held text, "a copy of the held write with the typing in its
    /// body"; "Over held media ... or nothing, the write is only what was
    /// typed" (R5), beside the cue's own attribute writes. `cue` is the cue as
    /// the store holds it now.
    public static func typing(_ body: String, chunk: TextChunk, cue: Cue, list: Int, channel: Int) -> Sending? {
        guard !body.isEmpty else { return nil }
        switch chunk.kind {
        case .other:
            return nil
        case .heldText(_, _, var fields, let riders):
            // The store may hold the copy already, the first send having landed: then it is that write edited.
            if case .write(.text, _) = CueSays.about(channel, in: cue).state { return edited(body, cue: cue, list: list, channel: channel) }
            fields["body"] = body
            return CueEdits.write(.text(fields: fields), riders: riders, channel: channel, cue: cue, list: list)
        case .write, .clear, .holdsNothing, .heldOther:
            return edited(body, cue: cue, list: list, channel: channel)
        }
    }

    /// The cue's text write with a new body, its other fields and riders kept; a
    /// write of the body alone where the cue writes no text on the channel.
    private static func edited(_ body: String, cue: Cue, list: Int, channel: Int) -> Sending? {
        var fields: [String: String] = [:]
        if case .write(.text(let had), _) = CueSays.about(channel, in: cue).state { fields = had }
        fields["body"] = body
        return CueEdits.write(.text(fields: fields), channel: channel, cue: cue, list: list)
    }

    /// Spec 11 §5, "Typing" — "A chunk left empty is a clear (R5): the editor
    /// sends the clear when the chunk loses the caret empty, keeping the
    /// write's `track` riders as standalone attribute writes as the Cues page
    /// does (§4)". Nil when the cue clears the channel already.
    public static func emptied(cue: Cue, list: Int, channel: Int) -> Sending? {
        switch CueSays.about(channel, in: cue).state {
        case .clear, .write(.empty, _): return nil
        default: return CueEdits.clear(channel: channel, cue: cue, list: list)
        }
    }

    /// Spec 11 §5, "The right column" — "Hold, which returns the channel to
    /// hold on that cue, keeping `track` riders as §4 says".
    public static func hold(cue: Cue, list: Int, channel: Int) -> Sending? {
        CueEdits.hold(channel: channel, cue: cue, list: list)
    }

    /// A new cue as the editor makes it: a Go trigger, an empty note, the
    /// label and section given, and on `channel` the write given or nothing.
    public static func newCue(uuid: UUID, label: String = "", section: String?, write: ChannelWrite?) -> Cue {
        Cue(uuid: uuid, label: label, section: section.flatMap { $0.isEmpty ? nil : $0 },
            commands: write.map { [GuardedCommand(.channelWrite($0))] } ?? [])
    }

    /// `edit list L insert cues K {…}` for a cue the editor made, "with a uuid
    /// the app makes, so a group can name the cue it inserts" (Spec 11 §4).
    public static func insert(_ cue: Cue, at position: Int, list: Int) -> Command {
        let value = (try? JSONCoding.encode(cue)) ?? .null
        return .edit(EditCommand(.list(list), .insert(path: "cues", at: position, value: value)))
    }

    /// Spec 11 §5, "An empty list" — "The first character typed creates the
    /// first cue and its write as one group, and typing goes on from there."
    /// One insert, the write inside the cue it makes.
    public static func firstCue(uuid: UUID, body: String, list: Int, channel: Int) -> Sending? {
        guard !body.isEmpty else { return nil }
        let write = ChannelWrite(channel: .number(channel), content: .text(fields: ["body": body]))
        return Sending([insert(newCue(uuid: uuid, section: nil, write: write), at: 0, list: list)])
    }
}
