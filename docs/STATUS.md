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
| 8 | Media pool: hash IDs, index, import by copy, poster frames, missing state | `specs/8-media-pool.md` | not started | Spec 8 accepted 2026-11-07, its prompt block in `docs/build-order.md`, to start after Area 9 (`media replace`, `media delete` and the defaults edits ride its edit path). The index types, a resolver over the media root, SHA-256 identity and a missing set computed at launch are on `main` since Area 2. |
| 9 | Cues, lists and playlists: write/clear/hold, Go and Time triggers, sections, linked items, live pointer, next | `specs/7-cues-lists-and-playlists.md` | not started | Spec 7 accepted 2026-11-07, its prompt block in `docs/build-order.md`. The runner on `main` logs a fired cue as its own group with `fire`; the control loop fires armed Time triggers as `next`; the thumbnail job projects a list from its top (Area 5). Since Area 15 the runner logs a cue fired inside a cue as its own group. |
| 10 | Text editor: whole-list text document with cue breaks | `specs/11-edit-mode.md` | not started | Spec 11 accepted 2026-11-08, its prompt block in `docs/build-order.md`, to start after Area 14, whose frame and Cues page it joins. |
| 11 | Variables: Time, Date, Timer and Popup slots, captions over OSC | `specs/6-presets-and-text.md` | not started | Spec 6 accepted 2026-11-04, its prompt block in `docs/build-order.md`, to start after Area 6 (its context values read Area 6's provenance). `popup N set` over OSC is on `main` since Area 3; `[Time]`, `[Date]` and `[Popup N]` in static boxes since Area 5. |
| 12 | Log and saving: command log with sources, continuous save, launch snapshots | `specs/9-log-and-saving.md` | not started | Spec 9 accepted 2026-11-07, its prompt block in `docs/build-order.md`, to start after Area 9 (it builds on Area 9's edit path, debounced write and versions). It also runs the startup macro at launch (Spec 9 §4), which Area 15 left to it. |
| 13 | Show-mode UI (`app/`): three columns, grid, strip, preview and multiviewer, tabs, top bar, keyboard | `specs/10-show-mode-ui.md` | not started | Spec 10 accepted 2026-11-08, its prompt block in `docs/build-order.md`, to start after Area 19 and once the spike passes on the bench. The clears tab's tiles send the commands Area 15's tests prove (Spec 10 §7), and the app maps keys to commands sent with source `key` (§9). |
| 14 | Edit mode, minimal: the Cues page with the inspector and palette, stack editor, channel sheet, preset editor with text styles, small editors for grades, transitions, audio transitions and macros; the render and uses queries | `specs/11-edit-mode.md` | not started | Spec 11 accepted 2026-11-08, its prompt block in `docs/build-order.md`, to start after Area 13, and so after the bench run. Its macro edits refuse a cycle or a nest past the cap with the one check Area 15 built (`MacroCalls`, on `main`). |
| 15 | Macros, basic: command lists without guards, the clears tab | `specs/2-commands.md` | merged | Adam's `approved` on 2026-11-10 as built, with every reading in the brief; `area/macros` merged into `main` with `--no-ff` (8ae03ef), with its Spec 2 §3, §5, §6, §9 and Spec 1 §2 corrections (1894f17); `swift test` green on the merged tree, pushed, branch and worktree removed, task `shipped`. `stack all blackout` and the all-toggle rule for stacks and audio; macros the same from a key, OSC and a cue, whole or not at all; `/o/error` for every rejected OSC message; the self-firing cue's crash and the gain kept across a list boundary fixed. |
| 16 | Audio, basic: routing to numbered outputs, gain | `specs/4-render-pipeline.md` §11 | merged | Adam's `approved` on 2026-11-04 with every reading as built; `area/audio` merged into `main` with `--no-ff` (89641e9), branch and worktree removed, task `shipped`. The hardware path (a real device unplugged, a card) waits for the bench. |
| 17 | Settings: outputs, audio outputs, key bindings, media, startup and backup, the lock page, variables, tracking, thumbnails and engine, network, command bar | `specs/10-show-mode-ui.md` | not started | Spec 10 accepted 2026-11-08, its prompt block in `docs/build-order.md`, to start after Areas 13 and 14. |
| 18 | Operator lock: passcode in the Keychain, edit mode blocked | `specs/10-show-mode-ui.md` | not started | Spec 10 accepted 2026-11-08, its prompt block in `docs/build-order.md`, to start after Area 17. |
| 19 | Engine API and first run: the local socket and the LAN API, topics and queries, the preview channel, first run | `specs/10-show-mode-ui.md` §2, §3 and §13 | not started | Spec 10 accepted 2026-11-08, its prompt block in `docs/build-order.md`, to start after Area 12; engine-only, so no bench run. It runs the shutdown macro on `stop` (Spec 10 §18) and puts the `outputs` and `audio` topics on the API; Area 15 keeps the muted audio outputs in the control loop for them. |
| v1.5 | After the pilot: runtime undo, library mode and local copies, NDI, live inputs, audio transitions, pre-flight report, optimize on import, macro guards and the scheduler, lookahead polish, distribution conventions | `docs/build-order.md` | not started | Specs wait until the pilot is scheduled. Each row has its own task in the Build tracker. |
| v2 | Slide designer, timelines and clocks, custom transitions, CCLI reporting | `docs/build-order.md` | not started | Deferred. |

## Now

**Nothing is in review; everything is on `main`.** Area 15, macros basic, shipped on
2026-11-10. Adam approved it as built, and it was merged with `--no-ff` (8ae03ef) and
pushed, with its spec corrections. Area 6 is next, in its own session. The bench run with a
card stays deferred to a window Adam sets aside; it gates `app/` and Area 7.

## Needs Adam

### Briefs waiting for approval

None. The Area 15 brief (the final message of the Area 15 session, 2026-11-10) was
answered the same day: approved as built, merged (8ae03ef).

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

- **The Build tracker mirrors `docs/build-order.md`** (5291cef, 2026-11-08): every task
  whose area has a block holds the common preamble and that block verbatim, with its
  dependencies from the block's "Starts after" line. Area 15's task is `shipped`.
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

None outstanding. Area 15's readings were approved as built on 2026-11-10, and are
recorded here and in its brief. The first five were Adam's answers during the session.
Earlier areas' readings were approved with their briefs and are in the specs' text or the
briefs: Area 16's on 2026-11-04, Area 5's on 2026-11-03, and Area 4's in 7032182.

| Spec | Left open | Chosen | Alternative |
| --- | --- | --- | --- |
| Spec 2 §7, and the Area 15 block's "no guards" | What happens to the guards Area 3 built | Left as built: a `when` on a macro's command runs per §7; Area 15 builds nothing for guards (Adam) | Turn guards off in v1, a guarded command a `noop` |
| Spec 2 §5 and §9 against Spec 3 §8 | The source of a macro's inner lines when a cue runs the macro | The cue's source plus the macro's number; nested macros name the innermost (Adam; §5 and §9 corrected, 1894f17) | The cue's source alone, as on `main` |
| Spec 2 §5, the depth cap | What uses up the 8 levels, and whether a macro held by a cue is checked | Every macro entered and every cue fired inside a group uses a level, the group's own navigation none; a macro runs whole or not at all from every source (Adam; §5 corrected, 1894f17) | A fresh 8 for every cue; or as on `main` (the cue used a level and a cue's macros were never checked) |
| Spec 2 §6, "Errors go back to the sender" | Whether a message the engine rejects at validation is answered | Every rejected OSC message or bundle is answered with `/o/error`, at `#bundle` for a bundle (Adam) | Engine log only |
| Spec 1 §2, a macro's scope | Whether `stack all blackout` makes a macro machine-level | It leaves it portable (Adam; §2 corrected, 1894f17) | Any stack command makes it machine-level |
| Spec 2 §6, `/o/error` | The reason's form for a rejection at validation | The rejection's message, as the parse errors already send | `code: message`, as the API's rejected result (Spec 2 §9) |
| Spec 2 §3, `stack all` | Effects and transitions over every stack | Every stack in number order ends at one value; one `blackout` effect per stack that changes, each with the blackout transition of the lowest-numbered output showing it (none for a stack no output shows); one `noop` when none changes | One effect for the whole command with one transition |
| Spec 2 §5 and Spec 1 §8 | A macro that calls a macro that does not exist | That one line is a `noop` with its reason in the engine log and the rest runs; it counts no level, and the validator lets it through | The validator rejects the outer macro with `noSuchReference` |
| Spec 1 §8, two macros with one number | Which one runs, and which one the validator checks | The library's first, then the machine's, and within a root the first; the validator now agrees with the runner (it had checked the last) | The validator's old rule, the last in a root |
| Spec 2 §3 and Spec 4 §11, `audio N mute` | A number that is no audio output, reachable through a macro since a macro's inner commands are not validated | Changes nothing; the muted set is kept even when the engine runs without audio | Record it as muted anyway |
| Spec 2 §2, rejections | The reason for an unfinished `stack all …` | Named by what is missing: `stack all` and `stack all blackout` are `missingArgument`, `stack all foo` is `unknownVerb`; `stack all mute 1 on` stays `badArgument` | `badArgument` for any `stack all` but a whole blackout command |
| Spec 3 §5, a boundary's resets | Which line carries the attribute resets a list boundary makes | The navigation's line, with the boundary and the pointer, so the engine applies them | The first line of the cue group |

### Spec corrections proposed

None outstanding. Area 15's corrections went onto `area/macros` (1894f17) from the plan
Adam approved, and reached `main` with the merge (8ae03ef) on 2026-11-10:

- **Spec 2 §3, intro.** "`N` is a channel number or the word `all`" becomes "`N` is the
  target's number; every channel command, `stack N blackout` and `audio N mute` also take
  the word `all`". The stack row gains "`stack all` for every stack, each with its own
  output's transition".
- **Spec 2 §5.**
  - The `macro` row names the cue's source with the macro's number.
  - A new paragraph, Macro depth: the levels counted per group, and a macro run whole or
    not at all.
- **Spec 2 §6.** The address row `stack all blackout toggle` → `/o/stack/all/blackout`
  `s:"toggle"`.
- **Spec 2 §9.** Inner lines carry the cue's source and the macro's number when a cue ran
  the macro.
- **Spec 1 §2.** `stack all blackout` names no stack, so it leaves a macro portable.

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

- **Engine-side, no bench run.** Areas 11, 9, 8, 12 and 19 follow in that order, from their
  blocks in `docs/build-order.md`, which their Build tracker tasks carry verbatim:
  - Area 11 starts after Area 6;
  - Areas 8 and 12 start after Area 9, whose edit path they extend;
  - Area 19 starts after Area 12.
- **The app's areas, after the bench run.** Area 13 follows Area 19, 14 follows 13, 10
  follows 14, 17 follows 13 and 14, and 18 follows 17.
- **The bench run with the card** happens whenever Adam sets a window. It must pass before
  anything in `app/` starts and before Area 7's bench verification.
- **Spec 5 has no area of its own.** Its engine side lands with Area 9 (the edit path) and
  Area 12 (edit undo and redo, and the restores).
