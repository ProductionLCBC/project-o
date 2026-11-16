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
| 4 | Engine spike (`engine/`): headless OEngine over OSC, two channels, two stacks, three hours clean | `specs/4-render-pipeline.md` §15 | merged | Adam's `approved` on 2026-10-31; `area/spike` merged (e735052); the soak fixes (2074bd6) and the §13 memory breakdown (87011b2) merged on his `approved`. Every display-side criterion of §15 holds; the DeckLink criteria wait for the bench run with a card, which Adam has deferred to a window he sets aside. |
| 5 | Render pipeline, the rest: 1080i weave, text cache, thumbnails, multiviewer, measurement | `specs/4-render-pipeline.md` | merged | Adam's `approved` on 2026-11-03 with every recommendation taken; Spec 4 §2, §10, §13, Spec 2 §6 and Spec 1 §5 corrected (e8e1e3f); `area/render` merged into `main` with `--no-ff` (5b3f6ed), branch and worktree removed, task `shipped`. The weave's capture-rig check (§16) joins the bench run. |
| 6 | Stacks and presets: slots, boxes, text styles, resolution order, blackout and mute, offset +1 | `specs/6-presets-and-text.md` | merged | Adam's `approved` on 2026-11-11 as built, with every reading in the brief and its recommended answers; the Spec 3 §6 correction and ADR 0008's acceptance on the branch (85b4e88), `area/presets` merged into `main` with `--no-ff` (af3c948), `swift test` green on the merged tree, pushed, branch and worktree removed, task `shipped`. Spec 1 §2's `weight` went into Area 11's block. |
| 7 | Output sinks: display per screen, DeckLink with weave, output transitions | `specs/4-render-pipeline.md` §10 | not started | After the bench run, and folded into it on Adam's answer of 2026-11-04: the area becomes bench verification and fixes, its block written from the run's findings. The sinks, the encode pass and the switch and blackout mixes are on `main` since Area 4, the weave since Area 5, the embedded audio feed since Area 16. |
| 8 | Media pool: hash IDs, index, import by copy, poster frames, missing state | `specs/8-media-pool.md` | merged | Adam's `approved` on 2026-11-14 as built, with every reading in the brief and its recommended answers, and no spec correction proposed; `area/media` merged into `main` with `--no-ff` (2c1b3d6), `swift test` green on the merged tree, pushed, branch and worktree removed, task `shipped`. |
| 9 | Cues, lists and playlists: write/clear/hold, Go and Time triggers, sections, linked items, live pointer, next | `specs/7-cues-lists-and-playlists.md` | merged | Adam's `approved` on 2026-11-10 as built, with every reading in the brief and its recommended answers; `area/playlists` merged into `main` with `--no-ff` (af2209e), with its Spec 1 §4, §5 and Spec 5 §2, §4 corrections (e538f2b); `swift test` green on the merged tree, pushed, branch and worktree removed, task `shipped`. The gaps it named are accepted: a folder operation that fails on disk is only logged, and Area 12 takes the kept copies when it restores the last state. |
| 10 | Text editor: whole-list text document with cue breaks | `specs/11-edit-mode.md` | not started | Spec 11 accepted 2026-11-08, its prompt block in `docs/build-order.md`, to start after Area 14, whose frame and Cues page it joins. |
| 11 | Variables: Time, Date, Timer and Popup slots, captions over OSC | `specs/6-presets-and-text.md` | merged | Adam's `approved` on 2026-11-11 as built, with every reading in the brief and its recommended answers, and no spec correction proposed; `area/variables` merged into `main` with `--no-ff` (d4333fa), `swift test` green on the merged tree, pushed, branch and worktree removed, task `shipped`. |
| 12 | Log and saving: command log with sources, continuous save, launch snapshots | `specs/9-log-and-saving.md` | merged | Adam's `approved` on 2026-11-15 as built, with every reading in the brief and its recommended answers; the Spec 9 §6 and §10 correction applied on the branch (7dbdf7d), `area/saving` merged into `main` with `--no-ff` (327454f), `swift test` green on the merged tree, pushed, branch and worktree removed, task `shipped`. |
| 13 | Show-mode UI (`app/`): three columns, grid, strip, preview and multiviewer, tabs, top bar, keyboard | `specs/10-show-mode-ui.md` | not started | Spec 10 accepted 2026-11-08, its prompt block in `docs/build-order.md`, to start after Area 19 and once the spike passes on the bench. The clears tab's tiles send the commands Area 15's tests prove (Spec 10 §7), the app maps keys to commands sent with source `key` (§9), the pool tab and the staging copy for drops build on Area 8's import, topic and queries, and the restore sheets, Undo and Redo and the saving badge read what Area 12 publishes (the two queries, the `history` and `saving` topics). |
| 14 | Edit mode, minimal: the Cues page with the inspector and palette, stack editor, channel sheet, preset editor with text styles, small editors for grades, transitions, audio transitions and macros; the render and uses queries | `specs/11-edit-mode.md` | not started | Spec 11 accepted 2026-11-08, its prompt block in `docs/build-order.md`, to start after Area 13, and so after the bench run. Its macro edits refuse a cycle or a nest past the cap with the one check Area 15 built (`MacroCalls`, on `main`); its edits extend the editor Area 9 built, and its slot and preset edits (Spec 5 §3 and §6, `notInV1` until then) meet Area 6's rules: one slot per channel, and the warning that counts boxes at offset 0. Since 2026-11-15 its block also has it rebuild the channel list between ticks, which lifts the `notInV1` Area 12's snapshot restore answers for a snapshot with another channel list. |
| 15 | Macros, basic: command lists without guards, the clears tab | `specs/2-commands.md` | merged | Adam's `approved` on 2026-11-10 as built, with every reading in the brief; `area/macros` merged into `main` with `--no-ff` (8ae03ef), with its Spec 2 §3, §5, §6, §9 and Spec 1 §2 corrections (1894f17); `swift test` green on the merged tree, pushed, branch and worktree removed, task `shipped`. |
| 16 | Audio, basic: routing to numbered outputs, gain | `specs/4-render-pipeline.md` §11 | merged | Adam's `approved` on 2026-11-04 with every reading as built; `area/audio` merged into `main` with `--no-ff` (89641e9), branch and worktree removed, task `shipped`. The hardware path (a real device unplugged, a card) waits for the bench. |
| 17 | Settings: outputs, audio outputs, key bindings, media, startup and backup, the lock page, variables, tracking, thumbnails and engine, network, command bar | `specs/10-show-mode-ui.md` | not started | Spec 10 accepted 2026-11-08, its prompt block in `docs/build-order.md`, to start after Areas 13 and 14. Its `edit machine mediaRoot` refuses a root where media may not live with the check Area 8 built (`MediaPlaces`, on `main`; Adam's answer to Area 8's plan). |
| 18 | Operator lock: passcode in the Keychain, edit mode blocked | `specs/10-show-mode-ui.md` | not started | Spec 10 accepted 2026-11-08, its prompt block in `docs/build-order.md`, to start after Area 17. Keeping the edit that turns the lock on off the undo stack (Spec 5 §8) is its work: Area 12's stack takes every applied edit. |
| 19 | Engine API and first run: the local socket and the LAN API, topics and queries, the preview channel, first run | `specs/10-show-mode-ui.md` §2, §3 and §13 | in progress | In progress on `area/api` since 2026-11-15: Adam approved the plan that day, with three answers (first run writes channel 2's render size as `largest`, with a one-line Spec 10 §13 correction to come on the branch; the first-run library is named "<campus> Library"; a hand launch on a root with no `machine.json` and without `--campus` and `--operator-screen` is refused). It stops for review after the Mach proof, after the socket and §3, and after first run; the Mach proof passed on 2026-11-15 (af5456a, both calls, looked up from an app LaunchServices started), and the session waits at the second stop since 2026-11-16 (db60639: the engine as a process, the local socket and §3). Engine-only, so no bench run. Area 12 built the stop sequence (the shutdown macro, the last try at unwritten documents, the `stop` note, `last.json` clean) and the launch decision that takes "this is a relaunch" as an input, so Area 19 adds the `stop` request with its answer, `--relaunch` and the detection of a run that ended without a stop. It puts on the API what waits in the engine's own publisher: the `outputs` and `audio` topics, Area 9's `library` and `live` events, Area 11's `timers` events, Area 8's `media` topic and `mediaUse` and `media` queries, and Area 12's `history` and `saving` topics, `note` request, `versions` and `snapshots` queries and the snapshot's id in `system snapshot`'s result. Its first run writes Spec 6 §9's channels, presets and stacks, and `dropChannels` from `DropChannels.firstRun` (Spec 8 §8). |
| v1.5 | After the pilot: runtime undo, library mode and local copies, NDI, live inputs, audio transitions, pre-flight report, optimize on import, macro guards and the scheduler, lookahead polish, distribution conventions | `docs/build-order.md` | not started | Specs wait until the pilot is scheduled. Each row has its own task in the Build tracker. |
| v2 | Slide designer, timelines and clocks, custom transitions, CCLI reporting | `docs/build-order.md` | not started | Deferred. |

## Now

**Area 19, engine API and first run, is in progress on `area/api`, stopped at its second
stop for review, after the socket and §3.** Adam approved its plan on 2026-11-15, with
three answers (row 19 above), and said to go on after the first stop, the Mach proof
(af5456a: both calls work on the dev Mac, no launchd agent needed, Spec 10 §2 stands). On
the branch since (db60639, pushed): the engine as a process (the lock file with exit
status 3, the console log trimmed in place, output windows as non-activating panels,
display outputs that wait for their own screen and never take another, the activity and
sleep assertions, the device list), the local socket with `hello`, and §3 (one order per
connection placed at build boundaries, results with `seq`, `group` and `applied`, the
topics, the queries, `ping`, `stop`, `releaseScreen`, the notes, `localOnly` on the LAN).
`swift test` is green on the branch (1288 tests, the real-Trash test skipped). Two things
found on the way are fixed there: macOS made an accessory process the active app at
launch, so the engine launches as a process that can't be activated and becomes an
accessory process once launched; and a test caught a command sent on a LAN connection
before `auth` reaching the engine. Left for this area: the Mach channel's payloads, the
LAN listener with the token and Bonjour, first run (the third stop), the relaunch rule and
the soak client. The spike fixture's outputs name no real screen, so `scripts/soak.sh`
shows nothing until its clone's outputs are bound to the bench's screens, which this area
does with the soak client. Nothing is in review. Area 12, log and saving, shipped on
2026-11-15 (327454f). The bench run with a card stays deferred to a window Adam sets
aside; it gates `app/` and Area 7.

## Needs Adam

### Briefs waiting for approval

None. The Area 12 brief (the final message of the Area 12 session, 2026-11-15) was answered
the same day: approved as built, with its recommended answers, merged (327454f).

### Decisions

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
  own black box folder.

### The attended run

- A second attended memory run is wanted only if the bench record shows the purgeable zone
  not capping: about ten minutes of the engine under Instruments' Allocations (`xctrace`,
  the purgeable category by call stack), in a window Adam sets aside. The quick external
  check stays on `main`: `scripts/soak-memory-sample.sh`, with `--minutes 1 --at "0.25 0.75"`
  for a smoke run.

### Housekeeping

- **The engine writes to the roots it runs on.** Since Area 9 it writes edits; since Area 8
  every launch also walks the media and writes the hash cache (`machine/media-cache.json`),
  pool tiles (`machine/thumbnails/pool/`) and, on a writable machine, posters (`.posters/`)
  and index changes. With Area 12 a launched engine also writes `machine/logs/`,
  `machine/blackbox/`, `machine/snapshots/` and `machine/state/last.json`, removes the
  snapshots and logs retention no longer keeps, and a list restore writes a kept version
  under `library/versions/`. Running `oengine` against `tests/fixtures/library-v1` therefore
  changes the fixture in the repository; the tests run on temporary copies (the harness
  refuses a media worker on `tests/fixtures/`), and the spike runs through `soak.sh` on
  clones.
- **A thumbnail test that timed out once.** `ThumbnailTests`' warm-the-live-list test waits
  for the thumbnail job on a real GPU; in one full local run during Area 12 it gave up
  before the job finished, and it passed on the next full run and alone. It doesn't touch
  Area 12's code. Worth watching on the bench; nothing was changed for it.
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
  dependencies from the block's "Starts after" line. Area 12's task is `shipped`; Area
  14's task carries its block as changed on 2026-11-15.
- **Interaction limit expires 2027-04-30** (16:00 UTC). Until then only collaborators can
  open issues and pull requests or comment on the public repository. Renew it before that
  date (Settings, Moderation options, Interaction limits: collaborators only, six months),
  or anyone with a GitHub account can open them.
- **Licence:** LCBC to choose before contributions open; set up a contributor agreement
  first.
- **The bench Mac is the only place the hardware tests run.** Since 962dd4b the hosted test
  step sets `O_HOSTED_RUNNER`, which makes the Metal and codec tests skip there with a
  visible message, because the runner's virtual GPU or VideoToolbox stalled some runs in a
  kernel call nothing could kill. Area 8's real-frame poster tests skip there too. A
  self-hosted runner on the bench Mac, without the variable, is what should run the goldens,
  the decode tests and the soak; until it exists, `swift test` on the bench by hand is the
  proof, as CLAUDE.md says. GitHub's macOS runner queue cancels a job after fifteen minutes
  of waiting when several pushes land together; `gh run rerun <id> --failed` is the remedy.
- **GitHub Actions billing** no longer blocks CI: on the public repository standard hosted
  runners are free. The ProductionLCBC account's payment problem (Settings, Billing and
  plans) matters again only if the repository goes private or a paid feature is wanted.
- **Two tests skip in the main checkout.** `EmbeddedAudioFeedTests`' unavailable-sink test
  skips wherever `vendor/DeckLinkSDK` is present ("a card may be present"); a fresh worktree
  has no SDK and runs it. `MediaTrashTests`' real-Trash test skips everywhere unless
  `O_REAL_TRASH=1`.

### Spec interpretations made so far

None outstanding. Area 12's readings, below, were approved as built on 2026-11-15, with the
recommended answers, and are recorded here and in its brief. "Adam's answer" marks a
choice he made on 2026-11-14 before he approved the plan, "with the plan" a reading he
approved with it, "at stop 1", "at stop 2" and "at stop 3" one he saw in the report at that
stop and let the session go on from, and "new" one first named in the brief. Earlier areas'
readings were approved with their briefs and are in the specs' text, the briefs, or this
page as it stood before: Area 8's at a8e741b, approved on 2026-11-14; Area 11's at 4096ede,
approved on 2026-11-11; Area 6's at a77bf69; Area 9's at f4b43ac; Area 15's on 2026-11-10,
Area 16's on 2026-11-04, Area 5's on 2026-11-03, and Area 4's in 7032182.

| Spec | Left open | Chosen | Alternative |
| --- | --- | --- | --- |
| Spec 9 §3, the zip | Which deflate | Apple's Compression framework in `engine/`, without an ADR, as CryptoKit was taken for Spec 8; the zip container and CRC-32 are written in Swift, and a test opens the result with `unzip` (Adam's answer) | A zip library, with an ADR |
| Spec 9 §4 and Spec 10 §2, the stop | Who builds the stop sequence | Area 12: the shutdown macro, one more try at unwritten documents, the `stop` note with `unsaved`, `last.json` clean; the terminate and interrupt signals and the `--seconds` end reach it. Area 19 adds the `stop` request and its answer (Adam's answer) | Area 19 builds it |
| Spec 9 §4, the relaunch rule | Who decides a launch is a relaunch | Area 12 builds the decision with "this launch is a relaunch" as an input; Area 19 adds `--relaunch` and the detection (Adam's answer) | Area 12 detects it |
| Spec 9 §3, `system snapshot` | When its line is logged, and what waits | Logged `ok` once the zip is complete; a failed write rejects it; a group sent directly waits whole; held by a cue, macro or key the rest runs at once; it never holds an edit back (Adam's answer) | Logged at once |
| Spec 9 §6, channels | A snapshot that adds, removes or resizes a channel | Refused with `notInV1`, naming the channels, until Area 14 rebuilds the channels between ticks; a channel on air that would go still answers `onAir` first; labels, defaults and decoder caps restore (Adam's answer) | Rebuild the channels in Area 12 |
| Spec 9 §6, a list version | Where its file is read | On the worker, behind the same gate as a snapshot, so the control thread never waits for the disk (with the plan) | In the tick |
| Spec 9 §6, "kept as a version first" | The number the current document is kept under | Its own when its file holds that document and the number isn't kept; else the next above every kept one. The inverse names it (with the plan) | Always its own |
| Spec 9 §6 and §5, undoing a snapshot restore | Whether the undo takes a snapshot of its own | Yes: every snapshot restore takes one, an undo's included (with the plan) | None for an undo |
| Spec 9 §6, the worker | A worker that never answers; a file arriving meanwhile | No answer in thirty seconds is `conflict`; an arriving file is looked at after the restore applies and then meets Spec 5 §10 (with the plan) | Wait; reject the restore |
| Spec 9 §6, the renumber check | Which objects | Every numbered type of both roots, stacks and outputs included (with the plan) | Library types only |
| Spec 9 §6, folders | A folder the snapshot doesn't list that still holds other files | Kept, with the folders above it; one with nothing visible left is removed (with the plan) | Refuse the restore |
| Spec 5 §8, the `undo` line | Whether `undo` and `redo` log a line of their own | Yes, not undoable, before the group with source `restore`; with nothing to undo it is `noop` (with the plan) | The group's lines alone |
| Spec 2 §3, `history jump` | Held by a cue, macro or key | `blocked` with `notInV1`; sent directly, rejected (with the plan) | Always rejected |
| Spec 9 §4, an older `last.json` | A file without `writtenAt` or `clean`; no file | Without `writtenAt` it isn't restored, reason `old`; without `clean` it counts as not clean; no file starts empty with no `lastStateSkipped` and `previous: none` (with the plan) | Restore it |
| Spec 9 §4, what else is gone | An output, a stack or a popup slot the machine no longer has | Left out and named in `left`, as a vanished channel is (with the plan) | Refuse the restore |
| Spec 9 §4, "after a runtime group" | What makes a write due | ShowState or the pending clears differing from what was last written, so a `noop` writes nothing and an edit never does (with the plan) | Every runtime group |
| Spec 9 §4, stop on request | Which ends are clean | The terminate and interrupt signals and the `--seconds` end; a kill is not (with the plan) | The terminate signal only |
| Spec 9 §3, "copies the documents on the control thread" | Copy or encode | The roots are copied as values there, one consistent moment; encoding and zipping happen on the worker (with the plan) | Encode on the control thread |
| Spec 9 §3, equal content | How it is compared | Each document's bytes against the newest zip's, on the worker; no key added to the manifest (with the plan) | A digest in the manifest |
| Spec 9 §3, the ten minutes | Which clock | Engine time since the last timer snapshot was due (with the plan) | The wall clock |
| Spec 9 §7, retention ages | How days are counted | Local calendar days between the day in the name and today; a year is 365 days; a file the engine didn't name is never touched (with the plan) | Hours since `takenAt` |
| Spec 9 §7, a full disk | Which failures; what is retried; what the memory cap drops | `ENOSPC` and `EDQUOT` from any of the engine's writers; every thirty seconds the waiting documents, or with none the held log lines; the first write that succeeds ends it; past the cap the oldest lines go, counted in `lost` (with the plan) | Any failure; a scratch file; drop the newest |
| Spec 9 §2, the note cap and limits | The second, and the sizes | A sliding second of engine time per client; `note` at most 4 KB as its one-line JSON in UTF-8; `text` at most 1,000 characters as a reader counts them (with the plan) | A calendar second |
| Spec 9 §2, a `media` line | Its fields | The walk's operation name and the ids, no paths (with the plan) | With paths |
| Spec 9 §2, the engine log | A media index change beside its worded log line | Written once, as its `media` line; the worded line stays in the engine's memory and the unified log (at stop 1) | Both lines |
| Spec 9 §2, `conflict` and `unsaved` | How a document is named | By its root and its path in it, `library/lists/007-a.json` (at stop 1) | By object and number |
| Spec 9 §2, a typing run's line | Which day's file | The day of its own stamp, the last keystroke's, though it is written when the run closes (at stop 1) | The day it is written |
| Spec 9 §2, "A group's lines go out in one write" | A navigation and the cue it fires | One write for both groups, as one call logs them (at stop 1) | A write per group |
| Spec 9 §2, the sync | Which files, on which clock | Only a file written since its last sync, once a second of engine time (at stop 1) | Every file, on the wall clock |
| Spec 9 §2, the engine's notes | What `text` holds | A plain line of words for a reader of the log (at stop 1) | Empty |
| Spec 9 §2, `dropped` | Counted for whom | Per client: the next note that client writes carries its own count (at stop 1) | One count for all |
| Spec 9 §2, a malformed `note` request | Its answer | `badValue` (at stop 1) | Ignored |
| Spec 2 §6, the restores over OSC | Their arguments | One string after `/o/system/restore`, as Spec 9 §9's row shows; no typed form (at stop 1) | Typed arguments too |
| Spec 9 §2 and §7, old daily black box files | What becomes of them | Trimmed with the earlier hours under the same cap (at stop 1) | Left for ever |
| Spec 9 §4, the stop | Whether the shutdown macro's picture is shown | No: the stop halts the frame clock first, then runs the macro in one last build with whatever was queued; its commands run and are logged (at stop 2) | Present until its transitions end |
| Spec 9 §4 and Spec 3 §8, a restore | Timers, and text | Timers are left as the launch has them; running text transitions are dropped, so restored text appears at once (at stop 2) | — |
| Spec 9 §4, a `writtenAt` ahead of the clock | How old it is | By its distance from now, so more than two hours ahead is `old` (at stop 2) | Any future stamp is `old` |
| Spec 9 §4, `lastStateSkipped` | The reason when more than one holds; a missing `writtenAt` | The first of `clean`, `old`, `restoredBefore`; `writtenAt` null (at stop 2) | Every reason |
| Spec 9 §2, `lastStateRestored` | The shape of `left` | A list of `{"channel": 9, "why": "gone"}`, `{"popup": 2, "why": "clearing"}`, `{"channel": 1, "why": "missing", "media": "ID"}` (at stop 2) | Words |
| Spec 9 §4, what comes back | An output whose stack is gone; what the file doesn't mention; an empty channel never written | The output stays on its default stack; the rest starts fresh; no provenance (at stop 2) | — |
| Spec 9 §4, the launch write | What it holds when a state comes back | The state about to be put back, with `restored: true`, so a kill during the restore gives `restoredBefore` (at stop 2) | The empty state |
| Spec 9 §4, the restore | Which frame, which clocks | The first frame built; the write cadence on engine time and `writtenAt` on the wall clock (at stop 2) | — |
| Spec 9 §4, the startup macro | A macro that doesn't exist | Its group is rejected and logged, and the launch goes on (at stop 2) | Stop the launch |
| Spec 3 §8, the replacement's effects | What feedback mirrors | The cuts and attributes, and stack, blackout, mute, popup and lock without a transition, once (at stop 2) | The spec's three kinds alone |
| Spec 4 §6, a restored paused channel | Its clock | A media clock starts as the channel's transport says; before, it always started playing (at stop 2) | — |
| Spec 9 §3, the `system snapshot` line | Whether it names the snapshot | No: the result names it, and the manifest names the last line logged by `run` and `seq`; Spec 2 §9's `snapshot` key is kept for runtime undo (at stop 3) | A key on the line |
| Spec 5 §8, a failed undo | Its code | `conflict` when a rule would break; `diskFull`, `noTrash` and `onAir` keep their own (at stop 3) | `conflict` always |
| Spec 9 §6, `system restore list N` | A number only a local copy has | `notInV1`; a number nothing has is `unknownObject` (at stop 3) | `unknownObject` |
| Spec 9 §6, a restore that changes nothing | Its result | `noop`, with no inverse and no undo step; the snapshot taken before it stays, as it does when the second checks refuse (at stop 3) | `ok` |
| Spec 9 §3, a group with `system snapshot` and edits | What the snapshot holds | The documents as they were before that group's own edits (at stop 3) | After them |
| Spec 9 §3, equal content | What counts | The documents and the library's folders (at stop 3) | Documents alone |
| Spec 9 §6, reading a snapshot | Which documents must read | All of them, those a restore leaves alone included, since the renumber check reads them (at stop 3) | The replaced kinds |
| Spec 5 §8, after a redo | Which group a later `undoes` names | The redo's; the step's `source` stays where the edits first came from (at stop 3) | The first group |
| Spec 5 §5, an undo during typing | Which runs close | Every open run, whichever client typed it (at stop 3) | The sender's |
| Spec 9 §3, paths in the zip | Where a document sits | Where its file is, or where its first save will put it; two never share a path (at stop 3) | The canonical name always |
| Spec 9 §3, a snapshot that can't be written | Its code | `diskFull` for want of space, else `conflict`; an engine with no roots on disk answers `conflict` (at stop 3) | — |
| Spec 9 §6, a snapshot id | What may be one | Letters, digits, `-`, `_` and `.`; anything else is `unknownObject` (at stop 3) | Any string |
| Spec 9 §6, a restored list's `version` | In memory, before its save | Never below the current one; a list that differs only by `version` isn't touched (at stop 3) | The snapshot's |
| Spec 9 §6, `readOnlyMasters` | Which checks run | The channel checks are skipped; the renumber check runs over both roots (at stop 3) | — |
| Spec 9 §6, while a restore is read | The writer's own reports | Taken in as usual; only what a scan of the disk found waits (at stop 3) | Everything waits |
| Spec 9 §2, the launch snapshot's note | Its place in the log | It takes the next `seq` when the worker's report is read, at the first tick or later (at stop 3) | — |
| Spec 5 §2, an undo, redo or restore a cue holds | When it runs | After the fire, in order with the cue's edits (new) | At its place in the cue |
| Spec 5 §8, a direct group with several undos | Which wait for the worker | The step on top is read first; a later one that needs a read the group didn't get is `conflict` (new) | — |
| Spec 5 §8, "A reload drops steps" | Which documents count | Those whose content a reload changed or took away, not ones the engine's edits won for; a step also touches the lists and playlists whose files it moved or removed (new) | Every file that arrived |
| Spec 9 §6, a version's file | Whose it is | The file at the list's uuid folder and `vNNNN`; its own `uuid` must be the list's (new) | Its inner `version` too |
| Spec 9 §6, a restore's refusals | Their order for a list | Operator lock, library mode, the full disk, the list, the version (new) | — |
| Spec 9 §6, a snapshot's library | How it is known | The manifest's `library` and the zip's `library.json` must both be this library's; a zip without one is `badValue` (new) | The manifest alone |
| Spec 9 §6, on air | When a channel that would go refuses | It has content and sits in a stack an output now shows; "resized" means its `renderSize` differs (new) | — |
| Spec 9 §6, a restored list's folder and file | Where it goes | Back to the folder the snapshot had it in, by a move; its name follows its number and title at its save; a playlist's file is renamed when its title's slug changed (new) | Left where it is |
| Spec 5 §2, a restore's `library` event | What `changed` names | Each list, folder, playlist and local copy, and each numbered object of a catalog, that changed, came or went; `library` and `keys` for those documents (new) | One entry for all |
| Spec 9 §6, a version that arrived by sync | Whether it counts | Yes: the worker lists the folder, and nothing is written over what it finds (new) | Only those the engine kept |
| Spec 9 §6, the queries | `keptAt`, and a file that doesn't read | A stamp in the machine's zone; a version or a snapshot whose file doesn't read is left out (new) | — |
| Spec 9 §5, the `history` topic | Before any edit | Sent on subscribe with both stacks null and `seq` 0 (new) | Nothing until a change |
| Spec 8 §6 and Spec 9 §6, the gate's timeout | Where it is checked | On every build, whichever workers run; before, only with a media worker (new) | — |
| Spec 9 §7, retention's ages | The boundaries | To and including 7, 30 and 365 days; a log more than 90 days old goes (new) | Up to but not including |
| Spec 9 §7, a week that straddles thirty days | What stays | Each day's newest among its newer days, and the week's newest among its older ones (new) | One for the week |
| Spec 9 §7, when the pass runs | The logs and the snapshots | The logs' on the log thread when a day's file starts, that day being today; the snapshots' on their worker at launch and after each one written (new) | One pass for both |
| Spec 9 §7, "the newest of each day" | Two in one second | The one with the higher `-N` is the newer (new) | — |
| Spec 9 §7, the named snapshots | When they are read | As the steps named them when a plan was last built (new) | — |
| Spec 9 §7, a low disk | The black box's minute records; a paused snapshot | The minute records go on in the black box too; a paused automatic snapshot is taken by the next timer once there is space (new) | Minute records in the engine log only |
| Spec 9 §7, the full state | When it starts and ends | With any writer's failure for want of space, for all of them; it ends when a waiting document's write or the logs' own try succeeds, each thirty seconds apart (new) | Per writer |
| Spec 9 §7, between tries | What the engine knows | Nothing until the next try: `system snapshot` and the restores stay `diskFull` for up to thirty seconds after space returns (new) | Probe on every command |
| Spec 9 §7, `last.json` at a stop on a full disk | Whether it is written | No: it stays removed, so the next launch finds none and starts empty (new) | Try once more |
| Spec 9 §2, `lost` | What it counts | Lines of either log dropped while they were in memory, as one number; `logToMemory` carries what was lost by then (new) | Per log |
| Spec 9 §7, `saving` | `unsaved` and `lastSnapshot` | Documents whose first unwritten edit is more than a second old, with those whose write failed; the newest snapshot this run knows of, one it wrote or one its launch matched, null before (new) | — |
| Spec 5 §2 and Spec 9 §7, a save that fails after its rename | The file's name | Put back, so the document is named where its file still is (new) | Left under the new name |
| Spec 9 §8, the fixture | The values of the new keys | `writtenAt` 2026-11-08T09:41:07.002-05:00 and a fixed `run`; no test restores from it, since its machine has `restoreLastState` off and the tests' clock is days away (new) | — |

### Spec corrections proposed

None. Area 12's one proposal was accepted and applied (7dbdf7d): Spec 9 §6 and §10 now say
that, until Area 14 rebuilds the channel list between ticks, a snapshot that adds, removes
or resizes a channel is refused with `notInV1`, naming the channels.

## Next

**Area 19 — Engine API and first run** (branch `area/api`). It runs in its own session from
the common preamble in `docs/build-order.md` and its own block there, verbatim:

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
Area: 19, engine API and first run. Spec: docs/specs/10-show-mode-ui.md §2 (the engine
side), §3, §13 and §16, with §18's Area 19 tests; Spec 2 §5, §8 and §9, Spec 4 §2, §5,
§10, §12 and §14, Spec 5 §6 and Spec 9 §2–§5 as Spec 10 corrected them. Starts after
Area 12 is merged: until then Areas 8, 9, 11 and 12 publish their topics and answer their
queries and requests through the engine's own publisher, and this area puts them on the
API. It is engine-only and needs no bench run. On main: the engine driven over OSC, a
quarter-size preview texture per stack backed by an IOSurface (Area 5), cue thumbnails
and pool tiles as files, and EngineProcess, whose screen(for:) falls back to the next
screen. Prove the Mach call first, on the dev Mac: bootstrap_check_in, or
bootstrap_register behind its seam, looked up from an app that didn't start the engine;
stop for review there, and if neither works, propose the per-user launchd agent before
anything else. Then the engine as a process (§2): the local socket with its owner-only
mode, the peer check, and hello once the engine takes commands; sources taken from that
socket only; the lock file with the process id and exit status 3; the console log
trimmed in place; the accessory process with its activity and sleep assertions; output
windows as non-activating panels on every Space that absorb clicks; and display outputs
that wait for their own screen. Then §3: subscriptions with answers and events in the
order produced and their seq, the topics and the queries, each answered with its
request's id or refused (Spec 2 §9 as Spec 11 corrected it), results with group and
applied, the requests the LAN refuses with localOnly, the notes, and Spec 2 §8's group
validation against the state the earlier commands leave. Then the Mach channel's
payloads: three preview surfaces per stack and three picture surfaces per channel with
their frame messages and the pictures' aux pass (choice U-3), and the meters. Then the
LAN listener with the token read on a background thread, Bonjour and the preview topic;
the first-run writer of §13 with output detection and --campus; the relaunch rule with
--relaunch and --released (Spec 9 §4 as corrected); the soak client that holds the Mach
channel; and the fixture's clear-all binding moved to shift+escape (§16). Tests first
from §18. Stop for review after the Mach proof, after the socket and §3, and after first
run. Nothing in app/.
```

**After Area 19:**

- **Area 19 meets Area 12's work on `main`.** The engine's publisher already holds the `history` and
  `saving` topics (each sent to a new subscriber at once), the `note` request and the
  `versions` and `snapshots` queries; the stop sequence returns what it couldn't write, for
  the `stop` request's answer; the launch returns what became of the last state, for the
  `engine` topic; and the launch decision takes the relaunch as an input that `--relaunch`
  and the detection set.
- **The app's areas, after the bench run.** Area 13 follows Area 19, 14 follows 13, 10
  follows 14, 17 follows 13 and 14, and 18 follows 17.
- **The bench run with the card** happens whenever Adam sets a window, with the bench
  machine root copied again from the spike fixtures first. It must pass before anything in
  `app/` starts and before Area 7's bench verification.
- **Spec 5 has no area of its own.** Its engine side landed with Area 9 (the edit path, the
  writer and changes on disk), Area 8 (the media edits and the defaults edits) and Area 12
  (edit undo and redo, and the restores), all on `main`.
