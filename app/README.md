# app/

The operator app: SwiftUI and AppKit, show mode and edit mode, talking to the engine only through the Spec 2 API (plus a Mach channel for the preview surfaces, the channel pictures and the meters, Spec 10 §2). It never defines its own notion of state and never does anything the command vocabulary cannot, apart from Spec 10 §3's local requests.

Nothing lived here until the engine spike passed (Spec 4 §15), a gate Adam lifted for Area 13, the show-mode app, on 2026-11-17, and for Area 14, edit mode, on 2026-11-18, with the bench run's DeckLink and capture lines still owed before Area 7 and the pilot. It builds Spec 10 (`docs/specs/10-show-mode-ui.md`), which carries over what the clickable demo settled, and Spec 11 (`docs/specs/11-edit-mode.md`) for edit mode.

## How it is put together

The app's code is targets of the package at the repository root, so `swift build` compiles it and `swift test` runs its tests; the Xcode project is a shell around them (Adam's answer to the Area 13 plan, 2026-11-17).

| Piece | Where | Holds |
| --- | --- | --- |
| `OApp` | `Sources/OApp/` | What the app does, with no AppKit and no SwiftUI: the connection to the engine's local socket, the supervisor that finds, starts and restarts the engine, the store that keeps what the engine reported, the models each topic and query feeds, first run's checks, the strings. Every wait goes through a clock a test can move. |
| `OAppUI` | `Sources/OAppUI/` | The views: AppKit for the window, the grid, the strip and the trees, SwiftUI for simple panels (Spec 10 §1). Thin adapters over `OApp`. |
| `OAppScripted` | `Sources/OAppScripted/` | The scripted engine on a local socket that the tests drive (Spec 10 §16). It shares no code with `OApp`, and plays back the engine's own answers as `tests/fixtures/api-v1/` records them. |
| `Project O.app` | `ProjectO.xcodeproj`, `Shell/`, `Info.plist`, `Config/` | `main.swift` (one call), the string catalog, the settings, and the build phase that embeds the engine. |

Tests are in `tests/OAppTests` (behavior, and the contract suite that holds the app's client to the real API hub) and `tests/OAppViewTests` (the views, laid out offscreen).

## Building the app

```
xcodebuild -project app/ProjectO.xcodeproj -scheme "Project O" -configuration Debug -derivedDataPath .build/xcode build
```

The "Embed the engine" phase runs `scripts/embed-engine.sh`, which builds `oengine` with the package's own build (never through Xcode) and puts it at `Contents/Helpers/oengine`, signed ad hoc (ADR 0007), with its shaders and fonts in `Contents/Resources` and a link to them beside the engine. `OENGINE_CONFIGURATION=debug` on the `xcodebuild` line embeds the debug engine already in `.build`.

The project file is written by hand: one folder, `Shell/`, whose files are the target's without being listed, a reference to the package at `..`, and its settings in `Config/Shell.xcconfig`, each with its reason. New Swift goes in `Sources/`, not in the project.

## Strings

Every string the app shows is a key of `Shell/Localizable.xcstrings` (Spec 10 §15). Add one to the table in `scripts/strings-catalog.py` and to `StringKey` (`Sources/OApp/Strings/Strings.swift`), then run `python3 -I scripts/strings-catalog.py`; `StringCatalogTests` fails when the two differ.
