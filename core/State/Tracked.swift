// OCore — Spec 3 §2, tracked attributes.

/// Spec 3 §2 — "Each tracked attribute is stored with how it was set:
/// `{value, origin}` where origin is `default`, `tracked` (from a `track`
/// write) or `once` (from a rider on the current content write)."
public enum Origin: String, Codable, Equatable, Sendable {
    case `default`
    case tracked
    case once
}

/// Spec 3 §2 and §10 — `Tracked<Value>`: a tracked attribute's value, its
/// origin, and the `shadow` the projection keeps beside a `once` value so the
/// fall-back is exact (§3 rule 3).
///
/// Reading of the spec: a `shadow` of nil means the once value falls back to
/// the channel default with origin `default`; a non-nil shadow falls back to
/// that value with origin `tracked`. Only a content write triggers the
/// fall-back; `clear` leaves attributes untouched (§3 rule 5).
public struct Tracked<Value: Codable & Equatable & Sendable>: Codable, Equatable, Sendable {
    public var value: Value
    public var origin: Origin
    public var shadow: Value?

    public init(value: Value, origin: Origin = .default, shadow: Value? = nil) {
        self.value = value
        self.origin = origin
        self.shadow = shadow
    }

    /// Spec 3 §2 — "every attribute at `{default value, origin: default}`".
    public static func defaulted(_ value: Value) -> Tracked<Value> {
        Tracked(value: value, origin: .default, shadow: nil)
    }
}
