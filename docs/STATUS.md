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
| 4 | Engine spike (`engine/`): headless OEngine over OSC, two channels, two stacks, three hours clean | `specs/4-render-pipeline.md` §15 | merged | Adam's `approved` on 2026-10-31 with every recommendation taken; the DeckLink SDK put in `vendor/` and the module's wrapper written against it (13d230e); Spec 4 §3, §8, §10, §16 corrected (7032182); `area/spike` merged into `main` with `--no-ff` (e735052), `swift test` green on the merged tree with the SDK compiled in, pushed, branch and worktree removed, task `shipped`; hosted CI first green on `main` on 2026-10-31 at cb20f6e, once the repository was public, but the macOS job hung on the next push (Needs Adam). The three-hour bench run with a card is still to do. |
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

**No area is live: Area 4 has shipped, Area 5 has not started, and the repository is
public.** On 2026-10-31 Adam wrote `approved` on the go-public brief, taking its
recommendation (the licence notice also names the viewing and forking GitHub's Terms of
Service allow; 3a777f9). The housekeeping session merged `area/go-public` into `main` with
`--no-ff` (cb20f6e), ran `swift test` green on the merged tree with the SDK compiled in,
pushed, made the repository public and applied every setting the brief listed with `gh`,
each read back (Housekeeping below has the one that expires). Hosted CI then passed on
`main` at cb20f6e, both jobs, the first green hosted run since Area 4's merge; on the next
push (bd42b70, status documents only) the macOS job hung in `swift test` until its
45-minute limit, with no log kept (Housekeeping below). The worktree is removed and the
branch deleted on both ends; everything is on `main` and nothing waits on a branch.
The bench's three-hour run of `scripts/soak.sh tests/soak/spike.json` with a card and both
outputs captured, which answers Spec 4 §15's 4K GPU time, DeckLink completion counts and A/V
sync, is still to do.

## Needs Adam

### Briefs waiting for approval

None. The go-public brief (the go-public session, 2026-10-31) is answered and merged.

### Housekeeping

- **Interaction limit expires 2027-04-30** (16:00 UTC). Until then only collaborators can
  open issues and pull requests or comment on the public repository. Renew it before that
  date (Settings, Moderation options, Interaction limits: collaborators only, six months),
  or anyone with a GitHub account can open them.
- **Licence:** LCBC to choose before contributions open; set up a contributor agreement
  first.
- **The hosted macOS `swift test` hangs sometimes; the test is not yet named.** On bd42b70,
  a push of status documents only, the macOS job built, then sat in `swift test` until the
  job's 45-minute limit cancelled it (run 41217993196). GitHub kept no log of the job (the
  job-logs API answers "BlobNotFound", `gh run view --log` "log not found"), so the test
  that hung cannot be named. The Linux job passed. The same code passed both jobs on
  cb20f6e in under three minutes (run 41217504317), and the Area 4 merge push hung the
  same way, so the hang is intermittent and the bounded waits of 431e72c do not catch it.
  A test that hangs only sometimes may be a race in the engine or only in the test
  harness; until a log names it, which one is unknown. Not fixed in the go-public session,
  as asked. Recommended: a tooling session gives the `swift test` step its own
  `timeout-minutes`, below the job's, so a hang fails that step while the job itself ends
  normally, which should keep the log that names the test. Watching a running job's live
  log in the Actions tab may also show it.
- **GitHub Actions billing** no longer blocks CI: on the public repository standard hosted
  runners are free. The ProductionLCBC account's payment problem (Settings, Billing and
  plans) matters again only if the repository goes private or a paid feature is wanted.

### Spec interpretations made so far

None outstanding. Adam's `approved` answered every Area 4 reading; the plan's answers and
the readings made while building are recorded in the Area 4 brief and in the
`Spec interpretations made so far` table of an earlier version of this page (980f092). The
spec now says what the code does.

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
