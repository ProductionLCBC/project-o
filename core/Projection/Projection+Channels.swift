// OCore — Spec 3 §4, write semantics and the channel verbs.

extension Fold {
    // MARK: - Transition selection

    /// Spec 3 §4 — "The effect's transition is, in order: the write's `once`
    /// rider, else the channel's current transition attribute (tracked or
    /// default). A `cut` emits a transition effect with zero duration."
    /// A `track` rider has already become the attribute by the time the
    /// effect is built, so any rider wins here.
    ///
    /// Spec 1 §8 — a reference to a transition that does not exist degrades to
    /// "the channel default transition", as that transition is defined (its own
    /// duration, not the rider's); when the channel default is missing too, to
    /// a zero-second cut (Adam, Area 2 review), which Spec 3 §4 defines as the
    /// zero-duration effect. The ref carried is the one that plays, or the one
    /// the cue asked for when nothing does.
    func selectTransition(rider: TransitionRider?, attribute: Tracked<TransitionSetting>, channel number: Int) -> (ref: Int, ms: Int) {
        let setting = rider.map { TransitionSetting(ref: $0.ref, ms: $0.ms) } ?? attribute.value
        if let object = context.library.transition(setting.ref) {
            return (setting.ref, max(0, setting.ms ?? object.ms))
        }
        let fallback = defaults(for: number).transition
        if let object = context.library.transition(fallback) {
            return (fallback, max(0, object.ms))
        }
        return (setting.ref, 0)
    }

    /// Spec 3 §4 — "The same order applies to the audio transition." A missing
    /// audio transition degrades the same way: the channel's default audio
    /// transition as defined, else a zero-second cut with no offset.
    func selectAudioTransition(rider: TransitionRider?, attribute: Tracked<TransitionSetting>, channel number: Int) -> (ref: Int, ms: Int, offsetMs: Int) {
        let setting = rider.map { TransitionSetting(ref: $0.ref, ms: $0.ms) } ?? attribute.value
        if let object = context.library.audioTransition(setting.ref) {
            return (setting.ref, max(0, setting.ms ?? object.ms), object.offsetMs)
        }
        let fallback = defaults(for: number).audioTransition
        if let object = context.library.audioTransition(fallback) {
            return (fallback, max(0, object.ms), object.offsetMs)
        }
        return (setting.ref, 0, 0)
    }

    // MARK: - Decoder budget

    /// Spec 3 §4 — "Each media write counts against the channel's cap: the
    /// incoming instance plus any outgoing instance still mid-transition. ...
    /// A write that would exceed the cap drops the oldest outgoing instance
    /// and emits `steppedOn` with the dropped ref."
    ///
    /// Reading of the spec: only media instances enter `outgoing`, but any
    /// write over media records it; a same-ref restart keeps its decoder and
    /// adds nothing; a cut records an outgoing instance that ends on the
    /// landing frame, which is why row 14's second write still sees B.
    mutating func replaceContent(of channel: inout ChannelState, number: Int, with to: ContentInstance,
                                 transitionMs: Int, restart: Bool) -> [String] {
        channel.outgoing.removeAll { $0.endsAtFrame <= frame }
        if let current = channel.content.media, !restart {
            channel.outgoing.append(OutgoingInstance(instance: current,
                                                     endsAtFrame: frame + context.rate.frames(forMs: transitionMs)))
        }
        var stepped: [String] = []
        if to.media != nil {
            let cap = max(1, context.library.channel(number)?.decoderCap ?? context.machine.decoderCapDefault)
            while 1 + channel.outgoing.count > cap, !channel.outgoing.isEmpty {
                stepped.append(channel.outgoing.removeFirst().instance.ref)
            }
        }
        channel.content = to
        return stepped
    }

    // MARK: - Write

    /// Spec 3 §4 — "A write replaces the channel's content instance, applies
    /// its riders, and emits a `transition` effect that tells the engine what
    /// to animate between." Per kind: media restarts on the same ref; identical
    /// text is a `noop`; the same slide with a new build is a `build` effect;
    /// the same input is a `noop`; `empty` is the clear.
    ///
    /// Reading of the spec: an identical-content write still applies its
    /// riders (§9 row 5 writes `text "y"` over `y` with `grade 6 once`), so
    /// only a write that changes nothing at all is a `noop`.
    mutating func write(_ number: Int, _ write: ChannelWrite, command: Command, source: CommandSource) -> Bool {
        guard var channel = state.channels[number] else { return false }
        if isBlocked(channel, source: source) {
            effects.append(.blocked(channel: number, command: command))
            return true
        }
        let current = channel.content
        var newContent: ContentInstance?
        var restart = false
        var buildChange: (from: Int?, to: Int?)?

        switch write.content {
        case .media(let m):
            // Spec 3 §4 — Media: "`startedAtFrame` set to the frame the write
            // lands on, `transport: playing`, and `inMs`, `outMs`, `loop`,
            // `gainOverride`, `syncOffsetMs` taken from the content expression,
            // falling back to the pool item's defaults, then to none.
            // `endBehavior` starts as `loop` when the expression says loop,
            // otherwise `hold`." Spec 1 §7 — the machine index is consulted
            // first, then the library index. The expression's `loop` can ask
            // for a loop, not refuse the pool's (`end hold` does that).
            let pool = (context.machine.mediaLocal.entry(m.ref) ?? context.library.mediaIndex.entry(m.ref))?.defaults
            let loop = m.loop || (pool?.loop ?? false)
            restart = current.media?.ref == m.ref
            newContent = .media(MediaInstance(
                ref: m.ref, inMs: m.inMs ?? pool?.trimInMs, outMs: m.outMs ?? pool?.trimOutMs, loop: loop,
                gainOverride: m.gain ?? pool?.gain, syncOffsetMs: m.syncOffsetMs ?? pool?.syncOffsetMs,
                startedAtFrame: frame, transport: .playing,
                endBehavior: loop ? .loop : .hold, missing: context.missing.contains(m.ref)))
        case .text(let fields):
            // Spec 3 §4 — Text: "If the fields are identical to the current
            // text, the result is `noop`. Fields not written are absent."
            if case .text(let t) = current, t.fields == fields {
                newContent = nil
            } else {
                newContent = .text(TextInstance(fields: fields))
            }
        case .slide(let ref, let build):
            // Spec 3 §4 — Slide: "`build` from the rider or the slide's final
            // state. The same slide ref with a different build changes only
            // `build` and emits a `build` effect; the same slide and build is a `noop`."
            let target = write.riders.build ?? build
            if let s = current.slide, s.ref == ref {
                if s.build != target {
                    buildChange = (s.build, target)
                    var updated = s
                    updated.build = target
                    channel.content = .slide(updated)
                }
            } else {
                newContent = .slide(SlideInstance(ref: ref, build: target, missing: context.missing.contains(ref)))
            }
        case .input(let input):
            // Spec 3 §4 — Input: "writing the same input is a `noop`."
            if case .input(let i) = current, i.input == input {
                newContent = nil
            } else {
                newContent = .input(InputInstance(input: input))
            }
        case .empty:
            newContent = current.isEmpty ? nil : .empty
        }

        var acted = false
        let contentChanged = newContent != nil

        // Riders first, so a `track` rider is the attribute the effect uses.
        var riderEffectsStart = effects.count
        if applyRiders(write.riders, to: &channel, number: number, contentChanged: contentChanged) {
            acted = true
        }
        let riderEffects = Array(effects[riderEffectsStart...])
        effects.removeSubrange(riderEffectsStart...)
        riderEffectsStart = effects.count

        if let to = newContent {
            let transition = selectTransition(rider: write.riders.transition, attribute: channel.attributes.transition, channel: number)
            let audio = selectAudioTransition(rider: write.riders.audioTransition, attribute: channel.attributes.audioTransition, channel: number)
            let stepped = replaceContent(of: &channel, number: number, with: to, transitionMs: transition.ms, restart: restart)
            channel.provenance = provenance(source)
            effects.append(.transition(TransitionEffect(
                channel: number, from: current, to: to, transition: transition.ref, ms: transition.ms,
                audioTransition: audio.ref, audioMs: audio.ms, audioOffsetMs: audio.offsetMs, restart: restart)))
            for ref in stepped {
                effects.append(.steppedOn(channel: number, dropped: ref))
            }
            acted = true
        } else if let change = buildChange {
            channel.provenance = provenance(source)
            effects.append(.build(channel: number, from: change.from, to: change.to))
            acted = true
        }
        effects.append(contentsOf: riderEffects)

        state.channels[number] = channel
        return acted
    }

    // MARK: - Clear and reset

    /// Spec 3 §3 rule 5 — "`channel N clear` writes `empty` and leaves every
    /// attribute as it was ... The clear itself dissolves to transparent using
    /// the channel's current transition attribute."
    mutating func clear(_ number: Int, command: Command, source: CommandSource) -> Bool {
        guard var channel = state.channels[number] else { return false }
        if isBlocked(channel, source: source) {
            effects.append(.blocked(channel: number, command: command))
            return true
        }
        let current = channel.content
        guard !current.isEmpty else { return false }
        let transition = selectTransition(rider: nil, attribute: channel.attributes.transition, channel: number)
        let audio = selectAudioTransition(rider: nil, attribute: channel.attributes.audioTransition, channel: number)
        _ = replaceContent(of: &channel, number: number, with: .empty, transitionMs: transition.ms, restart: false)
        channel.provenance = provenance(source)
        state.channels[number] = channel
        effects.append(.transition(TransitionEffect(
            channel: number, from: current, to: .empty, transition: transition.ref, ms: transition.ms,
            audioTransition: audio.ref, audioMs: audio.ms, audioOffsetMs: audio.offsetMs)))
        return true
    }

    /// Spec 3 §3 rule 6 — "`channel N reset` resets one channel's attributes
    /// and leaves its content."
    mutating func reset(_ number: Int) -> Bool {
        resetAttributes(of: number)
    }

    /// Spec 3 §3 rule 6 — "`system clearall` writes `empty` to every channel
    /// and resets every tracked attribute to default." The clear uses each
    /// channel's current transition, then the attributes reset. Lock does not
    /// apply (Spec 2 §3, passes).
    mutating func clearAll(command: Command) {
        var acted = false
        for number in state.channels.keys.sorted() {
            if clear(number, command: command, source: CommandSource(kind: .engine)) { acted = true }
            if resetAttributes(of: number) { acted = true }
        }
        if !acted { effects.append(.noop(command)) }
    }

    // MARK: - Attribute writes without content

    /// Spec 3 §4 — "Attribute writes without content (`channel N grade 5`,
    /// `channel N gain -6`, `channel N transition 2 500`) change only the
    /// attribute, with origin `tracked`, and emit an `attribute` effect. A
    /// grade change carries an optional duration." With the attribute's
    /// tracking switch off the write is `once` (§3 rule 7).
    mutating func attributeWrite(_ number: Int, _ value: AttributeValue, ms: Int?, command: Command, source: CommandSource) -> Bool {
        guard var channel = state.channels[number] else { return false }
        if isBlocked(channel, source: source) {
            effects.append(.blocked(channel: number, command: command))
            return true
        }
        let tracking = context.machine.tracking
        var riders = Riders()
        let attribute: ChannelAttribute
        switch value {
        case .grade(let ref):
            riders.grade = GradeRider(ref: ref, ms: ms, scope: effectiveScope(.track, trackingOn: tracking.grade))
            attribute = .grade
        case .transition(let setting):
            riders.transition = TransitionRider(ref: setting.ref, ms: setting.ms, scope: effectiveScope(.track, trackingOn: tracking.transition))
            attribute = .transition
        case .audioTransition(let setting):
            riders.audioTransition = TransitionRider(ref: setting.ref, ms: setting.ms, scope: effectiveScope(.track, trackingOn: tracking.audioTransition))
            attribute = .audioTransition
        case .gain(let db):
            riders.gain = GainRider(db: db, scope: effectiveScope(.track, trackingOn: tracking.gain))
            attribute = .gain
        case .chase(let on):
            riders.chase = on ? ChaseRider(scope: effectiveScope(.track, trackingOn: tracking.chase)) : nil
            attribute = .chase
        }
        let before = channel.attributes
        let effectsBefore = effects.count
        let changed = applyRiders(riders, to: &channel, number: number, contentChanged: false)
        guard changed else { return false }
        state.channels[number] = channel
        if effects.count == effectsBefore {
            // The value is unchanged but its origin is now tracked (or once):
            // Spec 3 §3's "redundant" write. Still an attribute write, so
            // still an `attribute` effect with old equal to new.
            let value = current(attribute, in: before)
            effects.append(.attribute(channel: number, attribute: attribute, old: value, new: value, ms: ms))
        }
        return true
    }

    /// The current value of one attribute, as an `AttributeValue`.
    func current(_ attribute: ChannelAttribute, in attributes: ChannelAttributes) -> AttributeValue {
        switch attribute {
        case .grade: return .grade(attributes.grade.value)
        case .transition: return .transition(attributes.transition.value)
        case .audioTransition: return .audioTransition(attributes.audioTransition.value)
        case .gain: return .gain(attributes.gain.value)
        case .chase: return .chase(attributes.chase.value)
        }
    }

    // MARK: - Transport, end behaviour, lock, freeze, build

    /// Spec 3 §4 — "`play`, `pause` and `stop` change `transport`; `stop` also
    /// resets the playhead by setting `startedAtFrame` to the landing frame
    /// and `transport: stopped`. These are `noop` on non-media content."
    mutating func transport(_ number: Int, _ mode: TransportMode, command: Command) -> Bool {
        guard var channel = state.channels[number], var media = channel.content.media else { return false }
        switch mode {
        case .play: media.transport = .playing
        case .pause: media.transport = .paused
        case .stop:
            media.transport = .stopped
            media.startedAtFrame = frame
        }
        guard channel.content != .media(media) else { return false }
        channel.content = .media(media)
        state.channels[number] = channel
        effects.append(.applied(command))
        return true
    }

    /// Spec 3 §4 — "`end loop | hold | clear` sets `endBehavior`. These are
    /// `noop` on non-media content."
    mutating func endBehavior(_ number: Int, _ mode: EndBehavior, command: Command) -> Bool {
        guard var channel = state.channels[number], var media = channel.content.media, media.endBehavior != mode else { return false }
        media.endBehavior = mode
        channel.content = .media(media)
        state.channels[number] = channel
        effects.append(.applied(command))
        return true
    }

    /// Spec 3 §3 rule 9 — "Lock is not tracked. It is operator state, set only
    /// by `channel N lock` and `unlock`." Spec 3 §8 — "`channel N lock` and
    /// `unlock` are themselves never blocked."
    mutating func lock(_ number: Int, _ locked: Bool, command: Command) -> Bool {
        guard var channel = state.channels[number] else { return false }
        channel.lock = locked
        state.channels[number] = channel
        effects.append(.applied(command))
        return true
    }

    /// Spec 2 §3 — `channel N freeze on`, `off`: "Live sources only (v1.5)".
    /// Sets `frozen` on an input instance; `noop` on anything else.
    mutating func freeze(_ number: Int, _ switchState: SwitchState, command: Command) -> Bool {
        guard var channel = state.channels[number], case .input(var input) = channel.content else { return false }
        let frozen: Bool
        switch switchState {
        case .on: frozen = true
        case .off: frozen = false
        case .toggle: frozen = !input.frozen
        }
        guard frozen != input.frozen else { return false }
        input.frozen = frozen
        channel.content = .input(input)
        state.channels[number] = channel
        effects.append(.applied(command))
        return true
    }

    /// Spec 3 §3 rule 8 — "A `build` rider or `channel N build K` changes the
    /// build index of the current slide; it has no meaning for other content
    /// kinds and is ignored with a `noop` effect."
    mutating func build(_ number: Int, _ build: Int, command: Command) -> Bool {
        guard var channel = state.channels[number], var slide = channel.content.slide, slide.build != build else { return false }
        let from = slide.build
        slide.build = build
        channel.content = .slide(slide)
        state.channels[number] = channel
        effects.append(.build(channel: number, from: from, to: build))
        return true
    }
}
