// OCore — Spec 3 §3, tracking rules.

/// Spec 3 §3 — the result of one attribute's rider or fall-back.
struct TrackedChange<Value: Equatable> {
    var changed: Bool
    var old: Value
    var new: Value
}

extension Fold {
    /// Spec 3 §3 rule 7 — "With tracking off, every write of that attribute
    /// behaves as `once` regardless of its stored scope."
    func effectiveScope(_ scope: Scope, trackingOn: Bool) -> Scope {
        trackingOn ? scope : .once
    }

    /// Spec 3 §3 rule 3 — the fall-back a `once` value keeps as `shadow`:
    /// "the previous tracked value if one exists, else the default."
    func shadow<V>(for current: Tracked<V>) -> V? {
        switch current.origin {
        case .tracked: return current.value
        case .once: return current.shadow
        case .default: return nil
        }
    }

    /// Spec 3 §3 rules 2 and 3 — apply a rider (`track` holds, `once` keeps
    /// a shadow) or, with no rider and a content change, let a `once` value
    /// fall back. Returns whether the stored attribute changed and the value
    /// before and after.
    func applyRider<V>(_ tracked: inout Tracked<V>, value: V?, scope: Scope?, trackingOn: Bool,
                       contentChanged: Bool, defaultValue: V) -> TrackedChange<V> {
        let old = tracked
        if let value, let scope {
            switch effectiveScope(scope, trackingOn: trackingOn) {
            case .track:
                tracked = Tracked(value: value, origin: .tracked, shadow: nil)
            case .once:
                tracked = Tracked(value: value, origin: .once, shadow: shadow(for: old))
            }
        } else if contentChanged, old.origin == .once {
            // Spec 3 §3 rule 3 — "When the content next changes without its
            // own rider for that attribute, the attribute falls back."
            if let fallback = old.shadow {
                tracked = Tracked(value: fallback, origin: .tracked, shadow: nil)
            } else {
                tracked = Tracked(value: defaultValue, origin: .default, shadow: nil)
            }
        }
        return TrackedChange(changed: tracked != old, old: old.value, new: tracked.value)
    }

    /// Spec 3 §3 — apply every rider of a write to a channel's attributes and
    /// let the riderless `once` values fall back when the content changed.
    /// Emits one `attribute` effect per changed value (Spec 3 §6). Returns
    /// whether any stored attribute changed.
    mutating func applyRiders(_ riders: Riders, to channel: inout ChannelState, number: Int,
                              contentChanged: Bool) -> Bool {
        let defaults = defaults(for: number)
        let tracking = context.machine.tracking
        var changed = false

        let grade = applyRider(&channel.attributes.grade, value: riders.grade?.ref, scope: riders.grade?.scope,
                               trackingOn: tracking.grade, contentChanged: contentChanged, defaultValue: 0)
        if grade.changed { changed = true }
        if grade.old != grade.new {
            effects.append(.attribute(channel: number, attribute: .grade, old: .grade(grade.old), new: .grade(grade.new),
                                      ms: riders.grade?.ms))
        }

        let transition = applyRider(&channel.attributes.transition,
                                    value: riders.transition.map { TransitionSetting(ref: $0.ref, ms: $0.ms) },
                                    scope: riders.transition?.scope, trackingOn: tracking.transition,
                                    contentChanged: contentChanged, defaultValue: TransitionSetting(ref: defaults.transition))
        if transition.changed { changed = true }
        if transition.old != transition.new {
            effects.append(.attribute(channel: number, attribute: .transition,
                                      old: .transition(transition.old), new: .transition(transition.new), ms: nil))
        }

        let audio = applyRider(&channel.attributes.audioTransition,
                               value: riders.audioTransition.map { TransitionSetting(ref: $0.ref, ms: $0.ms) },
                               scope: riders.audioTransition?.scope, trackingOn: tracking.audioTransition,
                               contentChanged: contentChanged, defaultValue: TransitionSetting(ref: defaults.audioTransition))
        if audio.changed { changed = true }
        if audio.old != audio.new {
            effects.append(.attribute(channel: number, attribute: .audioTransition,
                                      old: .audioTransition(audio.old), new: .audioTransition(audio.new), ms: nil))
        }

        let gain = applyRider(&channel.attributes.gain, value: riders.gain?.db, scope: riders.gain?.scope,
                              trackingOn: tracking.gain, contentChanged: contentChanged, defaultValue: defaults.gain)
        if gain.changed { changed = true }
        if gain.old != gain.new {
            effects.append(.attribute(channel: number, attribute: .gain, old: .gain(gain.old), new: .gain(gain.new), ms: nil))
        }

        let chase = applyRider(&channel.attributes.chase, value: riders.chase.map { _ in true }, scope: riders.chase?.scope,
                               trackingOn: tracking.chase, contentChanged: contentChanged, defaultValue: false)
        if chase.changed { changed = true }
        if chase.old != chase.new {
            effects.append(.attribute(channel: number, attribute: .chase, old: .chase(chase.old), new: .chase(chase.new), ms: nil))
        }

        return changed
    }

    /// Spec 3 §3 rule 6 and §5 — reset one channel's attributes to
    /// `{default, origin: default}`, emitting an `attribute` effect for every
    /// value that changes. Returns whether anything changed.
    mutating func resetAttributes(of number: Int) -> Bool {
        guard var channel = state.channels[number] else { return false }
        let old = channel.attributes
        let new = ChannelAttributes.defaults(for: defaults(for: number))
        guard old != new else { return false }
        channel.attributes = new
        state.channels[number] = channel
        if old.grade.value != new.grade.value {
            effects.append(.attribute(channel: number, attribute: .grade, old: .grade(old.grade.value), new: .grade(new.grade.value), ms: nil))
        }
        if old.transition.value != new.transition.value {
            effects.append(.attribute(channel: number, attribute: .transition,
                                      old: .transition(old.transition.value), new: .transition(new.transition.value), ms: nil))
        }
        if old.audioTransition.value != new.audioTransition.value {
            effects.append(.attribute(channel: number, attribute: .audioTransition,
                                      old: .audioTransition(old.audioTransition.value), new: .audioTransition(new.audioTransition.value), ms: nil))
        }
        if old.gain.value != new.gain.value {
            effects.append(.attribute(channel: number, attribute: .gain, old: .gain(old.gain.value), new: .gain(new.gain.value), ms: nil))
        }
        if old.chase.value != new.chase.value {
            effects.append(.attribute(channel: number, attribute: .chase, old: .chase(old.chase.value), new: .chase(new.chase.value), ms: nil))
        }
        return true
    }

    /// Spec 3 §3 rule 4 — "every tracked attribute on every channel returns to
    /// `{default, origin: default}`". Resolved question: "a boundary clears
    /// both value and shadow."
    mutating func resetAllAttributes() {
        for number in state.channels.keys.sorted() {
            _ = resetAttributes(of: number)
        }
    }
}
