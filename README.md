# Project O

A Metal-native macOS presenter with DeckLink SDI output, built by LCBC Church as a ProPresenter replacement for a multi-campus church. Working name until the brand team names it. Private until after the pilot; intended to open as open source after that.

**Status:** pre-spike. The four foundation specs are accepted; the first code (the projection in `OCore`) is next, then the engine spike. No UI exists yet.

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

## License

To be chosen before the repository opens. Until then: all rights reserved, LCBC Church.
