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
| 8 | Media pool: hash IDs, index, import by copy, poster frames, missing state | `specs/8-media-pool.md` | brief waiting for approval | In review on `area/media` (a3aba39, pushed, hosted CI green on both jobs): locations and both indexes' replaced maps, the six media commands, import and the walk on a background worker with the hash cache, posters and pool tiles, replace and delete as edits behind the edit gate, the media topic and the `mediaUse` and `media` queries, the defaults edits; the brief, the final message of the Area 8 session, waits for Adam's `approved`. |
| 9 | Cues, lists and playlists: write/clear/hold, Go and Time triggers, sections, linked items, live pointer, next | `specs/7-cues-lists-and-playlists.md` | merged | Adam's `approved` on 2026-11-10 as built, with every reading in the brief and its recommended answers; `area/playlists` merged into `main` with `--no-ff` (af2209e), with its Spec 1 §4, §5 and Spec 5 §2, §4 corrections (e538f2b); `swift test` green on the merged tree, pushed, branch and worktree removed, task `shipped`. The gaps it named are accepted: a folder operation that fails on disk is only logged, and Area 12 takes the kept copies when it restores the last state. |
| 10 | Text editor: whole-list text document with cue breaks | `specs/11-edit-mode.md` | not started | Spec 11 accepted 2026-11-08, its prompt block in `docs/build-order.md`, to start after Area 14, whose frame and Cues page it joins. |
| 11 | Variables: Time, Date, Timer and Popup slots, captions over OSC | `specs/6-presets-and-text.md` | merged | Adam's `approved` on 2026-11-11 as built, with every reading in the brief and its recommended answers, and no spec correction proposed; `area/variables` merged into `main` with `--no-ff` (d4333fa), `swift test` green on the merged tree, pushed, branch and worktree removed, task `shipped`. |
| 12 | Log and saving: command log with sources, continuous save, launch snapshots | `specs/9-log-and-saving.md` | not started | Next, in its own session: Spec 9 accepted 2026-11-07, its prompt block in `docs/build-order.md` and under Next below; it can start now. It writes Area 9's in-memory log to the day's file and builds undo, redo and the restores on its edit path and writer, runs the startup macro at launch (Spec 9 §4), takes the kept copies when it restores the last state, marks restored content `restored`, saves the popups' pending clears, and, once Area 8 is merged, undoes media replace and delete and drops the undo steps the media walk names (Spec 8 §4), which Area 8 returns and logs. |
| 13 | Show-mode UI (`app/`): three columns, grid, strip, preview and multiviewer, tabs, top bar, keyboard | `specs/10-show-mode-ui.md` | not started | Spec 10 accepted 2026-11-08, its prompt block in `docs/build-order.md`, to start after Area 19 and once the spike passes on the bench. The clears tab's tiles send the commands Area 15's tests prove (Spec 10 §7), the app maps keys to commands sent with source `key` (§9), and the pool tab and the staging copy for drops build on Area 8's import, topic and queries. |
| 14 | Edit mode, minimal: the Cues page with the inspector and palette, stack editor, channel sheet, preset editor with text styles, small editors for grades, transitions, audio transitions and macros; the render and uses queries | `specs/11-edit-mode.md` | not started | Spec 11 accepted 2026-11-08, its prompt block in `docs/build-order.md`, to start after Area 13, and so after the bench run. Its macro edits refuse a cycle or a nest past the cap with the one check Area 15 built (`MacroCalls`, on `main`); its edits extend the editor Area 9 built, and its slot and preset edits (Spec 5 §3 and §6, `notInV1` until then) meet Area 6's rules: one slot per channel, and the warning that counts boxes at offset 0. |
| 15 | Macros, basic: command lists without guards, the clears tab | `specs/2-commands.md` | merged | Adam's `approved` on 2026-11-10 as built, with every reading in the brief; `area/macros` merged into `main` with `--no-ff` (8ae03ef), with its Spec 2 §3, §5, §6, §9 and Spec 1 §2 corrections (1894f17); `swift test` green on the merged tree, pushed, branch and worktree removed, task `shipped`. |
| 16 | Audio, basic: routing to numbered outputs, gain | `specs/4-render-pipeline.md` §11 | merged | Adam's `approved` on 2026-11-04 with every reading as built; `area/audio` merged into `main` with `--no-ff` (89641e9), branch and worktree removed, task `shipped`. The hardware path (a real device unplugged, a card) waits for the bench. |
| 17 | Settings: outputs, audio outputs, key bindings, media, startup and backup, the lock page, variables, tracking, thumbnails and engine, network, command bar | `specs/10-show-mode-ui.md` | not started | Spec 10 accepted 2026-11-08, its prompt block in `docs/build-order.md`, to start after Areas 13 and 14. Its `edit machine mediaRoot` refuses a root where media may not live with the check Area 8 built (`MediaPlaces`, Adam's answer to Area 8's plan). |
| 18 | Operator lock: passcode in the Keychain, edit mode blocked | `specs/10-show-mode-ui.md` | not started | Spec 10 accepted 2026-11-08, its prompt block in `docs/build-order.md`, to start after Area 17. |
| 19 | Engine API and first run: the local socket and the LAN API, topics and queries, the preview channel, first run | `specs/10-show-mode-ui.md` §2, §3 and §13 | not started | Spec 10 accepted 2026-11-08, its prompt block in `docs/build-order.md`, to start after Area 12; engine-only, so no bench run. It runs the shutdown macro on `stop` (Spec 10 §18) and puts on the API what waits in the engine's own publisher: the `outputs` and `audio` topics, Area 9's `library` and `live` events, Area 11's `timers` events, and Area 8's `media` topic and `mediaUse` and `media` queries (the publisher's query hook). Its first run writes Spec 6 §9's channels, presets and stacks, and `dropChannels` from `DropChannels.firstRun` (Spec 8 §8). |
| v1.5 | After the pilot: runtime undo, library mode and local copies, NDI, live inputs, audio transitions, pre-flight report, optimize on import, macro guards and the scheduler, lookahead polish, distribution conventions | `docs/build-order.md` | not started | Specs wait until the pilot is scheduled. Each row has its own task in the Build tracker. |
| v2 | Slide designer, timelines and clocks, custom transitions, CCLI reporting | `docs/build-order.md` | not started | Deferred. |

## Now

**Area 8, media pool, is in review on `area/media`** (a3aba39, pushed, hosted CI green on both jobs). The
session built it tests first, with three stops Adam reviewed in the session (after the core
changes, after the walk, and after delete and replace) and his answers to the plan; the
brief is the session's final message and waits for his `approved`. None of Area 8 is on
`main` yet: `main` holds everything through Area 11. Area 12, log and saving, can start now
in its own session. The bench run with a card stays deferred to a window Adam sets aside; it
gates `app/` and Area 7.

## Needs Adam

### Briefs waiting for approval

- **Area 8, media pool** — the final message of the Area 8 session (2026-11-14), the code on
  `area/media` (a3aba39). It asks for `approved` as built, with every reading in the table
  below; recommended: approve. Three readings carry the most weight and are worth a look
  first: `mediaUse` counts a reference for the item it resolves to, so an item another has
  replaced shows no uses in the delete confirmation; a group sent directly that holds a
  `media delete` waits whole while the files move, its runtime commands included; and the
  poster is the first frame at or after the in-point, the one playback shows first. No spec
  correction is proposed.

### Decisions

- **Where the media root may live, later.** Spec 8 keeps v1's media root on the startup
  volume, outside Desktop, Documents and Downloads (§2, M-8), because macOS asks an
  ad-hoc-signed engine again after every update before it reads an external drive, a
  share or those folders (ADR 0007). Adam asked on 2026-11-07 to look into the
  alternative later: a media root anywhere, with access granted again after each update,
  or kept once builds are signed. It belongs with ADR 0007's revisit when the pilot is
  scheduled. Area 8 built the check (`MediaPlaces`) and Area 17 opens the edit.

- **When the bench run happens.** Deferred by Adam on 2026-11-03 ("later") to a window he
  sets aside: the bench machine root (a copy of `tests/fixtures/spike/machine/` with the
  main output at the LED wall's format, as a DeckLink output if the bench has 12G) and
  `scripts/soak.sh tests/soak/spike.json`. He can run it without a session; its record
  answers the DeckLink criteria of §15, sets the §13 median window, shows whether the
  purgeable zone caps and what the thumbnail job costs, checks the weave on the capture
  rig, and the embedded audio feed against the clapper. The bench machine root is copied
  again from the spike fixtures first (Spec 6 §2): Area 6 changed the stacks, and in an
  older copy stack 2's default preset is preset 2, now the Clock, so the confidence screen
  would show only the time. Once Area 8 is merged, `soak.sh` runs the spike on APFS clones
  of both roots with `libraryMode` writable (Adam's answer to Area 8's plan), so the launch
  walk lands each generated file on its fixed id; the bench run is the first end-to-end run
  of that script change.

### The attended run

- A second attended memory run is wanted only if the bench record shows the purgeable zone
  not capping: about ten minutes of the engine under Instruments' Allocations (`xctrace`,
  the purgeable category by call stack), in a window Adam sets aside. The quick external
  check stays on `main`: `scripts/soak-memory-sample.sh`, with `--minutes 1 --at "0.25 0.75"`
  for a smoke run.

### Housekeeping

- **The engine writes to the roots it runs on.** Since Area 9 it writes edits; once Area 8
  is merged, every launch also walks the media and writes the hash cache
  (`machine/media-cache.json`), pool tiles (`machine/thumbnails/pool/`) and, on a writable
  machine, posters (`.posters/`) and index changes. Running `oengine` against
  `tests/fixtures/library-v1` therefore changes the fixture in the repository; the tests run
  on temporary copies (the harness refuses a media worker on `tests/fixtures/`), and the
  spike runs through `soak.sh` on clones.
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
  dependencies from the block's "Starts after" line. Area 8's task is `in review`.
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
- **A card test skips in the main checkout.** `EmbeddedAudioFeedTests`' unavailable-sink
  test skips wherever `vendor/DeckLinkSDK` is present ("a card may be present"). A fresh
  worktree has no SDK and runs it.

### Spec interpretations made so far

Area 8's, waiting with its brief. "Adam's answer" marks a choice he made when he approved
the plan on 2026-11-11, "with the plan" a reading he approved with it, "at stop 2" and "at
stop 3" one he saw in the report at that stop and let the session go on from, and "new" one
first named in the brief. Earlier areas' readings were approved with their briefs and are in
the specs' text, the briefs, or this page as it stood before: Area 11's at 4096ede, approved
on 2026-11-11; Area 6's at a77bf69; Area 9's at f4b43ac; Area 15's on 2026-11-10, Area 16's
on 2026-11-04, Area 5's on 2026-11-03, and Area 4's in 7032182.

| Spec | Left open | Chosen | Alternative |
| --- | --- | --- | --- |
| Spec 8 §9, the spike | How the spike runs once presence checks bytes, since its index names generated media by fixed ids | `scripts/soak.sh` runs on APFS clones of both roots with `libraryMode` writable, and the launch walk lands each generated file on its fixed id as a re-export (M-2); no fixture change (Adam's answer) | Commit hashed spike media, or rewrite the spike index |
| Spec 8 §2, hashing | Which SHA-256 the engine uses | CryptoKit, without an ADR; OCore's own SHA-256 stays for Linux and cross-checks it in a test (Adam's answer) | OCore's pure-Swift hash everywhere |
| Spec 8 §2 and §10, M-8 | Who builds the `mediaRoot` check | Area 8 builds the check; Area 17 opens `edit machine mediaRoot`; a launch with a root where media may not live reports it and reads nothing there (Adam's answer) | Area 8 opens the edit too |
| Spec 8 §7 and Spec 10 §3, queries | Who answers `mediaUse` and `media` before the API exists | The engine's publisher, which gains a query hook; Area 19 puts them on the API (Adam's answer) | Wait for Area 19 |
| Spec 8 §6, replace | Which references `media replace` rewrites | Write refs in cues, macros, key bindings and scheduler entries, and in cues' held `cueChannel` edits; held media commands and `edit media` keep naming OLD, and local copies follow the mapping (Adam's answer) | Every id in every document |
| Spec 8 §2, presence at launch | A file at an item's location that isn't hashed yet | Present until hashed, unless the cache names other bytes for it (Adam's answer) | Missing until hashed |
| Spec 8 §6, the edit gate | What runs while a delete's files move | Runtime commands run; edits and media commands, and edits held by cues fired meanwhile, wait behind it in the order they arrived (Adam's answer) | Everything waits |
| Spec 8 §6, the Trash | Whether an engine without Full Disk Access can use the user's Trash | Checked first: a few-byte file moved into `~/.Trash` and back by an opt-in test, from a process that can't list the Trash; it passed (Adam's answer) | Stop and bring the options |
| Spec 8 §6, failed moves | The code for a move that fails, or a worker that never answers | `conflict`, every moved file put back; no report within ten seconds counts as a failure (with the plan) | `noTrash` for every failure |
| Spec 8 §3, kinds | ProRes 4444 XQ, ProRes RAW, a movie with only audio | 4444 XQ counts as 4444, RAW is refused, an MPEG-4 or QuickTime file with only AAC or ALAC audio is audio (with the plan) | By extension |
| Spec 8 §3, PATH | A relative PATH, or one where media may not live | `unreadable`, and the place is never touched (with the plan) | Resolved against the engine's folder |
| Spec 8 §2, paths outside the rules | An override where media may not live, a path that leaves its folder, a symbolic link | Missing and reported by the reference report; the walk doesn't follow links (with the plan) | Read anyway |
| Spec 8 §3, numbered names | Whether names compare by case | Without regard to case, as APFS does (with the plan) | By case |
| Spec 8 §4, the settle | What "held for two seconds" means | A modification date at least two seconds old and unchanged when read, so the launch walk reads old files at once (with the plan) | Watching every file for two seconds |
| Spec 8 §4 and §3, mappings | A landing over an entry that already maps; an import of an id both replaced and deleted | The landing's mapping replaces the old one; the import resolves to the replacement, `known` (with the plan) | Keep the old mapping; bring the deleted item back |
| Spec 8 §6, what a delete moves | Which files | The file at the item's location, an override's target included, and every copy the walk found, in either folder (with the plan) | The item's own file alone |
| Spec 8 §6, replace on a `readOnlyMasters` machine | NEW is library media with empty defaults | Its defaults stay empty, since the library isn't written (with the plan) | Copy them into the machine index |
| Spec 8 §7, `mediaUse` | Where scheduler entries count | Under `keys`, with key bindings (with the plan) | A field of their own |
| Spec 8 §4, undo | The undo steps the walk drops | Area 12's; Area 8 returns the entries the walk maps or brings back and logs them (with the plan) | — |
| Spec 8 §8, `dropChannels` | A `machine.json` without it, and first run | All null, so the pool asks; `DropChannels.firstRun` holds `{1, 1, null}` for Area 19's first-run writer (with the plan) | First run's values |
| Spec 2 §2 and §9, the logged forms | How a logged replace and delete carry what they did | One JSON object at the end of the text form, as an edit's picks print, so `parse(print(x)) == x` (with the plan) | A field beside the command in the log entry |
| Spec 1 §8 and Spec 8 §2, the reference report | A missing entry that a `replaced` map leads from; a loop | Not reported as missing, since its references resolve elsewhere; a loop reported once; a held media command naming an unknown id is `unknownReference` when its holder is saved (at stop 1) | Every missing entry |
| Spec 8 §3, files already in a folder | An import of a file where it lies | Its outcome comes from the walk that reads it; a file in `machine/media/` whose id the library holds is `known`, not copied (at stop 2) | Copied into the import folder |
| Spec 8 §3, refusals the table doesn't name | A file that vanishes or can't be read mid-import; an import into a media root that may not be read | `changed`; `readOnlyLibrary` (at stop 2) | `unsupported`; `unreadable` |
| Spec 8 §3, staged files | Moving or copying, and the 1 GB check | A staged file on the same volume is moved in and skips the check; any other file is copied and never moved or removed (at stop 2) | Always copy |
| Spec 8 §2, an index file deleted from disk | What the engine holds | The index it holds, written again at its next change (at stop 2) | An empty index |
| Spec 8 §4, a file still being written at an entry's path | What it stops | Not a move; but the entry doesn't take a copy's path while it is there, so a stalled export still lands (at stop 2) | Both |
| Spec 8 §4, several landings in one walk | Their order | Path order (at stop 2) | — |
| Spec 8 §4, what the walk reports | Copies, ids the other folder's index holds, kinds v1 doesn't take | The engine log, once per run; the reference report at launch comes with pre-flight (at stop 2) | The reference report at every launch |
| Spec 8 §2, places | Which folders M-8 checks | The media root and absolute overrides; `machine/media/` goes with its machine root (at stop 2) | Every folder |
| Spec 8 §2, an index reload | A location the reloaded index newly names, before the walk looks | Absent until the walk's first look lists it, a moment later (at stop 2) | Present until hashed |
| Spec 8 §5, "taken exactly" | An in-point between two frames | The first frame at or after it, the one playback publishes first, decoded from playback's own pre-roll; a test compares the two (at stop 3) | The frame on screen at that instant |
| Spec 8 §4 and §5, a new video the walk finds | How many index changes | Two `library` events with cause `media`: the entry, then its poster; an import writes the entry with its poster, one (at stop 3) | One, after the poster |
| Spec 8 §5, failures | A poster or a tile that can't be made | Logged, the poster null, not tried again until its source file changes (at stop 3) | Tried at every walk |
| Spec 8 §9 and Spec 4 §6, a write before its poster loads | What shows | With a transition, the previous picture until the first frame, with no jump to the poster midway; with a cut, or stopped, the poster once it loads (at stop 3) | Wait for the poster |
| Spec 8 §6, replace's details | Shadowing mappings, the poster, nothing to do, a reference edited since | A machine mapping of a library OLD goes too; NEW's poster name follows the defaults it takes, in the same edit; a replace that changes nothing is `noop`; an unreplace whose reference no longer names NEW is `conflict` (at stop 3) | — |
| Spec 8 §6 and Spec 5 §8, "exactly" | A list's `version` after a replace and its inverse | Every document comes back byte for byte but a list's `version`, which rises on every save (Spec 1 §4) (at stop 3) | — |
| Spec 8 §6, delete's details | Deleting a deleted item; undeleting one that isn't; checking a restored file; the entry's path after undelete | `noop`; `conflict`; by the entry's own size and date, else by hashing; the first restored file in its own folder, a numbered name when another file holds the path (at stop 3) | `badValue`; always hash |
| Spec 8 §6, "the group applies in one step" | A group sent directly that holds a delete | It waits whole while the files move, its runtime commands included; held, the rest of its group runs at once and only the delete and the edits after it wait (at stop 3) | Its runtime commands run at once |
| Spec 8 §6, while a delete waits | The walk, and a write of the item meanwhile | The walk's looks are set aside and a fresh walk follows; the write lands and its file opens when the wait ends, missing if the delete went through, playing once the files are back if not (at stop 3) | — |
| Spec 8 §6, no media worker | A delete where no worker runs (the bare test harness only) | `noTrash` (at stop 3) | — |
| Spec 8 §7, `mediaUse` | What counts as a use | Each holder once (a cue, local copies' included, a macro, a key binding or scheduler entry), by the item each reference resolves to: a reference to a replaced item counts for its replacement, so the replaced item shows none (new) | Also count the id a reference names |
| Spec 10 §3, the `media` query | Its fields | Each entry as its index holds it, with `index`, `presence` of its own file at its own location, `replacedBy` (where its chain ends, or null), `uses` (the total) and `tile` (the file's path, or null), in an array named `media` (new) | The four `mediaUse` counts per item |
| Spec 2 §9, query refusals | An unknown `what`, an unknown id | `badValue`; `unknownObject` (new) | — |
| Spec 5 §6 and Spec 1 §7, the defaults' values | Ranges Spec 1 doesn't give | Trims whole, 0 or more and within the item's duration, the out-point after the in-point; a grade or channel that exists; `unset` back to none (`loop` false); the entry's other fields `readOnlyField`; an item in both indexes edited in the machine's; a deleted item's defaults still editable (new) | Spec 2 §8's ranges alone |

### Spec corrections proposed

None. Area 8 proposes none.

## Next

**Area 12 — Log and saving** (branch `area/saving`). It runs in its own session from the
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
Area: 12, log and saving. Spec: docs/specs/9-log-and-saving.md, with §10's tests; Spec 5
§8 and §9 for edit undo and the restores; Spec 1 §3–§5, Spec 2 §3, §6 and §9, Spec 3 §3
and §8, Spec 4 §12 and §13, Spec 5 §2, §6 and §9, Spec 6 §7, Spec 7 §2 and Spec 8 §2 as
Spec 9 corrected them. Starts after Area 9 is merged: it builds on Area 9's edit path,
its debounced write and its versions filed by list uuid. On main: LogEntry and its line,
the atomic writer and write plans, the versions file, the restoreLastState and snapshots
settings, Machine.lastState read from state/last.json, the black box writing to the
folder the command line names, and EngineLog in unified logging. Build the core changes
first: LogEntry's note lines and its undoes and redoes fields; the two restore commands
in the grammar, parser, printer and OSC form; last.json's new keys. Then the logs (§2):
the command log and the engine log per local day, a group's lines in one write, synced
each second, a partial last line ended on opening, seq per run, the engine's notes, the
API's note request with its cap, and the black box moved to machine/blackbox/ in hourly
files, trimmed within the day, its reader following. Then the last state (§4): its
writes, the clean and restored flags, the minute refresh, the pending clears, the
two-hour limit and the once-only guard, Spec 3 §8's replacement of ShowState, and the
launch order. Then snapshots (§3), edit undo and redo with the history topic (§5), and
the restore commands with the two queries, the renumber check and the worker and queue
handling (§6). Last, retention, the low and full disk and the saving topic (§7), and
§8's fixture. Tests first from §10. Stop for review after the logs, after the last
state, and after the restore commands. Nothing in app/.
```

**After Area 12:**

- **Area 8 first, if it can be.** Area 8's merge on Adam's `approved` puts the media edits,
  the walk's dropped undo steps and the publisher's query hook on `main`; Area 12 started
  after it undoes `media replace` and `media delete` like any edit (Spec 5 §8) and drops the
  steps the walk names (Spec 8 §4), and started before it, it picks them up when Area 8
  merges.
- **Engine-side, no bench run.** Area 19 starts after Area 12, from its block in
  `docs/build-order.md`, which its Build tracker task carries verbatim.
- **The app's areas, after the bench run.** Area 13 follows Area 19, 14 follows 13, 10
  follows 14, 17 follows 13 and 14, and 18 follows 17.
- **The bench run with the card** happens whenever Adam sets a window, with the bench
  machine root copied again from the spike fixtures first. It must pass before anything in
  `app/` starts and before Area 7's bench verification.
- **Spec 5 has no area of its own.** Its engine side lands with Area 9 (the edit path, the
  writer and changes on disk, on `main`), Area 8 (the media edits and the defaults edits,
  in review) and Area 12 (edit undo and redo, and the restores).
