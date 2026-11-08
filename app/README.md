# app/

The operator app: SwiftUI and AppKit, show mode and edit mode, talking to the engine only through the Spec 2 API (plus a Mach channel for the preview surfaces, the channel pictures and the meters, Spec 10 §2). It never defines its own notion of state and never does anything the command vocabulary cannot, apart from Spec 10 §3's local requests.

Nothing lives here until the engine spike passes (Spec 4 §15). When it does, this folder gets an Xcode project that depends on the package at the repository root, and it builds Spec 10 (`docs/specs/10-show-mode-ui.md`), which carries over what the clickable demo settled.
