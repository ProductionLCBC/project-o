// OApp — Spec 10 §2, choice U-7: how soon the engine is started again after it ends.

import Foundation

/// Spec 10 §2, "When the engine stops" — "The app starts it again every time
/// it ends (choice U-7): at once for the first three ends within two
/// minutes, then five seconds after each, not counting restarts the operator
/// asked for."
///
/// Adam's answer to the Area 13 plan, 2026-11-17 — the two minutes slide: an
/// end restarts at once unless three ends lie in the two minutes before it,
/// and then after five seconds. So an engine that falls over now and then is
/// back at once every time, and one that can't stay up is tried every five
/// seconds for as long as it takes.
public struct RestartCadence: Equatable, Sendable {
    /// "within two minutes".
    public static let window: TimeInterval = 120
    /// "the first three ends".
    public static let prompt = 3
    /// "then five seconds after each".
    public static let wait: TimeInterval = 5

    private var ends: [TimeInterval] = []

    public init() {}

    /// Records an end at `now`, on the app's clock, and says how long to
    /// wait before starting the engine again: nothing, or five seconds.
    public mutating func ended(at now: TimeInterval) -> TimeInterval {
        ends.removeAll { now - $0 >= Self.window }
        let before = ends.count
        ends.append(now)
        return before >= Self.prompt ? Self.wait : 0
    }

    /// How many ends lie in the two minutes up to `now`.
    public func recent(at now: TimeInterval) -> Int {
        ends.filter { now - $0 < Self.window }.count
    }
}
