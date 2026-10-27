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
| 2 | Object model and library format (`core/`, `formats/`) | `specs/1-objects-and-format.md` | not started | Next, on `area/format`. Builds on Area 1's types, now on `main`; its prompt also closes the pool-defaults gap (Area 1 brief, deviation 1). |
| 3 | Command vocabulary: grammar, parser and printer, validation, OSC mapping (`core/`) | `specs/2-commands.md` | not started | Builds on Area 1's `Command` enum, now on `main`; independent of Area 2. Its prompt also has the decoder accept the bare `cmd` names Spec 1 §6 used before its correction (Area 1 brief, deviation 2). |
| 4 | Engine spike (`engine/`): headless OEngine over OSC, two channels, two stacks, three hours clean | `specs/4-render-pipeline.md` §15 | not started | Needs Areas 1–3 (the fixture library on disk, the vocabulary over OSC) and the DeckLink SDK in `vendor/`. Nothing in it runs unattended. |
| 5 | Render pipeline, the rest: 1080i weave, text cache, thumbnails, multiviewer, measurement | `specs/4-render-pipeline.md` | not started | After the spike passes every §15 criterion. |
| 6 | Stacks and presets: slots, boxes, text styles, resolution order, blackout and mute, offset +1 | `specs/1-objects-and-format.md` + presets-and-text spec | not started | Spec needed first (presets and text). |
| 7 | Output sinks: display per screen, DeckLink with weave, output transitions | `specs/4-render-pipeline.md` §10 | not started | After the spike. |
| 8 | Media pool: hash IDs, index, import by copy, poster frames, missing state | media-pool spec | not started | Spec needed first. |
| 9 | Cues, lists and playlists: write/clear/hold, Go and Time triggers, sections, linked items, live pointer, next | cues-lists-playlists spec | not started | Spec needed first. |
| 10 | Text editor: whole-list text document with cue breaks | edit-mode spec | not started | Spec needed first. |
| 11 | Variables: Time, Date, Timer and Popup slots, captions over OSC | presets-and-text spec | not started | Spec needed first. |
| 12 | Log and saving: command log with sources, continuous save, launch snapshots | log-and-saving spec | not started | Spec needed first. |
| 13 | Show-mode UI (`app/`): three columns, grid, strip, preview and multiviewer, tabs, top bar, keyboard | show-mode-ui spec | not started | Spec needed first; nothing in `app/` starts before the spike passes. |
| 14 | Edit mode, minimal: cue inspector with palette, stack editor, channel sheet, preset editor | edit-mode spec | not started | Spec needed first; in `app/`, so after the spike passes. |
| 15 | Macros, basic: command lists without guards, the clears tab | `specs/2-commands.md` | not started | After Area 3. |
| 16 | Audio, basic: routing to numbered outputs, gain | `specs/4-render-pipeline.md` §11 | not started | After the spike. |
| 17 | Settings: inputs, outputs, audio outputs, keys, media root, startup | settings section of show-mode-ui spec | not started | Spec needed first. |
| 18 | Operator lock: passcode in the Keychain, edit mode blocked | show-mode-ui spec | not started | Spec needed first. |
| v1.5 | After the pilot: runtime undo, library mode and local copies, NDI, live inputs, audio transitions, pre-flight report, optimize on import, macro guards and the scheduler, lookahead polish, distribution conventions | `docs/build-order.md` | not started | Specs wait until the pilot is scheduled. Each row has its own task in the Build tracker. |
| v2 | Slide designer, timelines and clocks, custom transitions, CCLI reporting | `docs/build-order.md` | not started | Deferred. |

## Now

**No area is live; Area 1 has shipped and Area 2 has not started.** On 2026-10-27 Adam
wrote `approved` on the Area 1 brief with its three answers: the spec corrections applied,
the pause-and-resume recommendation taken, Area 2 next. This session, in the main checkout
on `main`, corrected Spec 3 (§2: `build` leaves the tracked-attributes row and is slide
content; §4 Transport: `play` after `pause` resumes from the engine's playhead and
`startedAtFrame` is reset only by a write or `stop`, also under Resolved questions; §6:
`rate` in the context, the media index under `library`, the wider `machine`, the `applied`
effect, `variable` carrying `clearAfterMs`, `boundary` carrying `reset`) and Spec 1 §6
(`playlist.next`, `macro.run`), then merged `area/projection` into `main` with `--no-ff`,
ran `swift test` green on the merged `main`, pushed, saw CI pass on `main` (macOS build and
test, Linux OCore portability), deleted the branch locally and on origin, removed its
worktree and set its Build tracker task to `shipped`. Everything of Area 1 is on `main`;
nothing waits on a branch. The main checkout holds one uncommitted edit that is not this
session's: `.github/workflows/ci.yml` changed by hand to run CI on every branch; it is left
for Adam to commit or discard. The stale local branch
`claude/spec-3-channel-projection-7cbb77`, the Area 1 session's pre-rename stub at the
initial commit, was left alone.

## Needs Adam

### Briefs waiting for approval

None. Area 1's brief (`docs/reviews/area-1-projection.md`) is answered and merged.

### Spec interpretations made so far

None outstanding. Adam's `approved` answered every Area 1 reading; the file brief keeps the
record under "Choices made where the spec left room". This session chose no new reading of
its own. Its one judgement call is written into the spec rather than left open: Spec 3 §6
now lists the media index under `library`, because correction 1's fix (Area 2 adds it to
`ProjectionContext.library` so `write` can fall back to pool-item defaults) needs the
context to carry it.

### Spec corrections proposed

None. Area 1's corrections were applied on `main` in e57728f (Spec 3 §2, §4, §6 and
Resolved questions; Spec 1 §6). The two that are code rather than wording go to Area 2
(pool-item defaults) and Area 3 (the decoder's bare `cmd` names) through their prompts in
`docs/build-order.md`.

## Next

**Area 2 — Object model and library format** (branch `area/format`, its own Nimbalyst
worktree session). The prompt, verbatim from `docs/build-order.md`: the common preamble,
then the area's own block.

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

Area 3 (command vocabulary) depends only on Area 1's `Command` enum, which is on `main`, so
it could run in parallel with Area 2 in its own worktree session on `area/commands`; the
Area 1 brief recommends 2 then 3 and Adam chose Area 2 next. Area 4 waits for Areas 1–3
and the DeckLink SDK. The specs for the areas marked "Spec needed first" above can be
written in Cowork at any time; each already has its task in the Build tracker, marked
`spec needed`.
