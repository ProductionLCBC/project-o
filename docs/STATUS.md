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
| 7 | Output sinks: display per screen, DeckLink with weave, output transitions | `specs/4-render-pipeline.md` §10 | not started | After the bench run, and folded into it on Adam's answer of 2026-11-04: the area becomes bench verification and fixes, its block written from the run's findings. The sinks, the encode pass and the switch and blackout mixes are on `main` since Area 4, the weave since Area 5, the embedded audio feed since Area 16. |
| 8 | Media pool: hash IDs, index, import by copy, poster frames, missing state | `specs/8-media-pool.md` | merged | Adam's `approved` on 2026-11-14 as built, with every reading in the brief and its recommended answers, and no spec correction proposed; `area/media` merged into `main` with `--no-ff` (2c1b3d6), `swift test` green on the merged tree, pushed, branch and worktree removed, task `shipped`. |
| 9 | Cues, lists and playlists: write/clear/hold, Go and Time triggers, sections, linked items, live pointer, next | `specs/7-cues-lists-and-playlists.md` | merged | Adam's `approved` on 2026-11-10 as built, with every reading in the brief and its recommended answers; `area/playlists` merged into `main` with `--no-ff` (af2209e), with its Spec 1 §4, §5 and Spec 5 §2, §4 corrections (e538f2b); `swift test` green on the merged tree, pushed, branch and worktree removed, task `shipped`. The gaps it named are accepted: a folder operation that fails on disk is only logged, and Area 12 takes the kept copies when it restores the last state. |
| 10 | Text editor: whole-list text document with cue breaks | `specs/11-edit-mode.md` | not started | Spec 11 accepted 2026-11-08, its prompt block in `docs/build-order.md`, to start after Area 14, whose frame and Cues page it joins. |
| 11 | Variables: Time, Date, Timer and Popup slots, captions over OSC | `specs/6-presets-and-text.md` | merged | Adam's `approved` on 2026-11-11 as built, with every reading in the brief and its recommended answers, and no spec correction proposed; `area/variables` merged into `main` with `--no-ff` (d4333fa), `swift test` green on the merged tree, pushed, branch and worktree removed, task `shipped`. |
| 12 | Log and saving: command log with sources, continuous save, launch snapshots | `specs/9-log-and-saving.md` | merged | Adam's `approved` on 2026-11-15 as built, with every reading in the brief and its recommended answers; the Spec 9 §6 and §10 correction applied on the branch (7dbdf7d), `area/saving` merged into `main` with `--no-ff` (327454f), `swift test` green on the merged tree, pushed, branch and worktree removed, task `shipped`. |
| 13 | Show-mode UI (`app/`): three columns, grid, strip, preview and multiviewer, tabs, top bar, keyboard | `specs/10-show-mode-ui.md` | brief waiting for approval | Brief written 2026-11-18, the final message of the Area 13 session; code on `area/show` (a506438, pushed), `swift test` green there, and the app builds and signs under `xcodebuild` with the release engine inside it. Built in stages with the stops its block names, each of which Adam saw and answered on 2026-11-17: the engine connection with the first-run sheet (Spec 10 §2, §3, §13); the window and its regions (§4 to §8), approved as drawn and tried by him against a real engine; the keys (§9); and then, with no further stop, the edits of §10 with Undo and Redo, the drags, the drops of pool tiles and of the Finder's files (U-8), the pool's imports and tile menu, `view.json`, the notes, §14's tags, banner and sheets, and §15's announcements, keyboard focus, contrast and motion. Spec 10 §2, §4, §5 and §6 are corrected on the branch from his answers at the stops. His answers with the plan stand: Area 13 builds §13's app side, the first-run sheet and the first window's line (its block and Spec 10 §16 say so); the app's code is targets of the root package under `app/`, with the Xcode project a thin shell, so `swift test` stays the one gate; three changes outside `app/` are allowed, none changing what the engine does (the Mach client moved into a small module, `OMach`; the cue-view fold with the chip states in OCore, which the thumbnail job then calls; the key-name grammar in OCore); the look is proposed, clean, modern and dark, since the clickable demo isn't in the repository; the restart rule counts a sliding two minutes, with exit status 4 retried and status 2 stopping at the first-run sheet; a list whose number another shares has its edits disabled as well as its firing; and the drags get no menu items, since their commands exist for a key binding. The last stage was built on his word of 2026-11-18 that nothing run on a screen that day, so it is proved offscreen only, and the system's accessibility audit is not built (Needs Adam). Edit mode's entries wait for Area 14, Open in Text Editor for Area 10, Settings… and Bind a Key… for Area 17, and Lock Station and the lock tag for Area 18: each is there and disabled. The bench-run gate was lifted for this area alone (Spec 4 §15 says so since 2026-11-17); the DeckLink and capture lines, and the late-text and memory lines the soak of 2026-11-16 failed, are still owed before Area 7 and the pilot. |
| 14 | Edit mode, minimal: the Cues page with the inspector and palette, stack editor, channel sheet, preset editor with text styles, small editors for grades, transitions, audio transitions and macros; the render and uses queries | `specs/11-edit-mode.md` | not started | Spec 11 accepted 2026-11-08, its prompt block in `docs/build-order.md`, to start after Area 13, and so after the bench run. Its macro edits refuse a cycle or a nest past the cap with the one check Area 15 built (`MacroCalls`, on `main`); its edits extend the editor Area 9 built, and its slot and preset edits (Spec 5 §3 and §6, `notInV1` until then) meet Area 6's rules: one slot per channel, and the warning that counts boxes at offset 0. Since 2026-11-15 its block also has it rebuild the channel list between ticks, which lifts the `notInV1` Area 12's snapshot restore answers for a snapshot with another channel list. Area 19's Mach channel has the entry points it calls when it rebuilds the channel list: the surfaces sent again, and a removed channel named. |
| 15 | Macros, basic: command lists without guards, the clears tab | `specs/2-commands.md` | merged | Adam's `approved` on 2026-11-10 as built, with every reading in the brief; `area/macros` merged into `main` with `--no-ff` (8ae03ef), with its Spec 2 §3, §5, §6, §9 and Spec 1 §2 corrections (1894f17); `swift test` green on the merged tree, pushed, branch and worktree removed, task `shipped`. |
| 16 | Audio, basic: routing to numbered outputs, gain | `specs/4-render-pipeline.md` §11 | merged | Adam's `approved` on 2026-11-04 with every reading as built; `area/audio` merged into `main` with `--no-ff` (89641e9), branch and worktree removed, task `shipped`. The hardware path (a real device unplugged, a card) waits for the bench. |
| 17 | Settings: outputs, audio outputs, key bindings, media, startup and backup, the lock page, variables, tracking, thumbnails and engine, network, command bar | `specs/10-show-mode-ui.md` | not started | Spec 10 accepted 2026-11-08, its prompt block in `docs/build-order.md`, to start after Areas 13 and 14. Its `edit machine mediaRoot` refuses a root where media may not live with the check Area 8 built (`MediaPlaces`, on `main`; Adam's answer to Area 8's plan). Area 19 left it these: an edit of the campus name or the API port reaches Bonjour and the listener only at the next launch, a screen's mode change moves only the output's window (its render size and rate stay its `format`), and the Mach channel sends a stack's surfaces again through one entry point when its size changes. |
| 18 | Operator lock: passcode in the Keychain, edit mode blocked | `specs/10-show-mode-ui.md` | not started | Spec 10 accepted 2026-11-08, its prompt block in `docs/build-order.md`, to start after Area 17. Keeping the edit that turns the lock on off the undo stack (Spec 5 §8) is its work: Area 12's stack takes every applied edit. Area 19 keeps only the token's Keychain item, behind its seam (`SecretStore`), and answers `passcode`, `unlock`, `resetPasscode`, `token` and `newToken` with `notInV1` until then; `newToken` has to close every LAN connection. |
| 19 | Engine API and first run: the local socket and the LAN API, topics and queries, the preview channel, first run | `specs/10-show-mode-ui.md` §2, §3 and §13 | merged | Adam's `approved` on 2026-11-16 as built, with every reading in the brief and its recommended answers; the Spec 4 §12 and Spec 10 §13 corrections applied on the branch (6554d0c), `area/api` merged into `main` with `--no-ff` (73ab889), `swift test` green on the merged tree, pushed, branch and worktree removed, task `shipped`. After the merge Adam lifted his pause on runs that open outputs, and the last stage's checks ran on the external screen the same day: a relaunch after a real kill, a clean stop that isn't one, `--released`, the audio start on the real device with no watchdog event, and a one-minute smoke of the soak command with its own Mach client, which failed its GPU budget on a Mac that was busy (Housekeeping). The three-hour display-only soak that followed held its GPU budget throughout and had the soak's Mach client sent every preview and picture; what it failed is not Area 19's (Needs Adam). |
| v1.5 | After the pilot: runtime undo, library mode and local copies, NDI, live inputs, audio transitions, pre-flight report, optimize on import, macro guards and the scheduler, lookahead polish, distribution conventions | `docs/build-order.md` | not started | Specs wait until the pilot is scheduled. Each row has its own task in the Build tracker. |
| v2 | Slide designer, timelines and clocks, custom transitions, CCLI reporting | `docs/build-order.md` | not started | Deferred. |

## Now

**Area 13, show-mode UI, is built and its brief waits for Adam's `approved`** (the final
message of the Area 13 session, 2026-11-18). The code is on `area/show` (a506438, pushed);
`swift test` is green there, the hosted runner passed the commits before it, and the app
builds and signs under `xcodebuild` on this Mac with the release engine inside it. Nothing
of it is on `main` but the status documents and the gate's record.

It was built in four stages. The first three each ended at a stop Adam saw and answered
on 2026-11-17: the engine connection with the first-run sheet (Spec 10 §2, §3, §13); the
window and its regions (§4 to §8), which he approved as drawn and then tried himself
against a real engine under `/tmp/o-try`, twice, the second time writing "looking good
overall now"; and the keys (§9), where he took the readings as chosen and answered that a
press made while the engine isn't responding is dropped and the controls show disabled
with the reason. Spec 10 §2, §4, §5 and §6 are corrected on the branch from those answers.

The fourth stage ran without a stop, as the block has it, on 2026-11-18: the edits of §5,
§6 and §10 with their menus, fields in place, small panels, questions before a delete or
a restore, rejection sentences, and Undo and Redo named from the history; the drags of
the trees and the grid; a pool tile on a cue through the list of channels, and on a strip
cell after its 0.3 seconds; the Finder's files on a cue, a cell and the pool, staged,
imported and only then written (U-8), with what isn't sent said on the cell; the pool's
header with its imports, tile size and details, and a tile's menu; `machine/view.json`,
read at launch and written a second after the last change; the notes `browse` and
`backToLive`; §14's saving tag, engine tag, last-state banner and snapshots sheet beside
the versions sheet; and §15's announcements, keyboard focus in the trees, the grid, the
pool and the strip, Increase Contrast and Reduce Motion. One fault of the stage's own
early work was found and fixed on the way: a small panel the system closed by itself was
never forgotten, so the keys stayed with it.

Adam's word that day was that nothing run on a screen or an output, so all of the fourth
stage is proved by `swift test` alone, with the views laid out offscreen: no drag was made
with a pointer, no popover, sheet or file dialog was seen, VoiceOver was not listened to,
and Tab was not pressed in a real window. The system's accessibility audit, which the plan
put under `xcodebuild`, is not built: it needs a UI-test run, which takes the keyboard and
the screen and two commands only Adam can give. Both are in the brief as his to decide.

Everything else is on `main`. Area 19, engine API and first run, shipped on 2026-11-16
(73ab889). A display-only soak then ran on Adam's word and failed three lines: three hours
of `scripts/soak.sh` on `main`, both screens, no DeckLink, the first soak since 2026-11-02
and so the first of Areas 5, 6, 8, 9, 11, 12, 15, 16 and 19. It held every display line,
the GPU and CPU budgets, audio with no underrun and the watchdog with no recovery, and
failed late text and the two memory lines, each with a known cause: the confidence stack's
clock draws nothing for one frame as each minute changes, and the engine's in-memory
command log is still filling at three hours. Both want an engine fix or a spec answer from
Adam (Needs Adam, Decisions), and both are still owed, with the bench run's DeckLink and
capture lines, before Area 7 and the pilot. The bench run stays deferred to a window Adam
sets aside; it still gates Areas 14, 10, 17 and 18 and Area 7's bench verification.

## Needs Adam

### Briefs waiting for approval

- **Area 13, show-mode UI.** The brief is the final message of the Area 13 session
  (2026-11-18); the code is on `area/show` (a506438). It asks for:
  - *`approved`, or changes.* Recommended: try the last stage by hand first (next item),
    then approve as built with the readings marked "new" below.
  - *A hands-on try of the last stage.* Nothing of it has been on a screen: the drags and
    drops, the list of channels, the panels and sheets, Import… and Replace with… with
    their file dialog, Reveal in Finder, the tags' lists, the banner, and the keyboard's
    focus with Tab, ⌥ and the arrows, ⌥Return and ⌃Return. The app is rebuilt at a506438
    with the release engine (`.claude/worktrees/area-show/.build/xcode/Build/Products/Debug/Project O.app`);
    the try-out roots under `/tmp/o-try` are gone if the Mac restarted since, and are a
    few commands to make again. Recommended: before `approved`.
  - *The system's accessibility audit* (Spec 10 §18). Not built: it is a UI test under
    `xcodebuild`, which takes the keyboard, the mouse and the screen, and this Mac needs
    `sudo DevToolsSecurity -enable` and
    `sudo automationmodetool enable-automationmode-without-authentication` once.
    Recommended: a short session of its own after the merge, on his go; the labels, the
    spoken states, the focus and the clipping are held by `swift test` meanwhile.
  - *Drags that have no menu entry.* Reordering a playlist's items, moving a list or a
    folder, and a pool tile onto a cue are reached without the mouse only through the
    command bar, since his answer with the plan gave the drags no menu items. Spec 10 §15
    says every action is reachable without the mouse. Recommended: keep it so for v1 and
    say so in §15 (corrections, below); the alternative is Move Up, Move Down, Move to
    Folder ▸ and Write into Cue… in the menus.
  - *The spec corrections proposed below*, to be applied on the branch before the merge,
    as Area 19's were. Recommended: each of them.
  - *A soak before the merge.* The branch changes nothing in what the engine draws: the
    Mach client moved into its own module, the thumbnail job calls the cue-view fold that
    now lives in OCore, and the key-name grammar is new there. Recommended: none for the
    merge; the next soak he sets aside is the first of this code.
  - *Pushing `main`.* The status commit of this wrap-up is not pushed.

### Decisions

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
    and that late text should read zero, and not how the two meet. Recommended: the box
    keeps drawing its previous lines until the new raster is ready, the rule §9 already has
    for an edit, and such a change counts nothing late; the alternative is to rasterize a
    clock's next value a second ahead. Which change since 2026-11-02 brought it in was not
    found.
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
  him later that day. A soak still runs only on his word, in a window he sets aside.
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
  run still wants the Mac to itself, with no remote session on it.
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
- **Adam's try-out of the app.** He launches it himself: the Xcode-built app in the Area 13
  worktree's `.build/xcode`, on roots under `/tmp/o-try`, a copy of the fixture library
  with its output on the external screen, its second output's rate changed, and his own
  motion backgrounds, which are licensed and never in the repository. `/tmp` is emptied
  when the Mac restarts. A debug engine misses frames under his 1080p backgrounds, so the
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
  follow a stack and the edit warns about portable ones. Stack edits are `notInV1`, so
  nothing reaches it yet; it wants a fix in `core/` before Area 14 opens them, or a
  renumbered stack 2 carries Preset 1's confidence layout with it.
- **DM Sans on the dev and bench Mac.** It is installed there, as a variable font and as
  LCBC's static faces, so the engine uses the installed copy and logs the clash once at
  launch (T-7); the bundled copy draws where DM Sans isn't installed. The font tests inject
  the installed set, so they run alike everywhere.
- **The Build tracker mirrors `docs/build-order.md`** (5291cef, 2026-11-08): every task
  whose area has a block holds the common preamble and that block verbatim, with its
  dependencies from the block's "Starts after" line. Area 12's and Area 19's tasks are
  `shipped`, Area 13's is `in review`, and Area 14's carries its block as changed on
  2026-11-15.
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

Area 13's readings, below, wait for the brief's answer. "With the plan" marks a reading
Adam approved with the plan on 2026-11-17; "at stop 1", "at stop 2" and "at stop 3" one he
saw in that stop's report that day and took as chosen; and "new" one from the last stage,
first named in the brief. His own answers with the plan and at the stops are in row 13 and
in Now. Earlier areas' readings were approved with their briefs and are in the specs'
text, the briefs, or this page as it stood before: Area 19's at 8a82ec6, approved on
2026-11-16; Area 12's at f60a952, approved on 2026-11-15; Area 8's at a8e741b, approved on
2026-11-14; Area 11's at 4096ede, approved on 2026-11-11; Area 6's at a77bf69; Area 9's at
f4b43ac; Area 15's on 2026-11-10, Area 16's on 2026-11-04, Area 5's on 2026-11-03, and
Area 4's in 7032182.

| Spec | Left open | Chosen | Alternative |
| --- | --- | --- | --- |
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

From Area 13's brief, none applied yet: a spec changes only on Adam's word. (Spec 10 §2,
§4, §5 and §6 were corrected on the branch from his answers at the stops, 70ce361, 8fa5340,
a73e9ce and dc2859e, and reach `main` with the merge.)

- **Spec 10 §15, the live cue.** §15 still says "the live cue has a border and a "Live"
  tag"; §5 and §6 say, since his answer at stop 1, a red outline with no tag, and that is
  what is built. Fix: §15 says "the live cue has an outline of a weight nothing else in
  the grid has".
- **Spec 10 §14, the saving tag.** It says "A click lists what is waiting"; the `saving`
  topic counts the documents and names none (Spec 9 §7), so the click lists how many
  wait, how the disk stands and where the log goes, with Reveal in Finder. Fix: §14 says
  that; the alternative is engine work, the topic naming each document.
- **Spec 10 §15, keyboard navigation.** It says "Every action is reachable without the
  mouse"; reordering a playlist's items, moving a list or a folder and a pool tile onto a
  cue have no menu entry (Adam's answer with the plan), so without the mouse they are
  typed in the command bar. Fix: §15 names them as reached through their commands.
- **Spec 10 §18, accessibility and strings.** It asks for "the accented pseudolanguage and
  one 40% longer" and for the system's audit on every region. Xcode has no 40% one and
  macOS's audit has no clipping check, so both pseudolanguages are transforms of the
  app's own at the string lookup, under `swift test`; the audit is a UI test under
  `xcodebuild`, not built yet. Fix: §18 says where each runs.

## Next

**Area 14 — Edit mode** (branch `area/edit`) is next. It starts after Area 13 is merged,
and so after the bench run with the card, which Adam has deferred to a window he sets
aside; the gate was lifted for Area 13 alone. It runs in its own session from the common
preamble in `docs/build-order.md` and its own block there, verbatim:

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
Area: 14, edit mode. Spec: docs/specs/11-edit-mode.md §1–§4 and §6–§11, with §13's Area
14 tests; the UX spec (docs/ux-spec.md) and the clickable demo's cue inspector for look
and feel where the spec is silent, asking before guessing; Spec 5 §2 and §4–§6 for the
edits, when they show, their checks and inverses, Spec 6 §2–§4 for stacks, presets and
text styles, Spec 4 §10 for the thumbnail job, and Spec 10 §2–§4, §9, §10 and §15 for
the app it joins, all as Spec 11 corrected them. Starts after Area 13 is merged, and so
after the bench run. On main: Spec 5's edit path with the list, cue, folder and playlist
edits and the move by position (Area 9), the thumbnail job that draws a cue's projected
state with the normal stack pass (Area 5), the API's queries with their answer shape
(Area 19), and the app's window, models and scripted engine (Area 13). Build the engine
side first: the edits Spec 7 §7 gives this area (channels, stacks, presets, text styles,
grades, transitions and macros), with those of audio transitions and of an output's
default stack and transitions, their checks, warnings and inverses, a macro's move
between the roots, stack edits between ticks, a box's move by position, and the channel
list rebuilt between ticks when a channel is added, removed or resized, which lifts the
notInV1 Area 12's snapshot restore answers for a snapshot with another channel list
(Spec 9 §6, Adam's answer of 2026-11-14); then the
render query on the thumbnail job's queue, with its canvases, files and errors, on the
local socket only, and the uses query over both roots (§3). Then the app: the frame with
the edit bar, the ways in and out, the lock and the keys (§2), turning on the ways in
that Area 13 left disabled (Spec 10 §16); the Cues page with the filmstrip, Fire, the
canvas, the channel rows and their chips, the inspector, the palette, commands as text
and multi-cue editing (§4); the stack editor (§6); the channel sheet (§7); the preset
editor with its canvas, sample, boxes and text styles (§8); and the small editors (§9),
with VoiceOver and the string catalog as §10 says. Open in Text Editor stays disabled
until Area 10. Tests first from §13. Stop for review after the engine side, after the
frame and the Cues page, and after the preset editor.
```

**Area 14 and after:**

- **What Area 13 hands the next areas**, on `area/show` until the merge: the app as
  targets of the root package (`OApp` with no AppKit, `OAppUI`, `OAppScripted`) behind the
  Xcode shell in `app/`; the store and the models fed by Spec 10 §3's topics and queries;
  the one mapper from actions and edits to commands; the scripted engine the tests drive;
  the string catalog and its script; and the ways into the later areas, each there and
  disabled until its area turns it on: Edit and Edit Cue (Area 14), Open in Text Editor
  (Area 10), Settings… and Bind a Key… (Area 17), Lock Station and the lock tag (Area 18).
- **The app's areas.** 14 follows 13, 10 follows 14, 17 follows 13 and 14, and 18 follows
  17, each still after the bench run as its block says.
- **The bench run with the card** happens whenever Adam sets a window, with the bench
  machine root copied again from the spike fixtures first. It must pass before Areas 14,
  10, 17 and 18 start and before Area 7's bench verification, and its DeckLink and capture
  lines are owed before the pilot.
- **Spec 5 has no area of its own.** Its engine side landed with Area 9 (the edit path, the
  writer and changes on disk), Area 8 (the media edits and the defaults edits) and Area 12
  (edit undo and redo, and the restores), all on `main`.
