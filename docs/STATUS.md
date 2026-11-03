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
| 4 | Engine spike (`engine/`): headless OEngine over OSC, two channels, two stacks, three hours clean | `specs/4-render-pipeline.md` §15 | merged | Adam's `approved` on 2026-10-31 with every recommendation taken; the DeckLink SDK put in `vendor/` and the module's wrapper written against it (13d230e); Spec 4 §3, §8, §10, §16 corrected (7032182); `area/spike` merged into `main` with `--no-ff` (e735052), task `shipped`; hosted CI green on `main` since 962dd4b. The first three-hour soak on two displays (2026-11-01) found faults in the still source's release, the engine's sweep, the clock box's raster, the audio start and the watchdog's sink rule, fixed on `area/soak-fixes` and merged on Adam's `approved` (2074bd6, 2026-11-02) after a second three-hour run that was clean except for memory; the memory question was answered by the attribution run and the §13 breakdown now waits for approval on `area/soak-memory` (Now). The bench run with a card is still to do. |
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

**The §13 memory breakdown is in review on `area/soak-memory`** (pushed, tip 374d76d;
hosted CI green on both jobs; its Build tracker item "Soak memory: attribute the growth after
minute ten, then a fix or a Spec 4 §13 correction" is `in review`). On 2026-11-02 the
thirty-five-minute attribution run on Adam's machine named the growth the three-hour soaks
had failed on: resident size climbed after minute ten because the purgeable malloc zone
(system cache memory, most likely CoreGraphics and CoreText glyph caches from text
rasterization, which the kernel discards under pressure) grew in a straight line and the
small malloc zone fragmented, while everything the engine owns held still (the heap's live
bytes, the Metal textures and heaps, the IOSurfaces, the text cache); no leak was found, and
the GPU-owned part of the footprint swings by tens of megabytes between samples as the
driver's pools come and go. On 2026-11-03 Adam gave his OK to the breakdown, accepted the
§13 correction (the sliding median), deferred the bench run until the breakdown is in, and
agreed Instruments is wanted only if the purgeable zone does not cap. The spec was corrected
on `main` first (74de762): §13's per-minute line now names the footprint and its parts, and
its threshold judges the footprint less its graphics-tagged part and the heap's live bytes
as sliding per-minute medians against the first window after minute ten, resident size
only for records without the footprint. Then, tests first, the engine followed the spec
(db0d118): the minute record carries the footprint, its graphics-tagged part, the malloc
zones' live and allocated bytes with the purgeable zone on its own, the resource table's
texture bytes, the decoder pools' bytes, the text cache's bytes and the readback buffers'
bytes, beside the resident size it had; the black box writes them, the reader reads older
files with zeros, the verdict applies the corrected rule and the report names the largest
grower between minute ten and the end. The rasterizer no longer creates a spare font
object per line (374d76d, §8, no golden changes). `swift test` is green on the branch. On
`main`: the spec correction, the soak fixes, the sampling script's branch is not merged.
The bench's three-hour run with a card and both outputs captured (Spec 4 §15) comes after
the merge, in a window Adam sets aside.

## Needs Adam

### Briefs waiting for approval

- **The §13 memory breakdown** (`area/soak-memory`, 374d76d; the brief is the final
  message of the Area 4 session on 2026-11-03). It asks Adam to: (1) approve the breakdown
  and the corrected verdict as built (recommended: yes); (2) confirm the refinement to what
  he accepted, that the rule judges the footprint less its graphics-tagged part, since the
  driver's pools swing by tens of megabytes and the whole footprint's medians would fail
  flat runs at random (recommended: yes; the spec sentence on `main` already says so);
  (3) confirm the heap's live bytes as a second threshold under the same rule (recommended:
  yes, it is where a Swift-side leak shows first and it has no GPU noise); (4) say whether
  GPU-side growth should get its own rule later, since the texture bytes are recorded but
  not judged because stills and stack changes move them legitimately (recommended: not yet;
  a cap at the §5 pre-flight budget is the candidate, decided after the bench record). On
  `approved` the session merges with `--no-ff`, the bench run follows, then Area 5.

### The attended run

- Done on 2026-11-02 (Now). A second attended run is wanted only if the first bench record
  with the breakdown shows the purgeable zone not capping: about ten minutes of the engine
  under Instruments' Allocations (`xctrace`, the purgeable category by call stack), in a
  window Adam sets aside. The script stays the quick check: `scripts/soak-memory-sample.sh`
  from the `area/soak-memory` worktree, with `--minutes 1 --at "0.25 0.75"` for a smoke run.

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

| Spec | Left open | Chosen | Alternative |
| --- | --- | --- | --- |
| 4 §13, the memory threshold | Adam accepted "the footprint's sliding median"; the attribution run showed the GPU-owned part swinging by tens of megabytes between samples | The rule judges the footprint less its graphics-tagged part (the kernel's graphics ledger), recorded beside the footprint; the spec sentence on `main` says so (74de762) | The whole footprint, which would need a longer window or a wider allowance and would still fail flat runs when the driver's pools sit high |
| 4 §13, "the same rule on the heap's live bytes" | Whether the heap gets its own threshold or only a figure in the record | A second threshold: the malloc zones' live bytes, purgeable zone excluded, as sliding medians under the same allowance | The footprint rule alone |
| 4 §13, "the decoder pools' bytes" | VideoToolbox owns the pool and does not report its size | Each live session's pool is sized by §5's depth of eight times the frame its output format takes (NV12, P010, 4:2:2 10-bit, 16-bit RGBA) | Count the IOSurfaces the frame queue holds, which misses the pool's headroom |
| 4 §13, the median window | "a five-minute window until the first three-hour record with the breakdown sets it" | Five minutes, a named constant; a run with fewer settled minutes than the window is one window and cannot fail on memory | Fix the window now from the four samples of the attribution run, which cannot show the swing's period |
| 4 §13, GPU-side growth | Whether the resource table's texture bytes are judged | Recorded and reported, not judged: stills and stack or output changes move them legitimately (§5), and the text cache fills until the show's text has been seen | A cap at the §5 pre-flight budget, or flatness outside the text cache; a question in the brief |
| 4 §5, texture bytes | How a mip chain counts | A third more than the base level, the sum of the chain's series rounded down; formats by role as the §5 table gives them | The exact per-level sum, which differs by less than a kilobyte per texture |
| 4 §13, "the malloc zones' live and allocated bytes" | Which allocator figures stand for "heaps" | libmalloc's statistics: bytes in use and bytes allocated to the zone, summed over every zone but the purgeable one | The kernel's dirty pages per region as `vmmap` shows them, which needs a region walk and freezes the engine |

The soak fixes' readings were approved on 2026-11-02 and are in §11 and §8's text or
application; Area 4's readings in its brief and 7032182.

### Spec corrections proposed

None outstanding. §13 and §15 were corrected on `main` on Adam's acceptance of 2026-11-03
(74de762), with the refinement the table above names, which the brief asks him to confirm;
§11 and §12 in 6e546f8; Area 4's earlier ones in 7032182. The presets-and-text spec, when
written, owes the text style a vertical anchor defaulting to centre (Spec 4 §8 says so).

## Next

**Adam's `approved` on the breakdown brief, the merge, then the bench run.** On `approved`
the session merges `area/soak-memory` into `main` with `--no-ff`, runs `swift test` on the
merged tree, pushes, removes the worktree and the branch, and marks the tracker item
`shipped`. Then Spec 4 §15's run with the card: the bench machine root (a copy of
`tests/fixtures/spike/machine/` with the main output at the LED wall's format, as a
DeckLink output if the bench has 12G) and `scripts/soak.sh tests/soak/spike.json`, which
writes the media if it is missing, runs the engine with the script over OSC and prints the
§13 verdict, now with the breakdown in every minute record and the corrected rule. The run
takes the displays and the audio device, so it happens in a window Adam sets aside; he can
run it without a session, and its minute records set the median window.

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
