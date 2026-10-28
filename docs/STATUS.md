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
| 2 | Object model and library format (`core/`, `formats/`) | `specs/1-objects-and-format.md` | brief waiting for approval | Session of 2026-10-28 on `area/format` (pushed, 06bfc62): the fixture library, the §10 tests, the JSON layer, every §2–§3 object, loader, writer, validator, migrations, identity, the media index, the `OFormats` file adapter, the schemas; Area 1's pool-defaults gap closed. `swift test` green. The brief is the session's final message. |
| 3 | Command vocabulary: grammar, parser and printer, validation, OSC mapping (`core/`) | `specs/2-commands.md` | not started | Builds on Area 1's `Command` enum, which Area 2 extended (`unknown` and `invalid` keep their parameters; guarded entries carry unknown keys), so it should branch from `main` after Area 2 merges. Its prompt also has the decoder accept the bare `cmd` names Spec 1 §6 used before its correction (Area 1 brief, deviation 2). |
| 4 | Engine spike (`engine/`): headless OEngine over OSC, two channels, two stacks, three hours clean | `specs/4-render-pipeline.md` §15 | not started | Needs Areas 1–3 (the fixture library on disk, the vocabulary over OSC) and the DeckLink SDK in `vendor/`. Nothing in it runs unattended. |
| 5 | Render pipeline, the rest: 1080i weave, text cache, thumbnails, multiviewer, measurement | `specs/4-render-pipeline.md` | not started | After the spike passes every §15 criterion. |
| 6 | Stacks and presets: slots, boxes, text styles, resolution order, blackout and mute, offset +1 | `specs/1-objects-and-format.md` + presets-and-text spec | not started | Spec needed first (presets and text). The object types now exist on `area/format`. |
| 7 | Output sinks: display per screen, DeckLink with weave, output transitions | `specs/4-render-pipeline.md` §10 | not started | After the spike. |
| 8 | Media pool: hash IDs, index, import by copy, poster frames, missing state | media-pool spec | not started | Spec needed first. The index, the resolver, SHA-256 identity and the missing state are on `area/format`; the rebuild walk, import by copy and poster extraction remain. |
| 9 | Cues, lists and playlists: write/clear/hold, Go and Time triggers, sections, linked items, live pointer, next | cues-lists-playlists spec | not started | Spec needed first. |
| 10 | Text editor: whole-list text document with cue breaks | edit-mode spec | not started | Spec needed first. |
| 11 | Variables: Time, Date, Timer and Popup slots, captions over OSC | presets-and-text spec | not started | Spec needed first. |
| 12 | Log and saving: command log with sources, continuous save, launch snapshots | log-and-saving spec | not started | Spec needed first. The atomic write, the write plan and the versions folder are on `area/format`; debouncing, the log and snapshots remain. |
| 13 | Show-mode UI (`app/`): three columns, grid, strip, preview and multiviewer, tabs, top bar, keyboard | show-mode-ui spec | not started | Spec needed first; nothing in `app/` starts before the spike passes. |
| 14 | Edit mode, minimal: cue inspector with palette, stack editor, channel sheet, preset editor | edit-mode spec | not started | Spec needed first; in `app/`, so after the spike passes. |
| 15 | Macros, basic: command lists without guards, the clears tab | `specs/2-commands.md` | not started | After Area 3. |
| 16 | Audio, basic: routing to numbered outputs, gain | `specs/4-render-pipeline.md` §11 | not started | After the spike. |
| 17 | Settings: inputs, outputs, audio outputs, keys, media root, startup | settings section of show-mode-ui spec | not started | Spec needed first. |
| 18 | Operator lock: passcode in the Keychain, edit mode blocked | show-mode-ui spec | not started | Spec needed first. |
| v1.5 | After the pilot: runtime undo, library mode and local copies, NDI, live inputs, audio transitions, pre-flight report, optimize on import, macro guards and the scheduler, lookahead polish, distribution conventions | `docs/build-order.md` | not started | Specs wait until the pilot is scheduled. Each row has its own task in the Build tracker. |
| v2 | Slide designer, timelines and clocks, custom transitions, CCLI reporting | `docs/build-order.md` | not started | Deferred. |

## Now

**Area 2, object model and library format, is in review on `area/format`.** The session of
2026-10-28 ran in the area's worktree (`.claude/worktrees/area-format`, kept on disk) and
pushed the branch to origin at 06bfc62: the fixture library under `tests/fixtures/library-v1/`
(the §9 worked examples plus a complete first-run library, synthetic media, a machine root,
a previous version, a local copy, and the invented schema-0 list for the migration test); the
§10 tests, written first; then `core/Format/` (the format's own JSON parser and canonical
printer, the Codable bridge, documents, loader, writer, migrations, validator), the rest of
the §2–§3 objects in `core/Library/`, the §7 index and SHA-256 identity in `core/Media/`,
renumbering and cue addressing, commands kept verbatim when unknown or invalid, the pool
defaults on a media write (Area 1 brief, deviation 1), the zero-second cut for a missing
transition (Adam's answer to the plan), the `OFormats` package target in `formats/OFormats/`
(the only code that touches disk: snapshot, atomic write, hashing) and one JSON Schema per
document kind in `formats/schemas/`. `swift test` is green on macOS; CI has not run on the
branch because the committed workflow runs on pushes to `main` only (Adam's uncommitted
`.github/workflows/ci.yml` edit in the main checkout would change that; it is still left for
him to commit or discard). Nothing of Area 2 is on `main`; the code waits for `approved`. The
Build tracker task is `in review`.

## Needs Adam

### Briefs waiting for approval

- **Area 2** — the brief is the final message of the Area 2 session (2026-10-28). It asks
  for: (1) approval with the spec corrections below applied, recommended yes; (2) whether a
  local copy keeps the master's cue uuids under its own list uuid, recommended yes until the
  v1.5 library-mode spec says otherwise; (3) whether command objects may omit absent
  optionals while catalog objects write nulls, recommended yes, as the spec's own examples do;
  (4) committing the every-branch CI workflow edit so area branches get the Linux job before
  review, recommended yes; (5) Area 3 next, branched from `main` after the merge.

### Spec interpretations made so far

Adam's `approved` answered every Area 1 reading. This session's readings, each also an entry
in the brief:

| Spec | Left open | Chosen | Alternative |
| --- | --- | --- | --- |
| 1 §5 | "one object per line in arrays of objects" has no mechanical rule | A container whose members are all scalars or empty containers prints on one line; anything else one member per line; keys in UTF-8 byte order; integral numbers without a point; UUIDs lowercase | Every array element on one line however deep |
| 1 §8 | Where a broken reference degrades | At use: objects are kept as read and resolvers fall back (Preset 1 or the built-in copy, a zero-second cut, an empty slot); the report says so | Rewrite the object on load, which the next save would persist |
| 1 §8 | What the degrade for a missing transition is ("the channel default transition") | A zero-second cut whatever duration the rider carried, the ref carried as written (Adam, plan reading 5); the same for a missing audio transition | The channel's default transition object |
| 1 §6, 2 §7 | A `when` guard on a cue command; unknown commands and bad parameters | Cue commands use the macro's guarded shape; a cue guard is kept, flagged, never run; an unknown `cmd` keeps every parameter; a known `cmd` with bad parameters becomes `invalid`, kept whole, answered `noop` | Drop a cue guard silently; drop bad commands |
| 1 §8 | What "every object keeps an opaque bag" covers | Every object with fields of its own, written back with known keys winning; not the fixed value shapes (colour, frame, size, rate, outline, shadow, mask), the plain maps (layouts, fields, variations, overrides, replaced), non-media content, or the ShowState in `state/last.json`; commands keep theirs on the entry around them | A bag on every JSON object including value shapes |
| 1 §5, §6, §9 | Nulls versus omission | Catalog objects write every known key, nullable ones as `null`; command objects omit absent optionals and write `loop` only when true, as §6 and §9 show; a hand-written `"out": null` reads as absent and is normalised on the next save | Nulls everywhere, or omission everywhere |
| 1 §8 | Hard failures beyond malformed JSON and a too-new schema | A well-formed document of the wrong shape is unreadable the same way, naming the path inside the file; a too-old schema with no migration likewise; the rest of the root loads and a previous root's copy of the document stays in place | Skip a bad object inside a document and keep the rest |
| 1 §5, §8 | Unparseable or stray files | Dot files and `.tmp` files are skipped silently; a `.json` file the layout does not know is one info line; `media/`, `logs/` and `snapshots/` are not read | Ignore everything unparseable silently |
| 1 §10 | The schema-0 fixture | Invented for lists only: a bare-string `trigger` with `triggerMs` or `triggerTc` beside it and no `trackThrough`; the 0 to 1 migration ships in the table; every other kind reads from schema 1 | A test-only migration |
| 1 §8 | Duplicate numbers within a type | The first in document order wins at lookup; both are kept and written back; one line | Drop the later one |
| 1 §2, §5 | Local copies | `lists-local/NNN-slug.json`, identified by uuid; the copy has its own list uuid, keeps the master's cue uuids and the master's number, and is not renumbered with the master | New cue uuids at detach; or the master's uuid |
| 1 §2 | `decoderCap` | Nullable; null means the machine's `decoderCapDefault`; the first-run channels write 2 | Always 2 or 3 on the channel |
| 1 §2 | `builtIn` and `appliesTo` | `builtIn` on presets (§9) and on transitions 1–3, not on audio transitions; `appliesTo` derived from the transition type, not stored | A stored `appliesTo` |
| 1 §3 | The scheduler row of `keys.json` | One `bindings` array; a scheduler entry has `device: "scheduler"` and `when: {days, time}` in place of `key`, days as lowercase English names, time `HH:MM` | Two arrays |
| 1 §3 | `defaultRole` | The UX spec's roles: `editor`, `operator`, `librarian` | A free string |
| 1 §7 | The index documents' shape | `media-index.json`: `entries` in id order plus `replaced`; `media-local.json`: `entries` plus `overrides`; `tracks` and `crossfadeMs` only on audio sets | A map keyed by id |
| 1 §7 | The resolver | A replaced id means its replacement before either index is consulted; an override changes the path, not the entry; missing is a resolved path absent from the file list | Follow `replaced` only when no entry exists |
| 1 §4 | What renumbering rewrites | Also guard variables (`[Channel N …]`, `[Output N Stack]`, `[Stack N Blackout]`) and a preset's per-stack layout keys; not guard constants, not `state/last.json`, not a local copy's number | References in commands and objects only |
| 1 §4, §5 | A list save | `version` increments on save; the previous bytes go to `versions/NNN/vNNNN.json` under the previous version; a title change renames the file in the same save | Version on edit |
| 1 §2 | Macro scope | Machine-level when any command or guard names a stack or an output; audio outputs do not count | Count audio outputs |
| 1 §8 | Preset 1 | A reference to preset 1 is never broken (the built-in copy resolves it); its absence from disk is one `missingBuiltIn` line, as is a missing transition 1–3 | Report preset 1 like any missing preset |
| 3 §4 | Pool defaults | The expression's `loop` can ask for a loop, not refuse the pool's (`end hold` does that); the entry's `defaults.grade` is stored and checked but not applied, since §4 does not list it among the fall-backs; both tiers consulted, machine first | `defaults.grade` becomes a once grade rider |
| 1 §5 | The atomic write | A temporary named `.<name>.<random>.tmp` in the same folder, fsync, rename, folder fsync; a completed save sweeps stale temporaries of its own document | Leave temporaries until a launch sweep |

### Spec corrections proposed

- Spec 1 §8, reference checks: "the channel default transition" becomes "a zero-second cut";
  the code does that on Adam's instruction.
- Spec 1 §5, JSON rules: state the one-line rule (a container whose members are all scalars
  or empty containers) and lowercase UUIDs; the code and the fixtures do that.
- Spec 1 §8, hard failures: add "a document whose shape does not decode, naming where" to
  malformed JSON and a too-new schema; the code treats it so.
- Spec 1 §3, key bindings: name the scheduler entry's `device` value and the `days` and
  `time` forms; the code uses `"scheduler"`, lowercase day names and `HH:MM`.
- Spec 1 §7: name the index documents' top-level keys (`entries`, `replaced`, `overrides`);
  the code and the fixtures use them.
- Spec 3 §4 Media: one sentence that `loop` in the expression forces a loop and the pool's
  `defaults.grade` is not a fall-back; the code does that.
- Spec 1 §2 Macro: scope counts guards that name a stack or output; the code does that.
- `ARCHITECTURE.md`, `formats/`: could add "and the file adapter (`OFormats`)"; not changed
  by this session.

## Next

**Area 3 — Command vocabulary** (branch `area/commands`, its own Nimbalyst worktree session,
branched from `main` after Area 2 merges). The prompt, verbatim from `docs/build-order.md`:
the common preamble, then the area's own block.

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
Area: 3, command vocabulary. Spec: docs/specs/2-commands.md.
Build in core/: the canonical text grammar (§2), the full v1 vocabulary as Command
objects (§3), parse and print with parse(print(x)) == x (§4), validation and
results (§8), selection expansion and groups (§5), the OSC address mapping both
ways (§6, as pure functions; no sockets in core/), guards (§7), and the log entry
shape (§9). Tests from §10 first. Also close the Area 1 brief's deviation 2: the
command decoder accepts the bare cmd names Spec 1 §6 used before its correction
("next", "macro") on input and prints only the Spec 2 §3 object names.
```

Area 3 touches `core/Commands/Command.swift`, which Area 2 changed on its branch, so it
should start from `main` once Area 2 is merged rather than in parallel. Area 4 waits for
Areas 1–3 and the DeckLink SDK. The specs for the areas marked "Spec needed first" above
can be written in Cowork at any time; each already has its task in the Build tracker,
marked `spec needed`. Area 8's media-pool spec can now assume the index, the resolver and
the hash identity from Area 2 and specify only the rebuild walk, import by copy and posters.
