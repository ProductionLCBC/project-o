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
| 13 | Show-mode UI (`app/`): three columns, grid, strip, preview and multiviewer, tabs, top bar, keyboard | `specs/10-show-mode-ui.md` | not started | Spec 10 accepted 2026-11-08, its prompt block in `docs/build-order.md`, to start once the spike passes on the bench; Area 19, which it also waited for, is merged. The clears tab's tiles send the commands Area 15's tests prove (Spec 10 §7), the app maps keys to commands sent with source `key` (§9), the pool tab and the staging copy for drops build on Area 8's import, topic and queries, and the restore sheets, Undo and Redo and the saving badge read what Area 12 publishes (the two queries, the `history` and `saving` topics). The engine side it talks to is on `main` since Area 19: the local socket, §3's topics, queries and requests, the Mach channel with the previews, the channel pictures and the meters, first run, and the relaunch rule. |
| 14 | Edit mode, minimal: the Cues page with the inspector and palette, stack editor, channel sheet, preset editor with text styles, small editors for grades, transitions, audio transitions and macros; the render and uses queries | `specs/11-edit-mode.md` | not started | Spec 11 accepted 2026-11-08, its prompt block in `docs/build-order.md`, to start after Area 13, and so after the bench run. Its macro edits refuse a cycle or a nest past the cap with the one check Area 15 built (`MacroCalls`, on `main`); its edits extend the editor Area 9 built, and its slot and preset edits (Spec 5 §3 and §6, `notInV1` until then) meet Area 6's rules: one slot per channel, and the warning that counts boxes at offset 0. Since 2026-11-15 its block also has it rebuild the channel list between ticks, which lifts the `notInV1` Area 12's snapshot restore answers for a snapshot with another channel list. Area 19's Mach channel has the entry points it calls when it rebuilds the channel list: the surfaces sent again, and a removed channel named. |
| 15 | Macros, basic: command lists without guards, the clears tab | `specs/2-commands.md` | merged | Adam's `approved` on 2026-11-10 as built, with every reading in the brief; `area/macros` merged into `main` with `--no-ff` (8ae03ef), with its Spec 2 §3, §5, §6, §9 and Spec 1 §2 corrections (1894f17); `swift test` green on the merged tree, pushed, branch and worktree removed, task `shipped`. |
| 16 | Audio, basic: routing to numbered outputs, gain | `specs/4-render-pipeline.md` §11 | merged | Adam's `approved` on 2026-11-04 with every reading as built; `area/audio` merged into `main` with `--no-ff` (89641e9), branch and worktree removed, task `shipped`. The hardware path (a real device unplugged, a card) waits for the bench. |
| 17 | Settings: outputs, audio outputs, key bindings, media, startup and backup, the lock page, variables, tracking, thumbnails and engine, network, command bar | `specs/10-show-mode-ui.md` | not started | Spec 10 accepted 2026-11-08, its prompt block in `docs/build-order.md`, to start after Areas 13 and 14. Its `edit machine mediaRoot` refuses a root where media may not live with the check Area 8 built (`MediaPlaces`, on `main`; Adam's answer to Area 8's plan). Area 19 left it these: an edit of the campus name or the API port reaches Bonjour and the listener only at the next launch, a screen's mode change moves only the output's window (its render size and rate stay its `format`), and the Mach channel sends a stack's surfaces again through one entry point when its size changes. |
| 18 | Operator lock: passcode in the Keychain, edit mode blocked | `specs/10-show-mode-ui.md` | not started | Spec 10 accepted 2026-11-08, its prompt block in `docs/build-order.md`, to start after Area 17. Keeping the edit that turns the lock on off the undo stack (Spec 5 §8) is its work: Area 12's stack takes every applied edit. Area 19 keeps only the token's Keychain item, behind its seam (`SecretStore`), and answers `passcode`, `unlock`, `resetPasscode`, `token` and `newToken` with `notInV1` until then; `newToken` has to close every LAN connection. |
| 19 | Engine API and first run: the local socket and the LAN API, topics and queries, the preview channel, first run | `specs/10-show-mode-ui.md` §2, §3 and §13 | merged | Adam's `approved` on 2026-11-16 as built, with every reading in the brief and its recommended answers; the Spec 4 §12 and Spec 10 §13 corrections applied on the branch (6554d0c), `area/api` merged into `main` with `--no-ff` (73ab889), `swift test` green on the merged tree, pushed, branch and worktree removed, task `shipped`. After the merge Adam lifted his pause on runs that open outputs, and the last stage's checks ran on the external screen the same day: a relaunch after a real kill, a clean stop that isn't one, `--released`, the audio start on the real device with no watchdog event, and a one-minute smoke of the soak command with its own Mach client, which failed its GPU budget on a Mac that was busy (Housekeeping). The three-hour display-only soak that followed held its GPU budget throughout and had the soak's Mach client sent every preview and picture; what it failed is not Area 19's (Needs Adam). |
| v1.5 | After the pilot: runtime undo, library mode and local copies, NDI, live inputs, audio transitions, pre-flight report, optimize on import, macro guards and the scheduler, lookahead polish, distribution conventions | `docs/build-order.md` | not started | Specs wait until the pilot is scheduled. Each row has its own task in the Build tracker. |
| v2 | Slide designer, timelines and clocks, custom transitions, CCLI reporting | `docs/build-order.md` | not started | Deferred. |

## Now

**Nothing is in review; everything is on `main`.** Area 19, engine API and first run,
shipped on 2026-11-16. Adam approved it as built, with every reading in the brief and its
recommended answers; its Spec 4 §12 and Spec 10 §13 corrections were applied on the branch
(6554d0c), and it was merged with `--no-ff` (73ab889) and pushed. Its last stage's checks
ran on a screen that evening, once Adam lifted his pause on runs that open outputs, and
behaved (the Area 19 row; Housekeeping for the GPU time read that evening). A display-only
soak then ran on his word and failed three lines: three hours of `scripts/soak.sh` on
`main`, both screens, no DeckLink, the first soak since 2026-11-02 and so the first of
Areas 5, 6, 8, 9, 11, 12, 15, 16 and 19. It held every display line, the GPU and CPU
budgets, audio with no underrun and the watchdog with no recovery, and failed late text and
the two memory lines, each with a known cause: the confidence stack's clock draws nothing
for one frame as each minute changes, and the engine's in-memory command log is still
filling at three hours. Both want an engine fix or a spec answer from Adam (Needs Adam,
Decisions). No area can start until the bench run: every area left is in `app/` or is Area
7's bench verification, the bench run with a card gates both, and a display-only soak
cannot lift that gate, since Spec 4 §15's DeckLink and capture lines need the card. The
bench run stays deferred to a window Adam sets aside; Area 13, show-mode UI, is next after
it, in its own session.

## Needs Adam

### Briefs waiting for approval

None. The Area 19 brief (the final message of the Area 19 session, 2026-11-16) was answered
the same day: approved as built, with its recommended answers, merged (73ab889).

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
  `shipped`, and Area 14's carries its block as changed on 2026-11-15.
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

None outstanding. Area 19's readings, below, were approved as built on 2026-11-16, with the
recommended answers, and are recorded here and in its brief. "Adam's answer" marks a
choice he made on 2026-11-15 before he approved the plan, or on 2026-11-16 at the third stop
where the row says so; "with the plan" a reading he approved with it; "at stop 1", "at stop
2" and "at stop 3" one he saw in the report at that stop and let the session go on from; and
"new" one first named in the brief. Earlier areas' readings were approved with their briefs
and are in the specs' text, the briefs, or this page as it stood before: Area 12's at
f60a952, approved on 2026-11-15; Area 8's at a8e741b, approved on 2026-11-14; Area 11's at
4096ede, approved on 2026-11-11; Area 6's at a77bf69; Area 9's at f4b43ac; Area 15's on
2026-11-10, Area 16's on 2026-11-04, Area 5's on 2026-11-03, and Area 4's in 7032182.

| Spec | Left open | Chosen | Alternative |
| --- | --- | --- | --- |
| Spec 10 §13, channel 2 | Its render size at first run, where "the fixture library's values" gives a fixed 1920 by 1080 | `largest`, as Spec 1 §9 shows it; Spec 10 §13 corrected on the branch (5e63a20), and the fixture keeps its fixed size (Adam's answer) | The fixture's fixed size |
| Spec 10 §13, the library | What the first-run library is called | "<campus> Library", from `--campus`, or from the machine's own campus when only the library side is missing; "Library" with no campus (Adam's answer) | A fixed name |
| Spec 10 §13, a hand launch | A root with no `machine.json`, launched without `--campus` and `--operator-screen` | Refused with a line and nothing written; writing only a missing library side needs neither option (Adam's answer; Spec 10 §13 says so since 6554d0c) | Write with defaults |
| Spec 4 §11, §12 and Spec 10 §2, audio at launch | Whether the first frame waits for the audio devices | No: they open on a thread of their own, and until a device has opened its outputs are silent on the stand-in that keeps the channels' clocks moving, as for a device that is absent (Adam's answer at stop 3; Spec 4 §12 says so since 6554d0c) | Open them first, as Area 16 built |
| Spec 10 §3, order | Where a request is answered | At a build boundary; in each build a connection gets its results, then the build's events, then its answers (with the plan) | On the asking thread, which can double an event |
| Spec 10 §2, `ping` | Who answers | The control side, so a control thread that has stopped shows as not responding (with the plan) | The socket's thread |
| Spec 2 §9, `commands` | The result of several commands; `group` absent or false | One result, `ok` with the last line's `seq` and `results`, one per command; absent means one group; `false` runs each as its own group (with the plan) | A result per command |
| Spec 10 §2, `source` | Absent, or not one of the three | Absent is `ui`; anything else is `badValue` (with the plan) | Always `ui` |
| Spec 10 §3, a slow client | What happens to it | Closed once 4 MB wait for it; it connects again and asks again (with the plan) | Drop its events |
| Spec 10 §3, `render` and `uses` | Before Area 14 | `notInV1` on the local socket, `localOnly` for `render` on the LAN (with the plan) | `badValue` |
| Spec 10 §12, the lock's requests | Area 18's requests before Area 18; the `engine` topic's `passcode` | `notInV1` locally and `localOnly` on the LAN; `passcode` false; Area 19 keeps only the token's item (with the plan) | Build them now |
| Spec 10 §9, `releaseScreen` | Its fields | `screen` in, `outputs` out, and the note carries both (with the plan) | — |
| Spec 10 §3, `preview` | Its event, and who may subscribe | `stack`, `width`, `height` and `jpeg` as base64; any connection, the local socket included (with the plan) | A binary frame; the LAN only |
| Spec 10 §2, the Mach channel | Who may connect, and how many | The engine's own user, by the message's audit token; up to four clients (with the plan) | Anyone in the session; one |
| Spec 10 §2, the Mach channel | The message layouts | Fixed layouts of 32-bit words, each with a version (with the plan) | — |
| Spec 10 §18, "skipped first" | Among the aux work | The pictures are aux work, which is what is skipped first; there is no order within it (with the plan) | Pictures before previews |
| Spec 10 §2, a GPU reset | What "made again" means today | The recovery keeps the textures, so the same surfaces are sent again (with the plan) | — |
| Spec 10 §2, channels added, renumbered or removed | What drives it before Area 14 | One entry point for each, tested directly; Area 14 calls them when it rebuilds the channel list (with the plan) | — |
| Spec 10 §2, the meters | Silence; a channel on several devices; no sound anywhere | A floor of −120 dBFS; measured on the channel's clock device; one empty frame, then none (with the plan) | — |
| Spec 4 §10, the output window | Its level | The screen-saver level (with the plan) | As it was |
| Spec 10 §11, a screen's mode | What follows a change now | The window; the output's render size and rate stay its `format` until Area 17 rebuilds outputs (with the plan) | Rebuild here |
| Spec 10 §2, exit statuses | Roots that don't load, which exited 3 like a held root | They exit 4 (with the plan) | — |
| Spec 10 §13, uuids | Which are fixed | The built-ins keep the fixtures': Preset 1, transitions 1 to 3 and audio transitions 1 to 3; everything else is new (with the plan) | All new |
| Spec 10 §13, the rate family | Screens of both families | The ports take the family of the first screen output (with the plan) | — |
| Spec 10 §2, the OSC retry | What is sent again | The newest message per address for that target (with the plan) | Nothing |
| CLAUDE.md, dependencies | Apple frameworks, and a C shim | Network, Security and IOKit without an ADR, as Compression and CryptoKit were taken; no C target was needed (with the plan) | An ADR each |
| Spec 10 §2, the Mach call | Which call registers the service | `bootstrap_check_in` first, the deprecated `bootstrap_register` behind the seam when it is refused; both work on the dev Mac, from an app LaunchServices started too, so no launchd agent (at stop 1) | A per-user agent |
| Spec 10 §2, the deprecated call | How Swift reaches it | Looked up by name when it is needed, with no C target (at stop 1) | A C shim |
| Spec 10 §2, the service's name | Its form | `org.lcbc.projecto.engine.` and the run's uuid (at stop 1) | — |
| Spec 10 §18, the proof | What becomes of its tools | `oengine mach-proof` and `scripts/mach-proof.sh` are kept as tooling, with `oengine devices` and, later, `oengine mach-watch` (at stop 1) | Removed after the proof |
| Spec 10 §2, the lock file | After the engine exits | The file stays, with the last engine's process id; only the kernel's lock on it says an engine runs (at stop 2) | Removed at exit |
| Spec 10 §2, the socket | A path over 103 bytes; another failure to open it | The launch stops with a line; any other failure is logged and the engine runs on without its socket (at stop 2) | — |
| Spec 10 §3, `outputs` | `absent` beside `paused` | `absent` is an output whose device hasn't been there this run, `paused` one that presented and lost it; a screen that goes hides the window, and it opens again when the screen returns (at stop 2) | One state |
| Spec 4 §2, the master clock | When it is chosen | At launch: the card's, else the first display output with a screen, else the timer; it isn't chosen again when screens change (at stop 2) | Chosen again |
| Spec 10 §2, the accessory process | Launching without becoming the active app | It launches as a process that can't be activated and becomes an accessory process once launched, since macOS made an accessory process the active app at launch (at stop 2, found by hand) | An accessory from the start |
| Spec 10 §3, order | When each kind of request is taken | A command goes to the engine's queue as it arrives; every other request is taken when the next build starts and answered when it ends; `auth` is checked as it arrives (at stop 2) | All at the boundary |
| Spec 2 §9, `auth` | A command sent on a LAN connection before it | The connection is closed and the command never runs; a test caught one reaching the engine (at stop 2) | — |
| Spec 10 §3, the events' own keys | Names the spec doesn't give | `audioOutput` on the `audio` topic, `clearInMs` on `popups`, null when nothing counts, and `named` in the catalog for the list or playlist its number or title names (at stop 2) | — |
| Spec 10 §3, `state` | Its shape | `state`, `timers` and `events`, with `seq` and `rev` (at stop 2) | — |
| Spec 10 §3, `thumbnails` | A stack other than the thumbnail stack | `notInV1` (at stop 2) | Draw on any stack |
| Spec 10 §3, files on the API | How a tile or a thumbnail is named | By its path relative to the machine root when it is inside it (at stop 2) | Absolute |
| Spec 10 §3, `fonts` | Which faces | Installed and bundled, without the system's hidden faces, whose names begin with a dot (at stop 2) | Every face |
| Spec 4 §13, `metrics` | When it is worked out | Once a second while someone is subscribed, off the control thread (at stop 2) | Always |
| Spec 10 §3, `remote` | Whether a rejected command counts | Yes: its source is activity too (at stop 2) | Only commands that ran |
| Spec 10 §3, a result | Which lines it speaks for | Those under the group's id from its sender's source, and an edit folded into a typing run (at stop 2) | — |
| Spec 10 §2, a frame message | When a preview or picture frame is named | Only when that tick's GPU work has finished; a frame still unfinished after a second is dropped, and nothing is named for a tick that failed (at stop 3) | Named as it is planned |
| Spec 10 §2, a client that doesn't read | What the engine does | That message is dropped for it; the engine never waits for a client (at stop 3) | Close the client |
| Spec 10 §2, the meters | "Its loudest audio channel" | The highest peak among the content's channels, and the RMS of the one with the most energy (at stop 3) | One channel for both |
| Spec 10 §2, the meters | A paused channel that has sound | It reads the floor (at stop 3) | No reading |
| Spec 10 §12, the token's item | Its name and what it holds | Account `api-token.` and the machine's uuid; whatever text it holds is the token; an item that isn't text is unreadable and is not replaced (at stop 3) | Replace it |
| Spec 10 §2, the Keychain | How often it is read | Once, at launch; a refusal stands until the next launch (at stop 3) | Ask again |
| Spec 10 §2, the retry | "Every few seconds"; a refusal the system doesn't report | Five; a listener that opens and isn't advertised within five seconds counts as refused (at stop 3) | — |
| Spec 10 §2, the listener | A failure that isn't a refusal, such as a port something else holds | Shown as `closed` and retried the same way (at stop 3) | Give up |
| Spec 2 §9, a silent client | A LAN connection that sends nothing | Closed after ten seconds (at stop 3) | Left open |
| Spec 2 §9, "Nothing listens beyond the local network" | Whether connections are limited to the same link | No relay, and no limit to the same link, since a campus may route between the engine's network and a remote's; the token admits a client (at stop 3) | Same link only |
| Spec 10 §3, `preview` | How fresh, and under pressure | The stack's preview from two previews back, so never a frame half drawn; none while the previews are being skipped (at stop 3) | The newest |
| Spec 10 §13, the app's screen | It isn't among the Mac's screens | No screen becomes an output; the card's ports still do (at stop 3) | Every screen does |
| Spec 10 §13, audio output 1 | A Mac with no default output device | No audio output 1 is written, and the embedded ones still number from 2, so the channels feed none of them (at stop 3) | Embedded from 1 |
| Spec 10 §13, a refused launch | Its exit, and what it leaves | Status 2, and the lock takes back the file and the folders it made (at stop 3) | Status 1 |
| Spec 10 §13, where the roots may live | Who checks the place | The app's sheet; the engine checks only that the socket's path fits (at stop 3) | The engine refuses too |
| Spec 4 §4, a reused plan | Its previews and pictures | Skipped, as under pressure, so no surface is drawn twice from one plan (new) | Drawn again |
| Spec 10 §2, the picture | How it is filtered, and a missing channel's | Each picture pixel is the mean of the block it covers, up to 32 samples a side; opaque over black; a missing channel's is cleared without reading its texture (new) | — |
| Spec 10 §18, sound alone | A channel whose media is audio with no picture | No picture, and no channel pass is run for one (new) | — |
| Spec 10 §2, the meters | How the level leaves the audio callback; mute and delay | With atomics and memory the instance holds from the start, where the plan said a ring; after the channel's gain and its transition, before the output's mute and delay (new) | A ring; after mute |
| Spec 10 §2, a client leaving | How the engine learns of it | Its next send to that client fails, within a thirtieth of a second while previews flow (new) | A death notice |
| Spec 10 §3, `engine` | The client count; the LAN's state while an OSC send is refused | Connections that have signed in; `waiting` though the listener is open (new) | Every open connection; `open` |
| Spec 10 §2, the OSC retry | Which failures count as refused | The errors a send gets while the system holds local traffic back or the target can't be reached; a message the socket can't carry is not kept (new) | Every failure |
| Spec 2 §9, a WebSocket frame | What one carries | One JSON object in a text frame; a binary frame or a message over 1 MB closes the connection (new) | — |
| Spec 2 §9, Bonjour's name | A machine with no campus name; a campus edited while it runs | "Project O"; a changed name or port takes effect at the next launch until Area 17 (new) | — |
| Spec 10 §12, a new token | One that can't be written to the Keychain | Not used: the listener stays closed with the `keychain` badge, since the next launch would make another (new) | Used for this run |
| Spec 10 §2, a run without the LAN | Whether there is one | `--no-lan` opens no listener and never touches the Keychain (new) | Always on |
| Spec 10 §13, labels and channels | Audio output 1's label; an embedded output's; a one-channel device | The device's name; the port's name with "embedded"; channel 0 alone (new) | "System default" |
| Spec 10 §13, a root half written | Documents there but no `library.json` or `machine.json` | The missing ones are written and those there are kept; the side's own document goes last, so a launch cut short is finished by the next (new) | Refuse |
| Spec 10 §13, the first window's line | The engine's part of it | It prints "output N is NAME" for each new output in its console log (new) | — |
| Spec 10 §2, the launch's first checks | Their order | The lock, then the socket's path, then first run's options; a launch that stops at either check leaves nothing behind (new) | — |
| Spec 10 §2, the relaunch rule | A file without `clean` or `writtenAt`; a boot time that isn't known | Without `clean` it counts as not clean, as for the restore; without `writtenAt` it isn't of this boot; with no boot time only the flag makes a relaunch (new) | — |
| Spec 10 §2, "after the Mac started" | Where the boot time comes from | The kernel's, a wall-clock stamp like the file's (new) | Uptime |
| Spec 10 §2, `--released` | Its form | Given once for each screen (new) | One list |
| Spec 10 §18, the soak | Its screens, and what its client must be sent | Its display outputs take the screens `--screens` names, or every screen of the Mac left to right, and one past the last screen stays absent; the run fails when the client was sent no surfaces or no preview frame for a stack (new) | — |
| Spec 4 §12, a stop while a device opens | Whether the stop waits | No; a device that opens after the stop is stopped again (new) | Wait for it |

### Spec corrections proposed

None. Area 19's proposals were accepted and applied (6554d0c): Spec 4 §12 now says the
engine opens its audio devices beside its first frames, an output being silent until its
device has opened, as for a device that is absent; Spec 10 §13 now says a launch on a
machine root with no `machine.json` and without `--campus` and `--operator-screen` writes
nothing and exits with status 2. Spec 10 §13's sentence on channel 2's render size was
applied earlier (5e63a20, on Adam's answer of 2026-11-15).

## Next

**Area 13 — Show-mode UI** (branch `area/show`), once the bench run has passed; Area 19,
which it also waited for, is merged. It runs in its own session from the common preamble in
`docs/build-order.md` and its own block there, verbatim:

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
Area: 13, show-mode UI. Spec: docs/specs/10-show-mode-ui.md §1–§10, §14 and §15, with
§18's Area 13 tests; the UX spec (docs/ux-spec.md) and the clickable demo for look and
feel where the spec is silent, asking before guessing. Starts after Area 19 is merged
and after the bench run passes (Spec 4 §15). The app is new: an Xcode project in app/
that depends on the package at the root, with AppKit and SwiftUI as CLAUDE.md divides
them. Build the engine connection first: the roots in the app's preferences; finding,
starting and restarting the engine with the curtains and the restart rule (§2, choice
U-7); Quit; the scripted engine on a local socket that the tests drive; and the models
fed by §3's topics and queries. Then the window and its regions (§4–§8), with the
previews, the channel pictures and the meters from the Mach channel; the keys with their
precedence and the fixed keys (§9); the edits of §10 with undo and redo; drops from the
Finder that import and then write (choice U-8); the restore sheets and the tags (§14);
the notes and view.json; and VoiceOver labels and the string catalog from the first
build (§15). Edit mode is Area 14's, Bind a Key… waits for Area 17, and Lock Station and
the lock tag for Area 18: their entries stay disabled until then. Tests first from §18.
Stop for review after the engine connection, after the grid and the strip, and after the
keys.
```

**Area 13 and after:**

- **What Area 19 hands Area 13.** On `main`: the local socket in the machine root with
  `hello`, the topics, queries and requests of Spec 10 §3, the Mach channel with the
  previews, the channel pictures and the meters (`MachClient` is its other end, and
  `oengine mach-watch` shows what it carries), first run with `--campus` and
  `--operator-screen`, `--relaunch` and `--released`, and the exit statuses the app tells
  apart: 3 for a held root, 4 for roots that don't load, 2 for a first run asked wrongly.
- **The app's areas, after the bench run.** Area 13 comes first, 14 follows 13, 10 follows
  14, 17 follows 13 and 14, and 18 follows 17. None can start independently before it.
- **The bench run with the card** happens whenever Adam sets a window, with the bench
  machine root copied again from the spike fixtures first. It must pass before anything in
  `app/` starts and before Area 7's bench verification.
- **Spec 5 has no area of its own.** Its engine side landed with Area 9 (the edit path, the
  writer and changes on disk), Area 8 (the media edits and the defaults edits) and Area 12
  (edit undo and redo, and the restores), all on `main`.
