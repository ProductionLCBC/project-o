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
| 3 | Command vocabulary: grammar, parser and printer, validation, OSC mapping (`core/`) | `specs/2-commands.md` | not started | Next, on `area/commands`, branched from `main`. Builds on the `Command` enum as Areas 1 and 2 left it on `main` (`unknown` and `invalid` cases keep their parameters; guarded entries carry unknown keys). Its prompt also has the decoder accept the bare `cmd` names Spec 1 §6 used before its correction (Area 1 brief, deviation 2). |
| 4 | Engine spike (`engine/`): headless OEngine over OSC, two channels, two stacks, three hours clean | `specs/4-render-pipeline.md` §15 | not started | Needs Areas 1–3 (the fixture library is now on `main`; the vocabulary over OSC is Area 3) and the DeckLink SDK in `vendor/`. Nothing in it runs unattended. |
| 5 | Render pipeline, the rest: 1080i weave, text cache, thumbnails, multiviewer, measurement | `specs/4-render-pipeline.md` | not started | After the spike passes every §15 criterion. |
| 6 | Stacks and presets: slots, boxes, text styles, resolution order, blackout and mute, offset +1 | `specs/1-objects-and-format.md` + presets-and-text spec | not started | Spec needed first (presets and text). The object types are on `main` since Area 2. |
| 7 | Output sinks: display per screen, DeckLink with weave, output transitions | `specs/4-render-pipeline.md` §10 | not started | After the spike. |
| 8 | Media pool: hash IDs, index, import by copy, poster frames, missing state | media-pool spec | not started | Spec needed first. The index, the resolver, SHA-256 identity and the missing state are on `main` since Area 2; the rebuild walk, import by copy and poster extraction remain. |
| 9 | Cues, lists and playlists: write/clear/hold, Go and Time triggers, sections, linked items, live pointer, next | cues-lists-playlists spec | not started | Spec needed first. |
| 10 | Text editor: whole-list text document with cue breaks | edit-mode spec | not started | Spec needed first. |
| 11 | Variables: Time, Date, Timer and Popup slots, captions over OSC | presets-and-text spec | not started | Spec needed first. |
| 12 | Log and saving: command log with sources, continuous save, launch snapshots | log-and-saving spec | not started | Spec needed first. The atomic write, the write plan and the versions folder are on `main` since Area 2; debouncing, the log and snapshots remain. |
| 13 | Show-mode UI (`app/`): three columns, grid, strip, preview and multiviewer, tabs, top bar, keyboard | show-mode-ui spec | not started | Spec needed first; nothing in `app/` starts before the spike passes. |
| 14 | Edit mode, minimal: cue inspector with palette, stack editor, channel sheet, preset editor | edit-mode spec | not started | Spec needed first; in `app/`, so after the spike passes. |
| 15 | Macros, basic: command lists without guards, the clears tab | `specs/2-commands.md` | not started | After Area 3. |
| 16 | Audio, basic: routing to numbered outputs, gain | `specs/4-render-pipeline.md` §11 | not started | After the spike. |
| 17 | Settings: inputs, outputs, audio outputs, keys, media root, startup | settings section of show-mode-ui spec | not started | Spec needed first. |
| 18 | Operator lock: passcode in the Keychain, edit mode blocked | show-mode-ui spec | not started | Spec needed first. |
| v1.5 | After the pilot: runtime undo, library mode and local copies, NDI, live inputs, audio transitions, pre-flight report, optimize on import, macro guards and the scheduler, lookahead polish, distribution conventions | `docs/build-order.md` | not started | Specs wait until the pilot is scheduled. Each row has its own task in the Build tracker. |
| v2 | Slide designer, timelines and clocks, custom transitions, CCLI reporting | `docs/build-order.md` | not started | Deferred. |

## Now

**No area is live; Area 2 has shipped and Area 3 has not started.** On 2026-10-28 Adam
wrote `approved` on the Area 2 brief, reversing one reading (Spec 1 §8: a missing transition
degrades to the channel's default transition as it is defined, and to a zero-second cut only
when that is missing too) and taking the recommended answers on the rest (the spec
corrections applied; a local copy keeps the master's cue uuids under its own list uuid;
catalog objects write nulls while command objects omit absent optionals; CI on every branch;
Area 3 next from `main`). The same session changed the fallback on the branch (78902ef, tests
green), corrected Spec 1 §2, §3, §5, §7 and §8, Spec 3 §4 and `ARCHITECTURE.md` on `main`
(cc404c0), committed Adam's every-branch CI workflow (e8557c1), merged `area/format` into
`main` with `--no-ff` (70bf958), ran `swift test` green on the merged tree, pushed, saw CI
pass on `main` (macOS build and test, Linux OCore portability), removed the worktree, deleted
the branch locally and on origin and set the Build tracker task to `shipped`. Everything of
Area 2 is on `main`; nothing waits on a branch, and the main checkout is clean.

## Needs Adam

### Briefs waiting for approval

None. Area 2's brief (the final message of its session, 2026-10-28) is answered and merged.

### Spec interpretations made so far

None outstanding. Adam's `approved` answered every Area 2 reading; the readings are recorded
in the Area 2 brief and in the `Spec interpretations made so far` table of the previous
version of this page (89fffdd). The one he reversed is now what Spec 1 §8 says and what the
projection does.

### Spec corrections proposed

None. Area 2's corrections were applied on `main` in cc404c0 (Spec 1 §2, §3, §5, §7, §8;
Spec 3 §4; `ARCHITECTURE.md`).

## Next

**Area 3 — Command vocabulary** (branch `area/commands`, its own Nimbalyst worktree session,
branched from `main`). The prompt, verbatim from `docs/build-order.md`: the common preamble,
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
Area: 3, command vocabulary. Spec: docs/specs/2-commands.md.
Build in core/: the canonical text grammar (§2), the full v1 vocabulary as Command
objects (§3), parse and print with parse(print(x)) == x (§4), validation and
results (§8), selection expansion and groups (§5), the OSC address mapping both
ways (§6, as pure functions; no sockets in core/), guards (§7), and the log entry
shape (§9). Tests from §10 first. Also close the Area 1 brief's deviation 2: the
command decoder accepts the bare cmd names Spec 1 §6 used before its correction
("next", "macro") on input and prints only the Spec 2 §3 object names.
```

Area 3 can start now. The text half of Spec 1 §10's command-encoding test ("every command
object in the fixtures converts to canonical text and back") belongs to it: the fixture
library on `main` has a command of most vocabulary rows to print and parse. Area 4 waits for
Area 3 and the DeckLink SDK. The specs for the areas marked "Spec needed first" above can be
written in Cowork at any time; each already has its task in the Build tracker, marked
`spec needed`. Area 8's media-pool spec can assume the index, the resolver and the hash
identity from Area 2 and specify only the rebuild walk, import by copy and posters.
