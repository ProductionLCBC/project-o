// OApp — Spec 10 §9, the command bar: a line of canonical text, sent as a command.

import Foundation
import OCore

/// Spec 10 §9, "The command bar" — "off by default (`commandBar`), is a
/// field across the top of the center when on. ⌘K focuses it. As the
/// operator types, it shows the canonical form, or the error, from OCore's
/// parser (Spec 2 §4); Return sends the command with source `commandbar`
/// and shows the result or the rejection beside it; ↑ and ↓ recall the last
/// fifty commands of the run."
public struct CommandBar: Equatable, Sendable {
    /// "the last fifty commands of the run": kept in memory, gone when the app quits (Area 13 reading).
    public static let historyLimit = 50

    /// What the bar shows under the text as it is typed.
    public enum Preview: Equatable, Sendable {
        case empty
        /// The command as the parser read it, in canonical text.
        case canonical(String)
        /// The parser's own sentence for why the text isn't a command.
        case error(String)
    }

    /// What became of the last command sent.
    public enum Outcome: Equatable, Sendable {
        /// Sent, and not answered yet.
        case sent
        case result(ResultKind)
        /// Refused, with the engine's own sentence (Area 13 reading: the command bar shows it as it came).
        case rejected(String)
        /// It didn't go, or the connection closed before an answer: the engine is away.
        case engineAway
    }

    public private(set) var text = ""
    public private(set) var preview: Preview = .empty
    /// The last command sent, in canonical text, and what became of it.
    public private(set) var last: String?
    public private(set) var outcome: Outcome?
    /// The commands sent this run, oldest first, in canonical text.
    public private(set) var history: [String] = []
    private var parsed: GuardedCommand?
    /// Where ↑ and ↓ stand in the history, and what was being typed when they began.
    private var recalled: Int?
    private var draft = ""

    public init() {}

    /// The text changed. `mediaIDs` are the pool's, so a hash may be typed
    /// by its first twelve characters (Spec 2 §4).
    public mutating func type(_ text: String, mediaIDs: Set<String> = []) {
        self.text = text
        recalled = nil
        read(mediaIDs: mediaIDs)
    }

    private mutating func read(mediaIDs: Set<String>) {
        guard !text.allSatisfy(\.isWhitespace) else {
            parsed = nil
            preview = .empty
            return
        }
        switch CommandText.parse(text, options: ParseOptions(mediaIDs: mediaIDs)) {
        case .success(let command):
            parsed = command
            preview = .canonical(CommandText.print(command) ?? command.command.cmd)
        case .failure(let rejection):
            parsed = nil
            preview = .error(rejection.message)
        }
    }

    /// Return: the command to send, or nil when the text isn't one. A
    /// command that goes is remembered and the field emptied; text that
    /// doesn't parse stays, with its error.
    public mutating func submit() -> GuardedCommand? {
        guard let command = parsed, case .canonical(let canonical) = preview else { return nil }
        history.append(canonical)
        if history.count > Self.historyLimit { history.removeFirst(history.count - Self.historyLimit) }
        last = canonical
        outcome = .sent
        text = ""
        parsed = nil
        preview = .empty
        recalled = nil
        draft = ""
        return command
    }

    /// The engine answered the command sent last, or didn't.
    public mutating func answered(_ reply: Reply?) {
        guard let result = reply?.outcome else {
            outcome = .engineAway
            return
        }
        if result.kind == .rejected {
            outcome = .rejected(result.rejection?.message ?? result.rejection?.code ?? "")
        } else {
            outcome = .result(result.kind)
        }
    }

    /// ↑ (`earlier`) or ↓: the text the field now holds. ↑ at the oldest
    /// stays there; ↓ past the newest gives back what was being typed.
    public mutating func recall(earlier: Bool, mediaIDs: Set<String> = []) {
        guard !history.isEmpty else { return }
        if earlier {
            if let index = recalled {
                recalled = max(0, index - 1)
            } else {
                draft = text
                recalled = history.count - 1
            }
        } else {
            guard let index = recalled else { return }
            recalled = index + 1 < history.count ? index + 1 : nil
        }
        text = recalled.map { history[$0] } ?? draft
        read(mediaIDs: mediaIDs)
    }
}
