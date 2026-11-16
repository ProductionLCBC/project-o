// OEngine — Spec 2 §9 and Spec 10 §12, the LAN API's token.

import Foundation

/// Spec 10 §12 — "the API token (32 random bytes, base64url)"; "It makes the
/// token at first launch". Spec 10 §2 — "At launch the engine reads its two
/// Keychain items ... on a background thread, and makes the token if there
/// is none".
public enum ApiToken {
    public static let byteCount = 32

    /// What reading the token at launch came to.
    public enum Outcome: Equatable, Sendable {
        /// The item was there.
        case read(String)
        /// There was none: this one was made and written.
        case made(String)
        /// The Keychain can't be read, or the new token couldn't be written: no token, and the LAN stays closed.
        case unreadable(String)

        public var token: String? {
            switch self {
            case .read(let token), .made(let token): return token
            case .unreadable: return nil
            }
        }
    }

    /// A new token from the system's random source.
    public static func make() -> String {
        var generator = SystemRandomNumberGenerator()
        return make(using: &generator)
    }

    static func make(using generator: inout some RandomNumberGenerator) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        for index in bytes.indices { bytes[index] = UInt8.random(in: .min ... .max, using: &generator) }
        return base64url(Data(bytes))
    }

    /// RFC 4648 §5, without padding: letters, digits, `-` and `_` only, so the
    /// token goes into a JSON string, a URL or a settings field as it is.
    static func base64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Reads the machine's token, or makes and writes it when there is none.
    /// May wait on a system prompt: call it from a background thread.
    ///
    /// Area 19 readings: whatever text the item holds is the token, so one a
    /// person put there by hand is honoured; an item that isn't text, or is
    /// empty, is `unreadable` and is not replaced, since replacing it is New
    /// Token…'s job (Spec 10 §12); and a new token that can't be written is
    /// not used, since the next launch would make another and every remote
    /// would have to sign in again.
    public static func load(from store: any SecretStore, machine: UUID) -> Outcome {
        let account = SecretAccount.token(machine: machine)
        switch store.read(account: account) {
        case .found(let data):
            guard let token = String(data: data, encoding: .utf8), !token.isEmpty else {
                return .unreadable("the token's Keychain item doesn't hold a token")
            }
            return .read(token)
        case .missing:
            let token = make()
            guard store.write(Data(token.utf8), account: account) else {
                return .unreadable("the new token could not be written to the Keychain")
            }
            return .made(token)
        case .unreadable(let why):
            return .unreadable(why)
        }
    }
}
