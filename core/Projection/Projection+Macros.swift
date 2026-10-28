// OCore — Spec 3 §6, macros, and Spec 2 §7, guards.

extension Fold {
    /// Spec 3 §6 — "`macro` by inlining the macro's commands with their
    /// guards." Spec 3 §8 — "A macro fired by a cue inherits `cue` as its
    /// source kind, so lock cannot be dodged by wrapping a write in a macro."
    /// Spec 2 §5 — depth is capped at 8. An unknown macro, or one whose
    /// guards all fail, is a `noop`. Spec 1 §2 — a macro that names a stack
    /// or an output lives in the machine root, so both roots are searched.
    mutating func runMacro(_ number: Int, command: Command, source: CommandSource, depth: Int) {
        guard depth < Fold.maxDepth, let macro = context.library.macro(number) ?? context.machine.macro(number) else {
            effects.append(.noop(command))
            return
        }
        let inner: CommandSource
        if source.kind.isSubjectToLock {
            inner = source
        } else {
            inner = CommandSource(kind: .macro, list: source.list, cue: source.cue, playlist: source.playlist, macro: number)
        }
        let before = effects.count
        for guarded in macro.commands {
            // Spec 2 §7 — "Guards are evaluated at the moment the command
            // would run, inside the macro's group, against the state as
            // earlier commands in the same group have changed it."
            if let condition = guarded.when, !condition.holds(actual: value(of: condition.variable)) {
                continue
            }
            apply(guarded.command, source: inner, depth: depth + 1)
        }
        if effects.count == before {
            effects.append(.noop(command))
        }
    }

    /// Spec 2 §7 — the readable values a guard can name, without brackets:
    /// `Timer N`, `Popup N`, `Time`, `Date`, `Live Item`, `Live Cue`,
    /// `Live Title`, `Channel N Content`, `Channel N State`, `Output N
    /// Stack`, `Stack N Blackout`, `Channel N Lock`. State-derived values
    /// come from the fold; the rest from the context's `variables`.
    func value(of name: String) -> String? {
        let words = name.split(separator: " ").map { String($0) }
        let head = words.first?.lowercased() ?? ""
        let number = words.count >= 2 ? Int(words[1]) : nil
        let tail = words.count >= 3 ? words[2...].joined(separator: " ").lowercased() : ""

        switch (head, number, tail) {
        case ("popup", let n?, ""):
            return state.popups[n]
        case ("channel", let n?, "content"):
            // "`[Channel N Content]` reads as the content kind plus its label
            // (`"text: Verse 1"`), so `is empty` is the useful comparison."
            guard let content = state.channels[n]?.content else { return nil }
            switch content {
            case .empty: return nil
            case .media(let m): return "media: \(m.ref)"
            case .text(let t):
                let body = t.fields["body"] ?? t.fields.values.sorted().first ?? ""
                return "text: " + (body.split(separator: "\n").first.map(String.init) ?? "")
            case .slide(let s): return "slide: \(s.ref)"
            case .input(let i): return "input: \(i.input)"
            }
        case ("channel", let n?, "state"):
            guard let content = state.channels[n]?.content else { return nil }
            switch content {
            case .empty: return "empty"
            case .media(let m): return m.transport.rawValue
            case .text, .slide: return "showing"
            case .input(let i): return i.frozen ? "frozen" : "live"
            }
        case ("channel", let n?, "lock"):
            guard let channel = state.channels[n] else { return nil }
            return channel.lock ? "on" : "off"
        case ("output", let n?, "stack"):
            return state.outputs[n].map(String.init)
        case ("stack", let n?, "blackout"):
            return state.stacks[n].map { $0.blackout ? "on" : "off" }
        case ("live", nil, _) where words.count == 2:
            switch words[1].lowercased() {
            case "item": return state.pointer?.item.map(String.init)
            case "cue": return position(of: state.pointer).map { String($0.cueIndex + 1) }
            case "title": return position(of: state.pointer)?.list.title
            default: return context.variables(name)
            }
        default:
            return context.variables(name)
        }
    }
}
