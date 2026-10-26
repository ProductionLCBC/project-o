# Build order and session prompts

The one place to see what has shipped and what is next. Status is one of: `not started`, `spec needed` (write the spec in Cowork before any code), `in progress`, `in review` (the review brief is in `docs/reviews/`, waiting for Adam's `approved`), `shipped` (merged to `main`). Claude Code flips the status, writes the `CHANGELOG.md` line and rewrites `docs/STATUS.md` (`/wrap-up`, at the end of every session); Adam only ever writes `approved`. No dates, no estimates; the hours in the planning doc were only for ordering.

To start an area: copy its prompt from the section below into a new Code session on `~/Developer/project-o` (Fable, Plan mode, max effort; after approving the plan, Accept edits, high effort; plain `area/<name>` branch, worktree off). One area per session. The session ends by writing the review brief and running `/wrap-up`, which puts the brief and the status documents on `main` while the code stays on the branch; Adam reads the brief, asks questions, and writes `approved`, and the same session merges and can start the next area.

## v1 — run a Sunday at one campus from a linked playlist

| # | Area | Spec | Status |
| --- | --- | --- | --- |
| 1 | Channel state and projection (`core/`) | `specs/3-channel-state-and-projection.md` | in review |
| 2 | Object model and library format (`core/`, `formats/`) | `specs/1-objects-and-format.md` | not started |
| 3 | Command vocabulary: grammar, parser and printer, validation, OSC mapping (`core/`) | `specs/2-commands.md` | not started |
| 4 | Engine spike (`engine/`): headless OEngine over OSC, two channels, two stacks, three hours clean | `specs/4-render-pipeline.md` §15 | not started |
| 5 | Render pipeline, the rest: 1080i weave, text cache, thumbnails, multiviewer, measurement | `specs/4-render-pipeline.md` | not started |
| 6 | Stacks and presets: slots, boxes, text styles, resolution order, blackout and mute, offset +1 | `specs/1-objects-and-format.md` + presets-and-text spec | spec needed |
| 7 | Output sinks: display per screen, DeckLink with weave, output transitions | `specs/4-render-pipeline.md` §10 | not started |
| 8 | Media pool: hash IDs, index, import by copy, poster frames, missing state | media-pool spec | spec needed |
| 9 | Cues, lists and playlists: write/clear/hold, Go and Time triggers, sections, linked items, live pointer, next | cues-lists-playlists spec | spec needed |
| 10 | Text editor: whole-list text document with cue breaks | edit-mode spec | spec needed |
| 11 | Variables: Time, Date, Timer and Popup slots, captions over OSC | presets-and-text spec | spec needed |
| 12 | Log and saving: command log with sources, continuous save, launch snapshots | log-and-saving spec | spec needed |
| 13 | Show-mode UI (`app/`): three columns, grid, strip, preview and multiviewer, tabs, top bar, keyboard | show-mode-ui spec | spec needed |
| 14 | Edit mode, minimal: cue inspector with palette, stack editor, channel sheet, preset editor | edit-mode spec | spec needed |
| 15 | Macros, basic: command lists without guards, the clears tab | `specs/2-commands.md` | not started |
| 16 | Audio, basic: routing to numbered outputs, gain | `specs/4-render-pipeline.md` §11 | not started |
| 17 | Settings: inputs, outputs, audio outputs, keys, media root, startup | settings section of show-mode-ui spec | spec needed |
| 18 | Operator lock: passcode in the Keychain, edit mode blocked | show-mode-ui spec | spec needed |

Gate between 4 and 5: nothing in `app/` starts until the spike passes every criterion in Spec 4 §15.

## v1.5 — after the pilot

| Area | Status |
| --- | --- |
| Runtime undo: channel snapshots with playheads and pointer, restore provenance | spec needed |
| Library mode and local copies: detach, promote, relink, where used, version history | spec needed |
| NDI output and key/fill | spec needed |
| Live inputs: SDI, NDI and camera sources, freeze, no-signal | spec needed |
| Audio transitions: crossfade, fade through silence, J and L offsets, sync offset | spec needed |
| Pre-flight report | spec needed |
| Optimize on import: transcode, sync check, audio sets | spec needed |
| Macro guards and the scheduler | spec needed |
| Lookahead and multiviewer polish: negative offsets, ring buffer | spec needed |
| Distribution conventions: Syncthing layout, local-copy reports | spec needed |

## v2

Slide designer; timelines and clocks (LTC, MTC, Art-Net, chase, playlist timeline); custom transitions; CCLI reporting. Deferred entirely: arrangements, lyric generator, Planning Center service import, remote app, Windows, Bibles.

## Session prompts

Every prompt starts the same way; the per-area part follows.

```
Read docs/STATUS.md, then CLAUDE.md. Work on exactly one area from
docs/build-order.md, named below. Read its spec in full and only the sections of
other specs you need. Propose a plan before writing code and wait for my OK. Then
tests first, then the implementation, in small commits that name the spec section.
Every public function gets a doc comment quoting the spec section it implements.
When swift test is green, write the review brief from docs/reviews/TEMPLATE.md and
run /wrap-up, which commits the brief, the CHANGELOG.md line, the area's "in review"
status and docs/STATUS.md on main and leaves the code on the branch. Then stop.
Merge only when I write "approved".
```

**Area 1 — Channel state and projection** (branch `area/projection`)

```
Area: 1, channel state and projection. Spec: docs/specs/3-channel-state-and-projection.md.
Build in core/: the value types from §10, the projection from §6, the 24 rows of
the §9 test table as individual XCTest cases named after their row numbers, the
determinism property test, and the ShowState Codable round-trip test. Where the
projection needs object or command shapes, take them from Spec 1 §2–3 and §6 and
Spec 2 §3–4, defining only what this area uses.
```

**Area 2 — Object model and library format** (branch `area/format`)

```
Area: 2, object model and library format. Spec: docs/specs/1-objects-and-format.md.
Build in core/ (documents, loader, writer, validator, migrations) and formats/
(JSON schemas). Start by creating the fixture library in tests/fixtures/library-v1/
from the worked examples in §9, then the tests in §10 (round trip, identity,
cue addressing, validation report, migration, atomic writes, stack rule), then
the code. Reuse the types Area 1 created; extend, do not duplicate.
```

**Area 3 — Command vocabulary** (branch `area/commands`)

```
Area: 3, command vocabulary. Spec: docs/specs/2-commands.md.
Build in core/: the canonical text grammar (§2), the full v1 vocabulary as Command
objects (§3), parse and print with parse(print(x)) == x (§4), validation and
results (§8), selection expansion and groups (§5), the OSC address mapping both
ways (§6, as pure functions; no sockets in core/), guards (§7), and the log entry
shape (§9). Tests from §10 first.
```

**Area 4 — Engine spike** (branch `area/spike`)

```
Area: 4, the engine spike. Spec: docs/specs/4-render-pipeline.md, §15 defines the
scope and §1–§13 the rules. Build the headless OEngine process in engine/ with the
seams in §14 as protocols, the master tick, the frame plan builder over core/'s
projection, one video ContentSource, the still source, the channel pass, the
per-line text rasterizer, the stack pass with the +1 offset slot, the display and
DeckLink sinks, the audio graph for one device, the metrics ring, black box and
watchdog, and the headless harness with a software clock and capturing sink.
Before any Metal code, write the headless harness tests and the golden-image
scaffolding. The DeckLink SDK is in vendor/DeckLinkSDK (see vendor/README.md).
Stop for review at each of: the tick and harness, the channel pass, the stack
pass, each sink. Nothing here runs unattended.
```

**Areas marked `spec needed`**: open Cowork with this repo folder connected and ask for the spec first; it is written in `docs/specs/` and reviewed before its prompt is added here.
