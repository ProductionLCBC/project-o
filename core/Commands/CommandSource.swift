// OCore — Spec 2 §5, sources.

import Foundation

/// Spec 2 §5 — every command "is tagged with its source for the log and for
/// lock decisions". `engine` covers commands the engine issues to itself.
public enum SourceKind: String, Codable, Equatable, Sendable {
    case ui, key, osc, midi, streamdeck, macro, cue, timeline, scheduler
    case startup, shutdown, commandbar, api, restore, engine

    /// Spec 3 §8 — "With `source.kind` of `cue` or `timeline`, a `write`,
    /// `clear` or tracked attribute write to a locked channel produces a
    /// `blocked` effect."
    public var isSubjectToLock: Bool {
        self == .cue || self == .timeline
    }
}

/// Spec 2 §9 — the `source` record of a log entry: `{kind, list, cue,
/// playlist}`, plus the macro number for `macro` sources (Spec 2 §5).
public struct CommandSource: Codable, Equatable, Sendable {
    public var kind: SourceKind
    public var list: UUID?
    public var cue: UUID?
    public var playlist: UUID?
    public var macro: Int?

    public init(kind: SourceKind, list: UUID? = nil, cue: UUID? = nil, playlist: UUID? = nil, macro: Int? = nil) {
        self.kind = kind
        self.list = list
        self.cue = cue
        self.playlist = playlist
        self.macro = macro
    }
}
