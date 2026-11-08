# Status

The one-page view. Every session starts by reading this page and ends by rewriting it
(`CLAUDE.md`, "Session contract"; `/wrap-up` does the rewrite). It lives on `main` and is
current on `main` after every session, even while an area's code waits on its branch. The
detail is elsewhere: the areas and their prompts in `docs/build-order.md`, mirrored by the
Build tracker in Nimbalyst; each area's brief as the final message of its session (Area 1's
predates that and is a file, `docs/reviews/area-1-projection.md`, which records Adam's
answers at the top); one line per session in `CHANGELOG.md`; the scope of the areas still
waiting on a spec, as Adam settled it on 2026-11-04, in the Project O scope gaps doc
(https://claude.ai/artifact/2wd3EJdEYcY1uf3zpvFtW6).

## Areas

State is one of `not started`, `in progress`, `brief waiting for approval`, `merged`.

| # | Area | Spec | State | Last session, or what is left |
| --- | --- | --- | --- | --- |
| 1 | Channel state and projection (`core/`) | `specs/3-channel-state-and-projection.md` | merged | Adam's `approved` on 2026-10-27; spec corrections applied (e57728f), `area/projection` merged into `main` with `--no-ff` (d7465b8), `swift test` and CI green on `main`, branch and worktree removed, task `shipped`. |
| 2 | Object model and library format (`core/`, `formats/`) | `specs/1-objects-and-format.md` | merged | Adam's `approved` on 2026-10-28 with one reversal (a missing transition degrades to the channel default, then to a zero-second cut; 78902ef on the branch); spec corrections applied (cc404c0), `area/format` merged into `main` with `--no-ff` (70bf958), `swift test` and CI green on `main`, branch and worktree removed, task `shipped`. |
| 3 | Command vocabulary: grammar, parser and printer, validation, OSC mapping (`core/`) | `specs/2-commands.md` | merged | Adam's `approved` on 2026-10-28 with the recommended answers; spec corrections applied (fd2f4d2), `area/commands` merged into `main` with `--no-ff` (06a3ef1), `swift test` green on the merged tree, pushed, branch and worktree removed, task `shipped`. |
| 4 | Engine spike (`engine/`): headless OEngine over OSC, two channels, two stacks, three hours clean | `specs/4-render-pipeline.md` §15 | merged | Adam's `approved` on 2026-10-31 with every recommendation taken; the DeckLink SDK put in `vendor/` and the module's wrapper written against it (13d230e); Spec 4 §3, §8, §10, §16 corrected (7032182); `area/spike` merged into `main` with `--no-ff` (e735052), task `shipped`; hosted CI green on `main` since 962dd4b. The first three-hour soak on two displays (2026-11-01) found faults fixed on `area/soak-fixes` and merged on Adam's `approved` (2074bd6, 2026-11-02); the second run's memory growth was attributed on 2026-11-02 to purgeable cache memory and allocator fragmentation, no leak; the §13 memory breakdown and the corrected threshold merged on Adam's `approved` (87011b2, 2026-11-03). Every display-side criterion of §15 holds; the DeckLink criteria wait for the bench run with a card, which Adam has deferred to a window he sets aside. |
| 5 | Render pipeline, the rest: 1080i weave, text cache, thumbnails, multiviewer, measurement | `specs/4-render-pipeline.md` | merged | Adam's `approved` on 2026-11-03 with every recommendation taken; Spec 4 §2, §10, §13, Spec 2 §6 and Spec 1 §5 corrected (e8e1e3f); `area/render` merged into `main` with `--no-ff` (5b3f6ed), `swift test` green on the merged tree, pushed, branch and worktree removed, task `shipped`. The weave's capture-rig check (§16) joins the bench run. |
| 6 | Stacks and presets: slots, boxes, text styles, resolution order, blackout and mute, offset +1 | `specs/6-presets-and-text.md` | not started | Spec 6 accepted 2026-11-04 and on `main`, with the prompt block in `docs/build-order.md`: the offset on the box, Preset 1's confidence layout and the Clock preset, field boxes over the list's metadata with the provenance's list in `core/`, the text style's anchor, units and overflow, tabular digits, the bundled fonts, the fixtures and schemas. The object types are on `main` since Area 2; the stack pass, the +1 slot and the one shared `SlotResolver` since Areas 4 and 5. |
| 7 | Output sinks: display per screen, DeckLink with weave, output transitions | `specs/4-render-pipeline.md` §10 | not started | After the bench run, and folded into it on Adam's answer of 2026-11-04: key and fill stays v1.5, and the area becomes bench verification and fixes, its block written from the run's findings; its `docs/build-order.md` row and Build tracker task change together in a Nimbalyst session. The display and DeckLink sinks, the encode pass and the switch and blackout mixes are on `main` since Area 4, the 1080i weave since Area 5, the DeckLink sink as the embedded audio feed's destination since Area 16. |
| 8 | Media pool: hash IDs, index, import by copy, poster frames, missing state | `specs/8-media-pool.md` | not started | Spec 8 accepted 2026-11-07 and on `main`, with the prompt block in `docs/build-order.md`, to start after Area 9 (`media replace`, `media delete` and the defaults edits ride its edit path): the six media commands, import with staging and hash first, the walk with its hash cache telling moves, re-exports and restores apart, the two indexes and `machine/media/`, the media root on the startup volume (M-8), posters at the in-point and pool tiles, delete and replace with their inverses, the `media` topic and the use query, drop channels. The index types, a resolver over the media root, SHA-256 identity and a missing set computed at launch are on `main` since Area 2. |
| 9 | Cues, lists and playlists: write/clear/hold, Go and Time triggers, sections, linked items, live pointer, next | `specs/7-cues-lists-and-playlists.md` | not started | Spec 7 accepted 2026-11-07 and on `main`, with the prompt block in `docs/build-order.md`: list folders on disk, a playlist's title as its identity and items with uuids, the live pointer placed from the engine's kept copies when what it names is gone, the armed trigger with `disarm`, archive as a dated copy, live feedback and the countdown, and Spec 5's edit path for lists, cues, folders and playlists with the debounced write, and kept versions filed by list uuid and never written over (Spec 9 §6). The runner on `main` logs a fired cue as its own group with `fire`; the engine's control loop fires armed Time triggers as `next`; the thumbnail job projects a list from its top (Area 5). |
| 10 | Text editor: whole-list text document with cue breaks | edit-mode spec | not started | Spec 11, Edit mode, drafted 2026-11-08 in the specs doc and revised after three independent reviews, its §5 the text editor; its choices wait for Adam (one channel at a time, each chunk bound to its cue's uuid, an empty chunk clears; a paste breaks cues at blank lines and section lines; ⌘Z is the library's undo while the last change is the editor's own). It starts after Area 14, whose frame and Cues page it joins. |
| 11 | Variables: Time, Date, Timer and Popup slots, captions over OSC | `specs/6-presets-and-text.md` | not started | Spec 6 accepted 2026-11-04 and on `main`, with the prompt block in `docs/build-order.md`, to start after Area 6 (its context values read Area 6's provenance): the variable language and the v1 set with the context values and `[Service In]`, the adoption pacing, timers counting down and up, popups resolving their variables one level deep, the timer and remaining-time feedback. `popup N set` over OSC is on `main` since Area 3; `[Time]`, `[Date]` and `[Popup N]` in static boxes, behind the once-a-second gate, since Area 5. |
| 12 | Log and saving: command log with sources, continuous save, launch snapshots | `specs/9-log-and-saving.md` | not started | Spec 9 accepted 2026-11-07 and on `main`, with the prompt block in `docs/build-order.md`, to start after Area 9 (it builds on Area 9's edit path, debounced write and versions): the command log and the engine log a file a day each, the black box a file an hour in its own folder, notes, snapshots with their cadence and retention, the last state with the guard against a crash loop, edit undo and redo with the `history` topic, the two restore commands, a low or full disk and the `saving` topic. The atomic write, the write plan and the versions folder are on `main` since Area 2, the Spec 2 §9 entry and its one-line form since Area 3, the black box since Area 4. |
| 13 | Show-mode UI (`app/`): three columns, grid, strip, preview and multiviewer, tabs, top bar, keyboard | `specs/10-show-mode-ui.md` | not started | Spec 10 accepted 2026-11-08 and on `main`, with the prompt block in `docs/build-order.md`, to start after Area 19 and once the spike passes on the bench: the app and the engine as two processes, with the curtains and the rule that always starts the engine again; the main window and its regions, with each channel's live picture in the strip; the keys and their precedence; the edits from show mode, Finder drops that import and then write, the restore sheets and the tags; VoiceOver and the string catalog from the first build. The engine side of the preview and the multiviewer (one IOSurface-backed quarter-size texture per stack) and of thumbnails is on `main` since Area 5; the Mach hand-off, the channel pictures and the API's topics are Area 19's. The audio device badge is the snapshot's `audioDevices` list since Area 16. |
| 14 | Edit mode, minimal: cue inspector with palette, stack editor, channel sheet, preset editor | edit-mode spec | not started | Spec 11, Edit mode, drafted 2026-11-08 in the specs doc and revised after three independent reviews; its sixteen choices wait for Adam (A-1 has the engine draw the editors' pictures through a new `render` query, and A-9 adds a `uses` query; it also takes the small editors for grades, transition timing, audio transitions, text styles and macros); in `app/`, so after the bench run and Area 13. The thumbnail job that `render` reuses is on `main` since Area 5. |
| 15 | Macros, basic: command lists without guards, the clears tab | `specs/2-commands.md` | not started | Next. Its prompt block went into `docs/build-order.md` on Adam's word of 2026-11-04, with `stack all blackout` added; it needs no new spec. The runner's macro expansion, the depth cap and the cycle check are on `main`. |
| 16 | Audio, basic: routing to numbered outputs, gain | `specs/4-render-pipeline.md` §11 | merged | Adam's `approved` on 2026-11-04 with every reading as built; `area/audio` merged into `main` with `--no-ff` (89641e9), `swift test` green on the merged tree, pushed, branch and worktree removed, task `shipped`. One mix graph per distinct device and one per SDI-embedded output, the lowest-numbered output's device as the clock, device loss to the fallback or a silence stand-in and the return, the embedded feed on the card's stream time, underruns per device. The hardware path (a real device unplugged, a card) waits for the bench. |
| 17 | Settings: outputs, audio outputs, key bindings, media, startup and backup, the lock page, variables, tracking, thumbnails and engine, network, command bar | `specs/10-show-mode-ui.md` | not started | Spec 10 accepted 2026-11-08 and on `main`, with the prompt block in `docs/build-order.md`, to start after Areas 13 and 14: the settings window and its pages, each change an edit with §11's ask-first rules; the engine's edits of outputs, audio outputs, key bindings and the machine settings; the confirmation of an output on the app's own screen, which reverts after 15 seconds without Keep. No Inputs page until live inputs. |
| 18 | Operator lock: passcode in the Keychain, edit mode blocked | `specs/10-show-mode-ui.md` | not started | Spec 10 accepted 2026-11-08 and on `main`, with the prompt block in `docs/build-order.md`, to start after Area 17: the lock turned on by an edit kept off the undo stack and refused until a passcode exists; unlocking and the passcode as requests on the engine's local socket, with a five-attempt lockout that holds across a restart; the Keychain kept to the engine; the administrator's reset. |
| 19 | Engine API and first run: the local socket and the LAN API, topics and queries, the preview channel, first run | `specs/10-show-mode-ui.md` §2, §3 and §13 | not started | New with Spec 10 (U-1), accepted 2026-11-08, with the prompt block in `docs/build-order.md`, to start after Area 12; engine-only, so no bench run: the local socket, the LAN listener with the token and Bonjour, the Mach channel (its call proved first) with the preview surfaces, the channel pictures and the meters, the topics, queries and requests, the first-run writer, the relaunch rule and the engine's process behaviour. Its Build tracker task is still to be made. |
| v1.5 | After the pilot: runtime undo, library mode and local copies, NDI, live inputs, audio transitions, pre-flight report, optimize on import, macro guards and the scheduler, lookahead polish, distribution conventions | `docs/build-order.md` | not started | Specs wait until the pilot is scheduled. Each row has its own task in the Build tracker. |
| v2 | Slide designer, timelines and clocks, custom transitions, CCLI reporting | `docs/build-order.md` | not started | Deferred. |

## Now

**Nothing is in review; everything is on `main`.** Area 16 shipped earlier on 2026-11-04
(89641e9). The same day a docs session in Cowork went through every area marked "Spec
needed" with Adam, in the Project O scope gaps doc
(https://claude.ai/artifact/2wd3EJdEYcY1uf3zpvFtW6): for each unwritten spec, what Specs
1–4 and the UX spec already settle, what is on `main`, and his answer to every open
question, then a review of the answers whose fixes he accepted. It added a spec no area
owned, Spec 5, Editing (the `edit` command family, its inverses and edit undo), to be
written before the others, and an app-and-engine section for the show-mode UI spec. On his
word the Area 15 prompt block went into `docs/build-order.md` with `stack all blackout`
added. Spec 5 was then drafted in Cowork as a tab of the Project O specs doc, reviewed,
and accepted by Adam the same day with his answers to its seven choices (E-1 widened so
every source can hold an edit, with three rules for edits held by cues; the rest as
drafted). It is in `docs/specs/5-editing.md`, and its corrections to Specs 1–4 are
applied.

Spec 6, Presets and text (Areas 6 and 11), followed the same way: drafted, revised after
an independent review, and accepted by Adam the same day, with T-2 taking the alternative
(a popup's text resolves its variables one level deep). It is in
`docs/specs/6-presets-and-text.md`, its corrections to Specs 1–5 and `ARCHITECTURE.md` are
applied, and the prompt blocks for Areas 6 and 11 are in `docs/build-order.md`.

Spec 7, Cues, lists and playlists (Area 9), followed on 2026-11-07: drafted, revised after
two independent reviews (the first replaced its live pointer with one the engine places
each time it reads it), and accepted by Adam with every choice as drafted. It is in
`docs/specs/7-cues-lists-and-playlists.md`, its corrections to Specs 1, 2, 3, 5 and 6 are
applied, and the Area 9 prompt block is in `docs/build-order.md`.

Spec 8, Media pool (Area 8), followed the same day: drafted, revised after three
independent reviews (they moved the cases that syncing to read-only campuses creates to
library mode in v1.5, and settled how the walk tells a move from a re-export or a restore
and how a delete meets undo), and accepted by Adam with every choice as drafted; on M-8 he
asked to look into the alternative later. It is in `docs/specs/8-media-pool.md`, its
corrections to Specs 1–5 are applied, and the Area 8 prompt block is in
`docs/build-order.md`.

Spec 9, Log and saving (Area 12), followed the same day: drafted, revised after two
independent reviews (they added a guard so a state that crashes the engine can't come back
in a loop, filed kept list versions by uuid so nothing writes over them, and settled how a
snapshot restore runs beside cues and how a full disk is handled), and accepted by Adam
with every choice as drafted. It is in `docs/specs/9-log-and-saving.md`, its corrections to
Specs 1–8 are applied, the Area 9 block files kept versions by uuid, and the Area 12
prompt block is in `docs/build-order.md`.

Spec 10, Show-mode UI (Areas 13, 17 and 18), followed: drafted on 2026-11-07, revised
after three independent reviews, and accepted by Adam on 2026-11-08 with eleven choices
as drafted and four alternatives: the strip shows each channel's live picture (U-3), the
app always starts the engine again (U-7), a file from the Finder dropped on a cue or a
strip cell is imported and then written (U-8), and Next waits until something is live
(U-15). It adds Area 19, Engine API and first run, engine-side (U-1). It is in
`docs/specs/10-show-mode-ui.md`, its corrections to Specs 1, 2 and 4–9 and to
`ARCHITECTURE.md`, ADR 0002, `CLAUDE.md` and `app/README.md` are applied, and the prompt
blocks for Areas 19, 13, 17 and 18 are in `docs/build-order.md`.

Spec 11, Edit mode (Areas 14 and 10), was then drafted the same way on 2026-11-08 and
revised after three independent reviews. They made the text editor's ⌘Z undo only the
editor's own last change, made Fire send what a click sends where the list came from (its
playlist or the Library window), made a section line in a paste break cues as a blank line
does, had a swap check both of the objects it exchanges, kept `render` to the local
socket, and defined a move by position for what has no address of its own, such as a box
or a cue's command. Its sixteen choices, A-1 to A-16, wait for Adam's answers in the specs
doc; A-1 has the engine draw the editors' pictures through a new `render` query and A-9
adds a `uses` query, both Area 14's. It is the last of the specs the scope gaps doc
listed.

The bench's three-hour run with a card and both outputs captured is deferred to a window
Adam sets aside; it stays the gate for `app/`, its minute records set the §13 median
window and show the thumbnail job's cost, it checks the weave on the capture rig (§16), and
it now also proves the embedded audio feed against the clapper and a real device loss.

Area 15, macros (basic), is next; its block is in `docs/build-order.md`, and its session
starts from it in its own worktree.

## Needs Adam

### Briefs waiting for approval

None. The Area 16 brief (the final message of the Area 16 session, 2026-11-03) was answered
on 2026-11-04: approved as built, merged (89641e9).

### Decisions

- **Spec 11, Edit mode, for review.** Drafted in Cowork as a tab of the Project O specs
  doc (https://claude.ai/artifact/Gv6oJ5sSvzr9jBnMcaUpWh) from the scope gaps doc's
  answers (E1–E9, C4), its review (R5), the UX spec's edit-mode sections and the clickable
  demo's cue inspector, and revised after three independent reviews. Sixteen choices, A-1
  to A-16, wait for his answers in its §14. A-1 and A-9 add the `render` and `uses`
  queries to the engine, which Area 14 builds; A-7 makes audio transitions editable in v1,
  which takes them out of the v1.5 row but for the sync-offset UI and the strip's split
  transition bar; A-16 puts edit mode's controls in an edit bar under the top bar. On
  acceptance it is exported to `docs/specs/11-edit-mode.md` with its corrections to Specs
  1, 2, 4–8 and 10, `app/README.md` and `docs/build-order.md` (the Area 9 block gains the
  move by position and the check that a cue's uuid is unique in its list, the Area 19
  block the query answer shape, and the Area 17 block leaves an output's default stack and
  transitions to Area 14), and Areas 14 and 10 get their prompt blocks.

- **Where the media root may live, later.** Spec 8 keeps v1's media root on the startup
  volume, outside Desktop, Documents and Downloads (§2, M-8), because macOS asks an
  ad-hoc-signed engine again after every update before it reads an external drive, a
  share or those folders (ADR 0007). Adam asked on 2026-11-07 to look into the
  alternative later: a media root anywhere, with access granted again after each update,
  or kept once builds are signed. It belongs with ADR 0007's revisit when the pilot is
  scheduled.

- **When the bench run happens.** Deferred by Adam on 2026-11-03 ("later") to a window he
  sets aside: the bench machine root (a copy of `tests/fixtures/spike/machine/` with the
  main output at the LED wall's format, as a DeckLink output if the bench has 12G) and
  `scripts/soak.sh tests/soak/spike.json`. He can run it without a session; its record
  answers the DeckLink criteria of §15, sets the §13 median window, shows whether the
  purgeable zone caps and what the thumbnail job costs, checks the weave on the capture
  rig, and (once Area 16 is merged) the embedded audio feed against the clapper.

### The attended run

- A second attended memory run is wanted only if the bench record shows the purgeable zone
  not capping: about ten minutes of the engine under Instruments' Allocations (`xctrace`,
  the purgeable category by call stack), in a window Adam sets aside. The quick external
  check stays on `main`: `scripts/soak-memory-sample.sh`, with `--minutes 1 --at "0.25 0.75"`
  for a smoke run.

### Housekeeping

- **Areas 6, 8, 9, 11, 12, 13, 17, 18 and 19 in the Build tracker.** Their specs and
  prompt blocks are on `main`, but they still read `spec needed` in `docs/build-order.md`
  and in the tracker, which only Nimbalyst changes, and a status changes in both places
  or in neither. Area 19 is new and has no tracker task yet. Each area's first session
  sets both to `in progress`; until then they can move to `not started` together.
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

None outstanding. Area 16's readings were approved as built on 2026-11-04 and are recorded
here and in the brief:

| Spec | Left open | Chosen | Alternative |
| --- | --- | --- | --- |
| Spec 4 §11, "the first-numbered device is the clock" | Which device is first when a channel lists its outputs out of order | The device of the lowest-numbered Audio Output the channel names | The first device in the channel's list order |
| Spec 4 §12, the fallback when several outputs share a device | Whose fallback a graph follows | The lowest-numbered output's; an output on that device with a different or no fallback is silent until the primary returns, with its own log line | A second unit per differing fallback, giving up one unit per device |
| Spec 4 §12, "silence" | Whether a lost device's rings are still consumed | A paced silence stand-in consumes at 48 kHz on the machine clock, so decoders, the instance clocks and the picture continue | Stop consuming, which freezes the clock and the video of that channel for the outage |
| Spec 4 §12, "a badge", and §13 | What the badge is before the app exists, and whether a loss fails a soak | The device states in the metrics snapshot and the process summary, and one watchdog recovery per loss | Log only, and a soak with a device loss passes |
| Spec 4 §10 and §11, the embedded feed's lead | How far ahead of stream time audio is scheduled | Three video frames, the depth the sink schedules video, and the clock reads the scheduled position | A fixed millisecond lead independent of the frame rate |
| Spec 4 §13, "audio underruns per device" | The key and the shape | `audioUnderrunsByDevice` in the minute record and the snapshot, keyed by the graph's primary device (`default`, a UID, `sdi:N`); underruns on a fallback count against the primary's key | A per-output count |
| Spec 4 §11, a channel index beyond the device | Fold onto an existing channel or drop | Dropped with a warning; the graph's channel count is the outputs' highest index plus one | Fold modulo the device's channels |
| Spec 4 §11, a card that is not running | What the embedded graph does | Consumes on the machine clock and discards, joining the card's stream time when it starts | Hold the rings until the card runs |

Earlier areas' readings were approved on 2026-11-03 (Area 5), in 74de762 and the Area 4
brief (§13), 6e546f8 (the soak fixes) and 7032182 (Area 4), and are in the specs' text or
the briefs.

### Spec corrections proposed

None from Area 16; Spec 4 §11, §12 and §13 read as built. Accepted by Adam on 2026-11-04
in the scope gaps doc, and applied when the spec that owns each is written (that spec
proposes the exact text):

- Spec 2 §3 and §6: `stack all blackout` (Area 15).

## Next

**Area 15 — Macros, basic** (branch `area/macros`); it runs in its own session from the
common preamble in `docs/build-order.md` and its own block there, verbatim:

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

After Area 15, Areas 6, 11, 9, 8, 12 and 19 are ready, in that order, from their blocks in
`docs/build-order.md`; all six are engine-side and need no bench run, Areas 8 and 12 start
after Area 9, whose edit path they extend, and Area 19 after Area 12. The app's areas come
after the bench run: 13 after Area 19, then 14 once its spec is in, 17 after 13 and 14,
and 18 after 17. The edit-mode spec, Spec 11 (Areas 14 and 10), is drafted and waits for
Adam's answers; on acceptance it is exported to `docs/specs/` with its areas' prompts
added to `docs/build-order.md`, when their Build tracker tasks move from `spec needed` to
`not started`, and every spec the scope gaps doc listed is written. The bench run with the
card happens whenever Adam sets a window; it does not block Area 15 or the engine-side
areas, and it must pass before anything in `app/` starts (Areas 13, 14, 17 and 18) and
before Area 7's bench verification.

Spec 5 has no area of its own. Its engine side lands with Area 9, which builds the edit
path with the list, cue, folder and playlist edits and the debounced write with the
version cadence (Spec 7 §7), and with Area 12, which takes edit undo and redo and the
restore commands (C2, G6) alongside the log file. The other objects' edits come with Areas
8, 14 and 17, and the app areas issue edits through that path.
