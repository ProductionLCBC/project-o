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
| 4 | Engine spike (`engine/`): headless OEngine over OSC, two channels, two stacks, three hours clean | `specs/4-render-pipeline.md` §15 | merged | Adam's `approved` on 2026-10-31 with every recommendation taken; the DeckLink SDK put in `vendor/` and the module's wrapper written against it (13d230e); Spec 4 §3, §8, §10, §16 corrected (7032182); `area/spike` merged into `main` with `--no-ff` (e735052), task `shipped`; hosted CI green on `main` since 962dd4b. The first three-hour soak on two displays (2026-11-01) found faults in the still source's release, the engine's sweep, the clock box's raster, the audio start and the watchdog's sink rule, fixed on `area/soak-fixes` and merged on Adam's `approved` (2074bd6, 2026-11-02) after a second three-hour run that was clean except for memory, the live item (Now). The bench run with a card is still to do. |
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

**The soak fixes are merged; memory attribution is the live item, on `area/soak-memory`**
(pushed, tip 5761d3a, tooling only so far; its Build tracker item is
"Soak memory: attribute the growth after minute ten"). Adam ran the three-hour soak again
on 2026-11-02 from the fixed engine (two displays, no card, audio on): zero audio underruns,
a few one-off watchdog jitter events and no recovery, every display and GPU threshold held,
and memory rose from 256 MB at minute ten to a peak of 319 MB, which fails Spec 4 §13 by its
letter (flat after the first ten minutes). The shape changed, though: the first run grew in
a straight line and never stopped; this one decelerated to flat by the second hour (256, 281,
304, 314, 317, 314 and 315 MB at the half-hour marks from minute ten), the text cache held at
50 MB throughout, and the minute record carries one total, so it cannot name the remaining
growth. Adam decided in the session, in reply to the brief and that result: approve and merge
the fixes now; attribute the memory before anything else changes, both routes with the
sampling run first; and he names the window for the attended run, since the dev Mac is the
bench Mac and a multi-use computer, so nothing runs on it before he says so.

Done on that: Spec 4 §11 (the audio preroll) and §12 (half a tick of slack on the
watchdog's sink rule) corrected on `main` (6e546f8); `area/soak-fixes` merged into `main`
with `--no-ff` (2074bd6); `swift test` green on the merged tree; pushed; hosted CI green on
both jobs for the merge push; the branch deleted on both ends and its worktree removed, with both
three-hour black boxes kept under `tests/soak-output/` in the main checkout.
`scripts/soak-memory-sample.sh` is on `area/soak-memory`: one soak through
`scripts/soak.sh` with `footprint` and `vmmap` samples of the engine at minutes five, ten,
twenty and thirty, then a report of every memory category at every sample, largest growth
first, with the malloc zones' live bytes against their dirty bytes, and the black box's own
minute totals beside them. Adam gave the machine on 2026-11-02 and the thirty-five-minute
run happened (report under `tests/soak-output/memory-2026-11-02-163230/` in that worktree,
copied into the main checkout's `tests/soak-output/`). It named the growth. Resident size
rose from 255 MB at minute ten to 275 MB at the end, the same slope as the three-hour run's
first hour, and it is made of two things: the purgeable malloc zone, whose live bytes grew
from 7 MB at minute ten to 21 MB at minute thirty in a straight line (system cache memory,
most likely CoreGraphics and CoreText glyph and image caches from text rasterization, which
the kernel discards under pressure and which Apple's footprint figure leaves out), and the
small malloc zone's dirty pages, up 4 MB while its live bytes stayed flat (allocator
fragmentation, not objects). Everything the engine owns held still after minute ten: the
heap's live bytes at 75 MB, Metal textures and heaps at 117 MB, IOSurfaces at 157 MB, the
large malloc zone at 67 MB, the text cache at 50 MB. The GPU-owned part of the footprint
swings between about 173 MB and 213 MB from sample to sample, so the footprint total
oscillates while the CPU-side dirty memory moved by about 3 MB in twenty minutes. No leak
was found. Two more facts from the run: the minute record's resident figure counts the
purgeable cache and misses the GPU-owned memory, so it is the wrong figure for §13's rule in
both directions; and each `vmmap` sample freezes the engine for about two thirds of a
second, which the watchdog logs and a display answers with re-presents, so the attribution
run is never the §13 verdict run. The §13 per-minute breakdown in the minute record is
planned, with the footprint and the malloc zones among its fields, and waits for Adam's OK
(Needs Adam); the §13 rule itself has a correction proposed below. Everything else is on `main`; nothing but the script waits
on a branch. The bench's three-hour run with a card and both outputs captured (Spec 4 §15)
comes after memory is settled.

## Needs Adam

### Briefs waiting for approval

None. The soak-fixes brief (the final message of the Area 4 session on 2026-11-02) was
answered the same day: approved and merged (2074bd6), the §11 and §12 corrections applied.

### Plans waiting for an OK

- **The Spec 4 §13 per-minute breakdown** (engine, `area/soak-memory`, tests first). §13's
  per-minute line names "memory in use (heaps, decoder pools, caches)"; the record carries
  one total, the process's resident size. The plan: the minute record gains the process
  footprint (the figure Apple's `footprint` reports, beside the resident size it has), the
  malloc zones' live and dirty bytes with the purgeable zone on its own (so cache growth and
  fragmentation show as themselves), the resource table's texture bytes summed from its live
  descriptors, the decoder pools' bytes (per live session, its pool depth times its frame
  size), the text cache's bytes, and the readback buffers' bytes; the black box writes them
  with the other minute fields, the reader reads them with zeros for older files, and the
  soak verdict names which part grew between minute ten and the peak. Every source is a
  statistic the engine or libmalloc already keeps, read on the recorder's thread; nothing on
  the render thread changes. Tests: the record round-trips through the black box and its
  reader, an older record without the keys parses with zeros, the resource table's byte sum
  follows allocate and release, the verdict names the largest grower. Recommended: yes, now,
  so the bench's three-hour run attributes itself minute by minute, with no sampling freezes,
  and gives the §13 correction below its evidence.

### The attended run

- Done on 2026-11-02 (Now). A second attended run is wanted only if the purgeable growth
  needs naming beyond its zone: about ten minutes of the engine under Instruments'
  Allocations (`xctrace`, the purgeable category by call stack), in a window Adam sets
  aside. The script stays the quick check: `scripts/soak-memory-sample.sh` from the
  `area/soak-memory` worktree, with `--minutes 1 --at "0.25 0.75"` for a smoke run.

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
  CLAUDE.md says.
- **GitHub Actions billing** no longer blocks CI: on the public repository standard hosted
  runners are free. The ProductionLCBC account's payment problem (Settings, Billing and
  plans) matters again only if the repository goes private or a paid feature is wanted.

### Spec interpretations made so far

None outstanding. The soak fixes' readings were approved on 2026-11-02: the audio preroll is
now §11's text (6e546f8), and releasing a variable box's previous raster after its box
transition is §8's "the result replaces the cache entry" applied. The memory rule is read by
its letter, baseline at minute ten and no allowance for warm-up, which is why the second
soak reads FAIL; whether that letter should change is the attribution's question, not a
reading made.

### Spec corrections proposed

- Spec 4 §13, the memory threshold and the per-minute record: "memory in use" is recorded
  as the process's resident size, which counts purgeable cache memory the kernel reclaims at
  will and leaves out the GPU-owned textures and heaps. The attribution run showed the
  resident growth after minute ten to be exactly that purgeable memory plus allocator
  fragmentation, with everything the engine owns flat. Fix: judge the rule on the process
  footprint (`phys_footprint`, which excludes purgeable memory and includes GPU-owned
  memory), recorded per minute beside the breakdown, keeping the ten-minute baseline; and
  because the GPU-owned part swings by tens of megabytes between samples, judge the
  footprint's per-minute median over a sliding window rather than its raw peak, the window
  chosen from the first three-hour record that carries the breakdown. Until Adam accepts
  this the verdict keeps reading FAIL on the resident figure, and this page says why.

§11 and §12 were applied in 6e546f8, Area 4's earlier ones in 7032182. The presets-and-text
spec, when written, owes the text style a vertical anchor defaulting to centre (Spec 4 §8
says so).

## Next

**The breakdown on Adam's OK, the §13 correction on his word, then the bench run.** The
sampling run named the growth (Now); the breakdown (Plans waiting for an OK) makes every
later run name it without sampling; the §13 correction (Spec corrections proposed) makes
the verdict judge the right figure. Then Spec 4 §15's run with the card: the bench machine root (a copy of
`tests/fixtures/spike/machine/` with the main output at the LED wall's format, as a
DeckLink output if the bench has 12G) and `scripts/soak.sh tests/soak/spike.json`, which
writes the media if it is missing, runs the engine with the script over OSC and prints the
§13 verdict. Both runs take the displays and the audio device, so they happen in a window
Adam sets aside; he can run either without a session.

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
