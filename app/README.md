# app/

The operator app: SwiftUI and AppKit, show mode and edit mode, talking to the engine only through the Spec 2 API (plus a Mach channel for the preview surfaces, the channel pictures and the meters, Spec 10 §2). It never defines its own notion of state and never does anything the command vocabulary cannot, apart from Spec 10 §3's local requests.

Nothing lived here until the engine spike passed (Spec 4 §15), a gate Adam lifted for Area 13, the show-mode app, on 2026-11-17, with the bench run's DeckLink and capture lines still owed before Area 7 and the pilot. This folder gets an Xcode project that depends on the package at the repository root, and it builds Spec 10 (`docs/specs/10-show-mode-ui.md`), which carries over what the clickable demo settled, and Spec 11 (`docs/specs/11-edit-mode.md`) for edit mode.
