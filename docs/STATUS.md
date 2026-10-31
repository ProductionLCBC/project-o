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
| 4 | Engine spike (`engine/`): headless OEngine over OSC, two channels, two stacks, three hours clean | `specs/4-render-pipeline.md` §15 | merged | Adam's `approved` on 2026-10-31 with every recommendation taken; the DeckLink SDK put in `vendor/` and the module's wrapper written against it (13d230e); Spec 4 §3, §8, §10, §16 corrected (7032182); `area/spike` merged into `main` with `--no-ff` (e735052), `swift test` green on the merged tree with the SDK compiled in, pushed, branch and worktree removed, task `shipped`. The three-hour bench run with a card is still to do. |
| 5 | Render pipeline, the rest: 1080i weave, text cache, thumbnails, multiviewer, measurement | `specs/4-render-pipeline.md` | not started | Next, once its prompt block is written in `docs/build-order.md` and the spike has passed every §15 criterion on the bench. |
| 6 | Stacks and presets: slots, boxes, text styles, resolution order, blackout and mute, offset +1 | `specs/1-objects-and-format.md` + presets-and-text spec | not started | Spec needed first (presets and text; it owes the text style a vertical anchor, Spec 4 §8). The object types are on `main` since Area 2; the engine's stack pass on `main` since Area 4 resolves slots, fit modes, opacity, mute and the +1 slot. |
| 7 | Output sinks: display per screen, DeckLink with weave, output transitions | `specs/4-render-pipeline.md` §10 | not started | After the bench run. The display and DeckLink sinks, the encode pass and the switch and blackout mixes are on `main` since Area 4; the weave and key/fill remain. |
| 8 | Media pool: hash IDs, index, import by copy, poster frames, missing state | media-pool spec | not started | Spec needed first. The index, the resolver, SHA-256 identity and the missing state are on `main` since Area 2; the rebuild walk, import by copy and poster extraction remain. |
| 9 | Cues, lists and playlists: write/clear/hold, Go and Time triggers, sections, linked items, live pointer, next | cues-lists-playlists spec | not started | Spec needed first. The runner on `main` logs a fired cue as its own group with `fire`; the engine's control loop fires armed Time triggers and `next` as engine groups. |
| 10 | Text editor: whole-list text document with cue breaks | edit-mode spec | not started | Spec needed first. |
| 11 | Variables: Time, Date, Timer and Popup slots, captions over OSC | presets-and-text spec | not started | Spec needed first. `popup N set` over OSC is on `main` since Area 3; the engine resolves `[Time]`, `[Date]` and `[Popup N]`, not yet `[Timer N]` or the per-second `remaining` and `timer` feedback. |
| 12 | Log and saving: command log with sources, continuous save, launch snapshots | log-and-saving spec | not started | Spec needed first. The atomic write, the write plan and the versions folder are on `main` since Area 2; the Spec 2 §9 entry and its one-line form since Area 3; debouncing, the log file, snapshots and `restoreLastState` remain. |
| 13 | Show-mode UI (`app/`): three columns, grid, strip, preview and multiviewer, tabs, top bar, keyboard | show-mode-ui spec | not started | Spec needed first; nothing in `app/` starts before the spike passes on the bench. |
| 14 | Edit mode, minimal: cue inspector with palette, stack editor, channel sheet, preset editor | edit-mode spec | not started | Spec needed first; in `app/`, so after the bench run. |
| 15 | Macros, basic: command lists without guards, the clears tab | `specs/2-commands.md` | not started | After Area 3, so it can start; the runner's macro expansion, the depth cap and the cycle check are on `main`. |
| 16 | Audio, basic: routing to numbered outputs, gain | `specs/4-render-pipeline.md` §11 | not started | The mix graph for one device, routing, gain ramps, audio transitions, the delay line and mute are on `main` since Area 4; device loss while running and the SDI-embedded feed remain. |
| 17 | Settings: inputs, outputs, audio outputs, keys, media root, startup | settings section of show-mode-ui spec | not started | Spec needed first. |
| 18 | Operator lock: passcode in the Keychain, edit mode blocked | show-mode-ui spec | not started | Spec needed first. |
| v1.5 | After the pilot: runtime undo, library mode and local copies, NDI, live inputs, audio transitions, pre-flight report, optimize on import, macro guards and the scheduler, lookahead polish, distribution conventions | `docs/build-order.md` | not started | Specs wait until the pilot is scheduled. Each row has its own task in the Build tracker. |
| v2 | Slide designer, timelines and clocks, custom transitions, CCLI reporting | `docs/build-order.md` | not started | Deferred. |

## Now

**No area is live; Area 4 has shipped and Area 5 has not started.** On 2026-10-31 Adam
wrote `approved` on the Area 4 brief, taking every recommendation: the readings stand, the
display sink presents the frame of the previous master tick, text centres vertically until
the presets spec adds an anchor, `restoreLastState` and `[Timer N]` wait for Areas 12 and 11.
He put the DeckLink SDK in `vendor/`, and the same session wrote the module's Objective-C++
wrapper against it on the branch (13d230e; a Mac without the Desktop Video driver behaves
like the stub, so the dev Mac still reports the card unavailable), corrected Spec 4 §3, §8,
§10 and §16 on `main` (7032182), merged `area/spike` into `main` with `--no-ff` (e735052),
ran `swift test` green on the merged tree with the SDK compiled in, pushed, removed the
worktree, deleted the branch on both ends and set the Build tracker task to `shipped`.
Everything of Area 4 is on `main`; nothing waits on a branch. What the dev Mac could not do
remains for the bench: the three-hour run of `scripts/soak.sh tests/soak/spike.json` with a
card and both outputs captured, which is where Spec 4 §15's 4K GPU time, DeckLink completion
counts and A/V sync on the capture get their answer. Hosted CI has not confirmed the merge:
the Linux job passed, the macOS job sat in `swift test` for over forty minutes on the merge
push and was cancelled with no log kept, and the follow-up push (431e72c: every harness and
readback wait bounded, time limits on both jobs, so a hang ends with a log) was refused by
GitHub for billing ("recent account payments have failed or your spending limit needs to be
increased").

## Needs Adam

### Briefs waiting for approval

None. Area 4's brief (the Area 4 session, 2026-10-29) is answered and merged.

### Housekeeping

- **GitHub Actions billing.** Runs on `main` are refused until the ProductionLCBC account's
  payment or spending limit is fixed (Settings, Billing and plans). The macOS job bills at a
  multiple of Linux minutes and the hung run on 2026-10-31 spent forty of them. When runs
  start again, re-run the latest `main` run (`gh run rerun <id>`); if its macOS job fails
  rather than hangs, the log names the test, which is the point of 431e72c.

### Spec interpretations made so far

None outstanding. Adam's `approved` answered every Area 4 reading; the plan's seven answers
and the readings made while building are recorded in the Area 4 brief and in the
`Spec interpretations made so far` table of the previous version of this page (980f092).
The spec now says what the code does.

### Spec corrections proposed

None. Area 4's corrections were applied on `main` in 7032182 (Spec 4 §3, §8, §10, §16). The
presets-and-text spec, when written, owes the text style a vertical anchor defaulting to
centre (Spec 4 §8 says so).

## Next

**The bench run first.** Spec 4 §15 gates everything after the spike on three hours on the
test bench: the bench machine root (a copy of `tests/fixtures/spike/machine/` with the main
output at the LED wall's format, as a DeckLink output if the bench has 12G) and
`scripts/soak.sh tests/soak/spike.json`, which writes the media if it is missing, runs the
engine with the script over OSC and prints the §13 verdict. This can be run by Adam without
a session.

**Area 5 — Render pipeline, the rest** (branch `area/render`) is next in `docs/build-order.md`;
it has no prompt block there yet, only the row and the gate ("nothing in `app/` starts until
the spike passes every criterion in Spec 4 §15"). The common preamble, verbatim:

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

Area 15 (macros, basic) could start independently, since the runner's macro expansion is on
`main`. Area 16 (audio, basic) has most of its engine side on `main` now. The specs for the
areas marked "Spec needed first" above can be written in Cowork at any time; each already has
its task in the Build tracker, marked `spec needed`. The presets-and-text spec can take the
engine's stack pass as given and decide the vertical anchor; Area 9's cues spec can take the
runner's cue-group logging and the engine's armed triggers as given.
