// OCore — Spec 3 §6, ProjectionContext.

/// Spec 1 §3 — a frame rate as `{num, den}`. Spec 3 §9 fixes the test table
/// at 60 fps; the context carries the machine's rate so ms become frames.
public struct FrameRate: Codable, Equatable, Sendable {
    public var num: Int
    public var den: Int
    public init(num: Int, den: Int = 1) {
        self.num = num
        self.den = den
    }

    public static let fps60 = FrameRate(num: 60, den: 1)

    /// Milliseconds to whole frames, rounded to the nearest frame.
    public func frames(forMs ms: Int) -> Int {
        guard num > 0, den > 0 else { return 0 }
        let numerator = ms * num + 500 * den
        return numerator / (1000 * den)
    }
}

/// Spec 3 §6 — `ProjectionContext` "carries everything the fold needs that is
/// not state and not a command, all of it plain data: `frame`, `library`,
/// `machine`, `missing`, `source`, and `variables`. Nothing in the context is
/// mutable and nothing has a side effect."
///
/// Addition flagged for the spec: `rate`, the master frame rate, which rows
/// 14, 20 and 21 of §9 need to turn ms into frames.
public struct ProjectionContext: Sendable {
    /// The engine frame the group lands on.
    public var frame: Int
    public var rate: FrameRate
    public var library: Library
    public var machine: Machine
    /// The set of media ids the resolver cannot find.
    public var missing: Set<String>
    /// Spec 2's source record, for lock decisions.
    public var source: CommandSource
    /// Resolves `[Timer 1]` and friends for guards; the name without brackets.
    public var variables: @Sendable (String) -> String?

    public init(frame: Int, rate: FrameRate = .fps60, library: Library, machine: Machine,
                missing: Set<String> = [], source: CommandSource,
                variables: @escaping @Sendable (String) -> String? = { _ in nil }) {
        self.frame = frame
        self.rate = rate
        self.library = library
        self.machine = machine
        self.missing = missing
        self.source = source
        self.variables = variables
    }
}
