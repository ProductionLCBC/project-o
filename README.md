# Project O

A Metal-native macOS presenter with DeckLink SDI output, built by LCBC Church as a ProPresenter replacement for a multi-campus church. Working name until the brand team names it.

**Status:** early; no UI yet. Areas 1–4 of `docs/build-order.md` have shipped: in `OCore` and `formats/`, channel state and the projection, the object model and library format, and the command vocabulary; in `engine/`, the engine spike, a headless `OEngine` driven over OSC. Next is the spike's three-hour run on the test bench, then Area 5, the rest of the render pipeline. `docs/STATUS.md` is the current one-page view.

## Read first

- `ARCHITECTURE.md` — the model in one page.
- `CLAUDE.md` — how work happens here (the loop, the hard rules, what runs unattended).
- `docs/specs/` — one page per area, the authority on detail; `docs/ux-spec.md` is the UX and system design spec they refine.
- `CHANGELOG.md` — one line per shipped area; the only progress tracking.

## Build

Requires a Mac with Xcode (Metal shaders need the full Xcode, not only the command-line tools), git, and optionally the GitHub CLI.

```sh
scripts/bootstrap.sh    # checks the toolchain, builds, runs the tests
swift build
swift test
```

`OCore` is pure Swift and also builds and tests on Linux, which CI uses to prove that no Apple framework has crept into the core.

## Layout

```
app/        the operator app (SwiftUI + AppKit), a client of the engine's API
engine/     OEngine: the playback engine as its own process (Metal, VideoToolbox, Core Audio, DeckLink)
core/       OCore: objects, commands, channel state and the projection; pure Swift, no Apple frameworks
formats/    JSON schemas and the .pro importer
tools/      Python importers and Planning Center tooling, as API clients
docs/       specs/ (the authority), decisions/ (ADRs), ux-spec.md
tests/      unit tests, golden images, soak scenarios, the fixture library
```

## Contributions

The project is early and not accepting contributions. Issues and pull requests are limited to collaborators.

## License

Copyright (c) 2026 LCBC Church. All rights reserved. The source is public to read; no licence to use, copy, modify or distribute it is granted yet, beyond viewing and forking on GitHub under GitHub's Terms of Service. An open-source licence will be chosen before contributions open.

The Blackmagic DeckLink SDK is not included and stays under Blackmagic Design's own terms; `vendor/README.md` says how to get it. Without it the engine still builds, with SDI output unavailable.

Not affiliated with or endorsed by Renewed Vision. ProPresenter is a trademark of Renewed Vision.
