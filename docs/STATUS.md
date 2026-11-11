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
| 8 | Media pool: hash IDs, index, import by copy, poster frames, missing state | `specs/8-media-pool.md` | not started | Next, in its own session: Spec 8 accepted 2026-11-07, its prompt block in `docs/build-order.md` and under Next below; it can start now (`media replace`, `media delete` and the defaults edits ride Area 9's edit path and writer, and its fixtures meet the spike documents Area 6 left canonical). The index types, a resolver over the media root, SHA-256 identity and a missing set computed at launch are on `main` since Area 2. |
| 9 | Cues, lists and playlists: write/clear/hold, Go and Time triggers, sections, linked items, live pointer, next | `specs/7-cues-lists-and-playlists.md` | merged | Adam's `approved` on 2026-11-10 as built, with every reading in the brief and its recommended answers; `area/playlists` merged into `main` with `--no-ff` (af2209e), with its Spec 1 §4, §5 and Spec 5 §2, §4 corrections (e538f2b); `swift test` green on the merged tree, pushed, branch and worktree removed, task `shipped`. Two gaps accepted: a folder operation that fails on disk is only logged, and Area 12 takes the kept copies when it restores the last state. |
| 10 | Text editor: whole-list text document with cue breaks | `specs/11-edit-mode.md` | not started | Spec 11 accepted 2026-11-08, its prompt block in `docs/build-order.md`, to start after Area 14, whose frame and Cues page it joins. |
| 11 | Variables: Time, Date, Timer and Popup slots, captions over OSC | `specs/6-presets-and-text.md` | not started | Spec 6 accepted 2026-11-04, its prompt block in `docs/build-order.md`, which since Adam's approval of Area 6 also carries Spec 1 §2's `weight`; it can start now that Area 6 is merged, its context values reading the provenance's list. `popup N set` over OSC is on `main` since Area 3; `[Time]`, `[Date]` and `[Popup N]` in static boxes since Area 5, with tabular digits since Area 6; the pointer's reads, `[Next Title]` among them, in OCore since Area 9. |
| 12 | Log and saving: command log with sources, continuous save, launch snapshots | `specs/9-log-and-saving.md` | not started | Spec 9 accepted 2026-11-07, its prompt block in `docs/build-order.md`; it can start now: it writes Area 9's in-memory log to the day's file and builds undo, redo and the restores on its edit path and writer. It also runs the startup macro at launch (Spec 9 §4), which Area 15 left to it, takes the kept copies when it restores the last state (Area 9's brief), and marks restored content with the `restored` provenance that keeps its cue and list (Area 6). |
| 13 | Show-mode UI (`app/`): three columns, grid, strip, preview and multiviewer, tabs, top bar, keyboard | `specs/10-show-mode-ui.md` | not started | Spec 10 accepted 2026-11-08, its prompt block in `docs/build-order.md`, to start after Area 19 and once the spike passes on the bench. The clears tab's tiles send the commands Area 15's tests prove (Spec 10 §7), and the app maps keys to commands sent with source `key` (§9). |
| 14 | Edit mode, minimal: the Cues page with the inspector and palette, stack editor, channel sheet, preset editor with text styles, small editors for grades, transitions, audio transitions and macros; the render and uses queries | `specs/11-edit-mode.md` | not started | Spec 11 accepted 2026-11-08, its prompt block in `docs/build-order.md`, to start after Area 13, and so after the bench run. Its macro edits refuse a cycle or a nest past the cap with the one check Area 15 built (`MacroCalls`, on `main`); its edits extend the editor Area 9 built, and its slot and preset edits (Spec 5 §3 and §6, `notInV1` until then) meet Area 6's rules: one slot per channel, and the warning that counts boxes at offset 0. |
| 15 | Macros, basic: command lists without guards, the clears tab | `specs/2-commands.md` | merged | Adam's `approved` on 2026-11-10 as built, with every reading in the brief; `area/macros` merged into `main` with `--no-ff` (8ae03ef), with its Spec 2 §3, §5, §6, §9 and Spec 1 §2 corrections (1894f17); `swift test` green on the merged tree, pushed, branch and worktree removed, task `shipped`. |
| 16 | Audio, basic: routing to numbered outputs, gain | `specs/4-render-pipeline.md` §11 | merged | Adam's `approved` on 2026-11-04 with every reading as built; `area/audio` merged into `main` with `--no-ff` (89641e9), branch and worktree removed, task `shipped`. The hardware path (a real device unplugged, a card) waits for the bench. |
| 17 | Settings: outputs, audio outputs, key bindings, media, startup and backup, the lock page, variables, tracking, thumbnails and engine, network, command bar | `specs/10-show-mode-ui.md` | not started | Spec 10 accepted 2026-11-08, its prompt block in `docs/build-order.md`, to start after Areas 13 and 14. |
| 18 | Operator lock: passcode in the Keychain, edit mode blocked | `specs/10-show-mode-ui.md` | not started | Spec 10 accepted 2026-11-08, its prompt block in `docs/build-order.md`, to start after Area 17. |
| 19 | Engine API and first run: the local socket and the LAN API, topics and queries, the preview channel, first run | `specs/10-show-mode-ui.md` §2, §3 and §13 | not started | Spec 10 accepted 2026-11-08, its prompt block in `docs/build-order.md`, to start after Area 12; engine-only, so no bench run. It runs the shutdown macro on `stop` (Spec 10 §18) and puts the `outputs` and `audio` topics on the API; Area 15 keeps the muted audio outputs in the control loop for them, and Area 9's `library` and `live` events wait in the engine's own publisher. Its first run writes Spec 6 §9's channels, presets and stacks, which Area 6 put in Preset 1's code and the fixtures. |
| v1.5 | After the pilot: runtime undo, library mode and local copies, NDI, live inputs, audio transitions, pre-flight report, optimize on import, macro guards and the scheduler, lookahead polish, distribution conventions | `docs/build-order.md` | not started | Specs wait until the pilot is scheduled. Each row has its own task in the Build tracker. |
| v2 | Slide designer, timelines and clocks, custom transitions, CCLI reporting | `docs/build-order.md` | not started | Deferred. |

## Now

**Nothing is in review; everything is on `main`.** Area 6, stacks and presets, shipped on
2026-11-11. Adam approved it as built, with every reading in the brief and its recommended
answers: the Spec 3 §6 correction and ADR 0008's acceptance went onto the branch, it was
merged with `--no-ff` (af3c948) and pushed, and Spec 1 §2's `weight` went into Area 11's
block. Area 8 is next, in its own session; Areas 11 and 12 can start now too. The bench run
with a card stays deferred to a window Adam sets aside; it gates `app/` and Area 7.

## Needs Adam

### Briefs waiting for approval

None. The Area 6 brief (the final message of the Area 6 session, 2026-11-11) was answered
the same day: approved as built, with its recommended answers, merged (af3c948).

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
  rig, and the embedded audio feed against the clapper. The bench machine root is copied
  again from the spike fixtures first (Spec 6 §2): Area 6 changed the stacks, and in an
  older copy stack 2's default preset is preset 2, now the Clock, so the confidence screen
  would show only the time.

### The attended run

- A second attended memory run is wanted only if the bench record shows the purgeable zone
  not capping: about ten minutes of the engine under Instruments' Allocations (`xctrace`,
  the purgeable category by call stack), in a window Adam sets aside. The quick external
  check stays on `main`: `scripts/soak-memory-sample.sh`, with `--minutes 1 --at "0.25 0.75"`
  for a smoke run.

### Housekeeping

- **The engine writes edits to the roots it runs on** since Area 9. Running `oengine`
  against `tests/fixtures/library-v1` and sending it an edit (a playlist edit, since that
  fixture's machine is `readOnlyMasters`) changes the fixture in the repository. Soaks send
  no edits.
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
  dependencies from the block's "Starts after" line. Area 6's task is `shipped`, and Area
  11's carries its block's new `weight` clause.
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

None outstanding. Area 6's readings were approved as built on 2026-11-11, with the
recommended answers, and are recorded here and in its brief; some had been answered
already, with the plan on 2026-11-10 and at the second stop. Earlier areas' readings were
approved with their briefs and are in the specs' text, the briefs, or this page as it stood
before (Area 9's at f4b43ac): Area 9's on 2026-11-10, Area 15's on 2026-11-10, Area 16's on
2026-11-04, Area 5's on 2026-11-03, and Area 4's in 7032182.

| Spec | Left open | Chosen | Alternative |
| --- | --- | --- | --- |
| Spec 6 §4, choice T-6 | Which files of DM Sans are bundled | The roman and italic variable fonts, version 4.004, from google/fonts at a pinned commit (Adam's answer to the plan) | The roman alone |
| Spec 6 §4, the bundled names | Which names reach a bundled face | Core Text's own names (`DMSans-9ptRegular_Bold`) and the usual family-and-style names (`DMSans-Regular` to `DMSans-BlackItalic`) (Adam's answer) | Core Text's names only |
| Spec 3 §4 and Spec 6 §5, identical text from another cue or list | Its effect, and what the boxes do | An `applied` effect, logged `ok`, with no channel transition; a title, author, copyright or ccli box whose text changed runs its own box transition (Adam's answer) | A `noop` that updates the provenance silently |
| Spec 6 §3, field boxes | A field the write carries, but empty | It is the write's own and hides the box | It falls back to the list's metadata like an absent field |
| Spec 6 §3 and §5, "the list" | Content a cue wrote under an older provenance with no list, from a `last.json` written before Area 6 | It reads the pointer's list, as content no cue wrote | No list, so its field boxes show no metadata |
| Spec 6 §3, static boxes at an offset | The state their variables read | The state at the box's offset, so a +1 `[Popup N]` shows the popup the next cue sets | The live state |
| Spec 6 §4, "the overflow is reported" | Where | In the text's layout and the text cache's count, for the editor and pre-flight to read; no log line | A log line for every overflowing raster |
| Spec 6 §4, choice T-8 | A box too short for one whole line | Nothing draws, and the overflow is reported | The first line, clipped at the box |
| Spec 6 §4 and Spec 4 §8, a line's width | What alignment and fitting measure | What the line shows, without the space it wrapped at, so centred text sits centred and nothing draws outside the box | The full typographic width, as `main` measured it |
| Spec 6 §4, choice T-10 | Which text sets the tabular flag | The box's own text and the text of a popup it shows, one level deep as T-2 resolves popups | The box's own text only |
| Spec 6 §4 and Spec 1 §8, fonts | When a style's font counts as installed | Only a face whose PostScript name is the one asked for, as `main` detected a substitution; else a bundled face by its own or usual name; else the fallback, recorded. The plan took Core Text's nearest installed face instead | Core Text's choice of an installed face with another name |
| Spec 6 §9, preset 4 | The Credits preset's layout | Centred: `title` in the Body look at 56 pt on up to two lines, then `author`, `copyright` and `ccli` in the Caption look on one line each, every box with a 250 ms dissolve (as built, 2026-11-11) | Another layout |
| Spec 6 §9, "Preset 2 becomes Clock" | The Clock's uuid | Confidence's, `c0de…0002`: the document is replaced in place (as built) | A new uuid |
| Spec 6 §9, the fixtures' outputs | Whether stack 2 leaves its output, as at a fresh install | No: the fixtures keep output 2 on stack 2, which the soak's confidence display needs (as built) | Stack 2 on no output |

### Spec corrections proposed

None outstanding. Area 6's correction went onto `area/presets` (85b4e88) on Adam's
`approved`, and reached `main` with the merge (af3c948) on 2026-11-11:

- **Spec 3 §6, the `applied` effect.** Its list of state changes with nothing to animate
  gains a text write that updates the provenance alone (§4, as Spec 6 corrected it).

## Next

**Area 8 — Media pool** (branch `area/media`). It runs in its own session from the common
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
Area: 8, media pool. Spec: docs/specs/8-media-pool.md, with §11's tests; Spec 1 §3, §5,
§7 and §8, Spec 2 §2, §3, §6 and §9, Spec 3 §4, §6 and §8, Spec 4 §10 and Spec 5 §1, §2
and §6–§8 as Spec 8 corrected them. Starts after Area 9 is merged: media replace, media
delete and the edits of an item's defaults ride its edit path. On main: the two index
types, a resolver that reads every path under the media root, SHA-256 hashing, a missing
set computed once at launch, the poster loader, and the decoders Spec 4 §6 plays. Build
the core changes first: the resolver returns a location (the media root, machine/media/
or an override) and follows both indexes' replaced maps to the end of the chain with the
repeat check; the machine index gains its replaced map and an entry gains deletedAt;
media-local.json's paths read against machine/media/ (no schema bump, §9); the media
target and the hash token (the edit target and json values come with Area 9's edit
parser) and the six media commands in the grammar, parser, printer and OSC form;
dropChannels in machine settings; the projection's media defaults read from the entry a
ref resolves to. Then the file work on a background worker: import (§3) with staging,
hash first, the kinds v1 takes, numbered names, the hidden copy checked against its
hash, diskFull; the walk (§4) at launch, on media rebuild and from the watcher, with the
two-second settle, the hash cache, moves, landings, copies, ids the other folder's index
holds, pruning in the launch walk only and the undo steps it drops; presence per
location after every walk and index reload, with the missing set, the thumbnail keys and
the OSC hash expansion following it; the media root refused off the startup volume (§2,
M-8). Then posters at the in-point and pool tiles (§5), delete and replace with their
inverses as edits, groups included (§6), the media topic and mediaUse (§7), the defaults
edits (Spec 7 §7), and §9's fixtures. Tests first from §11; the clauses marked Area 12
wait for edit undo. Stop for review after the core changes, after the walk, and after
delete and replace. Nothing in app/: the app's staging copy and the pool tab come with
Area 13.
```

**After Area 8:**

- **Engine-side, no bench run.** Areas 11 and 12 can start now, in their own sessions, and
  Area 19 starts after Area 12, each from its block in `docs/build-order.md`, which its
  Build tracker task carries verbatim. Area 11's block now also carries Spec 1 §2's
  `weight`.
- **The app's areas, after the bench run.** Area 13 follows Area 19, 14 follows 13, 10
  follows 14, 17 follows 13 and 14, and 18 follows 17.
- **The bench run with the card** happens whenever Adam sets a window, with the bench
  machine root copied again from the spike fixtures first. It must pass before anything in
  `app/` starts and before Area 7's bench verification.
- **Spec 5 has no area of its own.** Its engine side lands with Area 9 (the edit path, the
  writer and changes on disk, on `main`) and Area 12 (edit undo and redo, and the restores).
