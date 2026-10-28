# Status

The one-page view. Every session starts by reading this page and ends by rewriting it
(`CLAUDE.md`, "Session contract"; `/wrap-up` does the rewrite). It lives on `main` and is
current on `main` after every session, even while an area's code waits on its branch. The
detail is elsewhere: the areas and their prompts in `docs/build-order.md`, mirrored by the
Build tracker in Nimbalyst; each area's brief as the final message of its session (Area 1's
predates that and is a file, `docs/reviews/area-1-projection.md`, which records Adam's
answers at the top); one line per session in `CHANGELOG.md`.

## Areas

State is one of `not started`, `in progress`, `brief waiting for approval`, `merged`.

| # | Area | Spec | State | Last session, or what is left |
| --- | --- | --- | --- | --- |
| 1 | Channel state and projection (`core/`) | `specs/3-channel-state-and-projection.md` | merged | Adam's `approved` on 2026-10-27; spec corrections applied (e57728f), `area/projection` merged into `main` with `--no-ff` (d7465b8), `swift test` and CI green on `main`, branch and worktree removed, task `shipped`. |
| 2 | Object model and library format (`core/`, `formats/`) | `specs/1-objects-and-format.md` | merged | Adam's `approved` on 2026-10-28 with one reversal (a missing transition degrades to the channel default, then to a zero-second cut; 78902ef on the branch); spec corrections applied (cc404c0), `area/format` merged into `main` with `--no-ff` (70bf958), `swift test` and CI green on `main`, branch and worktree removed, task `shipped`. |
| 3 | Command vocabulary: grammar, parser and printer, validation, OSC mapping (`core/`) | `specs/2-commands.md` | merged | Adam's `approved` on 2026-10-28 with the recommended answers; spec corrections applied (fd2f4d2), `area/commands` merged into `main` with `--no-ff` (06a3ef1), `swift test` green on the merged tree, pushed, branch and worktree removed, task `shipped`. |
| 4 | Engine spike (`engine/`): headless OEngine over OSC, two channels, two stacks, three hours clean | `specs/4-render-pipeline.md` §15 | not started | Next, on `area/spike`, branched from `main`. Needs the DeckLink SDK in `vendor/`. The vocabulary over OSC, with the packet codec and the runner, is on `main`. Nothing in it runs unattended. |
| 5 | Render pipeline, the rest: 1080i weave, text cache, thumbnails, multiviewer, measurement | `specs/4-render-pipeline.md` | not started | After the spike passes every §15 criterion. |
| 6 | Stacks and presets: slots, boxes, text styles, resolution order, blackout and mute, offset +1 | `specs/1-objects-and-format.md` + presets-and-text spec | not started | Spec needed first (presets and text). The object types are on `main` since Area 2. |
| 7 | Output sinks: display per screen, DeckLink with weave, output transitions | `specs/4-render-pipeline.md` §10 | not started | After the spike. |
| 8 | Media pool: hash IDs, index, import by copy, poster frames, missing state | media-pool spec | not started | Spec needed first. The index, the resolver, SHA-256 identity and the missing state are on `main` since Area 2; the rebuild walk, import by copy and poster extraction remain. |
| 9 | Cues, lists and playlists: write/clear/hold, Go and Time triggers, sections, linked items, live pointer, next | cues-lists-playlists spec | not started | Spec needed first. The runner on `main` logs a fired cue as its own group with `fire`; this area owns how `next` becomes a cue group in the engine. |
| 10 | Text editor: whole-list text document with cue breaks | edit-mode spec | not started | Spec needed first. |
| 11 | Variables: Time, Date, Timer and Popup slots, captions over OSC | presets-and-text spec | not started | Spec needed first. `popup N set` over OSC is on `main` since Area 3. |
| 12 | Log and saving: command log with sources, continuous save, launch snapshots | log-and-saving spec | not started | Spec needed first. The atomic write, the write plan and the versions folder are on `main` since Area 2; the Spec 2 §9 entry and its one-line form since Area 3; debouncing, the log file and snapshots remain. |
| 13 | Show-mode UI (`app/`): three columns, grid, strip, preview and multiviewer, tabs, top bar, keyboard | show-mode-ui spec | not started | Spec needed first; nothing in `app/` starts before the spike passes. |
| 14 | Edit mode, minimal: cue inspector with palette, stack editor, channel sheet, preset editor | edit-mode spec | not started | Spec needed first; in `app/`, so after the spike passes. |
| 15 | Macros, basic: command lists without guards, the clears tab | `specs/2-commands.md` | not started | After Area 3, so it can start; the runner's macro expansion, the depth cap and the cycle check are on `main`. |
| 16 | Audio, basic: routing to numbered outputs, gain | `specs/4-render-pipeline.md` §11 | not started | After the spike. |
| 17 | Settings: inputs, outputs, audio outputs, keys, media root, startup | settings section of show-mode-ui spec | not started | Spec needed first. |
| 18 | Operator lock: passcode in the Keychain, edit mode blocked | show-mode-ui spec | not started | Spec needed first. |
| v1.5 | After the pilot: runtime undo, library mode and local copies, NDI, live inputs, audio transitions, pre-flight report, optimize on import, macro guards and the scheduler, lookahead polish, distribution conventions | `docs/build-order.md` | not started | Specs wait until the pilot is scheduled. Each row has its own task in the Build tracker. |
| v2 | Slide designer, timelines and clocks, custom transitions, CCLI reporting | `docs/build-order.md` | not started | Deferred. |

## Now

**No area is live; Area 3 has shipped and Area 4 has not started.** On 2026-10-28 Adam
wrote `approved` on the Area 3 brief, taking the recommended answers: the readings made
while building stand, the two reaches outside `core/Commands/` stay (the projection runs
machine-level macros; `CommandSource` writes lowercase uuids), and the runner is the one
execute path. The same session corrected Spec 1 §6, Spec 2 §2, §4, §6 and §9 and Spec 3 §6
on `main` (fd2f4d2), merged `area/commands` into `main` with `--no-ff` (06a3ef1), ran
`swift test` green on the merged tree, pushed, removed the worktree, deleted the branch
locally and on origin and set the Build tracker task to `shipped`. Everything of Area 3 is
on `main`; nothing waits on a branch. The Area 3 brief (the session's message before
`approved`) records the readings and the tests.

## Needs Adam

### Briefs waiting for approval

None. Area 3's brief (the Area 3 session, 2026-10-28) is answered and merged.

### Spec interpretations made so far

None outstanding. Adam's `approved` answered every Area 3 reading; the six decisions of the
plan and the readings made while building are recorded in the Area 3 brief and in the
`Spec interpretations made so far` table of the previous version of this page (fa87157).
The spec now says what the code does.

### Spec corrections proposed

None. Area 3's corrections were applied on `main` in fd2f4d2 (Spec 1 §6; Spec 2 §2, §4, §6,
§9; Spec 3 §6).

## Next

**Area 4 — Engine spike** (branch `area/spike`, its own Nimbalyst worktree session, branched
from `main`). The prompt, verbatim from `docs/build-order.md`: the common preamble, then the
area's own block.

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

Area 4 can start once the DeckLink SDK is in `vendor/` (see `vendor/README.md`); its OSC
path is a socket over the codec, the mapping and the runner now on `main`. Area 15 (macros,
basic) could start independently, since the runner's macro expansion is on `main`. The specs
for the areas marked "Spec needed first" above can be written in Cowork at any time; each
already has its task in the Build tracker, marked `spec needed`. Area 9's cues spec can take
the runner's cue-group logging as given and specify the engine's side; Area 12's log spec can
take the Spec 2 §9 entry and its one-line form as given and specify the file, debouncing and
snapshots.
