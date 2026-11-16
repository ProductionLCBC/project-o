// OEngine — Spec 10 §2, which screen each display output is on.

import OCore

/// Spec 10 §3, the `outputs` topic — an output's state: "`presenting`,
/// `paused` while its screen or card is gone, `released`, or `absent` when
/// its device isn't there". `absent` is an output whose device has not been
/// there this run; `paused` one that presented and lost it.
public enum OutputStanding: String, Codable, Equatable, Sendable {
    case presenting
    case paused
    case released
    case absent
}

/// Where a display output goes: on the screen with this uuid, nowhere while
/// its screen isn't there, or off its screen for the rest of the run.
public enum OutputPlace: Equatable, Sendable {
    case screen(String)
    case absent
    case released
}

/// Spec 10 §2 — "A display output whose screen isn't there stays `absent` and
/// opens when a screen with its id appears; it never falls back to another
/// screen." Spec 10 §9 — `releaseScreen` "takes every output off the named
/// screen for the rest of the run". The rule alone, with no window in it, so
/// a table of screens can test it.
public enum OutputPlacement {
    /// Each display output's place, by output number: `released` when its
    /// screen was released this run, the screen whose uuid its `device`
    /// names when that screen is there, else `absent`. Outputs of other
    /// kinds have no place here.
    public static func places(outputs: [Output], screens: [DetectedScreen], released: Set<String>) -> [Int: OutputPlace] {
        let present = Set(screens.map(\.uuid))
        let gone = Set(released.map { $0.uppercased() })
        var places: [Int: OutputPlace] = [:]
        for output in outputs where output.kind == .display {
            guard let uuid = DetectedScreen.uuid(ofDevice: output.device) else {
                places[output.number] = .absent
                continue
            }
            if gone.contains(uuid) {
                places[output.number] = .released
            } else if present.contains(uuid) {
                places[output.number] = .screen(uuid)
            } else {
                places[output.number] = .absent
            }
        }
        return places
    }

    /// The soak's outputs on real screens (Area 19). The spike's display
    /// outputs name screens no Mac has (`display:main`), and a display output
    /// "opens only on the screen its device names" (Spec 10 §2), so a soak
    /// would draw on nothing. Each display output, in number order, is given
    /// the next of `screens` (`display:<uuid>`, in the order given); one past
    /// the last screen keeps its device and stays absent. Everything else of
    /// an output, its format included, is as the machine has it.
    public static func bound(_ outputs: [Output], to screens: [String]) -> [Output] {
        var remaining = screens[...]
        var bound = outputs
        for index in bound.indices.sorted(by: { bound[$0].number < bound[$1].number }) where bound[index].kind == .display {
            guard let screen = remaining.popFirst() else { break }
            bound[index].device = screen
        }
        return bound
    }

    /// The screens a soak uses when it is told none: every screen of the Mac,
    /// left to right, top to bottom where two share a left edge, as first run
    /// numbers them (Spec 10 §13).
    public static func soakScreens(_ screens: [DetectedScreen]) -> [String] {
        screens.sorted { ($0.frame.x, $0.frame.y) < ($1.frame.x, $1.frame.y) }.map(\.device)
    }

    /// Spec 10 §9 — the display outputs on the screen with this uuid, in
    /// number order: what `releaseScreen` closes and answers with.
    public static func outputs(onScreen uuid: String, of outputs: [Output]) -> [Int] {
        let wanted = uuid.uppercased()
        return outputs.filter { $0.kind == .display && DetectedScreen.uuid(ofDevice: $0.device) == wanted }.map(\.number).sorted()
    }

    /// Spec 4 §2 — "Display outputs only: the primary output's
    /// CADisplayLink": the screen of the lowest-numbered display output that
    /// has one now, or nil, when the engine runs on its timer.
    public static func clockScreen(outputs: [Output], screens: [DetectedScreen], released: Set<String>) -> String? {
        let placed = places(outputs: outputs, screens: screens, released: released)
        for number in placed.keys.sorted() {
            if case .screen(let uuid)? = placed[number] { return uuid }
        }
        return nil
    }
}
