// OCore — Spec 3 §6, effects.

import Foundation

/// Spec 3 §6 — the `attribute` effect names which tracked attribute changed.
public enum ChannelAttribute: String, Codable, Equatable, Sendable {
    case grade, transition, audioTransition, gain, chase
}

/// Spec 3 §6 — the old and new value an `attribute` effect carries.
public enum AttributeValue: Equatable, Sendable {
    case grade(Int)
    case transition(TransitionSetting)
    case audioTransition(TransitionSetting)
    case gain(Double)
    case chase(Bool)
}

/// Spec 3 §6 — the `transition` effect: "channel, from instance, to instance,
/// transition ref, ms, audio transition ref, ms, offset". `restart` is the
/// §9 row 2 mark: the same media written again "is a dissolve from the current
/// frame rather than from the previous content" (§4).
public struct TransitionEffect: Equatable, Sendable {
    public var channel: Int
    public var from: ContentInstance
    public var to: ContentInstance
    public var transition: Int
    public var ms: Int
    public var audioTransition: Int
    public var audioMs: Int
    public var audioOffsetMs: Int
    public var restart: Bool

    public init(channel: Int, from: ContentInstance, to: ContentInstance, transition: Int, ms: Int,
                audioTransition: Int, audioMs: Int, audioOffsetMs: Int = 0, restart: Bool = false) {
        self.channel = channel
        self.from = from
        self.to = to
        self.transition = transition
        self.ms = ms
        self.audioTransition = audioTransition
        self.audioMs = audioMs
        self.audioOffsetMs = audioOffsetMs
        self.restart = restart
    }
}

/// Spec 3 §6 and §10 — `Effect`: "what the engine and the UI act on. They are
/// the only output besides the new state." One case per row of the §6 table.
public enum Effect: Equatable, Sendable {
    /// Engine starts the visual and audio transitions.
    case transition(TransitionEffect)
    /// Engine animates the slide from one build to another (nil is final).
    case build(channel: Int, from: Int?, to: Int?)
    /// Engine applies the gain, or interpolates the grade over ms; UI updates chips.
    case attribute(channel: Int, attribute: ChannelAttribute, old: AttributeValue, new: AttributeValue, ms: Int?)
    /// Engine runs the output's switch transition.
    case stackSwitch(output: Int, old: Int, new: Int, transition: Int?)
    /// Engine runs the blackout transition of the first output showing the stack.
    case blackout(stack: Int, old: Bool, new: Bool, transition: Int?)
    /// Engine mutes or unmutes one channel's slot in a stack.
    case mute(stack: Int, channel: Int, old: Bool, new: Bool)
    /// Engine re-rasterizes affected boxes. `clearAfterMs` is the popup's
    /// `clearafter`, carried for the scheduler since it is not state.
    case variable(popup: Int, text: String?, clearAfterMs: Int?)
    /// UI shows the reset in the strip. `reset` is false when the list
    /// entered has `trackThrough`.
    case boundary(list: UUID, reset: Bool)
    /// UI moves the live marker; the scheduler arms or disarms its timer.
    case pointer(old: LivePointer?, new: LivePointer?, armed: ArmedTrigger?)
    /// Engine cuts the content; strip flashes; log records it.
    case steppedOn(channel: Int, dropped: String)
    /// Log records it; the strip shows a lock glint.
    case blocked(channel: Int, command: Command)
    /// The command changed state only, with nothing to animate (transport,
    /// end behaviour, lock, freeze); the engine reads the new state. Logged
    /// as `ok`. Addition flagged for the spec: §6 wants one result per
    /// command, and these verbs have no row in its effects table.
    case applied(Command)
    /// Nothing, but logged.
    case noop(Command)
    /// The caller (engine, history, scheduler) handles it.
    case passthrough(Command)

    public var isNoop: Bool {
        if case .noop = self { return true }
        return false
    }

    public var transitionEffect: TransitionEffect? {
        if case .transition(let t) = self { return t }
        return nil
    }
}
