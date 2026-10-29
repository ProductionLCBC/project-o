// OEngine — the playback engine of Project O (engine/OEngine, Spec 4).
//
// Spec 4 §14 — "OEngine is the second Swift package target, depending on OCore
// and on Apple frameworks ... It runs as its own process and talks to the
// operator app only through the Spec 2 API plus shared IOSurfaces for
// previews." Every seam of §14 is a protocol in its own file under Seams/;
// the engine is constructed with its backend, clock and sinks injected, so
// tests run it headless with a software clock and a capturing sink. OEngine
// imports ShowState, Command and Effect from OCore and never defines its own
// notion of state.
//
// Folders: Seams/ (the §14 protocols), Plan/ (the §4 frame plan and its
// builder), Clock/ (§2), Render/ (§3, §4, the render loop), Control/ (§3, the
// control thread), Sources/ (§6), Text/ (§8), Sinks/ (§10), Audio/ (§11),
// Metrics/ (§13, the watchdog of §12), OSC/ (Spec 2 §6), Harness/ (§14, §16),
// CommandLine/ (§15, the `oengine` process and the soak rig).

import Foundation
import OCore

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
