// OCore — Spec 2 §8, validation; Spec 2 §7, the guard rule.

import Foundation

/// What the validator checks against: the two roots, the live ShowState for
/// the checks that need the live position (`cue N`, `item N`), and the
/// source of the group, since "Guards on cue commands are ... rejected by the
/// v1 validator" (Spec 2 §7). Without a state the live-position checks are
/// skipped, the nil-means-skip pattern of Spec 1 §8's report.
public struct ValidationContext: Sendable {
    public var library: Library
    public var machine: Machine
    public var state: ShowState?
    public var source: CommandSource?

    public init(library: Library, machine: Machine, state: ShowState? = nil, source: CommandSource? = nil) {
        self.library = library
        self.machine = machine
        self.state = state
        self.source = source
    }
}

/// Spec 2 §8 — "**Validate** checks, in order: the target number exists (or
/// is `all`); referenced objects exist (a preset, a transition, a macro);
/// arguments are in range (gain within ±60 dB, offsets within ±1000 ms,
/// opacity 0–1); content references resolve in the media index (a missing
/// file is allowed and produces the missing state, an unknown id is
/// rejected); macro depth and cycles."
public enum CommandValidator {
    /// Spec 2 §8 — the rejection for one command, or nil when it may run.
    public static func validate(_ command: Command, guard condition: Guard? = nil, context: ValidationContext) -> Rejection? {
        do {
            let checker = Checker(context: context)
            try checker.check(command, guard: condition)
            return nil
        } catch let rejection as Rejection {
            return rejection
        } catch {
            return Rejection(reason: .malformed, message: "\(error)")
        }
    }

    /// Spec 2 §8 — "A group validates as a whole: one bad command rejects
    /// the group, and the rejection names the command and the reason." The
    /// group's own source decides the guard rule.
    public static func validate(_ group: CommandGroup, context: ValidationContext) -> Rejection? {
        var context = context
        context.source = group.source
        for (index, entry) in group.commands.enumerated() {
            guard var rejection = validate(entry.command, guard: entry.when, context: context) else { continue }
            rejection.index = index
            rejection.text = CommandText.print(entry.command)
            let name = rejection.text.map { " (\($0))" } ?? ""
            rejection.message = "command \(index + 1) of \(group.commands.count)\(name): " + rejection.message
            return rejection
        }
        return nil
    }
}

/// The checks, in Spec 2 §8's order.
struct Checker {
    let context: ValidationContext

    var library: Library { context.library }
    var machine: Machine { context.machine }

    func reject(_ reason: RejectionReason, _ message: String) -> Rejection {
        Rejection(reason: reason, message: message)
    }

    func check(_ command: Command, guard condition: Guard?) throws {
        if case .unknown(let cmd, _) = command {
            throw reject(.unknownCommand, "\(cmd) is not in the vocabulary")
        }
        if case .invalid(let cmd, _) = command {
            throw reject(.unknownCommand, "\(cmd): " + (command.invalidReason ?? "bad parameters"))
        }
        try targets(command)
        try references(command)
        try ranges(command)
        try media(command)
        try macros(command)
        if let condition { try check(condition) }
    }

    // MARK: - "the target number exists (or is `all`)"

    func targets(_ command: Command) throws {
        if let target = command.channelTarget, case .number(let n) = target {
            guard library.channel(n) != nil else { throw reject(.noSuchTarget, "channel \(n) does not exist") }
        }
        switch command {
        case .outputStack(let output, _):
            guard machine.output(output) != nil else { throw reject(.noSuchTarget, "output \(output) does not exist") }
        case .stackBlackout(let stack, _), .stackMute(let stack, _, _):
            guard machine.stack(stack) != nil else { throw reject(.noSuchTarget, "stack \(stack) does not exist") }
        case .cue(let n):
            guard n >= 1 else { throw reject(.noSuchTarget, "cue \(n) does not exist; cues count from 1") }
            try liveCue(n)
        case .itemCue(let item, let cue):
            try liveItem(item, cue: cue, section: nil)
        case .itemSection(let item, let section):
            try liveItem(item, cue: nil, section: section)
        case .listCue(let list, _):
            guard library.list(number: list) != nil else { throw reject(.noSuchTarget, "list \(list) does not exist") }
        case .playlistLoad(let title, let date):
            let wanted = title.lowercased()
            guard machine.playlists.contains(where: { $0.title.lowercased() == wanted && (date == nil || $0.serviceDate == date) }) else {
                throw reject(.noSuchTarget, "no playlist \"\(title)\"" + (date.map { " dated \($0)" } ?? "") + " on this machine")
            }
        case .timerSet(let timer, _), .timerStart(let timer), .timerPause(let timer), .timerReset(let timer):
            try slot(timer, count: machine.settings.timers, "timer", reason: .noSuchTarget)
        case .popupSet(let popup, _, _), .popupClear(let popup):
            try slot(popup, count: machine.settings.popups, "popup", reason: .noSuchTarget)
        case .audioMute(let target, _):
            if case .number(let n) = target {
                guard machine.audioOutput(n) != nil else { throw reject(.noSuchTarget, "audio output \(n) does not exist") }
            }
        case .macro(let n):
            guard library.macro(n) != nil || machine.macro(n) != nil else { throw reject(.noSuchTarget, "macro \(n) does not exist") }
        case .edit(let edit):
            guard let type = NumberedType(editTarget: edit.target) else {
                throw reject(.noSuchTarget, "\(edit.target) is not an object type")
            }
            guard Identity.exists(type, edit.number, library, machine) else {
                throw reject(.noSuchTarget, "\(type.displayName) \(edit.number) does not exist")
            }
        default:
            break
        }
    }

    /// Spec 1 §3 — timers and popups are slots counted in machine settings.
    func slot(_ n: Int, count: Int, _ name: String, reason: RejectionReason) throws {
        guard n >= 1, n <= count else {
            throw reject(reason, "\(name) \(n) does not exist; this machine has \(count) \(name) slots")
        }
    }

    /// Spec 2 §3 — `cue N` "Fires cue N of the live list", checked when a
    /// state is given.
    func liveCue(_ n: Int) throws {
        guard let state = context.state else { return }
        guard let listUuid = state.pointer?.listUuid,
              let list = library.list(uuid: listUuid) ?? machine.localList(uuid: listUuid) else {
            throw reject(.noSuchTarget, "cue \(n): no list is live")
        }
        guard n >= 1, n <= list.cues.count else {
            throw reject(.noSuchTarget, "cue \(n) does not exist in the live list (\(list.title) has \(list.cues.count) cues)")
        }
    }

    /// Spec 2 §3 — `item N cue M` and `item N section "NAME"` in the live
    /// playlist, checked when a state is given. Spec 3 §5 — a section with
    /// no match "is `rejected`".
    func liveItem(_ item: Int, cue: Int?, section: String?) throws {
        guard let state = context.state else { return }
        guard let playlistUuid = state.pointer?.playlist, let playlist = machine.playlist(uuid: playlistUuid) else {
            throw reject(.noSuchTarget, "item \(item): no playlist is live")
        }
        guard item >= 1, item <= playlist.items.count else {
            throw reject(.noSuchTarget, "item \(item) does not exist in the live playlist")
        }
        if case .header = playlist.items[item - 1].kind {
            throw reject(.noSuchTarget, "item \(item) is a header")
        }
        guard let list = CueAddressing.list(forItem: item, in: playlist, library: library, machine: machine) else {
            throw reject(.noSuchTarget, "item \(item) names a list that is missing")
        }
        if let cue {
            guard cue >= 1, cue <= list.cues.count else {
                throw reject(.noSuchReference, "cue \(cue) does not exist in item \(item) (\(list.title) has \(list.cues.count) cues)")
            }
        }
        if let section {
            let wanted = section.lowercased()
            guard list.cues.contains(where: { $0.section?.lowercased() == wanted }) else {
                throw reject(.noSuchReference, "no section \"\(section)\" in item \(item) (\(list.title))")
            }
        }
    }

    // MARK: - "referenced objects exist"

    func references(_ command: Command) throws {
        switch command {
        case .channelWrite(let write):
            if let t = write.riders.transition { try transition(t.ref) }
            if let t = write.riders.audioTransition { try audioTransition(t.ref) }
            if let g = write.riders.grade { try grade(g.ref) }
            if case .input(let n) = write.content {
                guard machine.input(n) != nil else { throw reject(.noSuchReference, "input \(n) does not exist") }
            }
        case .channelTransition(_, let ref, _):
            try transition(ref)
        case .channelAudioTransition(_, let ref, _):
            try audioTransition(ref)
        case .channelGrade(_, let ref, _):
            try grade(ref)
        case .outputStack(_, let stack):
            guard machine.stack(stack) != nil else { throw reject(.noSuchReference, "stack \(stack) does not exist") }
        case .stackMute(_, let channel, _):
            guard library.channel(channel) != nil else { throw reject(.noSuchReference, "channel \(channel) does not exist") }
        case .listCue(let list, let cue):
            if let master = library.list(number: list) {
                guard cue >= 1, cue <= master.cues.count else {
                    throw reject(.noSuchReference, "cue \(cue) does not exist in list \(list) (\(master.title) has \(master.cues.count) cues)")
                }
            }
        default:
            break
        }
    }

    func transition(_ ref: Int) throws {
        guard library.transition(ref) != nil else { throw reject(.noSuchReference, "transition \(ref) does not exist") }
    }

    func audioTransition(_ ref: Int) throws {
        guard library.audioTransition(ref) != nil else { throw reject(.noSuchReference, "audio transition \(ref) does not exist") }
    }

    /// Spec 2 §3 — "`grade 0` means none".
    func grade(_ ref: Int) throws {
        guard ref == 0 || library.grade(ref) != nil else { throw reject(.noSuchReference, "grade \(ref) does not exist") }
    }

    // MARK: - "arguments are in range (gain within ±60 dB, offsets within ±1000 ms)"

    func ranges(_ command: Command) throws {
        switch command {
        case .channelGain(_, let db):
            try gain(db, "gain")
        case .channelWrite(let write):
            if let g = write.riders.gain { try gain(g.db, "the gain rider") }
            if let ms = write.riders.transition?.ms { try nonNegative(ms, "the transition duration") }
            if let ms = write.riders.audioTransition?.ms { try nonNegative(ms, "the audio transition duration") }
            if let ms = write.riders.grade?.ms { try nonNegative(ms, "the grade duration") }
            if let b = write.riders.build { try nonNegative(b, "build") }
            switch write.content {
            case .media(let m):
                if let g = m.gain { try gain(g, "the media gain") }
                if let s = m.syncOffsetMs, abs(s) > 1000 {
                    throw reject(.outOfRange, "sync offset \(s) ms is outside ±1000 ms")
                }
                if let v = m.inMs { try nonNegative(v, "the in point") }
                if let v = m.outMs { try nonNegative(v, "the out point") }
            case .slide(_, let build?):
                try nonNegative(build, "build")
            default:
                break
            }
        case .channelTransition(_, _, let ms?), .channelAudioTransition(_, _, let ms?), .channelGrade(_, _, let ms?):
            try nonNegative(ms, "the duration")
        case .channelBuild(_, let build):
            try nonNegative(build, "build")
        case .timerSet(_, let ms):
            try nonNegative(ms, "the timer")
        case .popupSet(_, _, let after?):
            try nonNegative(after, "clearafter")
        default:
            break
        }
    }

    func gain(_ db: Double, _ what: String) throws {
        guard db >= -60, db <= 60 else {
            throw reject(.outOfRange, "\(what) \(CommandPrinter.decimalText(db)) dB is outside ±60 dB")
        }
    }

    func nonNegative(_ value: Int, _ what: String) throws {
        guard value >= 0 else { throw reject(.outOfRange, "\(what) \(value) is below 0") }
    }

    // MARK: - "content references resolve in the media index"

    func media(_ command: Command) throws {
        guard case .channelWrite(let write) = command, let ref = write.content.mediaRef else { return }
        guard MediaID.isValid(ref) else { throw reject(.unknownMedia, "\(ref) is not a media id") }
        guard MediaResolver.resolve(ref, library: library, machine: machine) != nil else {
            throw reject(.unknownMedia, "\(ref) is in neither media index")
        }
    }

    // MARK: - "macro depth and cycles"

    /// Spec 2 §5 — "A macro can call another macro; depth is capped at 8 and
    /// cycles are rejected at save." Checked for the macro being run, over the
    /// macros of both roots.
    func macros(_ command: Command) throws {
        guard case .macro(let number) = command else { return }
        var byNumber: [Int: Macro] = [:]
        for macro in machine.macros + library.macros { byNumber[macro.number] = macro }
        var path: [Int] = []
        var deepest = 0
        func walk(_ n: Int) throws {
            if let at = path.firstIndex(of: n) {
                let loop = (path[at...] + [n]).map { "macro \($0)" }.joined(separator: " → ")
                throw reject(.macroCycle, "macros call each other in a loop: \(loop)")
            }
            guard let macro = byNumber[n] else { return }
            path.append(n)
            deepest = max(deepest, path.count)
            for entry in macro.commands {
                if case .macro(let inner) = entry.command { try walk(inner) }
            }
            path.removeLast()
        }
        try walk(number)
        guard deepest <= Fold.maxDepth else {
            throw reject(.macroDepth, "macro \(number) nests \(deepest) macros deep; the cap is \(Fold.maxDepth)")
        }
    }

    // MARK: - Spec 2 §7, guards

    /// "Guards on cue commands are reserved in the schema and rejected by the
    /// v1 validator", and the readable values a guard may name: `[Timer N]`,
    /// `[Popup N]`, `[Time]`, `[Date]`, `[Live Item]`, `[Live Cue]`, `[Live
    /// Title]`, `[Channel N Content]`, `[Channel N State]`, `[Output N
    /// Stack]`, `[Stack N Blackout]`, `[Channel N Lock]`.
    func check(_ condition: Guard) throws {
        if context.source?.kind.isSubjectToLock == true {
            throw reject(.guardOnCue, "a guard on a cue command is reserved in v1 and does not run")
        }
        let words = condition.variable.split(separator: " ").map { String($0).lowercased() }
        let bad = reject(.badGuard, "[\(condition.variable)] is not a readable value")
        func number() throws -> Int {
            guard words.count >= 2, let n = Int(words[1]) else { throw bad }
            return n
        }
        switch words.first ?? "" {
        case "timer":
            guard words.count == 2 else { throw bad }
            try slot(try number(), count: machine.settings.timers, "timer", reason: .noSuchReference)
        case "popup":
            guard words.count == 2 else { throw bad }
            try slot(try number(), count: machine.settings.popups, "popup", reason: .noSuchReference)
        case "time", "date":
            guard words.count == 1 else { throw bad }
        case "live":
            guard words.count == 2, ["item", "cue", "title"].contains(words[1]) else { throw bad }
        case "channel":
            guard words.count == 3, ["content", "state", "lock"].contains(words[2]) else { throw bad }
            let n = try number()
            guard library.channel(n) != nil else { throw reject(.noSuchReference, "channel \(n) does not exist") }
        case "output":
            guard words.count == 3, words[2] == "stack" else { throw bad }
            let n = try number()
            guard machine.output(n) != nil else { throw reject(.noSuchReference, "output \(n) does not exist") }
        case "stack":
            guard words.count == 3, words[2] == "blackout" else { throw bad }
            let n = try number()
            guard machine.stack(n) != nil else { throw reject(.noSuchReference, "stack \(n) does not exist") }
        default:
            throw bad
        }
    }
}
