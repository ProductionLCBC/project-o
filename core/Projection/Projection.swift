// OCore — Spec 3 §6, the projection function.

/// Spec 3 §6 — `project(_ state: ShowState, _ commands: [Command], context:
/// ProjectionContext) -> (ShowState, [Effect])`: "a pure fold of commands
/// over state: given a state and a list of commands it returns the next
/// state and a list of effects, with no clock, no I/O and no Apple
/// frameworks."
///
/// Spec 2 §8 — "Commands run in array order, and later commands see earlier
/// ones' effects." Spec 3 §6 — "the fold stays total: every command in, one
/// result out." Validation happened before this; every lookup is guarded and
/// anything unexpected is a `noop`.
public func project(_ state: ShowState, _ commands: [Command], context: ProjectionContext) -> (ShowState, [Effect]) {
    var fold = Fold(state: state, context: context)
    for command in commands {
        fold.apply(command, source: context.source, depth: 0)
    }
    return (fold.state, fold.effects)
}

/// Spec 3 §7 — "Lookahead for offset slots. Start from the live ShowState and
/// fold the next K cues from the pointer, crossing item boundaries and
/// applying list boundaries exactly as a real fire would, with `frame` held
/// at the current frame so nothing appears to play." Returns nil past the end
/// of the playlist, which is what an empty `+K` slot shows.
public func lookahead(_ state: ShowState, steps: Int, context: ProjectionContext) -> ShowState? {
    var current = state
    guard steps > 0 else { return current }
    for _ in 0..<steps {
        let before = current.pointer
        let (next, _) = project(current, [.next], context: context)
        guard next.pointer != before else { return nil }
        current = next
    }
    return current
}

/// The fold in progress: the state being built, the effects so far and the
/// read-only context. A value type; `project` owns the only copy.
struct Fold {
    var state: ShowState
    var effects: [Effect] = []
    let context: ProjectionContext

    /// Spec 2 §5 — a macro can call a macro; "depth is capped at 8". The same
    /// cap bounds a cue whose commands fire cues.
    static let maxDepth = 8

    init(state: ShowState, context: ProjectionContext) {
        self.state = state
        self.context = context
    }

    // MARK: - Dispatch

    /// Spec 3 §6 — "The projection handles every command that touches
    /// ShowState ... Commands that do not touch state pass through as a
    /// `passthrough` effect for the caller to act on."
    mutating func apply(_ command: Command, source: CommandSource, depth: Int) {
        switch command {
        // Channels (§4)
        case .channelWrite(let write):
            forEachChannel(write.channel, command) { fold, n in fold.write(n, write, command: command, source: source) }
        case .channelClear(let target):
            forEachChannel(target, command) { fold, n in fold.clear(n, command: command, source: source) }
        case .channelReset(let target):
            forEachChannel(target, command) { fold, n in fold.reset(n) }
        case .channelTransition(let target, let ref, let ms):
            forEachChannel(target, command) { fold, n in
                fold.attributeWrite(n, .transition(TransitionSetting(ref: ref, ms: ms)), ms: nil, command: command, source: source)
            }
        case .channelAudioTransition(let target, let ref, let ms):
            forEachChannel(target, command) { fold, n in
                fold.attributeWrite(n, .audioTransition(TransitionSetting(ref: ref, ms: ms)), ms: nil, command: command, source: source)
            }
        case .channelGrade(let target, let ref, let ms):
            forEachChannel(target, command) { fold, n in
                fold.attributeWrite(n, .grade(ref), ms: ms, command: command, source: source)
            }
        case .channelGain(let target, let db):
            forEachChannel(target, command) { fold, n in
                fold.attributeWrite(n, .gain(db), ms: nil, command: command, source: source)
            }
        case .channelTransport(let target, let mode):
            forEachChannel(target, command) { fold, n in fold.transport(n, mode, command: command) }
        case .channelEndBehavior(let target, let mode):
            forEachChannel(target, command) { fold, n in fold.endBehavior(n, mode, command: command) }
        case .channelLock(let target, let locked):
            forEachChannel(target, command) { fold, n in fold.lock(n, locked, command: command) }
        case .channelFreeze(let target, let switchState):
            forEachChannel(target, command) { fold, n in fold.freeze(n, switchState, command: command) }
        case .channelBuild(let target, let build):
            forEachChannel(target, command) { fold, n in fold.build(n, build, command: command) }
        case .channelTrack:
            // Audio sets are v1.5 and not in ShowState; the engine handles it.
            effects.append(.passthrough(command))

        // Stacks and outputs, popups (§6 effects table)
        case .outputStack(let output, let stack):
            outputStack(output, stack, command: command)
        case .stackBlackout(let stack, let switchState):
            stackBlackout(stack, switchState, command: command)
        case .stackMute(let stack, let channel, let switchState):
            stackMute(stack, channel, switchState, command: command)
        case .popupSet(let popup, let text, let clearAfterMs):
            popupSet(popup, text, clearAfterMs: clearAfterMs, command: command)
        case .popupClear(let popup):
            popupClear(popup, command: command)

        // Navigation (§5)
        case .next:
            fireFollowing(command: command, depth: depth)
        case .previous:
            firePreceding(command: command, depth: depth)
        case .cue(let position):
            fireCue(position, command: command, depth: depth)
        case .itemCue(let item, let position):
            fireItem(item, cue: position, command: command, depth: depth)
        case .itemSection(let item, let section):
            fireSection(item, section, command: command, depth: depth)
        case .listCue(let list, let position):
            fireList(list, cue: position, command: command, depth: depth)
        case .playlistLoad(let title, let date):
            loadPlaylist(title, date: date, command: command)

        // System (§3 rule 6) and macros (§6)
        case .systemClearAll:
            clearAll(command: command)
        case .macro(let number):
            runMacro(number, command: command, source: source, depth: depth)

        // Pass-through: no ShowState in them.
        case .timerSet, .timerStart, .timerPause, .timerReset,
             .audioMute, .undo, .redo, .historyJump,
             .systemPreflight, .systemSnapshot, .edit:
            effects.append(.passthrough(command))

        case .unknown, .invalid:
            // Spec 1 §6 — kept verbatim and flagged by the loader; Spec 3 §6 answers `noop`.
            effects.append(.noop(command))
        }
    }

    // MARK: - Channel expansion

    /// Spec 2 §3 — "`N` is a channel number or the word `all`." Expands
    /// `all` over every channel in number order (Spec 2 §5, selection
    /// expansion is "in number order"). A channel that does not exist, or a
    /// command that changes nothing on any channel, is a `noop`.
    mutating func forEachChannel(_ target: Target, _ command: Command,
                                 _ body: (inout Fold, Int) -> Bool) {
        let numbers: [Int]
        switch target {
        case .number(let n): numbers = [n]
        case .all: numbers = state.channels.keys.sorted()
        }
        var acted = false
        for n in numbers where state.channels[n] != nil {
            if body(&self, n) { acted = true }
        }
        if !acted { effects.append(.noop(command)) }
    }

    // MARK: - Shared lookups

    var frame: Int { context.frame }

    /// Spec 3 §2 — "Defaults come from the Channel object (Spec 1)."
    func defaults(for channel: Int) -> ChannelDefaults {
        context.library.channel(channel)?.defaults ?? ChannelDefaults()
    }

    /// Spec 3 §2 — `provenance`: "the cue uuid that wrote it, or `restored`,
    /// or `ui`".
    func provenance(_ source: CommandSource) -> Provenance {
        switch source.kind {
        case .cue, .timeline:
            if let cue = source.cue { return .cue(cue) }
            return .source(source.kind)
        case .restore:
            return .restored
        default:
            return .source(source.kind)
        }
    }

    /// Spec 3 §8 — lock applies to writes, clears and tracked attribute
    /// writes from `cue` and `timeline` sources only.
    func isBlocked(_ channel: ChannelState, source: CommandSource) -> Bool {
        source.kind.isSubjectToLock && channel.lock
    }
}
