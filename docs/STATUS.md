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
| 4 | Engine spike (`engine/`): headless OEngine over OSC, two channels, two stacks, three hours clean | `specs/4-render-pipeline.md` §15 | brief waiting for approval | Built through its five checkpoints on `area/spike` (pushed, tip dc85c4f) in one session on 2026-10-28/29 with Adam's plan answers; `swift test` green; the `oengine` process ran the Spec 4 §15 script on the dev Mac's two displays for four minutes with every §13 threshold held. Waits on Adam's `approved`, the DeckLink SDK in `vendor/` for the ObjC++ wrapper, and the three-hour bench run. |
| 5 | Render pipeline, the rest: 1080i weave, text cache, thumbnails, multiviewer, measurement | `specs/4-render-pipeline.md` | not started | After the spike passes every §15 criterion on the bench. No prompt block in `docs/build-order.md` yet. |
| 6 | Stacks and presets: slots, boxes, text styles, resolution order, blackout and mute, offset +1 | `specs/1-objects-and-format.md` + presets-and-text spec | not started | Spec needed first (presets and text). The object types are on `main` since Area 2; the spike's stack pass on `area/spike` already resolves slots, fit modes, opacity, mute and the +1 slot. |
| 7 | Output sinks: display per screen, DeckLink with weave, output transitions | `specs/4-render-pipeline.md` §10 | not started | After the spike. The display and DeckLink sinks, the encode pass and the switch and blackout mixes exist on `area/spike`; the weave and key/fill remain. |
| 8 | Media pool: hash IDs, index, import by copy, poster frames, missing state | media-pool spec | not started | Spec needed first. The index, the resolver, SHA-256 identity and the missing state are on `main` since Area 2; the rebuild walk, import by copy and poster extraction remain. |
| 9 | Cues, lists and playlists: write/clear/hold, Go and Time triggers, sections, linked items, live pointer, next | cues-lists-playlists spec | not started | Spec needed first. The runner on `main` logs a fired cue as its own group with `fire`; the spike's control loop fires armed Time triggers and `next` as engine groups. |
| 10 | Text editor: whole-list text document with cue breaks | edit-mode spec | not started | Spec needed first. |
| 11 | Variables: Time, Date, Timer and Popup slots, captions over OSC | presets-and-text spec | not started | Spec needed first. `popup N set` over OSC is on `main` since Area 3; the spike resolves `[Time]`, `[Date]` and `[Popup N]`, not `[Timer N]`. |
| 12 | Log and saving: command log with sources, continuous save, launch snapshots | log-and-saving spec | not started | Spec needed first. The atomic write, the write plan and the versions folder are on `main` since Area 2; the Spec 2 §9 entry and its one-line form since Area 3; debouncing, the log file and snapshots remain. |
| 13 | Show-mode UI (`app/`): three columns, grid, strip, preview and multiviewer, tabs, top bar, keyboard | show-mode-ui spec | not started | Spec needed first; nothing in `app/` starts before the spike passes. |
| 14 | Edit mode, minimal: cue inspector with palette, stack editor, channel sheet, preset editor | edit-mode spec | not started | Spec needed first; in `app/`, so after the spike passes. |
| 15 | Macros, basic: command lists without guards, the clears tab | `specs/2-commands.md` | not started | After Area 3, so it can start; the runner's macro expansion, the depth cap and the cycle check are on `main`. |
| 16 | Audio, basic: routing to numbered outputs, gain | `specs/4-render-pipeline.md` §11 | not started | After the spike. The mix graph for one device, routing, gain ramps, audio transitions, the delay line and mute exist on `area/spike`. |
| 17 | Settings: inputs, outputs, audio outputs, keys, media root, startup | settings section of show-mode-ui spec | not started | Spec needed first. |
| 18 | Operator lock: passcode in the Keychain, edit mode blocked | show-mode-ui spec | not started | Spec needed first. |
| v1.5 | After the pilot: runtime undo, library mode and local copies, NDI, live inputs, audio transitions, pre-flight report, optimize on import, macro guards and the scheduler, lookahead polish, distribution conventions | `docs/build-order.md` | not started | Specs wait until the pilot is scheduled. Each row has its own task in the Build tracker. |
| v2 | Slide designer, timelines and clocks, custom transitions, CCLI reporting | `docs/build-order.md` | not started | Deferred. |

## Now

**Area 4, the engine spike, is in review on `area/spike`** (its own Nimbalyst worktree
session, branched from `main`; pushed, tip dc85c4f). The session proposed its plan, took
Adam's seven answers (build against a C face of the DeckLink module with a stub until the SDK
arrives, macOS 15, the in-repo Metal plugin, engine targets macOS-only, one package shape,
run through the checkpoints without stopping, nothing opening a screen under `swift test`),
then built checkpoint by checkpoint: the seams, clocks, frame plan, control and render loops,
harness and metrics; the Metal backend with the channel pass, sources and colour reference;
the text rasterizer, cache and stack pass with the +1 slot; the display and DeckLink sinks,
the tick scheduler and the threaded engine with its recovery rows; the audio graph with the
device clock driving media time, the OSC server, and the `oengine` process with `run`,
`soak`, `drive`, `evaluate` and `make-fixtures`, the spike fixture roots and the ten-minute
script. Running the process on the dev Mac found and fixed four things the harness could not:
the display sink's vsync race, an autorelease leak on every long-running thread, a watchdog
read of the control thread's tables, and pipelines compiled on a tick. `swift test` is green
on the branch; the four-minute soak on two displays held every Spec 4 §13 threshold with
memory flat. `main` carries nothing of Area 4 but this page; the code waits on the branch for
Adam's `approved`, and the three-hour run waits on the bench and the DeckLink SDK.

## Needs Adam

### Briefs waiting for approval

- **Area 4 — Engine spike**: the brief is the final message of the Area 4 session
  (2026-10-29). It asks Adam to decide: (1) whether the readings below stand (recommended:
  yes, with the four spec corrections proposed); (2) that the display sink presents one tick
  behind the master rather than "the newest completed frame" read literally (recommended:
  yes, it is what makes re-presents zero); (3) that text centres vertically in its box until
  the presets spec adds a vertical anchor (recommended: yes); (4) when to drop the DeckLink SDK
  into `vendor/` so the ObjC++ wrapper of `ODeckLink.h` can be written and the SDI output,
  embedded audio and hardware clock tried on the bench (recommended: before Area 5, in the
  same branch or a short follow-up session); (5) that `restoreLastState` and the `[Timer N]`
  variable are left to Areas 12 and 11 (recommended: yes).

### Spec interpretations made so far

| Spec | Left open | Chosen | Alternative |
| --- | --- | --- | --- |
| Spec 4 §14 | How the package is laid out and built | macOS 15 deployment target (Synchronization atomics); engine targets macOS-only in the manifest so the Linux CI job keeps proving OCore; `.metal` files compiled by an in-repo build-tool plugin into the resource bundle; targets OEngine, OEngineProcess (product `oengine`), ODeckLink, OEngineTests | A prebuilt metallib checked in; an Xcode project |
| Spec 4 §10, §14 | The DeckLink SDK is not in `vendor/` | The sink is built against a small C face (`ODeckLink.h`) with a stub that reports the card unavailable; the sink pauses and the engine runs on; the ObjC++ wrapper lands with the SDK | Block the area on the SDK |
| Spec 4 §6 | The outgoing of a transition when it is cut short, restarted, or when the transition is a cut | A one-copy snapshot of the outgoing channel texture; otherwise the outgoing keeps playing through the dissolve (two decoders) | Two decoders always |
| Spec 4 §6 | A write that lands before its first frame and has no poster | Hold the previous content until the first decoded frame, then start the transition; with a poster, cut to the poster then transition | Show transparent |
| Spec 4 §9 | Whether text has a channel pass | No: text is composited by each stack pass from its own rasters; a text channel renders no channel texture | Render text into the channel texture once |
| Spec 4 §9 | What fit modes fit | The content rect (the source's size) within the box, not the channel render size | The channel texture |
| Spec 4 §5, §9 | Transition targets | One ring of three textures per stack and nothing more; a box dissolve is two draws with opacities; a switch mixes at the sink from the old stack's ring | Dedicated transition targets |
| Spec 4 §8 | Vertical placement of text in a box | Centred; the style has no vertical anchor | Top-aligned; a style field (correction proposed) |
| Spec 4 §10 | The display encode's transfer function | The sRGB OETF at 10-bit for displays; v210 limited-range BT.709 for SDI | Rec.709 OETF on displays |
| Spec 4 §9, §10 | Per-slot mute | Instant, at the stack pass (opacity zero), as §10 says; the output's blackout transition does not apply to mute | Fade over the blackout transition |
| Spec 4 §3, §5 | "The render thread allocates nothing" against Metal's per-frame objects | Command buffers and encoders are made per tick (Metal has no other way) and are outside the count; the allocation test measures the engine's own tick and reads zero in an optimized build; completion is polled, no completion handlers | Treat the Metal objects as a violation |
| Spec 4 §2 | Outputs in two rate families on one machine | Refused at construction (`PacingError.mixedRateFamily`), as is a rate that does not divide the master | Two masters |
| Spec 4 §8, §9 | Which variables resolve in the spike | `[Time]`, `[Date]`, `[Popup N]`; `[Timer N]` is Area 11 | All four now |
| Spec 4 §11 | How audio is demuxed | A separate AVAssetReader on the audio track per instance | One reader with two outputs |
| Spec 4 §7 | Blur and grade during a dissolve | Blur applies to the incoming only; the grade applies to both | Blur both |
| Spec 4 §4, §13 | Aux (preview) passes before IOSurfaces exist | Planned and counted (`auxSkipped` works) but not drawn until Area 5 | Draw to offscreen targets now |
| Spec 1 §3 | `restoreLastState` | Not implemented; the engine starts empty | Load `state/last.json` |
| Spec 4 §16 | Golden images with transparency | An opaque colour PNG plus a separate `.alpha.png`; tolerances max 2 / mean 0.5, text max 64 / mean 1.5 | Straight-alpha PNGs |
| Spec 4 §13 | The p99 | The value at rank floor(0.99 × n) over the window, so it never flatters | Interpolated percentile |
| Spec 4 §2 | A screen faster than the master | The display-link clock delivers every Nth refresh; a sink on such a screen holds between frames without counting re-presents | A second master |
| Spec 4 §8 | Premultiplied sRGB text textures | Core Graphics premultiplies in sRGB space before the GPU linearizes on sample: edges are a shade off; accepted | Linear premultiply on the CPU |
| Spec 4 §10 | "Takes the newest completed frame from the output's ring" | The sink presents the frame of the previous master tick: it latches one frame behind the newest published frame at its first refresh and steps by the master time between refreshes (rounded to the nearest tick), falling back to the newest completed one when that frame is still on the GPU; literally newest-completed raced the render thread on the shared vsync and gave five re-presents a second | The literal reading (correction proposed) |
| Spec 4 §12 | The watchdog before the first tick, build or present | A zero time stamp means not yet; the sink rule counts from the first present | Count from engine start |
| Spec 4 §11 | Which audio outputs a graph serves | One graph per device: the `device` outputs on the HAL device; `sdiEmbedded` outputs belong to the DeckLink sink, whose scheduling of embedded audio is written but unfed until the SDK | One graph for all |
| Spec 4 §15 | The fixture media and list | One list with the five hymns as sections and the clapper as its last cue; six synthetic items written by `oengine make-fixtures` (not committed), named in the index by fixed ids rather than content hashes, posters null | Commit the clips and hash them |
| Spec 4 §16 | "Zero allocations on the render thread after warm-up" | A harness test under libmalloc's `malloc_logger`: exact zero under `swift test -c release`; the unoptimized build allocates and frees a compiler temporary per loop iteration, so there it proves allocations equal frees | Only in release |
| Spec 4 §7 | "Compiled at launch" | `warmUp` compiles every channel variant (each layout, each pair as dissolve or fade, with and without a grade), the box variants, linearize and the encodes at process start | On first use |
| Spec 2 §6 | Which feedback the engine sends in the spike | Live cue, label and item, channel content and state, output stack, blackout, popups and locks after each build; queries for outputs, blackout, channel state and content, lock; `/o/channel/N/remaining` and `/o/timer/N` wait for a per-second timer (Area 11) | Everything now |
| Spec 4 §12 | Audio device loss at run time | At start a missing device falls to the output's fallback device, then the default; loss while running is not handled yet (the hook exists) | Handle now |

### Spec corrections proposed

- Spec 4 §10, display sink: it says the callback "takes the newest completed frame"; the
  code presents the frame of the previous master tick and falls back to the newest completed
  one. Fix: say so, and that a refresh with nothing new is a re-present.
- Spec 4 §3, threads: add that every long-running thread drains an autorelease pool per pass
  (Metal command buffers, encoders, drawables and readback buffers are autoreleased; the first
  three-minute soak grew by gigabytes without it).
- Spec 4 §8 and the presets spec, text style: the box has no vertical anchor; the code centres.
  Fix: add a vertical alignment to the text style or box, defaulting to centre.
- Spec 4 §16, allocation test: say "in an optimized build" (the debug compiler allocates
  temporaries per loop iteration of unspecialised generic code).

## Next

**Area 4 stays live until Adam writes `approved`** in its session, after which the same
session merges `area/spike` into `main` with `--no-ff`, marks the task `shipped` and removes
the worktree. Before Area 5 can start, Spec 4 §15 wants the three-hour bench run: the DeckLink
SDK in `vendor/` (see `vendor/README.md`), the ObjC++ wrapper of `engine/ODeckLink/include/ODeckLink.h`
written against it, the bench machine root's main output set to the LED wall's format, then
`scripts/soak.sh tests/soak/spike.json` with both outputs captured.

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
`main`. Area 16 (audio, basic) has most of its engine side on `area/spike` and would follow
the merge. The specs for the areas marked "Spec needed first" above can be written in Cowork
at any time; each already has its task in the Build tracker, marked `spec needed`. The
presets-and-text spec can take the spike's stack pass as given and decide the vertical anchor.
