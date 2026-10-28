# Status

The one-page view. Every session starts by reading this page and ends by rewriting it
(`CLAUDE.md`, "Session contract"; `/wrap-up` does the rewrite). It lives on `main` and is
current on `main` after every session, even while an area's code waits on its branch. The
detail is elsewhere: the areas and their prompts in `docs/build-order.md`, mirrored by the
Build tracker in Nimbalyst; each area's brief as the final message of its session (Area 1's
predates that and is a file, `docs/reviews/area-1-projection.md`, which records Adam's
answers at the top); one line per session in `CHANGELOG.md`.

## Areas

State is one of `not started`, `in progress`, `brief waiting for approval`, `merged`.

| # | Area | Spec | State | Last session, or what is left |
| --- | --- | --- | --- | --- |
| 1 | Channel state and projection (`core/`) | `specs/3-channel-state-and-projection.md` | merged | Adam's `approved` on 2026-10-27; spec corrections applied (e57728f), `area/projection` merged into `main` with `--no-ff` (d7465b8), `swift test` and CI green on `main`, branch and worktree removed, task `shipped`. |
| 2 | Object model and library format (`core/`, `formats/`) | `specs/1-objects-and-format.md` | merged | Adam's `approved` on 2026-10-28 with one reversal (a missing transition degrades to the channel default, then to a zero-second cut; 78902ef on the branch); spec corrections applied (cc404c0), `area/format` merged into `main` with `--no-ff` (70bf958), `swift test` and CI green on `main`, branch and worktree removed, task `shipped`. |
| 3 | Command vocabulary: grammar, parser and printer, validation, OSC mapping (`core/`) | `specs/2-commands.md` | brief waiting for approval | On `area/commands` (pushed, c57e008): the Spec 2 §10 tests first, then the §2 grammar with both duration spellings, the §3 table as data, the §4 parser and printer with the short forms, §5 groups and selection, §6 OSC both ways with bundles, feedback shapes and the wire codec, §7 guards in text, §8 validation and results through a runner, the §9 log entry, and Area 1's deviation 2 closed. `swift test` and CI green on the branch; the brief is the session's final message. |
| 4 | Engine spike (`engine/`): headless OEngine over OSC, two channels, two stacks, three hours clean | `specs/4-render-pipeline.md` §15 | not started | Waits for Adam's `approved` on Area 3 (the vocabulary over OSC, with the packet codec, is on its branch) and the DeckLink SDK in `vendor/`. Nothing in it runs unattended. |
| 5 | Render pipeline, the rest: 1080i weave, text cache, thumbnails, multiviewer, measurement | `specs/4-render-pipeline.md` | not started | After the spike passes every §15 criterion. |
| 6 | Stacks and presets: slots, boxes, text styles, resolution order, blackout and mute, offset +1 | `specs/1-objects-and-format.md` + presets-and-text spec | not started | Spec needed first (presets and text). The object types are on `main` since Area 2. |
| 7 | Output sinks: display per screen, DeckLink with weave, output transitions | `specs/4-render-pipeline.md` §10 | not started | After the spike. |
| 8 | Media pool: hash IDs, index, import by copy, poster frames, missing state | media-pool spec | not started | Spec needed first. The index, the resolver, SHA-256 identity and the missing state are on `main` since Area 2; the rebuild walk, import by copy and poster extraction remain. |
| 9 | Cues, lists and playlists: write/clear/hold, Go and Time triggers, sections, linked items, live pointer, next | cues-lists-playlists spec | not started | Spec needed first. The runner on `area/commands` already logs a fired cue as its own group with `fire`; this area owns how `next` becomes a cue group in the engine. |
| 10 | Text editor: whole-list text document with cue breaks | edit-mode spec | not started | Spec needed first. |
| 11 | Variables: Time, Date, Timer and Popup slots, captions over OSC | presets-and-text spec | not started | Spec needed first. `popup N set` over OSC is on `area/commands`. |
| 12 | Log and saving: command log with sources, continuous save, launch snapshots | log-and-saving spec | not started | Spec needed first. The atomic write, the write plan and the versions folder are on `main` since Area 2; the Spec 2 §9 entry and its one-line form are on `area/commands`; debouncing, the log file and snapshots remain. |
| 13 | Show-mode UI (`app/`): three columns, grid, strip, preview and multiviewer, tabs, top bar, keyboard | show-mode-ui spec | not started | Spec needed first; nothing in `app/` starts before the spike passes. |
| 14 | Edit mode, minimal: cue inspector with palette, stack editor, channel sheet, preset editor | edit-mode spec | not started | Spec needed first; in `app/`, so after the spike passes. |
| 15 | Macros, basic: command lists without guards, the clears tab | `specs/2-commands.md` | not started | After Area 3. The runner's macro expansion, the depth cap and the cycle check are on `area/commands`. |
| 16 | Audio, basic: routing to numbered outputs, gain | `specs/4-render-pipeline.md` §11 | not started | After the spike. |
| 17 | Settings: inputs, outputs, audio outputs, keys, media root, startup | settings section of show-mode-ui spec | not started | Spec needed first. |
| 18 | Operator lock: passcode in the Keychain, edit mode blocked | show-mode-ui spec | not started | Spec needed first. |
| v1.5 | After the pilot: runtime undo, library mode and local copies, NDI, live inputs, audio transitions, pre-flight report, optimize on import, macro guards and the scheduler, lookahead polish, distribution conventions | `docs/build-order.md` | not started | Specs wait until the pilot is scheduled. Each row has its own task in the Build tracker. |
| v2 | Slide designer, timelines and clocks, custom transitions, CCLI reporting | `docs/build-order.md` | not started | Deferred. |

## Now

**Area 3 is live on `area/commands` and waits for Adam's `approved`.** The session of
2026-10-28 proposed its plan, Adam answered its six decisions (durations print clock style
for positions and timers and as seconds with a point for effect durations; a standalone
attribute write accepts a trailing `track`; a scope-less `gain` inside a media write is the
override; a slide's build belongs to its content; the macro line is logged with its inner
commands; feedback shapes and the OSC packet codec are in, the API envelope is not), and the
session built it tests first: `tests/OCoreTests/CommandTextTests.swift`,
`CommandRejectionTests.swift`, `SelectionExpansionTests.swift`, `OSCMappingTests.swift`,
`OSCCodecTests.swift`, `CommandRunnerTests.swift`, `LogEntryTests.swift` and
`CommandAliasTests.swift`, then `core/Commands/` (the vocabulary table, tokens and
durations, the parser and printer, groups, OSC and its codec, validation, the runner, the
log entry), a one-line JSON form in `core/Format/JSON/JSONPrinter.swift`, and two small
changes outside the area's files: `CommandSource` writes lowercase uuids, and the projection
runs machine-level macros too. The fixture's one slide write now carries its build in the
content. `swift test` is green on the branch and CI passed on the push (macOS build and
test, Linux OCore portability). On `main`: everything of Areas 1 and 2, and this page. Not
on `main`: all of Area 3, on its branch until `approved`.

## Needs Adam

### Briefs waiting for approval

- **Area 3, command vocabulary.** The brief is the final message of the Area 3 session
  (2026-10-28), after this page. It asks for `approved` with the readings below taken and
  the spec corrections applied (recommended: yes to both); then Area 4 is next, which also
  needs the DeckLink SDK in `vendor/`.

### Spec interpretations made so far

Adam answered the six decisions of the Area 3 plan in the session; they are recorded in the
brief. The readings below were made while building and wait for his `approved`.

| Spec | Left open | Chosen | Alternative |
| --- | --- | --- | --- |
| Spec 2 §6 | `cue 7` is `/o/cue` `i:7` in the table while `macro 12` is `/o/macro/12` | Followed the table: the cue number is an argument, the macro number an address part | Put both in the address for symmetry |
| Spec 2 §6 | A single string argument could be the typed argument or the remainder of the text form | Tried as the remainder first, then as the typed argument; one `s` of a text field without quotes is the text itself | Typed first, which would make a quoted remainder a popup text with literal quotes |
| Spec 2 §6 | Which OSC number type to print | `i` for whole numbers and whole seconds, `f` for a decimal that survives 32 bits, `d` otherwise, so the object round-trips | Always `f`, which loses `-6.1` |
| Spec 2 §6 | Case of address words | Matched case-insensitively like keywords; `ch` and `tr` expand there too | Exact lowercase only |
| Spec 2 §8 | One result per command when the projection folds a group as one | A runner folds one command at a time; `steppedOn` wins, then `ok` if anything changed, `blocked` if lock refused everything, else `noop`; `channel all` partly blocked is `ok` with a `blocked` effect | Attribute results from one flat effect list |
| Spec 2 §8 §9 | How a fired cue is logged when `next` fires it | The navigation line carries the boundary and pointer effects; the cue's commands follow as their own cue group with a fresh id and `fire`; the projection's whole fold is the state, the replay only attributes effects | Log `next` alone, losing `fire` and the cue's lines |
| Spec 2 §8 | `cue N` and `item N` need the live position | Checked only when a ShowState is given; skipped without one, the nil-means-skip pattern of Spec 1 §8 | Reject without a state |
| Spec 2 §8 | Ranges beyond gain and sync offset | Negative durations, in and out points, builds and `clearafter` are rejected; timer and popup slots are checked against machine settings; `playlist "TITLE"` must name a playlist on the machine; `edit` targets must exist | Leave them to the projection's `noop` |
| Spec 2 §7 | Guards outside macros | Accepted and evaluated by the runner from any source but `cue` and `timeline`; a failing guard skips the command without a log line; the variable's shape and numbers are validated | Reject guards from every non-macro source |
| Spec 2 §2 | Abbreviated hashes with nothing to expand against | Rejected as unknown media; a prefix needs at least 12 hex characters; uppercase hashes and uuids are lowercased | Keep the abbreviation and let validation reject it |
| Spec 2 §2 | Text fields in text form | `text "x"` is a body-only write; `text KEY "v" KEY "v"` several fields, a key quoted when it is not one word; `text` alone is no fields | Always `body` |
| Spec 2 §3 | `edit TARGET N FIELD VALUE`'s value | The rest of the line, read as JSON when it looks like JSON, else one word; `null` reads as no value | Quoted strings only |
| Spec 2 §5 §9 | Who makes group ids and how long they are | The caller; the helper makes `g-` plus eight hex characters from a UUID | The spec example's four characters |
| Spec 2 §9 | `ts`, `seq`, edit entries and rejections in the entry | Supplied by the caller; `undo: edit` for edit entries; a rejected result writes `reason` as `code: message`; unknown keys survive; `source` writes lowercase uuids and omits absent fields | Decide them in Area 12 |
| Spec 3 §6 | Machine-level macros (Spec 1 §2) | The projection runs a macro from either root | Library macros only, as Area 1 left it |

### Spec corrections proposed

- Spec 2 §2 examples: `channel 2 grade 5 track`, `channel 2 grade 5 2.0 track` and
  `channel 2 gain -6 track` carry a scope the §3 table does not; drop the word or say it is
  optional (the code accepts `track`, rejects `once`, prints neither).
- Spec 2 §4: state the canonical duration spelling: in and out points and timers print
  `M:SS` (`H:MM:SS` from an hour, fractions as `0:01.5`); transition, audio transition and
  grade durations print seconds with a point (`1.0`, `0.25`); every spelling parses anywhere.
- Spec 1 §6: drop `build` from the attribute riders list; a slide's build is the `build` of
  its `slide` content (Spec 3 §3 rule 8). A file with the rider is read as the content's build.
- Spec 2 §6: say the address words are case-insensitive, that one string argument is read as
  the remainder of the text form first, and that a `d` (double) is accepted and printed when a
  value does not survive `f`.
- Spec 2 §9: `group` ids are `g-` plus eight hex characters; rejected results at the API and
  command-bar boundary carry `reason`; edit entries have `undo: edit`.
- Spec 3 §6: "`macro` by inlining the macro's commands" from either root.

## Next

**Area 4 — Engine spike** (branch `area/spike`, its own Nimbalyst worktree session, branched
from `main` after Area 3 is merged). The prompt, verbatim from `docs/build-order.md`: the
common preamble, then the area's own block.

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
Area: 4, the engine spike. Spec: docs/specs/4-render-pipeline.md, §15 defines the
scope and §1–§13 the rules. Build the headless OEngine process in engine/ with the
seams in §14 as protocols, the master tick, the frame plan builder over core/'s
projection, one video ContentSource, the still source, the channel pass, the
per-line text rasterizer, the stack pass with the +1 offset slot, the display and
DeckLink sinks, the audio graph for one device, the metrics ring, black box and
watchdog, and the headless harness with a software clock and capturing sink.
Before any Metal code, write the headless harness tests and the golden-image
scaffolding. The DeckLink SDK is in vendor/DeckLinkSDK (see vendor/README.md).
Stop for review at each of: the tick and harness, the channel pass, the stack
pass, each sink. Nothing here runs unattended.
```

Area 4 waits for Adam's `approved` on Area 3 and for the DeckLink SDK in `vendor/`; its OSC
path is a socket over the codec and mapping on `area/commands`. The specs for the areas
marked "Spec needed first" above can be written in Cowork at any time; each already has its
task in the Build tracker, marked `spec needed`. Area 9's cues spec can take the runner's
cue-group logging as given and specify the engine's side; Area 12's log spec can take the
Spec 2 §9 entry and its one-line form as given and specify the file, debouncing and snapshots.
