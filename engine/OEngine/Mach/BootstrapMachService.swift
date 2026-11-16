// OEngine — Spec 10 §2, the Mach service in the user's bootstrap namespace.

import Bootstrap
@preconcurrency import Darwin
import Foundation

/// Spec 10 §2 — "The engine registers a Mach service in the user's bootstrap
/// namespace under the name `hello` gives, with `bootstrap_check_in`, or,
/// where launchd refuses a name it hasn't seen, the deprecated
/// `bootstrap_register`, behind a seam of its own (Spec 4 §14); the app looks
/// it up. Neither needs a launchd file or an entitlement (ADR 0007)." The one
/// v1 implementation of `MachService`. The service lasts as long as the
/// process that registered it: when the engine ends, launchd forgets the name.
public struct BootstrapMachService: MachService {
    /// The calls to try, in order: `bootstrap_check_in` first, as the spec
    /// has it. A test narrows it to prove each call on its own.
    public let calls: [MachRegistration.Call]

    public init(calls: [MachRegistration.Call] = [.checkIn, .register]) {
        self.calls = calls
    }

    /// Spec 10 §2 — "with `bootstrap_check_in`, or, where launchd refuses a
    /// name it hasn't seen, the deprecated `bootstrap_register`".
    public func register(name: String) throws -> MachRegistration {
        guard name.utf8.count < MachServiceName.limit else { throw MachServiceError.nameTooLong(name) }
        var codes: [MachRegistration.Call: kern_return_t] = [:]
        for call in calls {
            switch call {
            case .checkIn:
                var port = MachPorts.null
                let code = bootstrap_check_in(bootstrap_port, name, &port)
                if code == KERN_SUCCESS, port != MachPorts.null { return MachRegistration(name: name, port: port, call: .checkIn) }
                codes[.checkIn] = code
            case .register:
                let (code, port) = Self.registerDeprecated(name)
                if code == KERN_SUCCESS, let port { return MachRegistration(name: name, port: port, call: .register) }
                codes[.register] = code
            }
        }
        throw MachServiceError.refused(name: name, codes: codes)
    }

    /// Spec 10 §2 — "the app looks it up".
    public func lookUp(name: String) throws -> mach_port_t {
        var port = MachPorts.null
        let code = bootstrap_look_up(bootstrap_port, name, &port)
        guard code == KERN_SUCCESS, port != MachPorts.null else { throw MachServiceError.notFound(name: name, code: code) }
        return port
    }

    private typealias Register = @convention(c) (mach_port_t, UnsafePointer<CChar>, mach_port_t) -> kern_return_t

    /// Spec 10 §2 — "the deprecated `bootstrap_register`": a receive right of
    /// the engine's own, registered under the name. The call is deprecated
    /// since macOS 10.5, so it is reached by its symbol: the build carries no
    /// deprecation warning and still links if the headers ever drop it, and a
    /// Mac without the symbol answers "not supported" here.
    private static func registerDeprecated(_ name: String) -> (kern_return_t, mach_port_t?) {
        // RTLD_DEFAULT, which C spells as a cast Swift doesn't import.
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "bootstrap_register") else { return (KERN_NOT_SUPPORTED, nil) }
        let register = unsafeBitCast(symbol, to: Register.self)
        guard let port = MachPorts.makeReceive() else { return (KERN_RESOURCE_SHORTAGE, nil) }
        // launchd is handed a send right made from the receive right; the engine keeps only the receive right.
        let inserted = mach_port_insert_right(mach_task_self_, port, port, mach_msg_type_name_t(MACH_MSG_TYPE_MAKE_SEND))
        guard inserted == KERN_SUCCESS else {
            MachPorts.destroyReceive(port)
            return (inserted, nil)
        }
        let code = name.withCString { register(bootstrap_port, $0, port) }
        MachPorts.release(port)
        guard code == KERN_SUCCESS else {
            MachPorts.destroyReceive(port)
            return (code, nil)
        }
        return (code, port)
    }
}

/// Port rights, as the Mach channel takes and gives them back. Every right
/// the engine makes or is sent is released by name here, so a leak has one
/// place to look.
public enum MachPorts {
    public static let null = mach_port_t(0)

    /// A new receive right in this task, or nil when the kernel has none to give.
    public static func makeReceive() -> mach_port_t? {
        var port = null
        guard mach_port_allocate(mach_task_self_, MACH_PORT_RIGHT_RECEIVE, &port) == KERN_SUCCESS, port != null else { return nil }
        return port
    }

    /// Gives back one send right (or one reference to it).
    public static func release(_ port: mach_port_t) {
        guard port != null else { return }
        _ = mach_port_deallocate(mach_task_self_, port)
    }

    /// Gives back a receive right: the port dies, and its senders learn so.
    public static func destroyReceive(_ port: mach_port_t) {
        guard port != null else { return }
        _ = mach_port_mod_refs(mach_task_self_, port, MACH_PORT_RIGHT_RECEIVE, -1)
    }
}
