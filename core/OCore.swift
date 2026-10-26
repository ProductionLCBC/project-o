// OCore — the portable core of Project O (core/).
//
// This module holds the objects and on-disk format (Spec 1), the command grammar
// and command objects (Spec 2), and ShowState with the projection function
// (Spec 3). It imports nothing from Apple frameworks: Foundation only, and only
// for UUID, Codable and date parsing at the file boundary. Everything in here is
// a value type, and nothing in here reads a clock, a file, a socket or a GPU.
// See CLAUDE.md, hard rules.
//
// The first real code in this module is the projection (Spec 3 §6) and its test
// table (Spec 3 §9). Start there.

import Foundation

/// Module-level constants.
public enum OCore {
    /// The schema version this build writes into every document (Spec 1 §8).
    /// It changes only when a field's meaning changes or a required field is
    /// added; adding an optional field never bumps it.
    public static let schemaVersion = 1
}
