// OEngine — Spec 4 §14, a seam: the Mach service the operator app looks up.

import Darwin
import Foundation

/// Spec 10 §2, "The Mach channel" — "The engine registers a Mach service in
/// the user's bootstrap namespace under the name `hello` gives, with
/// `bootstrap_check_in`, or, where launchd refuses a name it hasn't seen, the
/// deprecated `bootstrap_register`, behind a seam of its own (Spec 4 §14); the
/// app looks it up. Neither needs a launchd file or an entitlement (ADR
/// 0007)." One v1 implementation, `BootstrapMachService`; if a Mac ever
/// refuses both calls, "a per-user launchd agent that declares the name takes
/// their place" behind this protocol.
public protocol MachService: Sendable {
    /// Spec 10 §2 — the service registered under `name`: the receive right
    /// the engine reads connections from, and which call launchd took.
    func register(name: String) throws -> MachRegistration

    /// Spec 10 §2 — "the app looks it up": a send right to the service
    /// registered under `name`, which the caller releases.
    func lookUp(name: String) throws -> mach_port_t
}

/// Spec 10 §2 — a registered service: its name, its receive right and the
/// call that registered it.
public struct MachRegistration: Equatable, Sendable {
    /// Spec 10 §2 — "with `bootstrap_check_in`, or ... the deprecated
    /// `bootstrap_register`".
    public enum Call: String, Equatable, Sendable {
        case checkIn
        case register
    }

    public var name: String
    public var port: mach_port_t
    public var call: Call

    public init(name: String, port: mach_port_t, call: Call) {
        self.name = name
        self.port = port
        self.call = call
    }
}

/// Spec 10 §2 — why a name was not registered or not found. The codes are
/// launchd's (`bootstrap.h`) or the kernel's.
public enum MachServiceError: Error, Equatable, CustomStringConvertible {
    /// The name does not fit launchd's 128 bytes.
    case nameTooLong(String)
    /// launchd refused every call tried; each call's code, in the order tried.
    case refused(name: String, codes: [MachRegistration.Call: kern_return_t])
    /// Nothing is registered under the name.
    case notFound(name: String, code: kern_return_t)

    public var description: String {
        switch self {
        case .nameTooLong(let name):
            return "the Mach service name \(name) is longer than launchd's \(MachServiceName.limit - 1) bytes"
        case .refused(let name, let codes):
            let tried = codes.sorted { $0.key.rawValue < $1.key.rawValue }.map { "\($0.key.rawValue) \($0.value)" }.joined(separator: ", ")
            return "launchd refused the Mach service name \(name): \(tried)"
        case .notFound(let name, let code):
            return "no Mach service is registered as \(name) (\(code))"
        }
    }
}

/// Spec 10 §2 — the name `hello` gives: `"mach":
/// "org.lcbc.projecto.engine.51e2…"`, the run's uuid after the engine's
/// prefix, so each run registers a name of its own.
public enum MachServiceName {
    public static let prefix = "org.lcbc.projecto.engine."

    /// launchd's `BOOTSTRAP_MAX_NAME_LEN`: a name with its end fits 128 bytes.
    public static let limit = 128

    /// Spec 10 §2 — the service name of the run with this uuid.
    public static func engine(run: UUID) -> String {
        prefix + run.uuidString.lowercased()
    }
}
