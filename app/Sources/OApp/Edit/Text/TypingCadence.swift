// OApp — Spec 11 §5 and Spec 5 §5, how often the text editor sends what is typed.

import Foundation

/// Spec 11 §5, "Typing" — "It sends at most four times a second while
/// typing, and once when the chunk loses the caret; the engine folds a
/// second of it into one edit and one undo step (Spec 5 §5)." And "Text
/// still being composed (an accent, dictation) isn't sent until it is
/// entered."
///
/// Area 10 reading: the first change after a quiet spell sends at once, so a
/// typed line shows on its thumbnail within a moment; the changes that follow
/// within a quarter second wait for the quarter's end, when the latest text
/// goes; leaving the chunk sends whatever hasn't gone. A chunk that holds its
/// typing back (Spec 11 §5, "Near the live cue") sends only when the caret
/// leaves it.
@MainActor
public final class TypingCadence {
    /// "at most four times a second".
    public static let interval: TimeInterval = 0.25

    private let clock: any AppClock
    /// Sends the chunk's whole text, and says whether anything went: an empty
    /// chunk sends nothing while typing, since "never ... an empty text write".
    private let send: @MainActor (String) -> Bool
    private var latest = ""
    private var sent = ""
    private var lastSentAt: TimeInterval?
    private var task: (any ClockTask)?
    private var composing = false

    /// Spec 11 §5, "Near the live cue" — "They send when the caret leaves them, not while typing".
    public var holdsBack = false {
        didSet {
            guard holdsBack != oldValue else { return }
            if holdsBack { cancel() } else { changed(latest, composing: composing) }
        }
    }

    public init(clock: any AppClock, send: @escaping @MainActor (String) -> Bool) {
        self.clock = clock
        self.send = send
    }

    /// The caret entered a chunk that reads `text`: "A chunk the caret passes
    /// through without typing sends nothing."
    public func start(_ text: String, holdsBack: Bool) {
        cancel()
        latest = text
        sent = text
        lastSentAt = nil
        composing = false
        self.holdsBack = holdsBack
    }

    /// The chunk's whole text changed, while the input method is or isn't still composing it.
    public func changed(_ text: String, composing: Bool) {
        latest = text
        self.composing = composing
        guard !composing, !holdsBack else { return }
        guard text != sent else {
            cancel()
            return
        }
        let now = clock.now
        if let at = lastSentAt, now - at < Self.interval {
            if task == nil {
                task = clock.after(at + Self.interval - now) { [weak self] in self?.due() }
            }
        } else {
            flush()
        }
    }

    /// The caret leaves the chunk: "once when the chunk loses the caret". True when something was sent.
    @discardableResult
    public func left() -> Bool {
        cancel()
        guard !composing, latest != sent else { return false }
        return flush()
    }

    /// What was typed and hasn't gone, or nil.
    public var unsent: String? {
        latest == sent || composing ? nil : latest
    }

    /// The text last sent, or the chunk's text when the caret entered it.
    public var lastSent: String { sent }

    /// When the last send went, on the app's clock.
    public var lastSentTime: TimeInterval? { lastSentAt }

    private func due() {
        task = nil
        guard !composing, !holdsBack, latest != sent else { return }
        flush()
    }

    @discardableResult
    private func flush() -> Bool {
        cancel()
        guard send(latest) else { return false }
        sent = latest
        lastSentAt = clock.now
        return true
    }

    private func cancel() {
        task?.cancel()
        task = nil
    }
}
