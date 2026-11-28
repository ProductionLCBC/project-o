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
| 4 | Engine spike (`engine/`): headless OEngine over OSC, two channels, two stacks, three hours clean | `specs/4-render-pipeline.md` §15 | merged | Adam's `approved` on 2026-10-31; `area/spike` merged (e735052); the soak fixes (2074bd6) and the §13 memory breakdown (87011b2) merged on his `approved`. Every display-side criterion of §15 held at the soak of 2026-11-02; the DeckLink criteria wait for the bench run with a card, which Adam has deferred to a window he sets aside. The display-only soak of 2026-11-16, the first of everything merged since, holds the display, GPU, audio and watchdog lines and fails late text and the two memory lines, both fixed on `main` since Area 14. |
| 5 | Render pipeline, the rest: 1080i weave, text cache, thumbnails, multiviewer, measurement | `specs/4-render-pipeline.md` | merged | Adam's `approved` on 2026-11-03 with every recommendation taken; Spec 4 §2, §10, §13, Spec 2 §6 and Spec 1 §5 corrected (e8e1e3f); `area/render` merged into `main` with `--no-ff` (5b3f6ed), branch and worktree removed, task `shipped`. The weave's capture-rig check (§16) joins the bench run. |
| 6 | Stacks and presets: slots, boxes, text styles, resolution order, blackout and mute, offset +1 | `specs/6-presets-and-text.md` | merged | Adam's `approved` on 2026-11-11 as built, with every reading in the brief and its recommended answers; the Spec 3 §6 correction and ADR 0008's acceptance on the branch (85b4e88), `area/presets` merged into `main` with `--no-ff` (af3c948), `swift test` green on the merged tree, pushed, branch and worktree removed, task `shipped`. Spec 1 §2's `weight` went into Area 11's block. |
| 7 | Output sinks: display per screen, DeckLink with weave, output transitions | `specs/4-render-pipeline.md` §10 | in progress | In progress on `area/sinks` since 2026-11-22, as bench verification and fixes (Adam's answer of 2026-11-04). That day a DeckLink SDI 4K went into the bench Mac with its SDI output cabled to its input, and a loopback test passed in every mode tried; its block in `docs/build-order.md` was written from that test and Adam said go the same day, taking every recommendation (Now). **Paused on 2026-11-22** while Adam moves the card's chassis; it resumes when he has reconnected it. On the branch (fb607d1, pushed): three of the loopback's faults fixed with tests, the frame stamp, `oengine capture`, the bench machine root and `soak.sh --capture`. The first ten-minute run with capture, at 1080p60, passed A/V and failed frame accuracy, and found a fifth and a sixth fault in the engine, not yet fixed (Now). The sinks, the encode pass and the switch and blackout mixes are on `main` since Area 4, the weave since Area 5, the embedded audio feed since Area 16. |
| 8 | Media pool: hash IDs, index, import by copy, poster frames, missing state | `specs/8-media-pool.md` | merged | Adam's `approved` on 2026-11-14 as built, with every reading in the brief and its recommended answers, and no spec correction proposed; `area/media` merged into `main` with `--no-ff` (2c1b3d6), `swift test` green on the merged tree, pushed, branch and worktree removed, task `shipped`. |
| 9 | Cues, lists and playlists: write/clear/hold, Go and Time triggers, sections, linked items, live pointer, next | `specs/7-cues-lists-and-playlists.md` | merged | Adam's `approved` on 2026-11-10 as built, with every reading in the brief and its recommended answers; `area/playlists` merged into `main` with `--no-ff` (af2209e), with its Spec 1 §4, §5 and Spec 5 §2, §4 corrections (e538f2b); `swift test` green on the merged tree, pushed, branch and worktree removed, task `shipped`. The gaps it named are accepted: a folder operation that fails on disk is only logged, and Area 12 takes the kept copies when it restores the last state. |
| 10 | Text editor: whole-list text document with cue breaks | `specs/11-edit-mode.md` | in progress | In progress on `area/text` since 2026-11-28. Adam approved the plan that day with six answers: the bench-run gate lifted for this area (c290bc4); the list's and the cue's fields in a tall column beside the document, with no inspector on the Text page; a SongSelect sheet's title line dropped with its footer; a break moved from the keyboard too, by Edit ▸ Move Line to Previous Cue and Next Cue (⌥⌘↑, ⌥⌘↓); the three chunks after the live cue holding back their typing only while an output shows a box at +1 to +3; and `main`'s status commits pushed this session. The spec corrections those took are on the branch (55ef461, G-46 to G-49). Stopped for review after typing (4112d6b), which Adam found ok on 2026-11-28 and said go for breaks. **Stopped for review after breaks** (abfb0e2, pushed; `swift test` green, 2437 tests; CI green): split, merge with its question, moved breaks by drag and by Move Line to Previous and Next Cue, each one group. Paste and the rest wait for Adam's word. |
| 11 | Variables: Time, Date, Timer and Popup slots, captions over OSC | `specs/6-presets-and-text.md` | merged | Adam's `approved` on 2026-11-11 as built, with every reading in the brief and its recommended answers, and no spec correction proposed; `area/variables` merged into `main` with `--no-ff` (d4333fa), `swift test` green on the merged tree, pushed, branch and worktree removed, task `shipped`. |
| 12 | Log and saving: command log with sources, continuous save, launch snapshots | `specs/9-log-and-saving.md` | merged | Adam's `approved` on 2026-11-15 as built, with every reading in the brief and its recommended answers; the Spec 9 §6 and §10 correction applied on the branch (7dbdf7d), `area/saving` merged into `main` with `--no-ff` (327454f), `swift test` green on the merged tree, pushed, branch and worktree removed, task `shipped`. |
| 13 | Show-mode UI (`app/`): three columns, grid, strip, preview and multiviewer, tabs, top bar, keyboard | `specs/10-show-mode-ui.md` | merged | Adam's `approved` on 2026-11-18 as built, with every reading in the brief and its recommended answers; the Spec 10 §14, §15 and §18 corrections applied on the branch (51abfca), `area/show` merged into `main` with `--no-ff` (02bff6f), `swift test` green on the merged tree, pushed, branch and worktree removed, task `shipped`. He went over the app himself that day and found it generally ok, with problems pausing and seeking to track down later (Needs Adam, Decisions). The last stage's checks on a screen and the system's accessibility audit are still owed; Adam lifted his pause on display tests on 2026-11-18, in the Area 14 session, and neither has been run yet. Edit mode's entries are on since Area 14; Open in Text Editor waits for Area 10, Settings… and Bind a Key… for Area 17, and Lock Station and the lock tag for Area 18: each is there and disabled. |
| 14 | Edit mode, minimal: the Cues page with the inspector and palette, stack editor, channel sheet, preset editor with text styles, small editors for grades, transitions, audio transitions and macros; the render and uses queries | `specs/11-edit-mode.md` | merged | Adam's `approved` on 2026-11-28, with a twenty-minute soak of ef279ac accepted in place of a green three-hour run; every spec correction (G-8 to G-45, Specs 3, 4 and 9, American spelling) went on the branch before its code; `area/edit` merged into `main` with `--no-ff` (a08c5d2), `swift test` green on the merged tree, pushed, branch and worktree removed, task `shipped`. |
| 15 | Macros, basic: command lists without guards, the clears tab | `specs/2-commands.md` | merged | Adam's `approved` on 2026-11-10 as built, with every reading in the brief; `area/macros` merged into `main` with `--no-ff` (8ae03ef), with its Spec 2 §3, §5, §6, §9 and Spec 1 §2 corrections (1894f17); `swift test` green on the merged tree, pushed, branch and worktree removed, task `shipped`. |
| 16 | Audio, basic: routing to numbered outputs, gain | `specs/4-render-pipeline.md` §11 | merged | Adam's `approved` on 2026-11-04 with every reading as built; `area/audio` merged into `main` with `--no-ff` (89641e9), branch and worktree removed, task `shipped`. The hardware path (a real device unplugged, a card) waits for the bench. |
| 17 | Settings: outputs, audio outputs, key bindings, media, startup and backup, the lock page, variables, tracking, thumbnails and engine, network, command bar | `specs/10-show-mode-ui.md` | not started | Spec 10 accepted 2026-11-08, its prompt block in `docs/build-order.md`, to start after Areas 13 and 14, both merged; it still waits for the bench run. Its `edit machine mediaRoot` refuses a root where media may not live with the check Area 8 built (`MediaPlaces`, on `main`; Adam's answer to Area 8's plan). Area 19 left it these: an edit of the campus name or the API port reaches Bonjour and the listener only at the next launch, a screen's mode change moves only the output's window (its render size and rate stay its `format`), and the Mach channel sends a stack's surfaces again through one entry point when its size changes. |
| 18 | Operator lock: passcode in the Keychain, edit mode blocked | `specs/10-show-mode-ui.md` | not started | Spec 10 accepted 2026-11-08, its prompt block in `docs/build-order.md`, to start after Area 17. Keeping the edit that turns the lock on off the undo stack (Spec 5 §8) is its work: Area 12's stack takes every applied edit. Area 19 keeps only the token's Keychain item, behind its seam (`SecretStore`), and answers `passcode`, `unlock`, `resetPasscode`, `token` and `newToken` with `notInV1` until then; `newToken` has to close every LAN connection. |
| 19 | Engine API and first run: the local socket and the LAN API, topics and queries, the preview channel, first run | `specs/10-show-mode-ui.md` §2, §3 and §13 | merged | Adam's `approved` on 2026-11-16 as built, with every reading in the brief and its recommended answers; the Spec 4 §12 and Spec 10 §13 corrections applied on the branch (6554d0c), `area/api` merged into `main` with `--no-ff` (73ab889), `swift test` green on the merged tree, pushed, branch and worktree removed, task `shipped`. After the merge Adam lifted his pause on runs that open outputs, and the last stage's checks ran on the external screen the same day: a relaunch after a real kill, a clean stop that isn't one, `--released`, the audio start on the real device with no watchdog event, and a one-minute smoke of the soak command with its own Mach client, which failed its GPU budget on a Mac that was busy (Housekeeping). The three-hour display-only soak that followed held its GPU budget throughout and had the soak's Mach client sent every preview and picture; what it failed is not Area 19's, and is fixed on `main` since Area 14. |
| v1.5 | After the pilot: runtime undo, library mode and local copies, NDI, live inputs, audio transitions, pre-flight report, optimize on import, macro guards and the scheduler, lookahead polish, distribution conventions | `docs/build-order.md` | not started | Specs wait until the pilot is scheduled. Each row has its own task in the Build tracker. |
| v2 | Slide designer, timelines and clocks, custom transitions, CCLI reporting | `docs/build-order.md` | not started | Deferred. |

## Now

**Area 10, the text editor, is in progress on `area/text`** since 2026-11-28. Adam approved
its plan that day and lifted the bench-run gate for it, on his word and with the date, in
each place the gate is written (Spec 4 §15, Spec 11 §11, `docs/build-order.md`,
`app/README.md`; c290bc4). **It stopped for review after breaks**, the second of its block's
three stops, at abfb0e2 on `area/text` (pushed; `swift test` green, 2437 tests with the two
known skips; CI green on both jobs). At the first stop, after typing (4112d6b), Adam found
the page ok and said go for breaks, saying he was unsure how breaks would work until he saw
them. On the branch: Spec 11 corrected on his answers (G-46 to G-49); the Text page in edit
mode's frame, enabled in the page picker and ⌥⌘2, with the document, its channel picker and
the fields column; typing sent as Spec 5 §5 folds it; other clients' changes; a fix to the
app's cue-thumbnail cache, which kept every version it read; and breaks: ⌥Return splits,
Backspace and forward Delete at a chunk's edges merge (asking first when the second cue does
more), and a break moves by dragging its rule or by Edit ▸ Move Line to Previous and Next
Cue, each one group the engine undoes in one step. His try-out app is built from the branch
in the worktree's `.build/xcode`. Paste is next, on his word. Nothing is in review.

**Area 14, edit mode, shipped on 2026-11-28** (a08c5d2, on `main` and pushed), on Adam's
`approved` with the twenty-minute soak of ef279ac accepted in place of a green three-hour
run. Edit mode is on `main` whole but for the Text page, which is Area 10's: the frame and
its ways in and out, the cue grid with its Tracking switch, the Stacks, Channels, Presets
and Objects pages, the media chooser, the `render` and `uses` queries, and the engine's
edits. With it reached `main`: the late text once a minute fixed (Spec 4 §8 and §9), the
engine keeping 500 command-log lines in memory (Spec 9 §2), audio fades that follow their
easing, J and L cuts, and audio loops that open their next reader ahead (Spec 4 §11).
The three-hour soak of 3df85af failed GPU time and footprint only in the nineteen minutes
after a ScreenConnect screen capture, with no frame dropped or late, and one minute of
audio underruns since fixed; the twenty-minute soak of ef279ac passed every Spec 4 §13
line. The runs' records are in the main checkout's `tests/soak-output/` and
`.build/area-edit-scratch/`. **Area 7, output sinks, is paused on `area/sinks`** (fb607d1)
since 2026-11-22, while Adam moves the card's chassis: three of the loopback's faults are
fixed with tests and the capture check is built; faults 5 and 6 and the runs at 1080p60,
1080i60 and 2160p30 wait for the card. Adam's try-out app is rebuilt from `main` in the
main checkout's `.build/xcode`.

## Needs Adam

### Briefs waiting for approval

None. Area 14's was answered with `approved` on 2026-11-28.

### Decisions

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
  own black box folder. Adam lifted the gate for Areas 13, 14 and 10 on his word (Area 10's
  on 2026-11-28); Areas 17 and 18 wait on it by their blocks. Since Area 19 a display output opens only on the screen its device
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
  lines say when that happened. On 2026-11-27 ScreenConnect was seen taking a ten-second
  capture every twenty minutes with nobody connected; one began nineteen minutes of slow
  stack passes and about 12 MB more footprint, with no frame dropped or late. Adam can't
  quit it and wants the engine to cope (2026-11-28), so a soak's GPU and footprint lines are
  read against `log show`'s capture times (`replayd`, `hasStarted=1`).
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
  when the Mac restarts. Since Area 14's merge his app is built from `main` in the main
  checkout's `.build/xcode`, on his roots in `~/Project O`. A debug engine misses frames under his 1080p backgrounds, so the
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
- **A bug outside Area 6, fixed:** renumbering a stack (`Identity` in `core/`) also moves every
  preset's layout for that stack number, where Spec 1 §4 says only machine-root references
  follow a stack and the edit warns about portable ones. Stack edits are `notInV1` on
  `main` until Area 14. Area 14 fixed it (2d3c1b2, on `main` since its merge), and it was
  wider than this: for a stack, output, audio output or input the same code also rewrote
  list cues, library macros and channels' `audioOutputs`, where Spec 5 §4 has only the
  machine root follow.
- **DM Sans on the dev and bench Mac.** It is installed there, as a variable font and as
  LCBC's static faces, so the engine uses the installed copy and logs the clash once at
  launch (T-7); the bundled copy draws where DM Sans isn't installed. The font tests inject
  the installed set, so they run alike everywhere.
- **The Build tracker mirrors `docs/build-order.md`** (5291cef, 2026-11-08): every task
  whose area has a block holds the common preamble and that block verbatim, with its
  dependencies from the block's "Starts after" line. Area 14's task is `shipped` since
  2026-11-28, with the merge commit linked; Areas 7 and 10 are `in progress`.
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

None wait for Adam. Area 14's were answered with its `approved` on 2026-11-28: G-8 to G-45
in Spec 11 §14, the readings from its stops and its last stage, and Area 13's, approved
on 2026-11-18, are on this page as it stood at 6fb5205. Those of the Area 14 session's
last rounds, reported as they came and approved with the merge, are below. Earlier
areas' readings were approved with their briefs and are in the specs' text, the briefs,
or this page as it stood before: Area 19's at 8a82ec6, Area 12's at f60a952, Area 8's at
a8e741b, Area 11's at 4096ede, Area 6's at a77bf69, Area 9's at f4b43ac, Area 15's on
2026-11-10, Area 16's on 2026-11-04, Area 5's on 2026-11-03, and Area 4's in 7032182.

| Spec | Left open | Chosen | Alternative |
| --- | --- | --- | --- |
| Spec 11 §9 (G-43), a grade's video on the stage | How fast it plays | As fast as the thumbnail job draws its two pictures, at most fifteen frames a second at the job's thirty a second (Area 14, approved 2026-11-28) | A playing stage let past the job's pace |
| Spec 11 §4 (G-45), a `once` value's lane | What follows its block | An outlined block and a dashed line to the channel's next content write, where it falls back, since a clear before then still uses it (Area 14, approved 2026-11-28) | No line |
| Spec 11 §4 (G-45), which attributes get a lane | `chase`, which Spec 3 §2 reserves | Transition, audio transition, grade and gain only (Area 14, approved 2026-11-28) | A lane for chase too |
| Spec 4 §11, a J cut | Whether the offset needs sound; onto an empty channel | Only when the outgoing or incoming item has sound (Adam's choice in the plan); the picture's transition still waits the offset when the channel showed nothing (Area 14, approved 2026-11-28) | Always; no delay onto an empty channel |
| Spec 4 §13, naming underruns | How often the engine looks | Every half second, each channel's missed samples with the item and the device, said once (Area 14, approved 2026-11-28) | Each burst as it happens, from the audio thread |

### Spec corrections proposed

None. Area 14's corrections were each made on its branch before the code they govern, on
Adam's word: Spec 11 (G-8 to G-45), Spec 4 §5 to §11, Spec 3 §4, Spec 5, Spec 9 §2 and §6,
and with G-36 Specs 1, 3, 6 and 10; and every spec in American spelling (672f688).

## Next

**Area 10 — Text editor** (branch `area/text`) is in progress; the bench-run gate was
lifted for it on Adam's word, 2026-11-28, and Area 14, whose frame and Cues page it joins,
is merged. It runs in its own session from the common preamble in `docs/build-order.md`
and its own block there, verbatim:

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

- **What Area 14 hands Area 10**, on `main`: edit mode's frame with the Text page in its
  page picker, disabled, and Open in Text Editor in the list menus, disabled; the cue grid
  and the app's fold of a list; the edit path with typing folded a second at a time.
- **The app's areas.** 10 follows 14 and is in progress, the gate lifted for it; 17 follows
  13 and 14; 18 follows 17; 17 and 18 wait for the bench run as their blocks say. Area 7
  resumes on `area/sinks` in its own session when the card is reconnected.
- **The bench run with the card** happens whenever Adam sets a window, with the bench
  machine root copied again from the spike fixtures first. It must pass before Areas 17
  and 18 start, unless he lifts the gate for one, and before Area 7's bench verification;
  its DeckLink and capture lines are owed before the pilot.
- **Spec 5 has no area of its own.** Its engine side landed with Area 9 (the edit path, the
  writer and changes on disk), Area 8 (the media edits and the defaults edits), Area 12
  (edit undo and redo, and the restores) and Area 14 (the edits of the library's and the
  machine's objects), all on `main`.
