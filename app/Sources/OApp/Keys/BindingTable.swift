// OApp — Spec 10 §9, the binding table as the app reads it.

import Foundation
import OCore

/// Spec 10 §9 — "The binding table is the feature: each binding maps a key
/// on a device to one command, stored in `keys.json` (Spec 1 §3). In v1 the
/// device is the keyboard; MIDI and Stream Deck devices and the scheduler's
/// rows are v1.5. The app reads the table and sends a binding's command with
/// source `key` when its key is pressed."
///
/// The engine refuses a reserved key, a key outside the grammar and a key
/// bound twice (Spec 5 §6), so a table it wrote holds none. A `keys.json`
/// edited by hand may, so each such row is left out here and kept to be
/// listed in the keys overlay, never fired and never a crash (Area 13
/// reading: of two rows on one key, the first in the file is the binding).
public struct BindingTable: Equatable, Sendable {
    /// A keyboard binding the app can fire.
    public struct Row: Equatable, Sendable {
        public var key: KeyName
        public var binding: KeyBinding

        public init(key: KeyName, binding: KeyBinding) {
            self.key = key
            self.binding = binding
        }
    }

    /// Why a keyboard row isn't in the table.
    public enum IgnoredReason: Equatable, Sendable {
        /// Its key is outside §9's grammar.
        case notAKeyName
        /// Its key is reserved.
        case reserved
        /// An earlier row binds the same key.
        case repeated
    }

    /// A keyboard row that is left out, with its key as the file has it.
    public struct Ignored: Equatable, Sendable {
        public var key: String
        public var reason: IgnoredReason

        public init(key: String, reason: IgnoredReason) {
            self.key = key
            self.reason = reason
        }
    }

    /// Spec 10 §9, "Safeguards" — "Settings ▸ Key bindings and the keys
    /// overlay warn when nothing is bound to `next` or to `system clearall`".
    public enum Missing: Equatable, Sendable {
        case next
        case clearAll
    }

    /// The keyboard bindings, in the file's order.
    public private(set) var rows: [Row] = []
    public private(set) var ignored: [Ignored] = []
    private var byKey: [KeyName: Int] = [:]

    public init(_ bindings: [KeyBinding] = []) {
        // "In v1 the device is the keyboard": another device's rows and the scheduler's aren't the app's to fire.
        for binding in bindings where binding.device == "keyboard" && binding.when == nil {
            let text = binding.key ?? ""
            switch KeyName.bindable(text) {
            case .failure(.notAKeyName):
                ignored.append(Ignored(key: text, reason: .notAKeyName))
            case .failure(.reserved):
                ignored.append(Ignored(key: text, reason: .reserved))
            case .success(let name):
                if byKey[name] != nil {
                    ignored.append(Ignored(key: text, reason: .repeated))
                } else {
                    byKey[name] = rows.count
                    rows.append(Row(key: name, binding: binding))
                }
            }
        }
    }

    /// The binding on a key, or nil when nothing is bound to it.
    public func binding(for key: KeyName) -> KeyBinding? {
        byKey[key].map { rows[$0].binding }
    }

    /// What the safeguards find missing.
    public var missing: [Missing] {
        var missing: [Missing] = []
        if !rows.contains(where: { $0.binding.command == .next }) { missing.append(.next) }
        if !rows.contains(where: { $0.binding.command == .systemClearAll }) { missing.append(.clearAll) }
        return missing
    }
}
