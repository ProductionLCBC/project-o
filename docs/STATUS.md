# Status

The one-page view. Every session starts by reading this page and ends by rewriting it
(`CLAUDE.md`, "Session contract"; `/wrap-up` does the rewrite). It lives on `main` and is
current on `main` after every session, even while an area's code waits on its branch. The
detail is elsewhere: the areas and their prompts in `docs/build-order.md`, mirrored by the
Build tracker in Nimbalyst; each area's brief as the final message of its session (Area 1's
predates that and is a file, `docs/reviews/area-1-projection.md`, which records Adam's
answers at the top); one line per session in `CHANGELOG.md`; the scope of the areas that
waited on a spec, as Adam settled it on 2026-11-04, in the Project O scope gaps doc
(https://claude.ai/artifact/2wd3EJdEYcY1uf3zpvFtW6).

## Areas

State is one of `not started`, `in progress`, `brief waiting for approval`, `merged`.

| # | Area | Spec | State | Last session, or what is left |
| --- | --- | --- | --- | --- |
| 1 | Channel state and projection (`core/`) | `specs/3-channel-state-and-projection.md` | merged | Adam's `approved` on 2026-10-27; spec corrections applied (e57728f), `area/projection` merged into `main` with `--no-ff` (d7465b8), `swift test` and CI green on `main`, branch and worktree removed, task `shipped`. |
| 2 | Object model and library format (`core/`, `formats/`) | `specs/1-objects-and-format.md` | merged | Adam's `approved` on 2026-10-28 with one reversal (a missing transition degrades to the channel default, then to a zero-second cut; 78902ef on the branch); spec corrections applied (cc404c0), `area/format` merged into `main` with `--no-ff` (70bf958), `swift test` and CI green on `main`, branch and worktree removed, task `shipped`. |
| 3 | Command vocabulary: grammar, parser and printer, validation, OSC mapping (`core/`) | `specs/2-commands.md` | merged | Adam's `approved` on 2026-10-28 with the recommended answers; spec corrections applied (fd2f4d2), `area/commands` merged into `main` with `--no-ff` (06a3ef1), `swift test` green on the merged tree, pushed, branch and worktree removed, task `shipped`. |
| 4 | Engine spike (`engine/`): headless OEngine over OSC, two channels, two stacks, three hours clean | `specs/4-render-pipeline.md` §15 | merged | Adam's `approved` on 2026-10-31; `area/spike` merged (e735052); the soak fixes (2074bd6) and the §13 memory breakdown (87011b2) merged on his `approved`. Every display-side criterion of §15 held at the soak of 2026-11-02; the DeckLink criteria wait for the bench run with a card, which Adam has deferred to a window he sets aside. The display-only soak of 2026-11-16, the first of everything merged since, holds the display, GPU, audio and watchdog lines and fails late text and the two memory lines (Needs Adam). |
| 5 | Render pipeline, the rest: 1080i weave, text cache, thumbnails, multiviewer, measurement | `specs/4-render-pipeline.md` | merged | Adam's `approved` on 2026-11-03 with every recommendation taken; Spec 4 §2, §10, §13, Spec 2 §6 and Spec 1 §5 corrected (e8e1e3f); `area/render` merged into `main` with `--no-ff` (5b3f6ed), branch and worktree removed, task `shipped`. The weave's capture-rig check (§16) joins the bench run. |
| 6 | Stacks and presets: slots, boxes, text styles, resolution order, blackout and mute, offset +1 | `specs/6-presets-and-text.md` | merged | Adam's `approved` on 2026-11-11 as built, with every reading in the brief and its recommended answers; the Spec 3 §6 correction and ADR 0008's acceptance on the branch (85b4e88), `area/presets` merged into `main` with `--no-ff` (af3c948), `swift test` green on the merged tree, pushed, branch and worktree removed, task `shipped`. Spec 1 §2's `weight` went into Area 11's block. |
| 7 | Output sinks: display per screen, DeckLink with weave, output transitions | `specs/4-render-pipeline.md` §10 | in progress | In progress on `area/sinks` since 2026-11-22, as bench verification and fixes (Adam's answer of 2026-11-04). That day a DeckLink SDI 4K went into the bench Mac with its SDI output cabled to its input, and a loopback test passed in every mode tried; its block in `docs/build-order.md` was written from that test and Adam said go the same day, taking every recommendation (Now). **Paused on 2026-11-22** while Adam moves the card's chassis; it resumes when he has reconnected it. On the branch (fb607d1, pushed): three of the loopback's faults fixed with tests, the frame stamp, `oengine capture`, the bench machine root and `soak.sh --capture`. The first ten-minute run with capture, at 1080p60, passed A/V and failed frame accuracy, and found a fifth and a sixth fault in the engine, not yet fixed (Now). The sinks, the encode pass and the switch and blackout mixes are on `main` since Area 4, the weave since Area 5, the embedded audio feed since Area 16. |
| 8 | Media pool: hash IDs, index, import by copy, poster frames, missing state | `specs/8-media-pool.md` | merged | Adam's `approved` on 2026-11-14 as built, with every reading in the brief and its recommended answers, and no spec correction proposed; `area/media` merged into `main` with `--no-ff` (2c1b3d6), `swift test` green on the merged tree, pushed, branch and worktree removed, task `shipped`. |
| 9 | Cues, lists and playlists: write/clear/hold, Go and Time triggers, sections, linked items, live pointer, next | `specs/7-cues-lists-and-playlists.md` | merged | Adam's `approved` on 2026-11-10 as built, with every reading in the brief and its recommended answers; `area/playlists` merged into `main` with `--no-ff` (af2209e), with its Spec 1 §4, §5 and Spec 5 §2, §4 corrections (e538f2b); `swift test` green on the merged tree, pushed, branch and worktree removed, task `shipped`. The gaps it named are accepted: a folder operation that fails on disk is only logged, and Area 12 takes the kept copies when it restores the last state. |
| 10 | Text editor: whole-list text document with cue breaks | `specs/11-edit-mode.md` | not started | Spec 11 accepted 2026-11-08, its prompt block in `docs/build-order.md`, to start after Area 14, whose frame and Cues page it joins. |
| 11 | Variables: Time, Date, Timer and Popup slots, captions over OSC | `specs/6-presets-and-text.md` | merged | Adam's `approved` on 2026-11-11 as built, with every reading in the brief and its recommended answers, and no spec correction proposed; `area/variables` merged into `main` with `--no-ff` (d4333fa), `swift test` green on the merged tree, pushed, branch and worktree removed, task `shipped`. |
| 12 | Log and saving: command log with sources, continuous save, launch snapshots | `specs/9-log-and-saving.md` | merged | Adam's `approved` on 2026-11-15 as built, with every reading in the brief and its recommended answers; the Spec 9 §6 and §10 correction applied on the branch (7dbdf7d), `area/saving` merged into `main` with `--no-ff` (327454f), `swift test` green on the merged tree, pushed, branch and worktree removed, task `shipped`. |
| 13 | Show-mode UI (`app/`): three columns, grid, strip, preview and multiviewer, tabs, top bar, keyboard | `specs/10-show-mode-ui.md` | merged | Adam's `approved` on 2026-11-18 as built, with every reading in the brief and its recommended answers; the Spec 10 §14, §15 and §18 corrections applied on the branch (51abfca), `area/show` merged into `main` with `--no-ff` (02bff6f), `swift test` green on the merged tree, pushed, branch and worktree removed, task `shipped`. He went over the app himself that day and found it generally ok, with problems pausing and seeking to track down later (Needs Adam, Decisions). The last stage's checks on a screen and the system's accessibility audit are still owed; Adam lifted his pause on display tests on 2026-11-18, in the Area 14 session, and neither has been run yet. Edit mode's entries wait for Area 14, Open in Text Editor for Area 10, Settings… and Bind a Key… for Area 17, and Lock Station and the lock tag for Area 18: each is there and disabled. |
| 14 | Edit mode, minimal: the Cues page with the inspector and palette, stack editor, channel sheet, preset editor with text styles, small editors for grades, transitions, audio transitions and macros; the render and uses queries | `specs/11-edit-mode.md` | brief waiting for approval | Built whole on `area/edit` (240e41a, pushed; `swift test` green), the brief the final message of its session on 2026-11-25. Plan approved on 2026-11-18 with the bench-run gate lifted for this area (cabc1ab) and his four answers (stacks drawn at their output's size, rebuilt at a live switch; a box keeps its previous lines until the new raster is ready; a channel sounding on an audio output is on air); stops on 2026-11-21 (engine side, two three-hour soaks on his word), 2026-11-24 (the frame and the Cues page, built to his own drawing, G-1 to G-23) and 2026-11-24 to 25 (Stacks, Channels and Presets, each page laid out for its own work, G-30 to G-36, with the media-transition fault, the fade-in from empty and a box's transition as an override of the channel's, all on his word); the last stage built the Objects page's small editors (Spec 11 §9), the accessibility and strings of §10 with an audit of every page, and the app's own registration of the bundled fonts (§8). Owed before the merge: a green soak, since the frame path changed after the soaks of 2026-11-21, which waits on his decision on the command log's size; the bench's golden images against the Preset 1 change. |
| 15 | Macros, basic: command lists without guards, the clears tab | `specs/2-commands.md` | merged | Adam's `approved` on 2026-11-10 as built, with every reading in the brief; `area/macros` merged into `main` with `--no-ff` (8ae03ef), with its Spec 2 §3, §5, §6, §9 and Spec 1 §2 corrections (1894f17); `swift test` green on the merged tree, pushed, branch and worktree removed, task `shipped`. |
| 16 | Audio, basic: routing to numbered outputs, gain | `specs/4-render-pipeline.md` §11 | merged | Adam's `approved` on 2026-11-04 with every reading as built; `area/audio` merged into `main` with `--no-ff` (89641e9), branch and worktree removed, task `shipped`. The hardware path (a real device unplugged, a card) waits for the bench. |
| 17 | Settings: outputs, audio outputs, key bindings, media, startup and backup, the lock page, variables, tracking, thumbnails and engine, network, command bar | `specs/10-show-mode-ui.md` | not started | Spec 10 accepted 2026-11-08, its prompt block in `docs/build-order.md`, to start after Areas 13 and 14. Its `edit machine mediaRoot` refuses a root where media may not live with the check Area 8 built (`MediaPlaces`, on `main`; Adam's answer to Area 8's plan). Area 19 left it these: an edit of the campus name or the API port reaches Bonjour and the listener only at the next launch, a screen's mode change moves only the output's window (its render size and rate stay its `format`), and the Mach channel sends a stack's surfaces again through one entry point when its size changes. |
| 18 | Operator lock: passcode in the Keychain, edit mode blocked | `specs/10-show-mode-ui.md` | not started | Spec 10 accepted 2026-11-08, its prompt block in `docs/build-order.md`, to start after Area 17. Keeping the edit that turns the lock on off the undo stack (Spec 5 §8) is its work: Area 12's stack takes every applied edit. Area 19 keeps only the token's Keychain item, behind its seam (`SecretStore`), and answers `passcode`, `unlock`, `resetPasscode`, `token` and `newToken` with `notInV1` until then; `newToken` has to close every LAN connection. |
| 19 | Engine API and first run: the local socket and the LAN API, topics and queries, the preview channel, first run | `specs/10-show-mode-ui.md` §2, §3 and §13 | merged | Adam's `approved` on 2026-11-16 as built, with every reading in the brief and its recommended answers; the Spec 4 §12 and Spec 10 §13 corrections applied on the branch (6554d0c), `area/api` merged into `main` with `--no-ff` (73ab889), `swift test` green on the merged tree, pushed, branch and worktree removed, task `shipped`. After the merge Adam lifted his pause on runs that open outputs, and the last stage's checks ran on the external screen the same day: a relaunch after a real kill, a clean stop that isn't one, `--released`, the audio start on the real device with no watchdog event, and a one-minute smoke of the soak command with its own Mach client, which failed its GPU budget on a Mac that was busy (Housekeeping). The three-hour display-only soak that followed held its GPU budget throughout and had the soak's Mach client sent every preview and picture; what it failed is not Area 19's (Needs Adam). |
| v1.5 | After the pilot: runtime undo, library mode and local copies, NDI, live inputs, audio transitions, pre-flight report, optimize on import, macro guards and the scheduler, lookahead polish, distribution conventions | `docs/build-order.md` | not started | Specs wait until the pilot is scheduled. Each row has its own task in the Build tracker. |
| v2 | Slide designer, timelines and clocks, custom transitions, CCLI reporting | `docs/build-order.md` | not started | Deferred. |

## Now

**Area 7, output sinks, is in progress on `area/sinks` since 2026-11-22.** That day Adam
put a DeckLink SDI 4K (`decklink:154e100e`; 6G, so up to 2160p30, no 12G; 16 embedded
channels; free-running, nothing on its reference input) into the bench Mac, in the Sonnet
chassis, with its SDI output cabled straight into its own input, and asked for it to be
tested. A scratch probe (`.build/decklink-loop/` in the main checkout, uncommitted) drove
the output through the engine's own DeckLink wrapper and captured it on the input: at
1080p59.94, 1080i59.94, 1080p60 and 2160p29.97 every frame came back bit for bit, none
late, dropped, skipped, repeated or with a field from another frame, the capture exactly
one frame after the scheduled time, and the embedded audio bit for bit too (16 channels
at 4K), a constant 0.6 ms ahead of its frame. The card holds its last frame when nothing
new is queued, reads a queued frame almost at once (so the engine's three-buffer ring is
safe), and waits for the first frame when playback starts before any is queued. The test
found four faults in the sink, never run on a card before: an interlaced output's frames
are scheduled for two frame periods, so 1080i plays at half rate (shown on the loop);
embedded audio is timed on the card's hardware clock while the picture plays on its
stream clock, measured a frame apart after the engine's start; every stop the sink asks
for is logged as the card stopping; the card's mode rates are listed unreduced. Adam said
go on the plan the same day, with every recommendation: the faults fixed with tests, a
capture check (`oengine capture`, a frame stamp in the SDI picture under a test option, a
clapper and a bars still, `soak.sh --capture`), the bench machine root with output 1 on
the card at 1080p60 in place of the wall's display, short runs on the loop at 1080p60,
1080i60 and 2160p30, then a stop for review; the three-hour run with capture waits for a
window he sets.

**Paused the same day, while Adam moves the card's chassis; it resumes when he has
reconnected it.** Nothing was holding the card when it paused. On `area/sinks` (fb607d1,
pushed; `swift test` not yet run whole on the branch, the suites touched are green):

- *Fixed, with tests* (2216688): an interlaced frame scheduled for one frame of its rate,
  with stream times from the frame count so a long run can't drift; a stop the sink asks
  for no longer reported as the card stopping (checked on the card); a port's mode rates
  in lowest terms. Spec 4 §15 corrected first for the bench's 6G card (a97cbbf).
- *The capture check* (ed73de1, a701918, fb607d1): `--stamp-sdi` writes each field's tick
  into the first 16 pixels of its first line; `oengine capture` reads the card's input
  through new input functions in the DeckLink module and judges every frame, the fields
  and the clapper; `scripts/bench-machine.py` makes the bench machine root from the spike
  fixtures (output 1 on the card at 1080p60, audio embedded there); `soak.sh --capture`.
  Smoke-tested on the card against the probe: 600 frames in order, PASS. The bars still
  is not built yet.
- *The first run with capture* (ten minutes at 1080p60, both outputs, the record in the
  worktree's `.build/bench/p60/`): **A/V passed**, four claps with the click 3.3 to 10 ms
  after its flash, inside the 16.7 ms limit. This contradicted my reading before the run
  (picture 1–2 frames late), so the loopback's second fault, embedded audio timed on the
  card's hardware clock rather than its stream clock, is left as it is: changing it alone
  would put the sound ahead of the picture by the sink's lead. **Frame accuracy failed**:
  8 frames shown twice and 6 skipped, each a repeat paired with a skip; the engine itself
  counted 16 re-sent, 9 dropped and 6 late. The black box shows the render on time (tick
  6527 drawn, its GPU work under 5 ms) and the sink re-sending 6526 and going on to 6528.
  *Fault 5:* the sink re-sends the previous frame whenever the card has fewer than three
  queued and the next frame's GPU work hasn't finished at that instant, though the card
  still holds two. *Fault 6:* with the card as master clock the engine's ticks carry the
  card's own time, not the Mac's monotonic clock (Spec 4 §2), so the watchdog logged 1,863
  false "control thread built no plan for 955,179,132 ms" events (the Mac's uptime) and
  the display output's latency read the same; video frame choice is unaffected (it reads
  each audio device's own clock). The late text once a minute is `main`'s known fault,
  fixed on `area/edit`.
- *Next, when the card is back:* fault 5 (each frame once in tick order, waiting while the
  card has slack, re-sending only at its last queued frame; the ring's two newest frames,
  an uncommitted start in the worktree) and fault 6 (engine time on the Mac's clock, the
  card pacing the ticks and its own times used only for the card), tests first; then the
  1080p60 run again, 1080i60 and 2160p30, and the stop for review.

**Area 14, edit mode, is built and its brief waits for Adam's `approved`** (the final
message of its session, 2026-11-25). The code is on `area/edit` (240e41a, pushed;
`swift test` green on the dev Mac, hosted CI on that commit as the Status commit says);
nothing of it is on `main`. The last stage, after his "Go for Stage 4", built the Objects
page (Spec 11 §9): its list in groups (grades, transitions, audio transitions, text styles,
macros) with their + rows (none for Transitions),
each object's editor in a tall column with its number, label and Used by beside it, a
grade's sliders with their identity marked and the Preview showing the item through the
grade beside it without, the easing curve for a transition, the preset editor's style
form shared with the text styles and Re-apply to Boxes, and a macro's commands as rows
or as text, the palette with a Channels group, its scope, its tile and Run on Air. Then
§10: a test walks every page at 1440 by 900 under both pseudolanguages and found
unlabelled pickers and clipped names, fixed; the page lists take the arrows and ⌃Return;
each canvas box is a VoiceOver element with actions to move and resize it by 1% of the
stack. And §8's last line: the app registers the engine's bundled fonts for its own
process. Adam's try-out app is built from the branch
(`.claude/worktrees/area-edit/.build/xcode/Build/Products/Debug/Project O.app`, on his
roots in `~/Project O`).

What is built of edit mode: the frame to Adam's own drawing of 2026-11-22 (the cue grid,
the Browser, Preview over Program, the inspector), the ways in and out, the lock and the
keys; the Cues page with every control's edit; the Stacks, Channels, Presets and Objects
pages, each laying the window out for its own work. Not built: the Text page, which is
Area 10's. Nobody has listened to it with VoiceOver, and the system's accessibility audit
(a UI test under `xcodebuild`) is not run: the checks are `swift test`'s offscreen ones.
Adam has used every page himself on a screen. After his look at the Objects page on
2026-11-25 it was rebuilt on his word (Spec 11 §4 and §9 corrected first, G-37; 977e16c,
pushed, `swift test` and hosted CI green): each object in one column with its number and
label at the top, the rest of the workspace a stage that plays a transition between two
pool items, draws an audio transition's gains and a text style's sample, or holds a
macro's commands; short tags for what is wrong with a command; Add Command a browser over
a tree of the whole vocabulary, for cues and macros alike. The top bar's "Nothing live"
lost its hint the same day, on his word (Spec 10 §8; 69a7e8a). The try-out app is rebuilt.

The engine side was at its first stop on 2026-11-21. On Adam's word that day ("free to
do any testing for any amount of time") it ran on the real engine, a release build of
the branch, sound into BlackHole, the LAN off:

- **Two three-hour soaks** in the configuration of 2026-11-16 (both screens, both outputs
  1920 by 1080), each with the soak's new editing client making and removing a stack and a
  channel every minute and asking for a render. *The second* (20:26 to 23:26) held every
  display, GPU, text, audio and watchdog line: no frame dropped, late or presented again;
  GPU p99 5.88 ms against 8.33, the same in every half hour; no text late after the first
  minute, where `main`'s soak counted one line a minute; no audio underrun; two watchdog
  events of the known kind (the external screen presenting nothing for under fifty
  milliseconds) and no recovery; 180 of 180 edit groups applied, 180 of 180 pictures
  drawn, no build late, texture memory flat. It fails the two memory lines exactly as
  `main` did on 2026-11-16: heap live 78 to 87 MB, at the same 47 KB a minute, which is
  the in-memory command log still filling, and footprint less graphics 317 to 341 MB,
  mostly the purgeable zone rising to its 57 MB cap. *The first* (17:02 to 20:02) read
  the same except for GPU time: from 17:28:31 to 17:50:10 every tick's stack pass took
  12.8 ms, and the system log shows the Mac's remote-control client (ScreenConnect)
  capturing the screens for exactly those seconds; before and after, its GPU p99 was 6.0
  to 6.1 ms. The engine dropped no frame through it and let its previews give way.
- **A run with outputs of two sizes** (output 1 at 3840 by 2160, 21 minutes): the engine's
  log shows the confidence stack and its clock channel made again at each of the
  scenario's four stack switches, with no frame dropped, no build late and no text late.
  It fails GPU time at that size, p99 about 21 ms, and so does `main` on the same roots
  (about 20 ms, 15 ms of it the sink part): four runs back to back, two of each build,
  read alike. That is this iMac at that size and matters for the bench's LED wall, not
  for this branch.

The records are in `tests/soak-output/2026-11-21-170206`, `-202623` and `-112945`, with
the engine's own logs, the runs' output and the scripts kept, uncommitted, in the main
checkout's `.build/soak-2026-11-21/`. Still open before the merge: Adam's decision on the
in-memory command log, which is what the memory lines wait on (Needs Adam, Decisions).

Everything else is on `main`. Area 13, show-mode UI, shipped on 2026-11-18 (02bff6f), on
Adam's `approved`. He went over the app himself before approving, on his try-out roots,
and found it generally ok. He reported problems pausing and seeking, to be tracked down
later. Seeking is not in v1: the transport's bar shows position only (Spec 10 §7, choice
U-5). Pausing should work, and the engine's log of his try has every pause, play and stop
he pressed answered `ok`, so what went wrong came after the command and is not in the logs
(Needs Adam, Decisions).

Two things of Area 13's are still owed. Display tests were paused when it shipped
("still no display tests at this time", 2026-11-18); later that day, in the Area 14
session, Adam lifted the pause ("you're free to do any output tests you want"), read
there as: a run that opens outputs no longer waits for his go each time, the session
says first what it will open, and a soak still wants a window he sets. Neither check has
been run since. The last stage was never checked on a screen by a session: the drags and drops, the panels and sheets, the file
dialog, the tags' lists, the banner, and the keyboard's focus are proved by `swift test`
with the views laid out offscreen. And the system's accessibility audit of Spec 10 §18 is
not built: it is a UI test under `xcodebuild`, which takes the keyboard and the screen.

The bench run with the card stays deferred to a window Adam sets aside; it still gates
Areas 10, 17 and 18 and Area 7's bench verification. Still owed from before, with that
run's DeckLink and capture lines, are the two failures of the display-only soak of
2026-11-16: the confidence stack's clock draws nothing for one frame as each minute
changes, which Area 14 has fixed on its branch on Adam's answer of 2026-11-18 (03fa22a;
it stays owed until a soak counts no late text), and the engine's in-memory command log
is still filling at three hours (Needs Adam, Decisions). Both are owed before Area 7 and
the pilot.

## Needs Adam

### Briefs waiting for approval

- **Area 14, edit mode** (the final message of the Area 14 session, 2026-11-25; the code
  on `area/edit` at 240e41a). It asks for:
  - *The readings,* each with what was chosen and the alternative: G-8 to G-36 in Spec 11
    §14 on the branch, the readings from building the frame and the Cues page (below,
    under Decisions), the engine side's from its first stop's report, and the last
    stage's in the table below. Recommended: take them as built.
  - *A look at the Objects page,* which he hasn't seen: in the try-out app, or in the
    brief's description. Recommended: a try before `approved`, as with the other pages.
  - *The soak before the merge.* The frame path changed after the soaks of 2026-11-21
    (the media transitions, the fade-in from empty, a box's transition as an override), so
    a green soak is owed, in a window he sets. Its memory lines wait on his decision on
    the command log's size (Decisions). Recommended: keep far fewer lines in memory, then
    one three-hour soak of the branch.
  - *The bench's golden images* haven't been run against the Preset 1 change (its `*`
    boxes take the channel's transition). Recommended: with the bench run.
  - *Two faults of the engine's audio transitions, found building their preview* (on
    `main` since Area 16): the gains ramp in a straight line whatever the object's easing,
    and a negative offset is taken as none, so a J cut never delays the picture as the UX
    spec says. The preview draws what the object asks. Recommended: fix both, with a plan,
    in this area or as a follow-up.

### Decisions

- **Area 14's readings and findings from its stops,** answered with its brief.
  - *Readings from building it,* not yet in the spec: a command's Edit… opens it as one
    line of canonical text, where the palette's Add has forms with pickers; leaving edit
    mode waits for the engine's answer to an edit just sent, which is how a refused
    commit keeps it open, and a second try leaves; the on-air note is said for a cue
    among the three after the live cue while an output shows a stack that draws a box at
    +1 to +3, once for a selection; the engine pill has a third look, hollow and amber,
    while it is connected and an output isn't presenting or a badge stands; in the grade
    chip None is a value (grade 0) and Remove takes the chip away; a click on a playlist
    in the Browser opens it to its items without moving what show mode browses.
  - *Three faults found on `main`, fixed on the branch with tests.* A source or a texture
    could be freed while the plan the render thread was still using named it, when the
    control thread fell behind (c4bf560; the test shows it on the old rule). A gamma-blend
    stack's scratch texture was made on the render thread, at first use and at every
    change of size (7854878). A display sink presented its drawable even when the frame's
    stack texture was gone and nothing had been drawn (7854878). One thing is left as it
    was and flagged: the render thread takes a short lock to look a scratch texture up, as
    it has since Area 4.

- **Pausing and seeking in the app** (Adam's try of 2026-11-18, on `/tmp/o-try`). He had
  problems with both and said they can be tracked down later.
  - *Seeking* is not in v1: the Transport tab's bar shows position only, and
    `channel N seek` waits for v1.5 (Spec 10 §7, choice U-5). If the bar reads as
    something to drag, that is a look to fix; if seeking is wanted sooner, it is new
    vocabulary with projection and engine work, and a spec change first.
  - *Pausing* should work. The engine's command log of that try has his pause, play and
    stop presses on channel 1, each answered `ok`, so the app sent them and the engine
    took them; what he saw go wrong is after that and not in the logs. Tracking it down
    wants the screen: a session on his word, with him saying what he pressed and what he
    saw.

- **What Area 13 still owes on a screen.** Display tests were paused when it shipped and
  Adam lifted the pause later on 2026-11-18; neither has run yet. Each wants a session of
  its own.
  - *The last stage by hand:* a real drag onto a cue, a strip cell and the pool; the list
    of channels, the small panels and the sheets; Import… and Replace with… with their
    file dialog; Reveal in Finder; the tags' lists and the banner; Tab, ⌥ with the arrows,
    ⌥Return and ⌃Return; VoiceOver listened to.
  - *The system's accessibility audit* (Spec 10 §18): a UI test under `xcodebuild`, not
    built. It takes the keyboard, the mouse and the screen, and this Mac needs his two
    commands once (Housekeeping).

- **The display-only soak's failures** (2026-11-16 into 2026-11-17; the record is
  `tests/soak-output/2026-11-16-225637/`, with the engine's own logs kept, uncommitted, in
  `.build/soak-2026-11-16-engine-logs/`). Fixes are engine work, so each wants a plan and
  Adam's OK, as the soak fixes of 2026-11-02 did.
  - *Late text, once a minute.* One line is late on the tick each wall-clock minute changes,
    all through the run; the soak of 2026-11-02 counted none after its first minute. It is
    the `[Time]` box of the Clock preset on the confidence stack: when its value changes,
    the new text is rasterized only when it is first needed, so that tick the box draws
    nothing and the next tick it draws the new time (`SlotResolver.textBox`, as Spec 4 §9
    says of any missing cache entry). On a screen that is the clock missing for one frame a
    minute; read from the code and the count, not seen on a capture. A timer's box changes
    each second by the same path. Spec 4 §8 says a variable's new raster replaces the old
    and that late text should read zero, and not how the two meet. Answered by Adam on
    2026-11-18, with the Area 14 plan: the box keeps drawing its previous lines until the
    new raster is ready, for a variable's new value as for a look edit, and such a change
    counts nothing late. Area 14 built it and corrected Spec 4 §8 and §9 on its branch
    (03fa22a), and both soaks of 2026-11-21 on the branch counted no late text after the
    first minute; it reaches `main` with Area 14's merge. Which change since 2026-11-02
    brought it in was not found.
  - *Memory, both lines.* The heap's live bytes rose slowly all run, from 78 MB to 86 MB by
    the five-minute medians, and the footprint less graphics from 316 MB to 334 MB, each
    past §13's limit. The heap's rise is the command log the engine keeps in memory, its
    last ten thousand lines (`CommandLog`): the soak had logged about half of that when it
    ended, and a check afterwards, with no output window, filled it twice over and saw the
    heap rise while it filled and stand still once it was full. So it is bounded and not a
    leak, but at the soak's pace it fills for about six hours, and until then §13's rule
    fails by its letter. No spec sets that size and nothing in the engine reads the kept
    lines but the tests. Recommended: keep far fewer lines in memory, so the log is full
    within the first minutes and costs little; the alternative is a §13 rule that allows
    for it. The rest of the footprint's rise is the purgeable zone, which stopped growing
    partway through (below).

- **Where the media root may live, later.** Spec 8 keeps v1's media root on the startup
  volume, outside Desktop, Documents and Downloads (§2, M-8), because macOS asks an
  ad-hoc-signed engine again after every update before it reads an external drive, a
  share or those folders (ADR 0007). Adam asked on 2026-11-07 to look into the
  alternative later: a media root anywhere, with access granted again after each update,
  or kept once builds are signed. It belongs with ADR 0007's revisit when the pilot is
  scheduled. Area 8 built the check (`MediaPlaces`, on `main`) and Area 17 opens the edit.

- **When the bench run happens.** Deferred by Adam on 2026-11-03 ("later") to a window he
  sets aside: the bench machine root (a copy of `tests/fixtures/spike/machine/` with the
  main output at the LED wall's format, as a DeckLink output if the bench has 12G) and
  `scripts/soak.sh tests/soak/spike.json`. He can run it without a session; its record
  answers the DeckLink criteria of §15, sets the §13 median window, shows whether the
  purgeable zone caps and what the thumbnail job costs, checks the weave on the capture
  rig, and the embedded audio feed against the clapper. The bench machine root is copied
  again from the spike fixtures first (Spec 6 §2): Area 6 changed the stacks, and in an
  older copy stack 2's default preset is preset 2, now the Clock, so the confidence screen
  would show only the time. Since Area 8, `soak.sh` runs the spike on APFS clones of both
  roots with `libraryMode` writable (Adam's answer to Area 8's plan), so the launch walk
  lands each generated file on its fixed id; the bench run is the first end-to-end run of
  that script change. Since Area 12, an `oengine run` on that root also writes its
  logs, its hourly black box, its snapshots and `state/last.json` there; the soak keeps its
  own black box folder. Since Area 19 a display output opens only on the screen its device
  names, so `oengine soak` gives its display outputs the screens `--screens` names, or
  every screen of the Mac left to right; it holds the engine's Mach channel with a client
  of its own for the whole run, so the previews and the channel pictures are in the GPU
  time it judges, and fails the run when that client was sent nothing; and it reads the
  login keychain and opens the LAN listener unless `--no-lan` is given.

### The attended run

- A second attended memory run is wanted only if the bench record shows the purgeable zone
  not capping: about ten minutes of the engine under Instruments' Allocations (`xctrace`,
  the purgeable category by call stack), in a window Adam sets aside. The display-only soak
  of 2026-11-16 showed it capping on this Mac: it grew from 23 MB to 57 MB over the first
  hour and a half and stood at 57 MB for the rest. So no attended run is wanted unless the
  bench record differs. The quick external check stays on `main`:
  `scripts/soak-memory-sample.sh`, with `--minutes 1 --at "0.25 0.75"` for a smoke run.

### Housekeeping

- **The engine writes to the roots it runs on.** Since Area 9 it writes edits; since Area 8
  every launch also walks the media and writes the hash cache (`machine/media-cache.json`),
  pool tiles (`machine/thumbnails/pool/`) and, on a writable machine, posters (`.posters/`)
  and index changes. With Area 12 a launched engine also writes `machine/logs/`,
  `machine/blackbox/`, `machine/snapshots/` and `machine/state/last.json`, removes the
  snapshots and logs retention no longer keeps, and a list restore writes a kept version
  under `library/versions/`. With Area 19 it also keeps `machine/.engine.lock` and
  `machine/engine.sock`, and a launch on a root without `library.json` or `machine.json`
  writes the first-run documents there. Running `oengine` against
  `tests/fixtures/library-v1` therefore changes the fixture in the repository; the tests run
  on temporary copies (the harness refuses a media worker on `tests/fixtures/`), and the
  spike runs through `soak.sh` on clones.
- **`oengine run` reaches the Keychain and the network** (since Area 19). Unless
  `--no-lan` is given it reads its token from the login keychain, making a "Project O"
  item for the machine at the first launch, opens a WebSocket listener on the machine's
  `apiPort` and advertises `_projecto._tcp`. macOS may ask about the keychain item after an
  update, about the local network, or about incoming connections. Hands-on runs on the dev
  Mac pass `--no-lan`; the one run with the LAN on, on 2026-11-16 at Adam's word, saw no
  refusal and left no item behind.
- **Runs that open outputs** were paused on Adam's word on 2026-11-16 and allowed again by
  him later that day; paused again on 2026-11-18 as Area 13 shipped, and allowed again by
  him the same day in the Area 14 session. A soak still runs only on his word, in a window
  he sets aside.
- **One run's watchdog events, not seen again.** After the engine began opening its audio
  devices beside its first frames (609b609, on `main` since Area 19's merge), one hands-on
  run with sound into BlackHole counted watchdog events, with no recovery and its outputs
  and meters as they should be, and that run's log wasn't kept. Every run since has counted
  none: the next one that day, then, once the pause was lifted, the same check repeated on
  the external screen, the relaunch and `--released` runs, and a minute of the soak command.
  The three-hour soak logged a few one-off events of another kind, the external screen
  presenting nothing for just under fifty milliseconds, with no recovery, as the soak of
  2026-11-02 did. The first run's stays one unexplained occurrence.
  The hand-check scripts of the Area 19 session are kept, uncommitted, in the main
  checkout's `.build/area-api-scratch/` (`onscreen-audio.sh`, `onscreen-relaunch.sh`,
  `onscreen-released.sh`, `onscreen-soak-smoke.sh`).
- **GPU time on the dev Mac while it is in use.** On the evening of 2026-11-16 every
  on-screen run read a GPU time several times that morning's on the same scenario, near a
  whole tick at its worst, and so did runs with no window on a screen (`--released`). The
  frame path had not changed in between: since the morning's runs only a rule that draws
  less (no picture for sound alone) went in. The Mac was busy at the time, with a
  remote-control session capturing its screens and the window server working hard while no
  engine ran; that is the likely cause, and it was not separated out. Under it the engine
  did what Spec 4 §12 asks: every output frame was presented, none dropped or late, no
  watchdog event, no audio underrun, and the previews and channel pictures gave way, named
  less often than their thirty a second. The one-minute smoke of `oengine soak` failed on
  its GPU budget alone for this reason, on a debug build. The three-hour soak that started
  minutes later, a release build with both screens covered, read a GPU time well inside
  its budget in every half hour, so the frame path is sound; what made the evening's
  readings high was the Mac at that hour, and it was not separated out. A soak or a bench
  run still wants the Mac to itself, with no remote session on it. On 2026-11-21 that
  was separated out: a soak's stack pass read 12.8 ms on every tick for the twenty-two
  minutes a ScreenConnect session captured the screens, starting and ending within a
  second of it (`log show` with the predicate `process == "ScreenConnect" OR process ==
  "replayd"`), and under 1.2 ms before and after. The same day a passing memory warning
  from the system made the engine shrink its text cache, as Spec 4 §12 says, and a jump
  back to an old cue then counted late text; the run's `pressure:` and `text cache:`
  lines say when that happened.
- **How the display-only soak was run** (2026-11-16): `scripts/soak.sh` unchanged, with
  `--no-lan`, `--screens` naming both screens and `--machine` a copy of the spike machine
  root whose audio output names BlackHole, so the audio path ran and the room stayed
  silent; both outputs at the fixture's 1920 by 1080, not the LED wall's format. The script
  removes its clone of the roots at the end, and the engine's own logs with it, so a copy
  of `machine/logs` was taken every two minutes while it ran.
- **An app test that timed out once.** `ScriptedEngineTests`' test that sends events to
  every client waited its five seconds for a client that never connected, once, in one run
  of the app's tests on 2026-11-17. It passed in twelve reruns of its suites and in every
  full run since. Nothing was changed for it.
- **Adam's try-out of the app.** He launches it himself: the Xcode-built app in the main
  checkout's `.build/xcode` (`Build/Products/Debug/Project O.app`, built with
  `xcodebuild -project app/ProjectO.xcodeproj -scheme "Project O" -configuration Debug -derivedDataPath .build/xcode build`),
  on roots under `/tmp/o-try`, a copy of the fixture library
  with its output on the external screen, its second output's rate changed, and his own
  motion backgrounds, which are licensed and never in the repository. `/tmp` is emptied
  when the Mac restarts. While Area 14 waits, his app is the one built from `area/edit` in
  its worktree's `.build/xcode`, on his roots in `~/Project O`. A debug engine misses frames under his 1080p backgrounds, so the
  app carries the release engine and no performance reading is taken from a debug one.
- **UI tests on this Mac** need two commands only Adam can give, once:
  `sudo DevToolsSecurity -enable` and
  `sudo automationmodetool enable-automationmode-without-authentication`. They take the
  keyboard, the mouse and the screen, so they run only on his go.
- **A thumbnail test that timed out once.** `ThumbnailTests`' warm-the-live-list test waits
  for the thumbnail job on a real GPU; in one full local run during Area 12 it gave up
  before the job finished, and it passed on the next full run and alone. It didn't recur
  during Area 19. Worth watching on the bench; nothing was changed for it.
- **The real-Trash check.** `O_REAL_TRASH=1 swift test --filter MediaTrashTests` moves a
  few-byte file into the Trash and back; it passed on the dev Mac on 2026-11-14 from a
  process without Full Disk Access, and ordinary runs skip it. Worth rerunning by hand after
  a macOS update.
- **A bug outside Area 9:** `OEngineCommandLine.drive` passes `--library` where the machine
  root goes. To fix in a tooling session, as Adam's answer to the Area 9 brief took.
- **A bug outside Area 6:** renumbering a stack (`Identity` in `core/`) also moves every
  preset's layout for that stack number, where Spec 1 §4 says only machine-root references
  follow a stack and the edit warns about portable ones. Stack edits are `notInV1` on
  `main`, so nothing reaches it yet. Area 14 has fixed it on its branch (2d3c1b2), and it
  was wider than this: for a stack, output, audio output or input the same code also
  rewrote list cues, library macros and channels' `audioOutputs`, where Spec 5 §4 has only
  the machine root follow. It reaches `main` with Area 14's merge.
- **DM Sans on the dev and bench Mac.** It is installed there, as a variable font and as
  LCBC's static faces, so the engine uses the installed copy and logs the clash once at
  launch (T-7); the bundled copy draws where DM Sans isn't installed. The font tests inject
  the installed set, so they run alike everywhere.
- **The Build tracker mirrors `docs/build-order.md`** (5291cef, 2026-11-08): every task
  whose area has a block holds the common preamble and that block verbatim, with its
  dependencies from the block's "Starts after" line. Area 12's, Area 13's and Area 19's
  tasks are `shipped`, and Area 14's is `in progress` and carries its block as changed on
  2026-11-18, when its gate was lifted.
- **Interaction limit expires 2027-04-30** (16:00 UTC). Until then only collaborators can
  open issues and pull requests or comment on the public repository. Renew it before that
  date (Settings, Moderation options, Interaction limits: collaborators only, six months),
  or anyone with a GitHub account can open them.
- **Licence:** LCBC to choose before contributions open; set up a contributor agreement
  first.
- **The bench Mac is the only place the hardware tests run.** Since 962dd4b the hosted test
  step sets `O_HOSTED_RUNNER`, which makes the Metal and codec tests skip there with a
  visible message, because the runner's virtual GPU or VideoToolbox stalled some runs in a
  kernel call nothing could kill. Area 8's real-frame poster tests skip there too. Area
  19's Mach, socket and loopback WebSocket tests do run there; the runner is slower than the
  dev Mac, and tests of Area 19 that leaned on timing failed there until they were made to
  wait on what they were waiting for. A self-hosted runner on the bench Mac, without the
  variable, is what should run the goldens, the decode tests and the soak; until it exists,
  `swift test` on the bench by hand is the proof, as CLAUDE.md says. GitHub's macOS runner
  queue cancels a job after fifteen minutes of waiting when several pushes land together;
  `gh run rerun <id> --failed` is the remedy.
- **GitHub Actions billing** no longer blocks CI: on the public repository standard hosted
  runners are free. The ProductionLCBC account's payment problem (Settings, Billing and
  plans) matters again only if the repository goes private or a paid feature is wanted.
- **Tests that skip.** `EmbeddedAudioFeedTests`' unavailable-sink test skips wherever
  `vendor/DeckLinkSDK` is present ("a card may be present"), as in the main checkout and in
  a worktree with the SDK linked in; `MediaTrashTests`' real-Trash test skips everywhere
  unless `O_REAL_TRASH=1`.

### Spec interpretations made so far

Area 14's wait for Adam with its brief: G-8 to G-36 in Spec 11 §14 on the branch, the
readings under Decisions above, and the last stage's, marked "Area 14" at the top of the
table. The rest of the table is Area 13's, approved as built on 2026-11-18, with
the brief's recommended answers, and are recorded here and in its brief. "With the plan"
marks a reading Adam approved with the plan on 2026-11-17; "at stop 1", "at stop 2" and
"at stop 3" one he saw in that stop's report that day and took as chosen; and "new" one
from the last stage, first named in the brief. His own answers with the plan and at the
stops are in the brief and in `CHANGELOG.md`. Earlier areas' readings were approved with
their briefs and are in the specs' text, the briefs, or this page as it stood before:
Area 19's at 8a82ec6, approved on 2026-11-16; Area 12's at f60a952, approved on
2026-11-15; Area 8's at a8e741b, approved on 2026-11-14; Area 11's at 4096ede, approved
on 2026-11-11; Area 6's at a77bf69; Area 9's at f4b43ac; Area 15's on 2026-11-10, Area
16's on 2026-11-04, Area 5's on 2026-11-03, and Area 4's in 7032182.

| Spec | Left open | Chosen | Alternative |
| --- | --- | --- | --- |
| Spec 11 §9 with §2, the Objects page | Where "the right column" and Duplicate and Delete go, now that each page lays the frame out for its own work | The object's editor in one tall column of the workspace and its number, label and Used by beside it; Duplicate, Renumber… and Delete in each row's ⋯ menu, as on the other pages; no inspector under it (Area 14) | The shared parts in an inspector strip, or buttons in the column |
| Spec 11 §9, a grade's preview | Where it shows and where its item is picked | In the Preview monitor, the graded picture beside "Without it", the item picked in the monitor's header among the pool's videos and images that are there (Area 14) | In the workspace, with a picker under it |
| Spec 11 §9, a grade's ranges | How the shown values meet the stored ones; the largest blur | Brightness shows 1 + its stored value as a percentage (Spec 4 §7 multiplies by it), contrast, saturation and opacity their factor as one; blur 0 to 64 pixels, the blur pass's 32 taps a side at half resolution; a slider sends when let go, its field on Return; a clear tint shows white (Area 14) | — |
| Spec 11 §9, transitions' preview | Its form; an audio transition's | The easing curve in the Preview monitor with "Ease in over 0.5 s"; for an audio transition the same curve drawn from its offset, the trigger marked (Area 14) | No preview for audio transitions |
| Spec 11 §9, Re-apply to Boxes | Which boxes; when it asks | The boxes the catalog's presets have naming the style in `fromStyle`; it always says how many first, even one (Area 14) | The boxes from `uses`; ask only for several |
| Spec 11 §9 and Spec 10 §15, a macro's rows | A channel write's plain name, which Spec 10 §15's table hasn't | "Channel 2 shows “Welcome”", "Channel 1 shows dawn.mp4" (Area 14) | Its canonical text, as a cue's other commands show |
| Spec 11 §9, the Channels group | Its forms | Write Media…, Write Text…, Clear…, Reset…, Grade…, Transition…, Audio Transition… and Gain…, each a small form with the channel and its value, the durations in milliseconds, empty taking the object's own (Area 14) | Commands as text only |
| Spec 11 §9, Run on Air | "While something is live" | A playlist or a list live, as Next reads it; it also asks for a macro that holds an edit, saying so (Area 14) | An output presenting |
| Spec 11 §9, a new object | What it holds; which object opens | The engine's defaults for its type; it opens once the library event brings it (Area 14) | A copy of the selected one |
| Spec 11 §10, what doesn't fit under a longer language | How the page gives way | Names measured to their wording; a segmented control's type down to 10 points; a button wraps to its own line; a label that names a list's or a preset's title may truncate, with its whole text in the tooltip (Area 14) | Narrower type everywhere |
| Spec 11 §10, the arrows in a page's list | Which list they walk | The Objects page's groups as one list; on the Presets page the list last clicked (Area 14) | Each group alone |
| Spec 11 §10, a canvas box's actions | Their names and steps | Move Left, Right, Up and Down, Wider, Narrower, Taller and Shorter, each by 1% of the stack and sent as one frame edit; an overflowing box also says how many lines were cut (Area 14) | — |
| Spec 11 §10, Reduce Motion | What edit mode animates | Nothing: the grid scrolls and the canvas snaps without animation, so there is nothing to drop (Area 14) | — |
| Spec 11 §8, fonts in the app | Where the app finds them; a face already installed | In the engine's resource bundle inside the app; a face the Mac already has counts as registered (Area 14) | — |
| Spec 10 §10, Quit with a field open | A field whose text can't be saved | It stays open with its reason and the quit waits (with the plan) | Quit and lose it |
| Spec 10 §2, the console log | How many of its last lines the app shows | Twenty, read from the file's tail (at stop 1) | — |
| Spec 10 §1, the roots | What the app makes at first run | `machine/` and `machine/logs/`, so the console log can be opened, and nothing else (at stop 1) | The engine makes them |
| Spec 10 §2, the lock file's process id | Whether it is trusted before a kill | The app first checks the id still names an `oengine`, since the file outlives its engine (at stop 1) | Kill by the id |
| Spec 10 §2, "no `hello`" | How long a socket that is there may stay silent | Five seconds, as for a ping (at stop 1) | Fifteen |
| Spec 10 §2, a late pong | Whether it clears "isn't responding" | Yes (at stop 1) | Only a restart does |
| Spec 10 §2, another build | What is compared | The two versions, since `hello` names a version only (at stop 1) | A build number |
| Spec 10 §3, lists held whole | Which | Those of what the grid browses and of what is live (at stop 1) | Every list |
| Spec 10 §2, the Mach channel | When it counts as failed | When the lookup or the connect fails, tried again every five seconds; no staleness timer, since under pressure the engine stops sending frames by design (at stop 1) | A timer |
| Spec 10 §2, the curtains | Which screens | One per display output whose screen is there and isn't the window's; none on a screen released with ⌃⌥⌘⎋ (at stop 1) | Every output screen |
| Spec 3 §7 and Spec 10 §6, the chips | A channel the cue doesn't touch; a clear of a channel this list hasn't written | Held; a clear, since content holds across lists (at stop 2) | No chip; redundant |
| Spec 10 §6, section names | How a name finds its hue | Without case, spaces, hyphens or a number after it: "Verse 2" and "verse" are one section (at stop 2) | Exact names |
| Spec 10 §6 and §8, the countdown | Its rounding and form | Up, so it never reads 0:00 before it is over; under a minute a sentence says seconds, from a minute on a clock (at stop 2) | Down |
| Spec 10 §5 and §6, the searches | What matches | Case and accents ignored, anywhere in the text; a CCLI number from its first digit (at stop 2) | Whole words |
| Spec 10 §4, at a connection | What the grid shows | What is live, else the last thing browsed when the catalog still has it; a grid that shows something stays (at stop 2; read from `view.json` since the last stage) | Nothing |
| Spec 10 §7, the why-line | `previous` before the first cue | "Start of the playlist" (at stop 2) | Nothing said |
| Spec 10 §7, the clears tiles | A tile with no targets; a tile that only fires | Unlit and disabled; never lit (at stop 2) | — |
| Spec 10 §7, the strip's selection | A channel the view no longer shows | It drops out, so Clear Selected never clears what can't be seen (at stop 2) | Kept |
| Spec 10 §7, the 0.3 seconds | Entering another cell | The wait starts again (at stop 2) | One wait for the strip |
| Spec 1 §3 and Spec 10 §5, order | "By title" | As the Finder orders: case ignored, numbers by value; playlists of one date by time, then title (at stop 2) | Byte order |
| Spec 10 §6, the trigger | A cue with a time and an advance | Shows both (at stop 2) | The time alone |
| Spec 10 §4, the window off an output's screen | Several free screens | The largest (at stop 2) | The first |
| Spec 10 §8, "Audio lost" | Which outputs | One a channel routes to that has gone silent; an embedded output nothing feeds says nothing (at stop 2) | Any silent output |
| Spec 10 §8, the remote dot | How long it is lit | Two seconds after each arrival (at stop 2) | One |
| Spec 10 §6, the pool's folders | What a folder shows; the search | What is in it and below it; the search sets the folder aside (at stop 2) | The folder alone |
| Spec 10 §8, the time of day | Its format | The system's short one (at stop 2) | 24-hour |
| Spec 10 §5 and §6, Show in Library | Whether it browses | No: it opens the folders on the way and marks the row (at stop 2) | Browse the list |
| Spec 10 §7, the go-to and timer fields | What they take; Return in a duration | Digits only; the grammar's durations; Return is Set (at stop 2) | — |
| Spec 10 §9, a key's name | Its spelling | One: lower case, the modifiers in the spec's order, each once (at stop 3) | Any order |
| Spec 10 §9, reserved keys | Which chords | The ten and no others; the same key under another modifier can be bound (at stop 3) | The keys under any modifier |
| Spec 10 §9, digits then Return | The source of `cue N` | `key` (at stop 3) | `ui` |
| Spec 10 §9, the digits' three seconds | Another key in between | It fires its binding and leaves the digits and their time as they were (at stop 3) | It clears them |
| Spec 10 §9 and §15, plain names | A command the table has no sentence for | Its canonical text: forms with a duration, a rider or a guard, edits and media commands (at stop 3; the names good as written, Adam's answer) | A shorter sentence |
| Spec 10 §9, ⌃⌥⌘⎋ the system didn't give | What is said | The overlay says it works only while the app is active (at stop 3) | Nothing |
| Spec 10 §9, the window raised | Until when | Until a `releaseScreen` is answered `ok`, by this engine or the next (at stop 3) | Two seconds |
| Spec 10 §9, the command bar | Its history; a refusal | Fifty lines in memory, gone at quit; the engine's own sentence as it came (at stop 3) | On disk; the app's sentence |
| Spec 10 §9, keys with no name | The ISO key beside left Shift, a JIS keyboard's own, the keypad's Clear | They can't be bound (at stop 3) | More names |
| Spec 10 §9, Caps Lock and Fn; a first press | Whether they count | Left out of a key's name; the first press is the one the system doesn't mark a repeat (at stop 3) | — |
| Spec 10 §9, the keys overlay | The show keys under it | They keep firing (at stop 3) | Held |
| Spec 10 §9, the keypad's Enter | What it is | Return, for a sheet's default button and for digits (at stop 3) | A key of its own |
| Spec 10 §10, a rename's click outside | Commit or discard | It commits, as in-place text does; an empty or unchanged name sends nothing and closes (new) | Discards |
| Spec 10 §5, Duplicate… and Date and Time… | The panels | An empty title field; a date and a time picker, each with a "None" tick (new) | The old title; text fields |
| Spec 10 §5, ⇧⌘N's "selected folder" | Which | The folder of the library list the grid browses, since the tree has no selection (new) | Always the top |
| Spec 10 §5, Make Live on the live playlist | Once a cue has fired | Disabled, since it would put the pointer back before cue 1 (new) | Allowed |
| Spec 10 §5, dragging an item | Into another playlist | No: it moves within its own (new) | Moves across |
| Spec 10 §5 and §6, a drop that can't be done | Whether it may be let go | Yes, and the region says why nothing happened (new) | The pointer refuses it |
| Spec 10 §10, what a cue says on a channel | Two content commands on one channel; "writes content" | The last is read; a `channel.write` (new) | The first |
| Spec 10 §10, Undo's title and the messages | Several changes; how long a message stands | "Undo Rename (3 changes, from OSC)"; three seconds for an undo's, five for a refusal's, in the top bar's centre or the region tried (new) | Three for all |
| Spec 10 §15, lists in sentences | The formatter's region | The Mac's (new) | English |
| Spec 10 §14, the versions sheet | During the question | It closes first; the question names the version whole (new) | It stays up |
| Spec 10 §14, Set Timers Again | "Its last value" | The last one received, not carried forward by the time since; offered once (new) | Counted on |
| Spec 10 §6, a dropped file's kind | Before the engine has opened it | By its name's extension; one that suggests nothing asks for a channel (new) | Always ask |
| Spec 10 §7, "a write or a clear has reached the channel" | How the app tells | The channel's kind of content, or what put it there, differs; a refire of the same cue isn't told apart (new) | A count from the engine |
| Spec 10 §6, the copy's progress | What shows | "Copying…" with no fraction, since a clone is instant; then the import's fraction (new) | A fraction |
| Spec 10 §6, the header's imports | How many show, and for how long | Three, one when collapsed, refusals first, with how many more; one that ended well leaves after five seconds, a refusal stays until dismissed (new) | All of them |
| Spec 10 §6 and §7, a missing or deleted item | On a cue or a cell | Refused, as its Fire to is disabled (new) | Written, and shows missing |
| Spec 10 §6, several files under the lock | Which reason is said | The lock, not "drop them on the pool" (new) | The pool |
| Spec 10 §6, Defaults… | "Each an edit" | The fields that changed go as one group, so one Undo takes the Save back (new) | A request each |
| Spec 8 §3, the staging copy | Two files of one name; a file inside a root | Each drop in a folder of its own under Staging; a file inside the roots or the media root is imported where it lies (new) | One flat folder |
| Spec 10 §6, the file dialog | What it offers | Video, stills and sound, and folders for Import… (new) | Any file |
| Spec 10 §10, Delete… with no `mediaUse` answer | What happens | Nothing is asked and nothing deleted (new) | Ask without the counts |
| Spec 10 §7, "showing the live red ... meanwhile" | From when | From the moment the drag is over the cell; let go before 0.3 seconds, nothing is sent; a refused drop is taken at once, since all it does is say why (new) | Red only once it would take |
| Spec 10 §10, the popover of channels | Its form | A list: a click chooses, the arrows move the pick, Return takes the picked one and waits when none is (new) | A menu |
| Spec 10 §6, the header's second line | Details and messages | The selected item's details under the controls, hidden while collapsed; a message takes the line while it stands (new) | In the controls' row |
| Spec 10 §6, tile size | The sizes; the collapsed strip | Three; the strip stays at the middle one (new) | A slider |
| Spec 10 §4, `view.json` | A key that doesn't read; the panel's "state and height" | That key keeps its default and the rest are taken; the state is the height, since the divider snaps (new) | The whole file dropped; a height |
| Spec 10 §4 and §13, `view.json` at first run | Whether it is written | Not until `machine.json` is there (new) | At once |
| Spec 10 §4, the window's frame | When the saved one is taken | When the middle of its title bar is on a screen the Mac has now, and never smaller than the window may be (new) | Always |
| Spec 10 §4, Reset Layout | What stays | The window's frame, recent media, the last thing browsed and the dismissed run (new) | Everything resets |
| Spec 10 §3, the notes | When; their text | `browse` when the grid shows another thing, `backToLive` when it was browsing; a line of English for the log (new) | Every click |
| Spec 10 §14, the saving tag | Several states; the five seconds | One tag, the worst first: full, then waiting, then low; counted on the app's clock from when the count rose (new) | A tag each |
| Spec 10 §14, the banner's timers | What it says | Nothing when the app saw the engine end with none set; "came back unset" alone when it didn't see it end; the button when it saw some (new) | Always the sentence |
| Spec 10 §14, Fire … again | When it is offered | Whenever nothing was put back and the app saw a cue live before the engine ended; once (new) | Only after a relaunch |
| Spec 10 §14, a snapshot's refusal | Its words | The app's sentence for the code, then the engine's own, which name the objects (new) | The app's alone |
| Spec 10 §14, after a snapshot restore; Take Snapshot | What is said | The sheet stays and says "Restored. Undo puts it back."; "Snapshot taken." for three seconds (new) | The sheet closes |
| Spec 10 §8, the tags | Which are buttons | Popup, engine and saving, drawn as tags; the audio tags are words; the popup tag opens the panel when it was folded (new) | All of them |
| Spec 10 §15, a live change's source | Where it comes from | The pointer command the `commands` topic sends ahead of the `live` event of the same tick (new) | A field on `live`, which is engine work |
| Spec 10 §15, the sources' words | Each | The app's keys and command bar say the cue alone; `scheduler`, `cue`, `timeline` and `engine` say "Auto"; the rest "From …" (new) | — |
| Spec 10 §15, at a connection | Whether what is live is announced | No (new) | Yes |
| Spec 10 §15, the keyboard's focus | Where it lives; ⌥↑ and ⌥↓ | In the region, by what the item is, since cells are drawn again on every event; to the nearest item in the row above or below (new) | In each cell |
| Spec 10 §15, ⌥Return | On a tile, a channel's cell, a list header | Selects the tile; selects that channel alone; nothing, since a header has only its menu (new) | Fires the tile |
| Spec 10 §15, Increase Contrast and Reduce Motion | How much; what else moves | Outlines half as heavy again; the flashes and the remote dot were steady already, so only the transition bar changes (new) | — |
| Spec 10 §15, the strip's meters | Left out how | They are no accessibility elements at all (new) | Unlabelled elements |
| Spec 10 §9 and §10, a panel the system closes | The keys afterwards | The panel is forgotten and the keys are the window's again; panels hang from the window, not from a cell (new; a fault of the stage's own, fixed) | — |

### Spec corrections proposed

None. Area 14's corrections were each made on its branch first, on Adam's word at its
stops (Spec 4 §5, §6, §7, §8 and §9, Spec 5, Spec 9 §6, Spec 11 §2, §4 and §14, and with G-36
Specs 1, 3, 6 and 10), so none waits. Area 13's proposals were accepted and applied on the branch before the merge (51abfca):
Spec 10 §14 says a click on the saving tag lists how many documents wait, how the disk
stands and whether the log is in memory; §15 says the drags with no menu entry are reached
through their commands, and that the live cue is told by its outline; §18 says the two
pseudolanguages are the app's own transforms under `swift test` and the system's audit a UI
test under `xcodebuild`. Spec 10 §2, §4, §5 and §6 were corrected earlier on the branch from
his answers at the stops (70ce361, 8fa5340, a73e9ce, dc2859e).

## Next

**Area 10 — Text editor** (branch `area/text`) is next, once Area 14 is merged: the text
editor is edit mode's Text page and joins its frame and Cues page, which wait on `area/edit`
for Adam's `approved`. It still waits for the bench run too (below). It runs in its own
session from the common preamble in `docs/build-order.md` and its own block there,
verbatim:

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
Area: 10, text editor. Spec: docs/specs/11-edit-mode.md §5, with §13's Area 10 tests,
and §1, §2 and §10 for the rules every page follows, the frame and accessibility; Spec 5
§4 and §5 for the channel edit, groups and typing, Spec 3 §3 and §7 for tracking and the
cue view, and Spec 10 §6, §9 and §15 for the app's fold of a list, the keys and
accessibility, all as Spec 11 corrected them. Starts after Area 14 is merged: the text
editor is edit mode's Text page and joins its frame and Cues page. On main: Spec 5's
edit path with typing folded a second at a time (Area 9), the app's fold of a list from
its top and the scripted engine (Area 13), and edit mode's frame and Cues page (Area
14). Build the document first: a chunk per cue on the chosen channel, in each state a
cue can leave it, with the sections in the margin and the thumbnails; then typing (whole
bodies at most four times a second and once on leaving, composed text held back, an
emptied chunk sent as a clear that keeps its track riders, typing into held text as a
copy of the held write, the three chunks after the live cue sent only on leaving),
selection within a chunk, and other clients' changes. Then breaks: split, merge and
moved breaks as Spec 5 §5's groups, with the questions a merge asks. Then paste: breaks
at blank lines and section lines, repeats, SongSelect's footer, a paste into an empty
list or into a chunk, the question a long paste with no breaks asks, and Paste as
Two-Line Cues. Last, undo as the library's while the last change is the editor's own,
the keys, and Open in Text Editor in the list menus. Tests first from §13, against the
fixture library's lists and the lyric sheets §11 names. Stop for review after typing,
after breaks, and after paste.
```

**After Area 14:**

- **What Area 13 hands the next areas**, on `main`: the app as
  targets of the root package (`OApp` with no AppKit, `OAppUI`, `OAppScripted`) behind the
  Xcode shell in `app/`; the store and the models fed by Spec 10 §3's topics and queries;
  the one mapper from actions and edits to commands; the scripted engine the tests drive;
  the string catalog and its script; and the ways into the later areas, each there and
  disabled until its area turns it on: Edit and Edit Cue (Area 14), Open in Text Editor
  (Area 10), Settings… and Bind a Key… (Area 17), Lock Station and the lock tag (Area 18).
- **The app's areas.** 14 waits for Adam's `approved`; 10 follows 14, 17 follows 13 and
  14, and 18 follows 17, each still after the bench run as its block says. Area 7 resumes
  on `area/sinks` in its own session when the card is reconnected.
- **The bench run with the card** happens whenever Adam sets a window, with the bench
  machine root copied again from the spike fixtures first. It must pass before Areas 10,
  17 and 18 start and before Area 7's bench verification, and its DeckLink and capture
  lines are owed before the pilot.
- **Spec 5 has no area of its own.** Its engine side landed with Area 9 (the edit path, the
  writer and changes on disk), Area 8 (the media edits and the defaults edits) and Area 12
  (edit undo and redo, and the restores), all on `main`.
