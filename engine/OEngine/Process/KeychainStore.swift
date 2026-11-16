// OEngine — Spec 10 §12, the real Keychain.

import Foundation
import Security

/// Spec 10 §12 — "two generic-password items under the service "Project O"
/// ... They are in the login keychain, not the data-protection keychain,
/// which needs an entitlement only a paid team can grant (ADR 0007)." The
/// queries name no keychain and don't ask for the data-protection one, so
/// macOS uses the user's default, which is the login keychain.
///
/// A read can put the system's prompt on screen and wait for an answer:
/// after an update the engine's signature has changed and macOS asks again.
/// Nothing here is called from a thread the outputs depend on.
public struct KeychainStore: SecretStore {
    public init() {}

    private func match(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: SecretAccount.service,
         kSecAttrAccount as String: account]
    }

    public func read(account: String) -> SecretRead {
        var query = match(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { return .unreadable("the item holds no data") }
            return .found(data)
        case errSecItemNotFound:
            return .missing
        default:
            return .unreadable(Self.text(status))
        }
    }

    public func write(_ value: Data, account: String) -> Bool {
        let updated = SecItemUpdate(match(account) as CFDictionary, [kSecValueData as String: value] as CFDictionary)
        if updated == errSecSuccess { return true }
        guard updated == errSecItemNotFound else { return false }
        var item = match(account)
        item[kSecValueData as String] = value
        item[kSecAttrLabel as String] = "Project O"
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    static func text(_ status: OSStatus) -> String {
        (SecCopyErrorMessageString(status, nil) as String?) ?? "OSStatus \(status)"
    }
}
