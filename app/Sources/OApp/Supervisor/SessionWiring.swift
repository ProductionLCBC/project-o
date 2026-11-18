// OApp — Spec 10 §2, which engine the window drives: the session its actions go through, by where the app stands with the engine.

import Foundation
import OCore

/// Spec 10 §2 — ties what sends to the engine it can send to. A session with
/// an engine carries the window's actions, the lists it holds, the Mach
/// channel's name and ⌃⌥⌘⎋'s `releaseScreen`; where the app stands with the
/// engine (the supervisor's phase) says which of those are live.
///
/// - **Connected:** all of them.
/// - **Not responding:** the session is open and the engine silent. "every
///   control that sends something is disabled with the reason, and a press
///   or a key is dropped", never left in the socket to land in a burst when
///   the engine wakes (Spec 10 §2, "When it doesn't answer", as Adam
///   answered at Area 13's third stop). ⌃⌥⌘⎋ still asks: its request is the
///   one that must wait (Spec 10 §9). When the engine answers again, the
///   window drives it again.
/// - **Anything else:** the engine is away. "every control that sends
///   something is disabled, and a key that would send a command is dropped,
///   never queued."
@MainActor
public final class SessionWiring {
    private let model: ShowModel
    private let mach: MachLink
    private let releaser: ScreenReleaser
    private var session: EngineSession?

    public init(model: ShowModel, mach: MachLink, releaser: ScreenReleaser) {
        self.model = model
        self.mach = mach
        self.releaser = releaser
    }

    /// A session with an engine has started (the supervisor's `onConnected`).
    public func connected(_ session: EngineSession) {
        self.session = session
        drive(session)
        releaser.transmit = { [weak session] request, answer in
            guard let session else { return answer(nil) }
            session.send(request, completion: answer)
        }
        // Spec 10 §9 — the app "sends `releaseScreen` again to any engine it connects to".
        releaser.connected()
    }

    private func drive(_ session: EngineSession) {
        model.transmit = { [weak session] request, answer in
            guard let session else { return answer(nil) }
            session.send(request, completion: answer)
        }
        model.hold = { [weak session] lists in session?.hold(lists: lists) }
        mach.connect(name: session.hello.mach)
    }

    /// Where the app stands with the engine changed (the supervisor's `onPhase`).
    public func phaseChanged(_ phase: EngineSupervisor.Phase) {
        switch phase {
        case .connected:
            // The engine answers again after a silence. (At a new connection the session comes a moment after the
            // phase, and `connected` does this.)
            model.store.silent(false)
            if model.transmit == nil, let session, session.isOpen { drive(session) }
        case .notResponding:
            // The store says so, and with it every control that sends shows disabled with the reason (Spec 10 §2).
            model.store.silent(true)
            model.transmit = nil
            mach.disconnect()
        default:
            model.transmit = nil
            mach.disconnect()
            releaser.transmit = nil
            session = nil
        }
    }
}
