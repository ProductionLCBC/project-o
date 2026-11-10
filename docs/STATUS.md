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
| 6 | Stacks and presets: slots, boxes, text styles, resolution order, blackout and mute, offset +1 | `specs/6-presets-and-text.md` | not started | Next: Spec 6 accepted 2026-11-04, its prompt block in `docs/build-order.md`. The object types are on `main` since Area 2; the stack pass, the +1 slot and the one shared `SlotResolver` since Areas 4 and 5. |
| 7 | Output sinks: display per screen, DeckLink with weave, output transitions | `specs/4-render-pipeline.md` §10 | not started | After the bench run, and folded into it on Adam's answer of 2026-11-04: the area becomes bench verification and fixes, its block written from the run's findings. The sinks, the encode pass and the switch and blackout mixes are on `main` since Area 4, the weave since Area 5, the embedded audio feed since Area 16. |
| 8 | Media pool: hash IDs, index, import by copy, poster frames, missing state | `specs/8-media-pool.md` | not started | Spec 8 accepted 2026-11-07, its prompt block in `docs/build-order.md`, to start once Area 9 is merged (`media replace`, `media delete` and the defaults edits ride its edit path and its writer). The index types, a resolver over the media root, SHA-256 identity and a missing set computed at launch are on `main` since Area 2. |
| 9 | Cues, lists and playlists: write/clear/hold, Go and Time triggers, sections, linked items, live pointer, next | `specs/7-cues-lists-and-playlists.md` | brief waiting for approval | Built on `area/playlists` (211dd4c, pushed) in three stops Adam reviewed in the session (the core changes, the edit path, the live pointer), with the spec corrections from his approved plan (e538f2b); `swift test` green on the branch. The brief is the final message of the Area 9 session, 2026-11-10. |
| 10 | Text editor: whole-list text document with cue breaks | `specs/11-edit-mode.md` | not started | Spec 11 accepted 2026-11-08, its prompt block in `docs/build-order.md`, to start after Area 14, whose frame and Cues page it joins. |
| 11 | Variables: Time, Date, Timer and Popup slots, captions over OSC | `specs/6-presets-and-text.md` | not started | Spec 6 accepted 2026-11-04, its prompt block in `docs/build-order.md`, to start after Area 6 (its context values read Area 6's provenance). `popup N set` over OSC is on `main` since Area 3; `[Time]`, `[Date]` and `[Popup N]` in static boxes since Area 5; Area 9 adds the pointer's reads, `[Next Title]` among them, in OCore. |
| 12 | Log and saving: command log with sources, continuous save, launch snapshots | `specs/9-log-and-saving.md` | not started | Spec 9 accepted 2026-11-07, its prompt block in `docs/build-order.md`, to start once Area 9 is merged: it writes Area 9's in-memory log to the day's file and builds undo, redo and the restores on its edit path and writer. It also runs the startup macro at launch (Spec 9 §4), which Area 15 left to it, and takes the kept copies when it restores the last state (Area 9's brief). |
| 13 | Show-mode UI (`app/`): three columns, grid, strip, preview and multiviewer, tabs, top bar, keyboard | `specs/10-show-mode-ui.md` | not started | Spec 10 accepted 2026-11-08, its prompt block in `docs/build-order.md`, to start after Area 19 and once the spike passes on the bench. The clears tab's tiles send the commands Area 15's tests prove (Spec 10 §7), and the app maps keys to commands sent with source `key` (§9). |
| 14 | Edit mode, minimal: the Cues page with the inspector and palette, stack editor, channel sheet, preset editor with text styles, small editors for grades, transitions, audio transitions and macros; the render and uses queries | `specs/11-edit-mode.md` | not started | Spec 11 accepted 2026-11-08, its prompt block in `docs/build-order.md`, to start after Area 13, and so after the bench run. Its macro edits refuse a cycle or a nest past the cap with the one check Area 15 built (`MacroCalls`, on `main`); its edits extend the editor Area 9 builds. |
| 15 | Macros, basic: command lists without guards, the clears tab | `specs/2-commands.md` | merged | Adam's `approved` on 2026-11-10 as built, with every reading in the brief; `area/macros` merged into `main` with `--no-ff` (8ae03ef), with its Spec 2 §3, §5, §6, §9 and Spec 1 §2 corrections (1894f17); `swift test` green on the merged tree, pushed, branch and worktree removed, task `shipped`. |
| 16 | Audio, basic: routing to numbered outputs, gain | `specs/4-render-pipeline.md` §11 | merged | Adam's `approved` on 2026-11-04 with every reading as built; `area/audio` merged into `main` with `--no-ff` (89641e9), branch and worktree removed, task `shipped`. The hardware path (a real device unplugged, a card) waits for the bench. |
| 17 | Settings: outputs, audio outputs, key bindings, media, startup and backup, the lock page, variables, tracking, thumbnails and engine, network, command bar | `specs/10-show-mode-ui.md` | not started | Spec 10 accepted 2026-11-08, its prompt block in `docs/build-order.md`, to start after Areas 13 and 14. |
| 18 | Operator lock: passcode in the Keychain, edit mode blocked | `specs/10-show-mode-ui.md` | not started | Spec 10 accepted 2026-11-08, its prompt block in `docs/build-order.md`, to start after Area 17. |
| 19 | Engine API and first run: the local socket and the LAN API, topics and queries, the preview channel, first run | `specs/10-show-mode-ui.md` §2, §3 and §13 | not started | Spec 10 accepted 2026-11-08, its prompt block in `docs/build-order.md`, to start after Area 12; engine-only, so no bench run. It runs the shutdown macro on `stop` (Spec 10 §18) and puts the `outputs` and `audio` topics on the API; Area 15 keeps the muted audio outputs in the control loop for them, and Area 9's `library` and `live` events wait in the engine's own publisher. |
| v1.5 | After the pilot: runtime undo, library mode and local copies, NDI, live inputs, audio transitions, pre-flight report, optimize on import, macro guards and the scheduler, lookahead polish, distribution conventions | `docs/build-order.md` | not started | Specs wait until the pilot is scheduled. Each row has its own task in the Build tracker. |
| v2 | Slide designer, timelines and clocks, custom transitions, CCLI reporting | `docs/build-order.md` | not started | Deferred. |

## Now

**Area 9 is in review** on `area/playlists` (211dd4c, pushed), its worktree kept for the
merge. The session built it in three stops, each reviewed by Adam: the core changes, the
edit path with the writer and changes on disk, and the live pointer; `swift test` is green
on the branch. On `main` there is this page and nothing of Area 9's code or its spec
corrections, which merge on Adam's `approved`. Area 6 stays next, in its own session;
Areas 8 and 12 wait for Area 9's merge. The bench run with a card stays deferred to a window
Adam sets aside; it gates `app/` and Area 7.

## Needs Adam

### Briefs waiting for approval

- **Area 9, cues, lists and playlists**: the final message of the Area 9 session
  (2026-11-10), code on `area/playlists` (211dd4c). It asks for:
  - the readings made during the build, in the table below. Recommended: as built,
    including the one that departs from the approved plan's reading 22 (a live reload
    keeps the order of lists sharing a number, so a sync can't switch which list
    `list 57 cue 3` fires mid-service);
  - two known gaps. Recommended: accept them as gaps. A folder operation that fails on disk
    is only logged, and the library keeps the edit's picture until the next launch. The
    kept copies at a state restore are taken by Area 12, when it restores the last state;
  - then `approved`, to merge `area/playlists` with its spec corrections.

### Decisions

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
  rig, and the embedded audio feed against the clapper.

### The attended run

- A second attended memory run is wanted only if the bench record shows the purgeable zone
  not capping: about ten minutes of the engine under Instruments' Allocations (`xctrace`,
  the purgeable category by call stack), in a window Adam sets aside. The quick external
  check stays on `main`: `scripts/soak-memory-sample.sh`, with `--minutes 1 --at "0.25 0.75"`
  for a smoke run.

### Housekeeping

- **The engine writes edits to the roots it runs on** once Area 9 is merged. Running
  `oengine` against `tests/fixtures/library-v1` and sending it an edit (a playlist edit,
  since that fixture's machine is `readOnlyMasters`) changes the fixture in the repository.
  Soaks send no edits.
- **A bug outside Area 9:** `OEngineCommandLine.drive` passes `--library` where the machine
  root goes. To fix in a tooling session.
- **The Build tracker mirrors `docs/build-order.md`** (5291cef, 2026-11-08): every task
  whose area has a block holds the common preamble and that block verbatim, with its
  dependencies from the block's "Starts after" line. Area 9's task is `in review`.
- **Interaction limit expires 2027-04-30** (16:00 UTC). Until then only collaborators can
  open issues and pull requests or comment on the public repository. Renew it before that
  date (Settings, Moderation options, Interaction limits: collaborators only, six months),
  or anyone with a GitHub account can open them.
- **Licence:** LCBC to choose before contributions open; set up a contributor agreement
  first.
- **The bench Mac is the only place the hardware tests run.** Since 962dd4b the hosted test
  step sets `O_HOSTED_RUNNER`, which makes the Metal and codec tests skip there with a
  visible message, because the runner's virtual GPU or VideoToolbox stalled some runs in a
  kernel call nothing could kill. A self-hosted runner on the bench Mac, without the
  variable, is what should run the goldens, the decode tests and the soak; until it exists,
  `swift test` on the bench by hand is the proof, as CLAUDE.md says. GitHub's macOS runner
  queue cancels a job after fifteen minutes of waiting when several pushes land together;
  `gh run rerun <id> --failed` is the remedy.
- **GitHub Actions billing** no longer blocks CI: on the public repository standard hosted
  runners are free. The ProductionLCBC account's payment problem (Settings, Billing and
  plans) matters again only if the repository goes private or a paid feature is wanted.
- **One card test skips in the main checkout.** `EmbeddedAudioFeedTests`' unavailable-sink
  test skips wherever `vendor/DeckLinkSDK` is present ("a card may be present"). A fresh
  worktree has no SDK and runs it.

### Spec interpretations made so far

Area 9's, outstanding until Adam answers its brief. The readings in the plan he approved on
2026-11-10 are answered, and the brief restates them; these were made during the build and
reported at its stops. Earlier areas' readings were approved with their briefs and are in
the specs' text or the briefs: Area 15's on 2026-11-10, Area 16's on 2026-11-04, Area 5's
on 2026-11-03, and Area 4's in 7032182.

| Spec | Left open | Chosen | Alternative |
| --- | --- | --- | --- |
| Spec 7 §2, "Other files are never replaced" | A new list whose own file name another file holds | The first free `-2`, `-3` name, as a playlist takes one (Spec 7 §3) | Refuse the create with `duplicate` |
| Spec 1 §4 and choice E-3 | What "the last copy is more than ten minutes old" measures | The kept versions' file dates against the wall clock | A record of the copies kept, in memory |
| Spec 1 §8, the report | How it names a playlist | By its title | By its uuid |
| Spec 5 §4, `section` | Which cues a section block holds | Labels compared ignoring case; a cue with no section is a block of one | Exact case; neighbouring cues with no section form one block |
| Spec 7 §3, local items | When an edit may add a local item | Only when an undo puts one back; otherwise `notInV1` | Never |
| Spec 7 §5, `archived true` | On a playlist already archived | A `noop` | Refused with `archived` |
| Spec 7 §2, folder names | A new folder whose parent is typed in another case | The parent keeps its case: `folder "worship/Hymns" create` makes `Worship/Hymns` | `unknownObject` |
| Spec 5 §6, check 8 | When an edit a cue holds is checked | When the cue is saved, as if it ran then, without operator lock and library mode, which apply when it fires | Lock and library mode at the save too |
| Spec 5 §6, check 5 | What a cue may name that this machine lacks | A playlist by title, and stacks, outputs, audio outputs and inputs: a cue is portable | The machine-level numbers only |
| Spec 7 §2, "a save renames the file" | When a retitled or renumbered list's file is renamed | At its next write | At the edit, as a move |
| Spec 5 §4, the text form | `section` as a cue's field and as the verb | The word after it decides: `duplicate`, `move N` or `remove` is the verb, a string is the field | Another word for the verb |
| Spec 5 §3, key bindings | The text address of one binding | `keys DEVICE "KEY"` | `key DEVICE "KEY"` |
| Spec 5 §3, values | How a structured value is written in the text form | One JSON token | Words per field |
| Spec 2 §6, `/o/edit` with the words in the address | The case of a path in the address | Kept as sent | Lowercased with the other words |
| Spec 2 §9, `fire` | A cue that holds only edits | Its first edit line carries the fire record | No fire record |
| Spec 2 §9, the log in memory | How much of the run it keeps until Area 12 writes the file | The last 10,000 lines | All of it |
| Spec 5 §5, typing | Events and the revision while someone types | Every keystroke applies at once and sends its own `library` event, so other screens follow; the log line and the undo step fold; over OSC the client is the sender's address and port | One event per run |
| Spec 5 §2, "within one second of each change" | When the first write of a change goes | At once, then at most once a second | A second after the first change |
| Spec 5 §2, which documents a group writes | The documents a renumber rewrites | Every document that differs after the group: lists, macros, key bindings and playlists; a local copy is saved where its file is, never renamed | Only the documents the edits name |
| Spec 5 §2 and plan reading 18 | A file operation that fails | A write is logged once and tried every second, the document named where its file still is; a list move leaves the list where it is, with a `file` event; a folder operation is only logged, and the library keeps the edit's picture until the next launch | Re-read the folders after any failure |
| Spec 5 §10 | When a change that arrived is caught | When a scan finds it while edits are unwritten, and when the writer is about to overwrite, move or remove a file that changed since it last read it; kept once either way | At scans only |
| Spec 5 §10, the engine's edits win | The version of the engine's next write when the arriving file's is higher | Above the arriving file's, so versions never run backwards | The engine's own next version |
| Spec 5 §10, the conflict's name | The time in the name | Local time, `machine/conflicts/2026-11-08-085959-007-doxology.json`, and `-2` within the same second | UTC; or milliseconds |
| Spec 5 §10 | A file deleted on disk while edits to it are unwritten | The edits win and it is written again: a list after its three-second window, a playlist at once; a change arriving at a file an edit has just deleted goes to `conflicts/` | The deletion wins and the edits are dropped |
| Spec 7 §2, the three-second window | Writes of a list whose file has gone | Held until the window closes, so a delete then a create stays a move | Written at once at the old path |
| Spec 7 §3 and plan reading 17 | A local copy whose file goes, or two files holding one | Deleted at once, as a playlist; of two files, the loaded one stays | The three-second window |
| Spec 7 §2 and plan reading 22 | A list's place among lists sharing its number, after a live reload | Kept: a reload replaces it in place, and a list that arrives goes after them; only a launch re-ranks. This departs from reading 22, which said a reload changes the order | Re-rank on every reload |
| Spec 5 §2, `changed` | What a reload's event names | Whole objects, with no paths | The fields that changed |
| Spec 4 §10 and Spec 5 §2 | Thumbnails after a write | The live list warms again when its version changes: about once a second while someone types into it | Only on a fire |
| Spec 2 §7 and Spec 7 §6, the live guards | `[Live Item]` and `[Live Cue]` when what they name is gone | `[Live Item]` is empty, as for a library list (`/o/live/item` sends 0); `[Live Cue]` is the number of the cue before the place, 0 at the top, as `/o/live/cue` | `[Live Item]` reads 0 |
| Spec 7 §4 and plan reading 23 | `cue N` after a relaunch with the live item gone | It fires in the live list and keeps the gone item, so `next` and `previous` stay idle until a fire names a place | `cue N` re-anchors the pointer |
| Spec 7 §4, lookahead | The +1 boxes from a pointer the engine can't place | Empty, as `next` does nothing | The live list from its top |
| Spec 7 §6, "sent on a fire" | Two fires in one tick | One set of messages per tick, after its commands, at the final position | A set per fire |
| Spec 7 §6, `/o/live/playlist` | When it goes | With every position update; an empty string for a library list or nothing loaded | Only while a playlist is live |
| Spec 7 §6 and Spec 10 §3, the `live` event | Its extra fields, and when it goes | `playlistTitle`, `listTitle`, `label`, and `boundary: {"reset": …}` on a fire into another list; also when only a handle or the list's title changes, which the OSC messages don't carry | Only with the OSC messages; `boundary` as a flat field |
| Spec 7 §6, a pointer the engine can't place | What feedback sends | What can still be found: the item's and cue's positions where they exist, else 0 | 0 throughout |
| Spec 6 §5, `[Next Title]` | Where Area 9 puts the read | In the live reading in OCore, for Area 11's boxes; it isn't feedback, so a change to it sends nothing | Leave it to Area 11 |
| Spec 7 §4, the countdown at its time | The state its liveness is read in | The state at the start of the tick, before that tick's queued commands | After them |
| Spec 7 §4, the copies at a launch or restore | Who takes them | Area 12's restore of the last state, when it puts the pointer back; the engine starts with no pointer until then | Area 9 takes them at every build |

### Spec corrections proposed

None new. Area 9's corrections went onto `area/playlists` (e538f2b) from the plan Adam
approved on 2026-11-10, and reach `main` with the merge:

- **Spec 1 §4.** A list's version rises on a save that replaces its file; a new list is
  written at its version; a version already kept is never copied again.
- **Spec 1 §5.** A playlist keeps its file's name until its title changes.
- **Spec 5 §2.** A document is written within a second of each change, and at most once a
  second.
- **Spec 5 §4.**
  - What `duplicate`, `archive` and `swap` carry, with the picks printed as one trailing
    JSON object.
  - `cueChannel`'s attributes and place, its text form, and its inverse's fallback to an
    `edit.set` of the cue's whole `commands`.

## Next

**Area 6 — Stacks and presets** (branch `area/presets`). It runs in its own session from
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
Area: 6, stacks and presets. Spec: docs/specs/6-presets-and-text.md §2–§4 and §9, with
§11's Area 6 tests; Spec 1 §2 and §3, Spec 3 §2, §4 and §7 and Spec 4 §8 and §9 as it
corrected them. On main: the stack pass with fit modes, opacity and mute, the shared
SlotResolver, the +1 slot with its text rasterized a cue ahead, Preset 1 built in. Build
the core changes first: the slot loses its offset and the box gains one (written on
every box), a later slot for a channel is ignored and reported, and the provenance
records the cue's list, with an identical text write from another cue or list updating
it (Spec 3 §2 and §4). Then the engine: offset boxes, with fallback per offset and the
fold within the list in thumbnails; field boxes falling back to the list's title,
author, copyright and ccli; static boxes on an empty channel; the text style's
verticalAlignment, the units with the shadow padding scaled, whole-line overflow with
the ellipsis, tabular digits with the flag in the cache key; DM Sans bundled and
registered in the engine at launch, an installed copy winning a name clash. Last,
Preset 1's "2" layout, the Clock preset, and the fixtures and JSON Schemas of §9
(library-v1 and spike; no schema bump, §2). Tests first from §11's Area 6 list, with
goldens for the anchor, the overflow and the confidence stack. Stop for review after the
core changes and again after the fixtures. Nothing in app/.
```

**After Area 6:**

- **Engine-side, no bench run.** Areas 11, 8, 12 and 19 follow, from their blocks in
  `docs/build-order.md`, which their Build tracker tasks carry verbatim:
  - Area 11 starts after Area 6;
  - Areas 8 and 12 start once Area 9 is merged, since they extend its edit path and writer;
  - Area 19 starts after Area 12.
- **The app's areas, after the bench run.** Area 13 follows Area 19, 14 follows 13, 10
  follows 14, 17 follows 13 and 14, and 18 follows 17.
- **The bench run with the card** happens whenever Adam sets a window. It must pass before
  anything in `app/` starts and before Area 7's bench verification.
- **Spec 5 has no area of its own.** Its engine side lands with Area 9 (the edit path, the
  writer and changes on disk) and Area 12 (edit undo and redo, and the restores).
