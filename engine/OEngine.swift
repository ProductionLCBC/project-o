// OEngine — the playback engine of Project O (engine/, Spec 4).
//
// This target is a placeholder until the engine spike begins (Spec 4 §15).
// When it does: every seam in Spec 4 §14 gets a protocol in its own file with a
// doc comment naming that section; the engine is constructed with its backend,
// clock and sinks injected; shaders live in one .metal file per pass; and
// Objective-C++ is confined to the DeckLink module. OEngine imports ShowState,
// Command and Effect from OCore and never defines its own notion of state.
//
// The #if keeps the package building on Linux CI, where only OCore matters.

import OCore

#if canImport(Metal)
import Metal
#endif

/// Module-level constants.
public enum OEngine {
    /// True on platforms where the Metal backend can be built.
    public static var hasMetal: Bool {
        #if canImport(Metal)
        return true
        #else
        return false
        #endif
    }
}
