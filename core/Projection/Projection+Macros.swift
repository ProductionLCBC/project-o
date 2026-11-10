// OCore — Spec 3 §6, macros, and Spec 2 §7, guards.

extension Fold {
    /// Spec 3 §6 — "`macro` by inlining the macro's commands with their
    /// guards." Spec 3 §8 — "A macro fired by a cue inherits `cue` as its
    /// source kind, so lock cannot be dodged by wrapping a write in a macro."
    /// Spec 2 §5 — "A macro runs whole or not at all": one that loops, nests
    /// deeper than the levels left here, or does not exist is a `noop`, and so
    /// is one whose guards all fail. Spec 1 §2 — a macro that names a stack or
    /// an output lives in the machine root, so both roots are searched.
    mutating func runMacro(_ number: Int, command: Command, source: CommandSource, nesting: Nesting) {
        // Spec 2 §5 — "A macro runs whole or not at all": the same check as the runner's and the validator's.
        guard MacroCalls.check(number, levels: nesting.levelsLeft, library: context.library, machine: context.machine) == nil,
              let macro = MacroCalls.macro(number, library: context.library, machine: context.machine) else {
            effects.append(.noop(command))
            return
        }
        let inner = source.inMacro(number)
        let before = effects.count
        for guarded in macro.commands {
            // Spec 2 §7 — "Guards are evaluated at the moment the command
            // would run, inside the macro's group, against the state as
            // earlier commands in the same group have changed it."
            if let condition = guarded.when, !condition.holds(actual: value(of: condition.variable)) {
                continue
            }
            apply(guarded.command, source: inner, nesting: nesting.insideMacro)
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
            // Spec 7 §4 — "What reads the pointer reads its place": the positions as
            // they are now, and the title from the kept copy once the list is gone.
            guard case .placed(let place) = placer.placement(of: state.pointer) else {
                return words[1].lowercased() == "item" || words[1].lowercased() == "cue" || words[1].lowercased() == "title"
                    ? nil : context.variables(name)
            }
            switch words[1].lowercased() {
            case "item": return place.itemPosition.map(String.init)
            case "cue":
                switch place.cue {
                case .at(let index): return String(index + 1)
                case .after(let index): return String(index + 1)
                }
            case "title": return place.list.title
            default: return context.variables(name)
            }
        default:
            return context.variables(name)
        }
    }
}
