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
| 8 | Media pool: hash IDs, index, import by copy, poster frames, missing state | `specs/8-media-pool.md` | spec needed |
| 9 | Cues, lists and playlists: write/clear/hold, Go and Time triggers, sections, linked items, live pointer, next | `specs/7-cues-lists-and-playlists.md` | spec needed |
| 10 | Text editor: whole-list text document with cue breaks | `specs/11-edit-mode.md` | spec needed |
| 11 | Variables: Time, Date, Timer and Popup slots, captions over OSC | `specs/6-presets-and-text.md` | spec needed |
| 12 | Log and saving: command log with sources, continuous save, launch snapshots | `specs/9-log-and-saving.md` | spec needed |
| 13 | Show-mode UI (`app/`): three columns, grid, strip, preview and multiviewer, tabs, top bar, keyboard | `specs/10-show-mode-ui.md` | spec needed |
| 14 | Edit mode, minimal: the Cues page with the inspector and palette, stack editor, channel sheet, preset editor with text styles, small editors for grades, transitions, audio transitions and macros; the render and uses queries | `specs/11-edit-mode.md` | spec needed |
| 15 | Macros, basic: command lists without guards, the clears tab | `specs/2-commands.md` | not started |
| 16 | Audio, basic: routing to numbered outputs, gain | `specs/4-render-pipeline.md` §11 | shipped |
| 17 | Settings: outputs, audio outputs, key bindings, media, startup and backup, the lock page, variables, tracking, thumbnails and engine, network, command bar | `specs/10-show-mode-ui.md` | spec needed |
| 18 | Operator lock: passcode in the Keychain, edit mode blocked | `specs/10-show-mode-ui.md` | spec needed |
| 19 | Engine API and first run: the local socket and the LAN API, topics and queries, the preview channel, first run | `specs/10-show-mode-ui.md` §2, §3 and §13 | spec needed |

Gate between 4 and 5: nothing in `app/` starts until the spike passes every criterion in Spec 4 §15.

## v1.5 — after the pilot

| Area | Status |
| --- | --- |
| Runtime undo: channel snapshots with playheads and pointer, restore provenance | spec needed |
| Library mode and local copies: detach, promote, relink, where used, version history | spec needed |
| NDI output and key/fill | spec needed |
| Live inputs: SDI, NDI and camera sources, freeze, no-signal | spec needed |
| Audio transitions: the sync-offset UI and the strip's split transition bar | spec needed |
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

**Area 8 — Media pool** (branch `area/media`)

```
Area: 8, media pool. Spec: docs/specs/8-media-pool.md, with §11's tests; Spec 1 §3, §5,
§7 and §8, Spec 2 §2, §3, §6 and §9, Spec 3 §4, §6 and §8, Spec 4 §10 and Spec 5 §1, §2
and §6–§8 as Spec 8 corrected them. Starts after Area 9 is merged: media replace, media
delete and the edits of an item's defaults ride its edit path. On main: the two index
types, a resolver that reads every path under the media root, SHA-256 hashing, a missing
set computed once at launch, the poster loader, and the decoders Spec 4 §6 plays. Build
the core changes first: the resolver returns a location (the media root, machine/media/
or an override) and follows both indexes' replaced maps to the end of the chain with the
repeat check; the machine index gains its replaced map and an entry gains deletedAt;
media-local.json's paths read against machine/media/ (no schema bump, §9); the media
target and the hash token (the edit target and json values come with Area 9's edit
parser) and the six media commands in the grammar, parser, printer and OSC form;
dropChannels in machine settings; the projection's media defaults read from the entry a
ref resolves to. Then the file work on a background worker: import (§3) with staging,
hash first, the kinds v1 takes, numbered names, the hidden copy checked against its
hash, diskFull; the walk (§4) at launch, on media rebuild and from the watcher, with the
two-second settle, the hash cache, moves, landings, copies, ids the other folder's index
holds, pruning in the launch walk only and the undo steps it drops; presence per
location after every walk and index reload, with the missing set, the thumbnail keys and
the OSC hash expansion following it; the media root refused off the startup volume (§2,
M-8). Then posters at the in-point and pool tiles (§5), delete and replace with their
inverses as edits, groups included (§6), the media topic and mediaUse (§7), the defaults
edits (Spec 7 §7), and §9's fixtures. Tests first from §11; the clauses marked Area 12
wait for edit undo. Stop for review after the core changes, after the walk, and after
delete and replace. Nothing in app/: the app's staging copy and the pool tab come with
Area 13.
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
pointer's item becomes itemUuid and the armed trigger gains itemUuid; playlist items
gain a uuid (UUIDv5 for hand-made files) and linked items a listUuid they resolve by;
`playlist "TITLE"` loads by title alone, with §3's order for clashes; `disarm` in the
grammar, parser, printer and OSC form; list folders in the format (the loader walks
lists/ and its folders, skipping dot-folders, records empty folders, applies §2's
tie-breaks and never replaces another file; a save keeps a list in its folder); playlist
files named from their titles. Then the edit path of §7: Spec 5's parser and printer for
the edit family, with the move by position of a child that has no address of its own,
such as a cue's command (Spec 5 §4 as Spec 11 corrected it), the one queue, validation,
with a cue's uuid unique in its list (Spec 5 §6), inverses logged with each edit, groups
and typing, the library event, operator lock and library mode, and the debounced write
with E-3's version cadence, with kept versions filed by list uuid and never written over
(Spec 9 §6), for lists, cues, folders and playlists, archive included (other objects'
edits wait for Areas 8, 14 and 17 and are rejected until then); changes on disk, with
the three-second window for moves and the conflicts folder. Then the live pointer of §4:
the kept copies, the place rules and the reads table, the armed trigger sending next or
disarm, and §6's feedback with /o/live/armed and the live event. Last, §8's fixtures and
the playlist schema. Tests first from §10. Stop for review after the core changes, after
the edit path, and after the live pointer. Nothing in app/.
```

**Area 10 — Text editor** (branch `area/text`)

```
Area: 10, text editor. Spec: docs/specs/11-edit-mode.md §5, with §13's Area 10 tests,
and §1, §2 and §10 for the rules every page follows, the frame and accessibility; Spec 5
§4 and §5 for the channel edit, groups and typing, Spec 3 §3 and §7 for tracking and the
cue view, and Spec 10 §6, §9 and §15 for the app's fold of a list, the keys and
accessibility, all as Spec 11 corrected them. Starts after Area 14 is merged: the text
editor is edit mode's Text page and joins its frame and Cues page. On main: Spec 5's
edit path with typing folded a second at a time (Area 9), the app's fold of a list from
its top and the scripted engine (Area 13), and edit mode's frame and Cues page (Area
14). Build the document first: a chunk per cue on the chosen channel, in each state a
cue can leave it, with the sections in the margin and the thumbnails; then typing (whole
bodies at most four times a second and once on leaving, composed text held back, an
emptied chunk sent as a clear that keeps its track riders, typing into held text as a
copy of the held write, the three chunks after the live cue sent only on leaving),
selection within a chunk, and other clients' changes. Then breaks: split, merge and
moved breaks as Spec 5 §5's groups, with the questions a merge asks. Then paste: breaks
at blank lines and section lines, repeats, SongSelect's footer, a paste into an empty
list or into a chunk, the question a long paste with no breaks asks, and Paste as
Two-Line Cues. Last, undo as the library's while the last change is the editor's own,
the keys, and Open in Text Editor in the list menus. Tests first from §13, against the
fixture library's lists and the lyric sheets §11 names. Stop for review after typing,
after breaks, and after paste.
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

**Area 12 — Log and saving** (branch `area/saving`)

```
Area: 12, log and saving. Spec: docs/specs/9-log-and-saving.md, with §10's tests; Spec 5
§8 and §9 for edit undo and the restores; Spec 1 §3–§5, Spec 2 §3, §6 and §9, Spec 3 §3
and §8, Spec 4 §12 and §13, Spec 5 §2, §6 and §9, Spec 6 §7, Spec 7 §2 and Spec 8 §2 as
Spec 9 corrected them. Starts after Area 9 is merged: it builds on Area 9's edit path,
its debounced write and its versions filed by list uuid. On main: LogEntry and its line,
the atomic writer and write plans, the versions file, the restoreLastState and snapshots
settings, Machine.lastState read from state/last.json, the black box writing to the
folder the command line names, and EngineLog in unified logging. Build the core changes
first: LogEntry's note lines and its undoes and redoes fields; the two restore commands
in the grammar, parser, printer and OSC form; last.json's new keys. Then the logs (§2):
the command log and the engine log per local day, a group's lines in one write, synced
each second, a partial last line ended on opening, seq per run, the engine's notes, the
API's note request with its cap, and the black box moved to machine/blackbox/ in hourly
files, trimmed within the day, its reader following. Then the last state (§4): its
writes, the clean and restored flags, the minute refresh, the pending clears, the
two-hour limit and the once-only guard, Spec 3 §8's replacement of ShowState, and the
launch order. Then snapshots (§3), edit undo and redo with the history topic (§5), and
the restore commands with the two queries, the renumber check and the worker and queue
handling (§6). Last, retention, the low and full disk and the saving topic (§7), and
§8's fixture. Tests first from §10. Stop for review after the logs, after the last
state, and after the restore commands. Nothing in app/.
```

**Area 13 — Show-mode UI** (branch `area/show`)

```
Area: 13, show-mode UI. Spec: docs/specs/10-show-mode-ui.md §1–§10, §14 and §15, with
§18's Area 13 tests; the UX spec (docs/ux-spec.md) and the clickable demo for look and
feel where the spec is silent, asking before guessing. Starts after Area 19 is merged
and after the bench run passes (Spec 4 §15). The app is new: an Xcode project in app/
that depends on the package at the root, with AppKit and SwiftUI as CLAUDE.md divides
them. Build the engine connection first: the roots in the app's preferences; finding,
starting and restarting the engine with the curtains and the restart rule (§2, choice
U-7); Quit; the scripted engine on a local socket that the tests drive; and the models
fed by §3's topics and queries. Then the window and its regions (§4–§8), with the
previews, the channel pictures and the meters from the Mach channel; the keys with their
precedence and the fixed keys (§9); the edits of §10 with undo and redo; drops from the
Finder that import and then write (choice U-8); the restore sheets and the tags (§14);
the notes and view.json; and VoiceOver labels and the string catalog from the first
build (§15). Edit mode is Area 14's, Bind a Key… waits for Area 17, and Lock Station and
the lock tag for Area 18: their entries stay disabled until then. Tests first from §18.
Stop for review after the engine connection, after the grid and the strip, and after the
keys.
```

**Area 14 — Edit mode** (branch `area/edit`)

```
Area: 14, edit mode. Spec: docs/specs/11-edit-mode.md §1–§4 and §6–§11, with §13's Area
14 tests; the UX spec (docs/ux-spec.md) and the clickable demo's cue inspector for look
and feel where the spec is silent, asking before guessing; Spec 5 §2 and §4–§6 for the
edits, when they show, their checks and inverses, Spec 6 §2–§4 for stacks, presets and
text styles, Spec 4 §10 for the thumbnail job, and Spec 10 §2–§4, §9, §10 and §15 for
the app it joins, all as Spec 11 corrected them. Starts after Area 13 is merged, and so
after the bench run. On main: Spec 5's edit path with the list, cue, folder and playlist
edits and the move by position (Area 9), the thumbnail job that draws a cue's projected
state with the normal stack pass (Area 5), the API's queries with their answer shape
(Area 19), and the app's window, models and scripted engine (Area 13). Build the engine
side first: the edits Spec 7 §7 gives this area (channels, stacks, presets, text styles,
grades, transitions and macros), with those of audio transitions and of an output's
default stack and transitions, their checks, warnings and inverses, a macro's move
between the roots, stack edits between ticks, and a box's move by position; then the
render query on the thumbnail job's queue, with its canvases, files and errors, on the
local socket only, and the uses query over both roots (§3). Then the app: the frame with
the edit bar, the ways in and out, the lock and the keys (§2), turning on the ways in
that Area 13 left disabled (Spec 10 §16); the Cues page with the filmstrip, Fire, the
canvas, the channel rows and their chips, the inspector, the palette, commands as text
and multi-cue editing (§4); the stack editor (§6); the channel sheet (§7); the preset
editor with its canvas, sample, boxes and text styles (§8); and the small editors (§9),
with VoiceOver and the string catalog as §10 says. Open in Text Editor stays disabled
until Area 10. Tests first from §13. Stop for review after the engine side, after the
frame and the Cues page, and after the preset editor.
```

**Area 15 — Macros, basic** (branch `area/macros`)

```
Area: 15, macros, basic. Spec: docs/specs/2-commands.md §3 (the macro row), §5 (groups
and macro expansion, the depth cap, the cycle check) and §9 (the macro's own log line
then each inner command under the same group). The runner on main already expands a
macro into its commands with the cap and the check; Area 15 gives the engine the
machine-level and library macros as first-class objects it can run from a key, OSC
and a cue (no guards: Spec 2 §7's guards are v1.5); the clears tab sends its commands
directly (Spec 10 §7). Add `stack all blackout on | off | toggle` to the vocabulary,
one grammar row like `channel all` with its OSC address, for the clears tab's
"blackout stack and all" (Adam's word, 2026-11-04); its `toggle` with `all` follows
Spec 2 §3, and `audio all mute toggle` is made to as well (Spec 10 §7); propose the
Spec 2 §3 and §6 correction in the plan before any code. Tests first from §10's groups
and log rows. Nothing in app/.
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

**Area 17 — Settings** (branch `area/settings`)

```
Area: 17, settings. Spec: docs/specs/10-show-mode-ui.md §11, with §18's Area 17 tests,
and §9 for the key names and the key recorder; Spec 5 §4 for the edits of machine
objects, and Spec 1 §3 and Spec 4 §10 as Spec 10 corrected them. Starts after Areas 13
and 14 are merged. Build the engine side first: the edits of outputs (but for their
default stack and transitions, which are Area 14's), audio outputs, key bindings and the
machine settings through Area 9's edit path (Spec 7 §7), the key-name checks with
reserved keys refused as badValue, and output and audio-output changes applied between
ticks. Then the settings window and its pages in SwiftUI, each change an edit sent when
its control commits, with §11's ask-first rules; the confirmation of an output on the
app's own screen, which defaults to Revert and reverts with the result's inverses after
15 seconds; and Bind a Key… with the key recorder. The lock's controls on the Roles and
lock page come with Area 18. Tests first from §18. Stop for review after the engine side
and again after the pages.
```

**Area 18 — Operator lock** (branch `area/lock`)

```
Area: 18, operator lock. Spec: docs/specs/10-show-mode-ui.md §12, with §18's Area 18
tests; Spec 5 §2, §6, §7 and §8 as Spec 10 corrected them; ADR 0007 for the Keychain.
Starts after Area 17 is merged, whose pages it makes read-only. Build the engine side
first: the passcode, unlock, resetPasscode, token and newToken requests on the local
socket; the passcode's Keychain item as a salted PBKDF2 hash with the attempt count, and
the five-attempt lockout that holds across a restart; noPasscode and keychain for the
lock edit, which stays off the undo stack and safe from a hand edit of machine.json; the
library event with cause lock; the administrator's reset through Authorization Services;
and the Keychain behind a seam, tested with an in-memory store and one bench test against
the login keychain. Then the lock in the app: Lock Station, the unlock sheet, the lock
tag, the lock's controls on Roles and lock, and everything §12 disables. Tests first from
§18. Stop for review after the engine side.
```

**Area 19 — Engine API and first run** (branch `area/api`)

```
Area: 19, engine API and first run. Spec: docs/specs/10-show-mode-ui.md §2 (the engine
side), §3, §13 and §16, with §18's Area 19 tests; Spec 2 §5, §8 and §9, Spec 4 §2, §5,
§10, §12 and §14, Spec 5 §6 and Spec 9 §2–§5 as Spec 10 corrected them. Starts after
Area 12 is merged: until then Areas 8, 9, 11 and 12 publish their topics and answer their
queries and requests through the engine's own publisher, and this area puts them on the
API. It is engine-only and needs no bench run. On main: the engine driven over OSC, a
quarter-size preview texture per stack backed by an IOSurface (Area 5), cue thumbnails
and pool tiles as files, and EngineProcess, whose screen(for:) falls back to the next
screen. Prove the Mach call first, on the dev Mac: bootstrap_check_in, or
bootstrap_register behind its seam, looked up from an app that didn't start the engine;
stop for review there, and if neither works, propose the per-user launchd agent before
anything else. Then the engine as a process (§2): the local socket with its owner-only
mode, the peer check, and hello once the engine takes commands; sources taken from that
socket only; the lock file with the process id and exit status 3; the console log
trimmed in place; the accessory process with its activity and sleep assertions; output
windows as non-activating panels on every Space that absorb clicks; and display outputs
that wait for their own screen. Then §3: subscriptions with answers and events in the
order produced and their seq, the topics and the queries, each answered with its
request's id or refused (Spec 2 §9 as Spec 11 corrected it), results with group and
applied, the requests the LAN refuses with localOnly, the notes, and Spec 2 §8's group
validation against the state the earlier commands leave. Then the Mach channel's
payloads: three preview surfaces per stack and three picture surfaces per channel with
their frame messages and the pictures' aux pass (choice U-3), and the meters. Then the
LAN listener with the token read on a background thread, Bonjour and the preview topic;
the first-run writer of §13 with output detection and --campus; the relaunch rule with
--relaunch and --released (Spec 9 §4 as corrected); the soak client that holds the Mach
channel; and the fixture's clear-all binding moved to shift+escape (§16). Tests first
from §18. Stop for review after the Mach proof, after the socket and §3, and after first
run. Nothing in app/.
```

**Areas marked `spec needed`**: open Cowork with this repo folder connected and ask for the spec first; it is written in `docs/specs/` and reviewed before its prompt is added here.
