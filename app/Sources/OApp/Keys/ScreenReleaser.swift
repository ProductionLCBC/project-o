// OApp — Spec 10 §9, the fixed key ⌃⌥⌘⎋: taking every output off the screen that holds the app's window.

import Foundation
import OCore

/// Spec 10 §9, "Fixed keys" — "⌃⌥⌘⎋ (R6) takes every output off the screen
/// that holds the app's window, lock or not. ... At once, before the engine
/// answers, the app raises its main window one level above the outputs on
/// that screen; then it sends `releaseScreen` with that screen, and the
/// engine closes those outputs' windows, reports them `released` (§3) and
/// logs a `screenReleased` note, and the window drops back to its level. If
/// the engine doesn't answer within two seconds, the window stays raised
/// with the not-responding banner (§2), so the way back holds even with the
/// engine stuck. The app remembers the screens it released while it runs,
/// names them with `--released` to each engine it starts (§2), and sends
/// `releaseScreen` again to any engine it connects to."
///
/// The window is raised for as long as a release hasn't been answered `ok`
/// (Area 13 reading): with no engine to ask, or one that refuses, it stays
/// raised, since an engine that isn't answering may still have its windows
/// up; the answer to the `releaseScreen` sent to the next engine drops it.
@MainActor
public final class ScreenReleaser {
    /// "If the engine doesn't answer within two seconds".
    public static let patience: TimeInterval = 2

    private let clock: any AppClock
    /// The screens released this run, as `display:<uuid>`, in the order they were released.
    public private(set) var released: [String] = []
    /// The screens whose release no engine has answered yet.
    public private(set) var waiting: Set<String> = []

    /// How a request reaches the engine; nil while none is connected.
    public var transmit: ((EngineRequest, @escaping (Reply?) -> Void) -> Void)?
    /// Called when the window should go above the outputs, or drop back to its level.
    public var onRaised: ((Bool) -> Void)?
    /// Called when a connected engine has left a release unanswered for two seconds.
    public var onSilent: (() -> Void)?

    public init(clock: any AppClock) {
        self.clock = clock
    }

    /// Whether the main window stands above the outputs.
    public var isRaised: Bool { !waiting.isEmpty }

    /// The key was pressed, or Help ▸ Release Output from This Screen chosen, with the window on `screen`.
    public func release(screen: String) {
        if !released.contains(screen) { released.append(screen) }
        // "At once, before the engine answers".
        let wasRaised = isRaised
        waiting.insert(screen)
        if !wasRaised { onRaised?(true) }
        send(screen)
    }

    /// An engine connected: "sends `releaseScreen` again to any engine it connects to".
    public func connected() {
        for screen in released { send(screen) }
    }

    private func send(_ screen: String) {
        guard let transmit else { return }
        let answer = Answered()
        transmit(.releaseScreen(screen)) { [weak self] reply in
            // Any answer says the engine is there; only `ok` says the outputs are off the screen.
            answer.arrived = reply != nil
            guard let self, reply?.outcome?.kind == .ok else { return }
            self.answered(screen)
        }
        clock.after(Self.patience) { [weak self] in
            guard let self, !answer.arrived, self.waiting.contains(screen), self.transmit != nil else { return }
            self.onSilent?()
        }
    }

    private final class Answered {
        var arrived = false
    }

    private func answered(_ screen: String) {
        guard waiting.remove(screen) != nil, waiting.isEmpty else { return }
        onRaised?(false)
    }
}
