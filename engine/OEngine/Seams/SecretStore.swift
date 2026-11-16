// OEngine — Spec 10 §12, the Keychain behind a seam.

import Foundation

/// What a read of one secret gave.
public enum SecretRead: Equatable, Sendable {
    case found(Data)
    /// There is no such item: the first launch on this Mac.
    case missing
    /// The item is there, or may be, and can't be read: someone refused the
    /// system's prompt, the keychain is locked, or the system failed. The
    /// text is for the log.
    case unreadable(String)
}

/// Spec 10 §12 — "The Keychain (R2). Only the engine reads or writes it: two
/// generic-password items under the service "Project O", with the machine's
/// uuid in their account names". Spec 4 §14 — every device and system
/// service behind a seam, so the engine's rules are tested without it:
/// `KeychainStore` is the real one, `MemorySecretStore` the harness's. A
/// read may wait on a system prompt for as long as nobody answers it, so
/// both calls are made from a background thread only, never one the outputs
/// depend on (Spec 10 §2, "never holds back the outputs").
public protocol SecretStore: Sendable {
    func read(account: String) -> SecretRead
    /// Writes the item, replacing what it held; false when it couldn't.
    func write(_ value: Data, account: String) -> Bool
}

/// Spec 10 §12 — the items' names: the service "Project O", and the
/// machine's uuid in each account name.
public enum SecretAccount {
    public static let service = "Project O"

    /// The API token's item for one machine (Area 19 reading: the account is `api-token.<uuid>`).
    public static func token(machine: UUID) -> String {
        "api-token." + machine.uuidString.lowercased()
    }
}
