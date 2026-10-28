// OCore — the portable core of Project O (core/).
//
// This module holds the objects and on-disk format (Spec 1), the command grammar
// and command objects (Spec 2), and ShowState with the projection function
// (Spec 3). It imports nothing from Apple frameworks: Foundation only, and only
// for UUID, Codable and date parsing at the file boundary. Everything in here is
// a value type, and nothing in here reads a clock, a file, a socket or a GPU.
// See CLAUDE.md, hard rules.
//
// core/Library/ and core/Media/ are the objects (Spec 1 §2, §3, §7),
// core/Format/ the documents, loader, writer, validator and migrations
// (Spec 1 §5, §8), core/Commands/ the command objects (Spec 1 §6, Spec 2 §3),
// core/State/ and core/Projection/ the state and the projection (Spec 3).

import Foundation

/// Module-level constants.
public enum OCore {
    /// The schema version this build writes into every document (Spec 1 §8).
    /// It changes only when a field's meaning changes or a required field is
    /// added; adding an optional field never bumps it.
    public static let schemaVersion = 1

    /// Spec 1 §5 — the `app` field of every document header: the version of
    /// the app that wrote it. Stamped on every save.
    public static let appVersion = "0.1.0"
}
