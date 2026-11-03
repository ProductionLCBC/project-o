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
| 4 | Engine spike (`engine/`): headless OEngine over OSC, two channels, two stacks, three hours clean | `specs/4-render-pipeline.md` §15 | merged | Adam's `approved` on 2026-10-31 with every recommendation taken; the DeckLink SDK put in `vendor/` and the module's wrapper written against it (13d230e); Spec 4 §3, §8, §10, §16 corrected (7032182); `area/spike` merged into `main` with `--no-ff` (e735052), task `shipped`; hosted CI green on `main` since 962dd4b. The first three-hour soak on two displays (2026-11-01) found faults fixed on `area/soak-fixes` and merged on Adam's `approved` (2074bd6, 2026-11-02); the second run's memory growth was attributed on 2026-11-02 to purgeable cache memory and allocator fragmentation, no leak; the §13 memory breakdown and the corrected threshold merged on Adam's `approved` (87011b2, 2026-11-03). Every display-side criterion of §15 holds; the DeckLink criteria wait for the bench run with a card, which Adam has deferred to a window he sets aside. |
| 5 | Render pipeline, the rest: 1080i weave, text cache, thumbnails, multiviewer, measurement | `specs/4-render-pipeline.md` | merged | Adam's `approved` on 2026-11-03 with every recommendation taken (the readings as built, the spec corrections accepted, the `/o/metrics` query kept, the bench run later); Spec 4 §2, §10, §13, Spec 2 §6 and Spec 1 §5 corrected (e8e1e3f); `area/render` merged into `main` with `--no-ff` (5b3f6ed), `swift test` green on the merged tree, pushed, branch and worktree removed, task `shipped`. The weave's capture-rig check (§16) joins the bench run. |
| 6 | Stacks and presets: slots, boxes, text styles, resolution order, blackout and mute, offset +1 | `specs/1-objects-and-format.md` + presets-and-text spec | not started | Spec needed first (presets and text; it owes the text style a vertical anchor, Spec 4 §8). The object types are on `main` since Area 2; the engine's stack pass resolves slots, fit modes, opacity, mute and the +1 slot since Area 4, through the one shared `SlotResolver` since Area 5. |
| 7 | Output sinks: display per screen, DeckLink with weave, output transitions | `specs/4-render-pipeline.md` §10 | not started | After the bench run. The display and DeckLink sinks, the encode pass and the switch and blackout mixes are on `main` since Area 4, the 1080i weave since Area 5; key and fill remain. |
| 8 | Media pool: hash IDs, index, import by copy, poster frames, missing state | media-pool spec | not started | Spec needed first. The index, the resolver, SHA-256 identity and the missing state are on `main` since Area 2; the rebuild walk, import by copy and poster extraction remain. |
| 9 | Cues, lists and playlists: write/clear/hold, Go and Time triggers, sections, linked items, live pointer, next | cues-lists-playlists spec | not started | Spec needed first. The runner on `main` logs a fired cue as its own group with `fire`; the engine's control loop fires armed Time triggers and `next` as engine groups; the thumbnail job projects a list from its top (Area 5). |
| 10 | Text editor: whole-list text document with cue breaks | edit-mode spec | not started | Spec needed first. |
| 11 | Variables: Time, Date, Timer and Popup slots, captions over OSC | presets-and-text spec | not started | Spec needed first. `popup N set` over OSC is on `main` since Area 3; the engine resolves `[Time]`, `[Date]` and `[Popup N]` and, since Area 5, adopts a variable box's new value at most once per wall-clock second; not yet `[Timer N]` or the per-second `remaining` and `timer` feedback. |
| 12 | Log and saving: command log with sources, continuous save, launch snapshots | log-and-saving spec | not started | Spec needed first. The atomic write, the write plan and the versions folder are on `main` since Area 2; the Spec 2 §9 entry and its one-line form since Area 3; debouncing, the log file, snapshots and `restoreLastState` remain. |
| 13 | Show-mode UI (`app/`): three columns, grid, strip, preview and multiviewer, tabs, top bar, keyboard | show-mode-ui spec | not started | Spec needed first; nothing in `app/` starts before the spike passes on the bench. The engine side of the preview and the multiviewer (one IOSurface-backed quarter-size texture per stack, ids exposed) and of thumbnails (PNGs by cue, stack and library version) is on `main` since Area 5; the Mach hand-off of the surfaces and the API's `metrics` and `preview` topics belong with the app and the API. |
| 14 | Edit mode, minimal: cue inspector with palette, stack editor, channel sheet, preset editor | edit-mode spec | not started | Spec needed first; in `app/`, so after the bench run. |
| 15 | Macros, basic: command lists without guards, the clears tab | `specs/2-commands.md` | not started | Next. It needs no new spec; the runner's macro expansion, the depth cap and the cycle check are on `main`. Its prompt block is proposed under Needs Adam and goes into `docs/build-order.md` on his word. |
| 16 | Audio, basic: routing to numbered outputs, gain | `specs/4-render-pipeline.md` §11 | not started | The mix graph for one device, routing, gain ramps, audio transitions, the delay line and mute are on `main` since Area 4; device loss while running and the SDI-embedded feed remain. |
| 17 | Settings: inputs, outputs, audio outputs, keys, media root, startup | settings section of show-mode-ui spec | not started | Spec needed first. |
| 18 | Operator lock: passcode in the Keychain, edit mode blocked | show-mode-ui spec | not started | Spec needed first. |
| v1.5 | After the pilot: runtime undo, library mode and local copies, NDI, live inputs, audio transitions, pre-flight report, optimize on import, macro guards and the scheduler, lookahead polish, distribution conventions | `docs/build-order.md` | not started | Specs wait until the pilot is scheduled. Each row has its own task in the Build tracker. |
| v2 | Slide designer, timelines and clocks, custom transitions, CCLI reporting | `docs/build-order.md` | not started | Deferred. |

## Now

**Nothing is in review; everything is on `main`.** On 2026-11-03 Adam wrote `approved` on
the Area 5 brief with every recommendation taken: the readings stand as built, the spec
corrections are accepted, the `/o/metrics` query stays as the OSC form of the `metrics`
topic, and the bench run waits for a window. The specs were corrected first (e8e1e3f: Spec 4
§2, §10, §13, Spec 2 §6, Spec 1 §5), then `area/render` was merged into `main` with
`--no-ff` (5b3f6ed), `swift test` ran green on the merged tree, the merge was pushed, the
branch was deleted on both ends, its worktree removed, and the Build tracker task "Area 5 —
Render pipeline, the rest" set to `shipped`. The engine now holds every rule of Spec 4 §1
to §13 that a dev Mac can prove: the text cache's rest, one preview per stack and the
thumbnail job, the measurement of §13, and the 1080i weave in the harness.

The bench's three-hour run with a card and both outputs captured is deferred to a window
Adam sets aside; it stays the gate for `app/`, its minute records set the §13 median
window and show the thumbnail job's cost, and it checks the weave on the capture rig (§16).

## Needs Adam

### Briefs waiting for approval

None. The Area 5 brief (the final message of the Area 5 session on 2026-11-03) was answered
the same day: approved with every recommendation, merged (5b3f6ed).

### Decisions

- **The Area 15 prompt block.** The next area that needs no new spec is Area 15, macros
  (basic). `docs/build-order.md` has its row and no block. The block below is proposed in
  the shape of the earlier ones; on Adam's word it goes into `docs/build-order.md` under the
  common preamble, and the next session starts with it. Area 16 (audio, basic) is the other
  candidate; its engine side is mostly on `main`.

  ```
  Area: 15, macros, basic. Spec: docs/specs/2-commands.md §3 (the macro row), §5 (groups
  and macro expansion, the depth cap, the cycle check) and §9 (the macro's own log line
  then each inner command under the same group). The runner on main already expands a
  macro into its commands with the cap and the check; Area 15 gives the engine the
  machine-level and library macros as first-class objects it can run from a key, OSC
  and a cue (no guards: Spec 2 §7's guards are v1.5), and the clears tab's command
  lists (ux-spec, the tabbed panel) as macros the UI will call. Tests first from §10's
  groups and log rows. Nothing in app/.
  ```

- **When the bench run happens.** Deferred by Adam on 2026-11-03 ("later") to a window he
  sets aside: the bench machine root (a copy of `tests/fixtures/spike/machine/` with the
  main output at the LED wall's format, as a DeckLink output if the bench has 12G) and
  `scripts/soak.sh tests/soak/spike.json`. He can run it without a session; its record
  answers the DeckLink criteria of §15, sets the §13 median window, shows whether the
  purgeable zone caps and what the thumbnail job costs, and checks the weave on the
  capture rig.

### The attended run

- A second attended memory run is wanted only if the bench record shows the purgeable zone
  not capping: about ten minutes of the engine under Instruments' Allocations (`xctrace`,
  the purgeable category by call stack), in a window Adam sets aside. The quick external
  check stays on `main`: `scripts/soak-memory-sample.sh`, with `--minutes 1 --at "0.25 0.75"`
  for a smoke run.

### Housekeeping

- **Interaction limit expires 2027-04-30** (16:00 UTC). Until then only collaborators can
  open issues and pull requests or comment on the public repository. Renew it before that
  date (Settings, Moderation options, Interaction limits: collaborators only, six months),
  or anyone with a GitHub account can open them.
- **Licence:** LCBC to choose before contributions open; set up a contributor agreement
  first.
- **The bench Mac is the only place the hardware tests run.** Since 962dd4b the hosted test
  step sets `O_HOSTED_RUNNER`, which makes the Metal and codec tests skip there with a
  visible message, because the runner's virtual GPU or VideoToolbox stalled some runs in a
  kernel call nothing could kill (a step time limit and cancels did nothing; only GitHub's
  force-cancel API ended them). Every harness, readback and media-open wait is bounded and
  the step runs unbuffered, so a future stall would fail a test and name it. A self-hosted
  runner on the bench Mac, without the variable, is what should run the goldens, the decode
  tests and the soak; until it exists, `swift test` on the bench by hand is the proof, as
  CLAUDE.md says. GitHub's macOS runner queue cancels a job after fifteen minutes of
  waiting when several pushes land together; `gh run rerun <id> --failed` is the remedy.
- **GitHub Actions billing** no longer blocks CI: on the public repository standard hosted
  runners are free. The ProductionLCBC account's payment problem (Settings, Billing and
  plans) matters again only if the repository goes private or a paid feature is wanted.

### Spec interpretations made so far

None outstanding. Area 5's readings (the preview as a consumer at the preview rate, one
preview per stack, the once-a-second gate on wall-clock seconds, the library version as a
content hash plus the list's version, `thumbnails/` in the machine root, warming on the
live list, `/o/metrics`, the minute record's notes, the pressure policy, the fallback-font
retry, the interlaced sink on the second field's tick, this tick's mix for both fields) were
approved on 2026-11-03 with every recommendation and are in the specs' text (e8e1e3f) or in
the brief; the §13 readings in 74de762 or the Area 4 brief; the soak fixes' in 6e546f8;
Area 4's in its brief and 7032182.

### Spec corrections proposed

None outstanding. Spec 4 §2, §10 and §13, Spec 2 §6 and Spec 1 §5 corrected in e8e1e3f on
Adam's acceptance; §13 and §15 in 74de762, §11 and §12 in 6e546f8, Area 4's earlier ones in
7032182. The presets-and-text spec, when written, owes the text style a vertical anchor
defaulting to centre (Spec 4 §8 says so).

## Next

**Area 15 — Macros, basic** (branch `area/macros`), in its own session, once Adam has put
its prompt block into `docs/build-order.md` (the proposal is under Needs Adam). The common
preamble, verbatim:

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

The bench run with the card happens whenever Adam sets a window; it does not block Area 15
or 16, and it must pass before anything in `app/` starts (Areas 13 and 14) and before Area
7 (output sinks). Area 16 (audio, basic) has most of its engine side on `main`. The specs
for the areas marked "Spec needed first" above can be written in Cowork at any time; each
already has its task in the Build tracker, marked `spec needed`. The presets-and-text spec
can take the engine's stack pass and the shared slot resolver as given and decide the
vertical anchor; Area 9's cues spec can take the runner's cue-group logging, the engine's
armed triggers and the thumbnail job's projection from the top of a list as given.
