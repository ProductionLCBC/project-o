// OCore — Spec 3 §7, the cue view: a list folded from its top, and each cue's chips (Spec 3 §3, Spec 10 §6).

/// Spec 3 §3, "What a chip colour means" — "An attribute whose value changed
/// and whose origin is `tracked` or `once` from this cue is *new*; one whose
/// value is unchanged and was not written by this cue is *held*; one written
/// by this cue to the value it already had is *redundant*, a write worth
/// removing. Content follows the same three rules." Spec 10 §6 gives each
/// state its own shape, and a clear its own: "filled blue for a new value,
/// outlined grey for held, amber with a diagonal stripe for a redundant
/// write, and struck through for a clear".
public enum ChipState: String, Codable, Equatable, Sendable {
    case new
    case held
    case redundant
    case clear
}

/// Spec 10 §6, "The chips" — one channel's chip on one cue: what the cue did
/// to the channel's content, and the tracked attributes it wrote there ("A
/// dot on a chip marks attribute writes, listed on hover").
public struct CueChip: Equatable, Sendable {
    /// One tracked attribute a cue wrote on a channel.
    public struct AttributeWrite: Equatable, Sendable {
        public var attribute: ChannelAttribute
        /// The value written.
        public var value: AttributeValue
        /// Spec 3 §3 — "written by this cue to the value it already had".
        public var isRedundant: Bool

        public init(attribute: ChannelAttribute, value: AttributeValue, isRedundant: Bool) {
            self.attribute = attribute
            self.value = value
            self.isRedundant = isRedundant
        }
    }

    public var channel: Int
    public var state: ChipState
    /// In the order the cue wrote them.
    public var attributes: [AttributeWrite]

    public init(channel: Int, state: ChipState, attributes: [AttributeWrite] = []) {
        self.channel = channel
        self.state = state
        self.attributes = attributes
    }
}

/// Spec 3 §7, "Cue view and thumbnails" — "Start from a fresh ShowState,
/// treat the list's first cue as a boundary into that list, and fold cue 1
/// through cue K. The result is what the default stack would show if the
/// list ran from the start, which is the UX spec's definition of a cue
/// thumbnail and of the chip colours."
///
/// One fold for both: the engine's thumbnail job draws the states, and the
/// cue grid shows the chips (Spec 10 §6: "from the app's own fold of the
/// list, made with OCore's projection over the documents it holds ... as the
/// engine's thumbnail job does"), so a thumbnail and its chips can't disagree.
public enum CueView {
    /// One cue of the fold: the state after it, and its chips.
    public struct Step: Equatable, Sendable {
        /// Spec 6 §5 — "In a static box, a value reads the state's pointer:
        /// its cue and its list"; "A projected state has no playlist". The
        /// state after the cue, its pointer naming the cue and the list.
        public var state: ShowState
        /// One chip a channel, in number order; a channel the cue doesn't
        /// touch is held (Area 13 reading).
        public var chips: [CueChip]

        public init(state: ShowState, chips: [CueChip]) {
            self.state = state
            self.chips = chips
        }
    }

    /// Folds `list` from a fresh state through the cue at `index`, zero-based,
    /// or through its last cue. `variables` resolves what the state doesn't
    /// hold (`[Timer 1]`, `[Time]`), and is given the state each cue lands on.
    public static func fold(_ list: List, through index: Int? = nil, library: Library, machine: Machine, missing: Set<String> = [],
                            variables: @escaping @Sendable (String, ShowState) -> String? = { _, _ in nil }) -> [Step] {
        walk(list, through: index, library: library, machine: machine, missing: missing, variables: variables, chips: true)
    }

    /// The states alone, for a caller that draws them and shows no chips.
    public static func states(of list: List, through index: Int? = nil, library: Library, machine: Machine, missing: Set<String> = [],
                              variables: @escaping @Sendable (String, ShowState) -> String? = { _, _ in nil }) -> [ShowState] {
        walk(list, through: index, library: library, machine: machine, missing: missing, variables: variables, chips: false).map(\.state)
    }

    private static func walk(_ list: List, through index: Int?, library: Library, machine: Machine, missing: Set<String>,
                             variables: @escaping @Sendable (String, ShowState) -> String?, chips: Bool) -> [Step] {
        var state = ShowState.fresh(library: library, machine: machine)
        // The channels whose content this list has written or cleared so far.
        var touched: Set<Int> = []
        var steps: [Step] = []
        for (position, cue) in list.cues.enumerated() {
            if let index, position > index { break }
            let before = state
            var context = ProjectionContext(frame: 0, library: library, machine: machine, missing: missing,
                                            source: CommandSource(kind: .cue, list: list.uuid, cue: cue.uuid),
                                            variables: { name in variables(name, before) })
            context.firesPlainly = true
            let commands = cue.commands.map(\.command)
            let (after, effects) = project(before, commands, context: context)
            state = after
            var drawn = after
            drawn.pointer = LivePointer(listUuid: list.uuid, cueUuid: cue.uuid)
            let cueChips = chips ? classify(commands: commands, effects: effects, before: before, after: after,
                                            library: library, machine: machine, touched: &touched) : []
            steps.append(Step(state: drawn, chips: cueChips))
        }
        return steps
    }

    // MARK: - The chips

    /// What one cue did to one channel's content, read from the fold's effects.
    private struct ContentWrite {
        /// The content before the cue's first change of it, and after its last.
        var from: ContentInstance?
        var to: ContentInstance?
        /// A slide's build changed.
        var build = false
        /// A write that changed nothing: the content was there already.
        var same = false
        /// A clear that changed nothing: the channel was empty already.
        var emptyClear = false
    }

    /// Spec 3 §3 — the chips of one cue, from what the projection reported
    /// for it. A channel's content is new when the cue changed it, redundant
    /// when the cue wrote what was there, a clear when the cue emptied it,
    /// and held otherwise.
    ///
    /// Area 13 reading — "Content holds across lists" (Spec 3 §3 rule 4), so
    /// a clear of a channel this list hasn't written yet empties whatever the
    /// list before left there: it is a clear. Only a clear of a channel the
    /// list itself already left empty is redundant.
    private static func classify(commands: [Command], effects: [Effect], before: ShowState, after: ShowState,
                                 library: Library, machine: Machine, touched: inout Set<Int>) -> [CueChip] {
        let channels = after.channels.keys.sorted()
        var writes: [Int: ContentWrite] = [:]
        var attributes: [Int: [CueChip.AttributeWrite]] = [:]
        var emptied = false

        func numbers(_ target: Target) -> [Int] {
            switch target {
            case .number(let n): return after.channels[n] == nil ? [] : [n]
            case .all: return channels
            }
        }

        for effect in effects {
            switch effect {
            case .transition(let transition):
                var write = writes[transition.channel] ?? ContentWrite()
                if write.from == nil { write.from = transition.from }
                write.to = transition.to
                writes[transition.channel] = write
                if transition.to.isEmpty { emptied = true }
            case .build(let channel, _, _):
                writes[channel, default: ContentWrite()].build = true
            case .attribute(let channel, let attribute, let old, let new, _):
                attributes[channel, default: []].append(CueChip.AttributeWrite(attribute: attribute, value: new, isRedundant: old == new))
            case .applied(let command), .noop(let command):
                // A command that changed nothing it could animate: a write of what was there, a clear of an empty
                // channel, or an attribute set to the value and origin it had.
                switch command {
                case .channelWrite(let write):
                    for n in numbers(write.channel) {
                        if case .empty = write.content {
                            writes[n, default: ContentWrite()].emptyClear = true
                        } else {
                            writes[n, default: ContentWrite()].same = true
                        }
                    }
                case .channelClear(let target):
                    for n in numbers(target) { writes[n, default: ContentWrite()].emptyClear = true }
                case .systemClearAll:
                    for n in channels { writes[n, default: ContentWrite()].emptyClear = true }
                case .channelGrade(let target, let ref, _):
                    for n in numbers(target) { attributes[n, default: []].append(.init(attribute: .grade, value: .grade(ref), isRedundant: true)) }
                case .channelGain(let target, let db):
                    for n in numbers(target) { attributes[n, default: []].append(.init(attribute: .gain, value: .gain(db), isRedundant: true)) }
                case .channelTransition(let target, let ref, let ms):
                    for n in numbers(target) {
                        attributes[n, default: []].append(.init(attribute: .transition, value: .transition(TransitionSetting(ref: ref, ms: ms)), isRedundant: true))
                    }
                case .channelAudioTransition(let target, let ref, let ms):
                    for n in numbers(target) {
                        attributes[n, default: []].append(.init(attribute: .audioTransition, value: .audioTransition(TransitionSetting(ref: ref, ms: ms)),
                                                                isRedundant: true))
                    }
                default:
                    break
                }
            default:
                break
            }
        }

        // A clear of every channel reports only the channels it emptied. When the cue reaches one and something was
        // emptied, the channels that were empty already were cleared by it too.
        if emptied, reachesClearOfAll(commands, library: library, machine: machine, levels: MacroCalls.maxDepth) {
            for n in channels where writes[n]?.to == nil { writes[n, default: ContentWrite()].emptyClear = true }
        }

        var chips: [CueChip] = []
        for n in channels {
            let state: ChipState
            if let write = writes[n] {
                if let to = write.to {
                    if to.isEmpty {
                        state = .clear
                    } else if let from = write.from, sameValue(from, to), !write.build {
                        state = .redundant
                    } else {
                        state = .new
                    }
                } else if write.build {
                    state = .new
                } else if write.same {
                    state = .redundant
                } else if write.emptyClear {
                    state = touched.contains(n) ? .redundant : .clear
                } else {
                    state = .held
                }
                touched.insert(n)
            } else {
                state = .held
            }
            chips.append(CueChip(channel: n, state: state, attributes: attributes[n] ?? []))
        }
        return chips
    }

    /// Spec 3 §3 — "the value it already had": two contents are the same
    /// value when they differ only in when the write landed and how the media
    /// is playing, which no cue writes.
    static func sameValue(_ a: ContentInstance, _ b: ContentInstance) -> Bool {
        guard var x = a.media, var y = b.media else { return a == b }
        x.startedAtFrame = 0
        y.startedAtFrame = 0
        x.transport = .playing
        y.transport = .playing
        return x == y
    }

    /// Whether the commands a cue can reach hold a clear of every channel:
    /// `system clearall`, `channel all clear` or a write of empty to all,
    /// its own or in a macro it runs, whatever the macro's guards say.
    private static func reachesClearOfAll(_ commands: [Command], library: Library, machine: Machine, levels: Int) -> Bool {
        for command in commands {
            switch command {
            case .systemClearAll, .channelClear(channel: .all):
                return true
            case .channelWrite(let write):
                if case .all = write.channel, case .empty = write.content { return true }
            case .macro(let number):
                guard levels > 0, let macro = MacroCalls.macro(number, library: library, machine: machine) else { continue }
                if reachesClearOfAll(macro.commands.map(\.command), library: library, machine: machine, levels: levels - 1) { return true }
            default:
                continue
            }
        }
        return false
    }
}
