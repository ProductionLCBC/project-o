// OCore — Spec 3 §5, firing with `state`: a cue's list's state taken up before it fires.

extension Fold {
    /// Spec 3 §5 — "Firing with `state` ... takes up, between the boundary and
    /// the cue's commands, the state its list leaves before it: the cue view
    /// of §7 folded through the cue before it. Each channel those cues touched
    /// takes that state's content and tracked attributes with a cut
    /// (zero-duration `transition` effects and `attribute` effects); a channel
    /// already playing the same media (ref, in, out and loop) keeps playing
    /// it; a locked channel is left as it is (§8). A channel the list never
    /// touched before the cue keeps what is live. Then the cue fires as above,
    /// its writes with their own transitions ... The other commands of the
    /// cues before it don't run. The first cue of a list takes up nothing."
    ///
    /// A channel the cue itself writes or clears takes the attributes alone:
    /// its content goes from what is live to the cue's own, with the cue's
    /// transition, as when the show runs, and never shows an earlier cue's
    /// content for a frame on the way.
    mutating func takeUpState(before position: CuePosition) {
        guard position.cueIndex > 0 else { return }
        let list = position.list
        let library = context.library, machine = context.machine
        let steps = CueView.states(of: list, through: position.cueIndex - 1, library: library, machine: machine, missing: context.missing)
        guard let target = steps.last else { return }
        // The channels the cues before it touched: any whose state a step changed, from a fresh state.
        var touched: Set<Int> = []
        var previous = ShowState.fresh(library: library, machine: machine)
        for step in steps {
            for (number, channel) in step.channels where previous.channels[number] != channel { touched.insert(number) }
            previous = step
        }
        let written = contentTargets(of: position.cue)
        let source = CommandSource(kind: .cue, list: list.uuid, cue: position.cue.uuid, playlist: position.playlist?.uuid)
        for number in touched.sorted() {
            guard var channel = state.channels[number], let taken = target.channels[number] else { continue }
            if isBlocked(channel, source: source) { continue }
            // The attributes first, so a content change below goes with the cue's own.
            let before = channel.attributes
            channel.attributes = taken.attributes
            for attribute in [ChannelAttribute.grade, .transition, .audioTransition, .gain, .chase] {
                let old = current(attribute, in: before), new = current(attribute, in: taken.attributes)
                if old != new { effects.append(.attribute(channel: number, attribute: attribute, old: old, new: new, ms: nil)) }
            }
            if !written.contains(number) {
                let from = channel.content
                var to = taken.content
                if let clip = to.media {
                    if let playing = from.media, playing.ref == clip.ref, playing.inMs == clip.inMs, playing.outMs == clip.outMs,
                       playing.loop == clip.loop {
                        to = from
                    } else {
                        // The cue view was folded at frame 0: the clip starts now, from its in-point.
                        var now = clip
                        now.startedAtFrame = frame
                        now.transport = .playing
                        to = .media(now)
                    }
                }
                if to != from {
                    _ = replaceContent(of: &channel, number: number, with: to, transitionMs: 0, restart: false)
                    effects.append(.transition(TransitionEffect(
                        channel: number, from: from, to: to, transition: channel.attributes.transition.value.ref, ms: 0,
                        audioTransition: channel.attributes.audioTransition.value.ref, audioMs: 0, audioOffsetMs: 0)))
                    channel.provenance = taken.provenance
                }
            }
            state.channels[number] = channel
        }
    }

    /// The channels a cue's own commands write content to or clear, `all` as every channel.
    func contentTargets(of cue: Cue) -> Set<Int> {
        var numbers: Set<Int> = []
        for entry in cue.commands {
            let target: Target
            switch entry.command {
            case .channelWrite(let write): target = write.channel
            case .channelClear(let channel): target = channel
            default: continue
            }
            switch target {
            case .number(let n): numbers.insert(n)
            case .all: numbers.formUnion(state.channels.keys)
            }
        }
        return numbers
    }
}
