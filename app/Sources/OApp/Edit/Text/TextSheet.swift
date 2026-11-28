// OApp — Spec 11 §5, "The sheet view" (G-50): the Text page's document as one field of text.

import Foundation

/// Spec 11 §5, "The sheet view" (Adam, 2026-11-28, G-50) — "the same
/// document as one field of text, as a printed lyric sheet reads". The
/// field's text is each cue's lines one after another, one line break
/// between two cues; where each cue's text lies in it is a `Segment`, so an
/// edit of the field is read as an edit of one cue. A cue that clears or
/// holds the channel is an empty line; other content is a line naming it,
/// not editable. Positions are UTF-16 units, as a text view counts them.
public struct TextSheet: Equatable, Sendable {
    public struct Segment: Equatable, Sendable {
        /// The cue's uuid, in lower case; `TextEditor.emptyChunk` for an empty list's one line.
        public var cue: String
        /// "its number in the margin at its first line"; 0 for a line that has no cue (an empty list's, a removed cue's).
        public var number: Int
        /// "a section's label in the margin at its first cue", and its hue.
        public var section: String?
        public var hue: Int?
        /// "with a blank line before each new section".
        public var gapBefore: Bool
        public var text: String
        public var isEditable: Bool
        public var isLive = false
        public var holdsBack = false
        /// Where the cue's text lies in the field.
        public var location: Int
        public var length: Int

        public var range: NSRange { NSRange(location: location, length: length) }
        public var end: Int { location + length }
    }

    public var segments: [Segment]

    public init(segments: [Segment] = []) {
        self.segments = segments
        place()
    }

    /// The field's text: each segment's, one line break between two.
    public var string: String { segments.map(\.text).joined(separator: "\n") }

    /// Sets each segment's place from the texts before it.
    private mutating func place() {
        var at = 0
        for index in segments.indices {
            segments[index].location = at
            segments[index].length = (segments[index].text as NSString).length
            at += segments[index].length + 1
        }
    }

    /// The sheet of a document. `text` gives an editable chunk's text as the
    /// field shows it (the caret's as typed); `row` an other-content chunk's
    /// line ("Video: Ocean loop"). An empty list is one line, `empty`'s text;
    /// a removed cue's text stays where it stood (`removed`).
    public static func make(document: TextDocument, text: (TextChunk) -> String, row: (TextChunk) -> String,
                            empty: String? = nil, removed: RemovedChunk? = nil) -> TextSheet {
        var segments: [Segment] = []
        for (index, chunk) in document.chunks.enumerated() {
            var segment = Segment(cue: chunk.cue, number: chunk.number, section: chunk.startsRun ? chunk.section : nil, hue: chunk.hue,
                                  gapBefore: chunk.startsRun && index > 0, text: chunk.isEditable ? text(chunk) : row(chunk),
                                  isEditable: chunk.isEditable, location: 0, length: 0)
            segment.isLive = chunk.isLive
            segment.holdsBack = chunk.holdsBack
            segments.append(segment)
        }
        if let removed {
            let ghost = Segment(cue: removed.cue, number: 0, section: nil, hue: nil, gapBefore: false, text: removed.text, isEditable: true,
                                location: 0, length: 0)
            segments.insert(ghost, at: min(max(0, removed.index), segments.count))
        }
        if segments.isEmpty, let empty {
            segments = [Segment(cue: "", number: 0, section: nil, hue: nil, gapBefore: false, text: empty, isEditable: true,
                                location: 0, length: 0)]
        }
        return TextSheet(segments: segments)
    }

    /// The segment a place in the field belongs to: its text and its end,
    /// so the place just before a line break belongs to the cue above it.
    public func index(at location: Int) -> Int? {
        segments.firstIndex { location >= $0.location && location <= $0.end }
    }

    /// The segment of a cue.
    public func index(of cue: String) -> Int? {
        segments.firstIndex { $0.cue == cue }
    }

    /// What an edit of the field is.
    public enum Change: Equatable, Sendable {
        /// Typing within one cue: its whole new text.
        case edit(index: Int, text: String)
        /// "Backspace or forward Delete at a dashed line merges, as at a chunk's edge": the lower cue joins the upper.
        case merge(lower: Int)
        /// "typing, Delete, Cut or Paste over a selection that crosses a cue's dashed line does nothing and says
        /// "Select within one cue.""
        case refused
        /// An edit of a line of other content, or a merge into one: it does nothing ("None reaches into a row of
        /// other content").
        case ignored
    }

    /// Reads an edit of the field: `range` replaced with `replacement`.
    public func change(in range: NSRange, with replacement: String) -> Change {
        guard let first = index(at: range.location) else { return .refused }
        // The line break between two cues, deleted alone: a merge.
        if range.length == 1, replacement.isEmpty, range.location == segments[first].end, first + 1 < segments.count {
            return segments[first].isEditable && segments[first + 1].isEditable ? .merge(lower: first + 1) : .ignored
        }
        guard range.location + range.length <= segments[first].end else { return .refused }
        let segment = segments[first]
        guard segment.isEditable else { return .ignored }
        let local = NSRange(location: range.location - segment.location, length: range.length)
        let text = (segment.text as NSString).replacingCharacters(in: local, with: replacement)
        return .edit(index: first, text: text)
    }

    /// The sheet after an edit of one cue's text: the segments after it move along.
    public mutating func apply(index: Int, text: String) {
        guard segments.indices.contains(index) else { return }
        segments[index].text = text
        place()
    }

    /// What Copy gives for a selection: its text, a blank line where it crosses
    /// from one cue to the next, so it pastes back as the same cues (Area 10 reading).
    public func copied(_ range: NSRange) -> String {
        var parts: [String] = []
        for segment in segments {
            let lower = max(range.location, segment.location)
            let upper = min(range.location + range.length, segment.end)
            guard upper > lower || (upper == lower && range.length == 0) else { continue }
            parts.append((segment.text as NSString).substring(with: NSRange(location: lower - segment.location, length: upper - lower)))
        }
        return parts.joined(separator: "\n\n")
    }
}
