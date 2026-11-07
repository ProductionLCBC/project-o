# Build order and session prompts

The one place to see what has shipped and what is next. Status is one of: `not started`, `spec needed` (write the spec in Cowork before any code), `in progress`, `in review` (the brief has been posted as the final message of the area's session, waiting for Adam's `approved`), `shipped` (merged to `main`). Claude Code flips the status, writes the `CHANGELOG.md` line and rewrites `docs/STATUS.md` (`/wrap-up`, at the end of every session); Adam only ever writes `approved`. This file is the plan of record; the Build tracker in Nimbalyst has one task per area with the same statuses and mirrors it (`CLAUDE.md`, "Working in Nimbalyst"). No dates, no estimates; the hours in the planning doc were only for ordering.

To start an area: open its task in the Build tracker and start a new Nimbalyst worktree session on `~/Developer/project-o` from it, with the prompt from the section below (Fable, Plan mode, max effort; after approving the plan, Accept edits, high effort; branch `area/<name>`). One area per session; the session sets the task to `in progress`. The session ends by running `/wrap-up`, which puts the status documents on `main` while the code stays on the branch, and then the brief as its final message; Adam reads the brief, asks questions, and writes `approved` in the session, and the same session merges, marks the task `shipped` and removes its worktree. The next area starts in its own session.

## v1 — run a Sunday at one campus from a linked playlist

| # | Area | Spec | Status |
| --- | --- | --- | --- |
| 1 | Channel state and projection (`core/`) | `specs/3-channel-state-and-projection.md` | shipped |
| 2 | Object model and library format (`core/`, `formats/`) | `specs/1-objects-and-format.md` | shipped |
| 3 | Command vocabulary: grammar, parser and printer, validation, OSC mapping (`core/`) | `specs/2-commands.md` | shipped |
| 4 | Engine spike (`engine/`): headless OEngine over OSC, two channels, two stacks, three hours clean | `specs/4-render-pipeline.md` §15 | shipped |
| 5 | Render pipeline, the rest: 1080i weave, text cache, thumbnails, multiviewer, measurement | `specs/4-render-pipeline.md` | shipped |
| 6 | Stacks and presets: slots, boxes, text styles, resolution order, blackout and mute, offset +1 | `specs/6-presets-and-text.md` | spec needed |
| 7 | Output sinks: display per screen, DeckLink with weave, output transitions | `specs/4-render-pipeline.md` §10 | not started |
| 8 | Media pool: hash IDs, index, import by copy, poster frames, missing state | media-pool spec | spec needed |
| 9 | Cues, lists and playlists: write/clear/hold, Go and Time triggers, sections, linked items, live pointer, next | `specs/7-cues-lists-and-playlists.md` | spec needed |
| 10 | Text editor: whole-list text document with cue breaks | edit-mode spec | spec needed |
| 11 | Variables: Time, Date, Timer and Popup slots, captions over OSC | `specs/6-presets-and-text.md` | spec needed |
| 12 | Log and saving: command log with sources, continuous save, launch snapshots | log-and-saving spec | spec needed |
| 13 | Show-mode UI (`app/`): three columns, grid, strip, preview and multiviewer, tabs, top bar, keyboard | show-mode-ui spec | spec needed |
| 14 | Edit mode, minimal: cue inspector with palette, stack editor, channel sheet, preset editor | edit-mode spec | spec needed |
| 15 | Macros, basic: command lists without guards, the clears tab | `specs/2-commands.md` | not started |
| 16 | Audio, basic: routing to numbered outputs, gain | `specs/4-render-pipeline.md` §11 | shipped |
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
docs/build-order.md, named below. Set its task in the Build tracker to "in
progress". Read its spec in full and only the sections of other specs you need.
Propose a plan before writing code and wait for my OK. Then tests first, then the
implementation, in small commits that name the spec section. Every public function
gets a doc comment quoting the spec section it implements. When the spec is silent
or ambiguous, ask me before guessing. When swift test is green, run /wrap-up, which
commits the CHANGELOG.md line, the area's "in review" status and docs/STATUS.md on
main and leaves the code on the branch, then end with the brief as your final
message under the four headings in CLAUDE.md. Then stop. Merge only when I write
"approved".
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
the code. Reuse the types Area 1 created; extend, do not duplicate. Also close
the Area 1 brief's deviation 1: add the media index to ProjectionContext.library
so a media write falls back to the pool item's defaults (Spec 3 §4 Media, §6),
with a test.
```

**Area 3 — Command vocabulary** (branch `area/commands`)

```
Area: 3, command vocabulary. Spec: docs/specs/2-commands.md.
Build in core/: the canonical text grammar (§2), the full v1 vocabulary as Command
objects (§3), parse and print with parse(print(x)) == x (§4), validation and
results (§8), selection expansion and groups (§5), the OSC address mapping both
ways (§6, as pure functions; no sockets in core/), guards (§7), and the log entry
shape (§9). Tests from §10 first. Also close the Area 1 brief's deviation 2: the
command decoder accepts the bare cmd names Spec 1 §6 used before its correction
("next", "macro") on input and prints only the Spec 2 §3 object names.
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

**Area 5 — Render pipeline, the rest** (branch `area/render`)

```
Area: 5, the render pipeline, the rest. Spec: docs/specs/4-render-pipeline.md, §1–§13
are the rules. The spike (Area 4) is on main and holds every display-side criterion of
§15; the DeckLink criteria wait for the bench run with the card, which is deferred.
Build the card-independent parts first and the weave last: what §8 still wants of the
text cache (variables re-laid-out no more than once a second and the box transition on
change, memory pressure shrinking the caches per §12, the substitution record for
pre-flight); the thumbnail and multiviewer aux passes of §10 (IOSurface-backed, rate
limited, the PNG thumbnail cache keyed by cue, stack and library version, skipped first
under pressure per §4); the measurement of §13 the spike left out (the live summary
under the metrics topic, per-output present latency, the thermal and memory-pressure
notes of §12); then the 1080i weave of §10, field-correct on a motion fixture in the
harness, verified on the capture rig when the card run happens (§16). Keep the five
guarantees of §1 and the render thread rules of §3; a new pass is a plan pass type, not a
change to the render loop (§4). Tests first from §16's list; goldens for the aux passes
and the weave. Stop for review at each of: the text cache, the aux passes, the
measurement, the weave. Nothing here runs unattended.
```

**Area 6 — Stacks and presets** (branch `area/presets`)

```
Area: 6, stacks and presets. Spec: docs/specs/6-presets-and-text.md §2–§4 and §9, with
§11's Area 6 tests; Spec 1 §2 and §3, Spec 3 §2, §4 and §7 and Spec 4 §8 and §9 as it
corrected them. On main: the stack pass with fit modes, opacity and mute, the shared
SlotResolver, the +1 slot with its text rasterized a cue ahead, Preset 1 built in. Build
the core changes first: the slot loses its offset and the box gains one (written on
every box), a later slot for a channel is ignored and reported, and the provenance
records the cue's list, with an identical text write from another cue or list updating
it (Spec 3 §2 and §4). Then the engine: offset boxes, with fallback per offset and the
fold within the list in thumbnails; field boxes falling back to the list's title,
author, copyright and ccli; static boxes on an empty channel; the text style's
verticalAlignment, the units with the shadow padding scaled, whole-line overflow with
the ellipsis, tabular digits with the flag in the cache key; DM Sans bundled and
registered in the engine at launch, an installed copy winning a name clash. Last,
Preset 1's "2" layout, the Clock preset, and the fixtures and JSON Schemas of §9
(library-v1 and spike; no schema bump, §2). Tests first from §11's Area 6 list, with
goldens for the anchor, the overflow and the confidence stack. Stop for review after the
core changes and again after the fixtures. Nothing in app/.
```

**Area 9 — Cues, lists and playlists** (branch `area/playlists`)

```
Area: 9, cues, lists and playlists. Spec: docs/specs/7-cues-lists-and-playlists.md, with
§10's tests; Spec 5 §2–§7 and §10 for the edit path this area builds (Spec 7 §7); Spec 1
§2–§5 and §8, Spec 2 §3 and §6, Spec 3 §5 and §6 and Spec 6 §5 as Spec 7 corrected them.
On main: the live pointer with list boundaries; next and previous across items, skipping
headers and missing or empty lists; Go and Time triggers with the armed state, which the
control loop fires as next; section jumps; the fire record; playlist load by title and
date; the atomic writer and the versions folder. Build the core changes first: the
pointer's item becomes itemUuid and the armed trigger gains itemUuid; playlist items gain
a uuid (UUIDv5 for hand-made files) and linked items a listUuid they resolve by;
`playlist "TITLE"` loads by title alone, with §3's order for clashes; `disarm` in the
grammar, parser, printer and OSC form; list folders in the format (the loader walks
lists/ and its folders, skipping dot-folders, records empty folders, applies §2's
tie-breaks and never replaces another file; a save keeps a list in its folder); playlist
files named from their titles. Then the edit path of §7: Spec 5's parser and printer for
the edit family, the one queue, validation, inverses logged with each edit, groups and
typing, the library event, operator lock and library mode, and the debounced write with
E-3's version cadence, for lists, cues, folders and playlists, archive included (other
objects' edits wait for Areas 8, 14 and 17 and are rejected until then); changes on disk,
with the three-second window for moves and the conflicts folder. Then the live pointer of
§4: the kept copies, the place rules and the reads table, the armed trigger sending next
or disarm, and §6's feedback with /o/live/armed and the live event. Last, §8's fixtures
and the playlist schema. Tests first from §10. Stop for review after the core changes,
after the edit path, and after the live pointer. Nothing in app/.
```

**Area 11 — Variables** (branch `area/variables`)

```
Area: 11, variables. Spec: docs/specs/6-presets-and-text.md §5–§8, with §11's Area 11
tests; Spec 1 §3 (the playlist's serviceTime) and Spec 2 §3 and §6 as it corrected them.
Starts after Area 6 is merged: its context values read the provenance Area 6 adds. On
main: [Time], [Date] and [Popup N] in static boxes behind the once-a-second gate, and
popup N set over OSC. Build the core changes first: `timer N set DURATION up` in the
grammar, parser, printer and OSC form, and the playlist's serviceTime with its schema.
Then the variable language (names in any case, the fixed formats, overrun, doubled
brackets, other bracketed text printed as written, numbers above the slot count
resolving empty); variables in text content and, one level deep, in a popup's text; the
v1 set, with the six context values read from the state being drawn and [Service In]
from the live playlist's serviceTime; the adoption pacing (context values at once,
popups at most every 100 ms, the clock and timers once a wall-clock second); timers on
the monotonic clock, counting down and up, with overrun and the noop cases; clearafter
logged from source engine; the /o/timer/N and timers-topic feedback and
/o/channel/N/remaining. Tests first from §11's Area 11 list. Stop for review after the
core changes and again after the adoption pacing. Nothing in app/.
```

**Area 15 — Macros, basic** (branch `area/macros`)

```
Area: 15, macros, basic. Spec: docs/specs/2-commands.md §3 (the macro row), §5 (groups
and macro expansion, the depth cap, the cycle check) and §9 (the macro's own log line
then each inner command under the same group). The runner on main already expands a
macro into its commands with the cap and the check; Area 15 gives the engine the
machine-level and library macros as first-class objects it can run from a key, OSC
and a cue (no guards: Spec 2 §7's guards are v1.5), and the clears tab's command
lists (ux-spec, the tabbed panel) as macros the UI will call. Add `stack all blackout
on | off | toggle` to the vocabulary, one grammar row like `channel all` with its OSC
address, for the clears tab's "blackout stack and all" (Adam's word, 2026-11-04);
propose the Spec 2 §3 and §6 correction in the plan before any code. Tests first from
§10's groups and log rows. Nothing in app/.
```

**Area 16 — Audio, basic** (branch `area/audio`)

```
Area: 16, audio, basic. Spec: docs/specs/4-render-pipeline.md §11 is the rule, with the
audio row of §12 and the audio line of §16; Spec 1 §3 for the Audio Output object (kind
device or sdiEmbedded, device, channels, delayMs, fallbackDevice). The mix graph for one
device is on main since Area 4: routing to numbered outputs, gain with its ramp, the
three audio transitions, the delay line, mute, the clock from delivered samples, the
preroll. Build what §11 still wants: one graph per distinct device, each with its own
render callback, the first-numbered device the clock when a channel is routed to more
than one; device loss while running per §12 (the fallback device if one is configured,
otherwise silence with a badge and a log line, and the device taken back when it
reappears, never a guess); the SDI-embedded feed (an Audio Output whose device is a
DeckLink output: the same graph on a timer thread, scheduled against the card's stream
time through the sink's scheduleAudio, so embedded audio and the picture share one
clock); audio underruns per device in the minute record (§13). Tests first from §16's
audio line, on the software device: sample-exact crossfades, ramps and the delay line
stay green; device loss simulated and recovered with the documented response and log
line; the embedded feed's samples landing on the right stream time against a fake
card. Keep §3's thread rules: nothing on the render thread, nothing blocking in a
render callback. Nothing here runs unattended; the dev Mac has BlackHole for a silent
device and no card, so the hardware path waits for the bench.
```

**Areas marked `spec needed`**: open Cowork with this repo folder connected and ask for the spec first; it is written in `docs/specs/` and reviewed before its prompt is added here.
