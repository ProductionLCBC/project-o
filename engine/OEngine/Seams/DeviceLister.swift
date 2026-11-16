// OEngine — Spec 4 §14, a seam: the devices this Mac has.

import OCore

/// Spec 10 §3, the `devices` query — "Screens (`display:<uuid>`, name, frame,
/// current mode, and whether it is mirrored), DeckLink output ports
/// (`decklink:<id>`, name, the modes it plays) and audio output devices (UID,
/// name, channel count, whether it is the system default)". Spec 10 §13 —
/// first run reads the same list to decide "which screens become outputs".
/// One v1 implementation, `SystemDevices`; Spec 10 §16 — "Area 19's tests run
/// the first-run writer against fake device lists (screens, ports, audio
/// devices)", which is `FakeDevices`.
public protocol DeviceLister: Sendable {
    /// The devices now: screens as the Mac reports them, ports "in the order
    /// the driver lists them", and the audio devices that can play.
    func devices() -> DetectedDevices
}
