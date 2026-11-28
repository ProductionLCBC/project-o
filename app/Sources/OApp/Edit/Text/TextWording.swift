// OApp — Spec 11 §5 and §10, the text editor in words: what the operator reads and what VoiceOver says.

import Foundation
import OCore

/// Spec 11 §10 — "Every string is in the app's catalog (Spec 10 §15)": the
/// text editor's models become text here, and the views compose nothing.
@MainActor
public enum TextWording {
    /// What a chunk with no text of its own says, or nil when it has text or is a row of other content.
    public static func placeholder(_ chunk: TextChunk) -> String? {
        switch chunk.kind {
        case .clear: return Strings.text(.textClears)
        case .holdsNothing: return Strings.text(.textHoldsNothing)
        case .heldOther(let held): return Strings.text(.textHolds, Self.content(held))
        case .write, .heldText, .other: return nil
        }
    }

    /// "Other content written on this channel (media, a slide, an input): a row naming it ("Video: Ocean loop")".
    public static func content(_ content: CueGridContent) -> String {
        switch content {
        case .media(_, let tile?): return Strings.text(.textContent, ShowWording.kind(tile.kind), tile.name)
        case .media(_, nil): return Strings.text(.textContent, Strings.text(.kindVideo), Strings.text(.editCellMissing))
        case .text(let text):
            let first = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? text
            return Strings.text(.textContent, Strings.text(.kindText), first)
        case .slide: return Strings.text(.kindSlide)
        case .input(let input): return Strings.text(.editCellInput, input)
        }
    }

    /// The row a chunk of other content shows.
    public static func row(_ chunk: TextChunk) -> String? {
        if case .other(let shown) = chunk.kind { return Self.content(shown) }
        return nil
    }

    /// An item of the channel picker: "Channel 2 · Foreground".
    public static func channel(_ channel: Channel) -> String {
        Strings.text(.textChannel, channel.number, channel.label)
    }

    /// Spec 11 §10 — "the caret entering a chunk announces its cue ("Cue 4,
    /// Chorus")": its number with its section, else its label.
    public static func spoken(_ chunk: TextChunk) -> String {
        let name = chunk.section ?? (chunk.label.isEmpty ? nil : chunk.label)
        return name.map { Strings.text(.textCueSpoken, chunk.number, $0) } ?? Strings.text(.textCueSpokenPlain, chunk.number)
    }

    /// The tag a chunk carries, if any: the confidence screen's hold, a change from elsewhere, a removed cue.
    public static func tags(_ chunk: TextChunk, editor: TextEditor) -> [String] {
        var tags: [String] = []
        if chunk.holdsBack { tags.append(Strings.text(.textConfidence)) }
        if editor.caret == chunk.cue, editor.changedElsewhere { tags.append(Strings.text(.textChangedElsewhere)) }
        return tags
    }
}
