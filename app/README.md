# app/

The operator app: SwiftUI and AppKit, show mode and edit mode, talking to the engine only through the Spec 2 API (plus shared IOSurfaces for previews). It never defines its own notion of state and never does anything the command vocabulary cannot.

Nothing lives here until the engine spike passes (Spec 4 §15). When it does, this folder gets an Xcode project that depends on the package at the repository root, and the show-mode UI spec in `docs/specs/` is written first, carrying over what the clickable demo settled.
