# Status

The one-page view. Every session starts by reading this page and ends by rewriting it
(`CLAUDE.md`, "Session contract"; `/wrap-up` does the rewrite). It lives on `main` and is
current on `main` after every session, even while an area's code waits on its branch. The
detail is elsewhere: the areas and their prompts in `docs/build-order.md`, one review brief
per area in `docs/reviews/`, one line per session in `CHANGELOG.md`.

## Areas

State is one of `not started`, `in progress`, `brief waiting for approval`, `merged`.

| # | Area | Spec | State | Last session, or what is left |
| --- | --- | --- | --- | --- |
| 1 | Channel state and projection (`core/`) | `specs/3-channel-state-and-projection.md` | brief waiting for approval | Built on `area/projection`, `swift test` green, brief at `docs/reviews/area-1-projection.md`. Left: Adam's `approved`; the merge, by hand where the branch also edited `CHANGELOG.md`, `CLAUDE.md` and `docs/build-order.md`; CI has not run on the branch. |
| 2 | Object model and library format (`core/`, `formats/`) | `specs/1-objects-and-format.md` | not started | Next. Reuses Area 1's types, so it starts after `area/projection` merges. Also closes the pool-defaults gap the Area 1 brief names. |
| 3 | Command vocabulary: grammar, parser and printer, validation, OSC mapping (`core/`) | `specs/2-commands.md` | not started | Builds on Area 1's `Command` enum, so after the merge; independent of Area 2. The parser must accept the bare Spec 1 §6 verbs (Area 1 brief, deviation 2). |
| 4 | Engine spike (`engine/`): headless OEngine over OSC, two channels, two stacks, three hours clean | `specs/4-render-pipeline.md` §15 | not started | Needs Areas 1–3 (the fixture library on disk, the vocabulary over OSC) and the DeckLink SDK in `vendor/`. Nothing in it runs unattended. |
| 5 | Render pipeline, the rest: 1080i weave, text cache, thumbnails, multiviewer, measurement | `specs/4-render-pipeline.md` | not started | After the spike passes every §15 criterion. |
| 6 | Stacks and presets: slots, boxes, text styles, resolution order, blackout and mute, offset +1 | `specs/1-objects-and-format.md` + presets-and-text spec | not started | Spec needed first (presets and text). |
| 7 | Output sinks: display per screen, DeckLink with weave, output transitions | `specs/4-render-pipeline.md` §10 | not started | After the spike. |
| 8 | Media pool: hash IDs, index, import by copy, poster frames, missing state | media-pool spec | not started | Spec needed first. |
| 9 | Cues, lists and playlists: write/clear/hold, Go and Time triggers, sections, linked items, live pointer, next | cues-lists-playlists spec | not started | Spec needed first. |
| 10 | Text editor: whole-list text document with cue breaks | edit-mode spec | not started | Spec needed first. |
| 11 | Variables: Time, Date, Timer and Popup slots, captions over OSC | presets-and-text spec | not started | Spec needed first. |
| 12 | Log and saving: command log with sources, continuous save, launch snapshots | log-and-saving spec | not started | Spec needed first. |
| 13 | Show-mode UI (`app/`): three columns, grid, strip, preview and multiviewer, tabs, top bar, keyboard | show-mode-ui spec | not started | Spec needed first; nothing in `app/` starts before the spike passes. |
| 14 | Edit mode, minimal: cue inspector with palette, stack editor, channel sheet, preset editor | edit-mode spec | not started | Spec needed first. |
| 15 | Macros, basic: command lists without guards, the clears tab | `specs/2-commands.md` | not started | After Area 3. |
| 16 | Audio, basic: routing to numbered outputs, gain | `specs/4-render-pipeline.md` §11 | not started | After the spike. |
| 17 | Settings: inputs, outputs, audio outputs, keys, media root, startup | settings section of show-mode-ui spec | not started | Spec needed first. |
| 18 | Operator lock: passcode in the Keychain, edit mode blocked | show-mode-ui spec | not started | Spec needed first. |
| v1.5 | After the pilot: runtime undo, library mode and local copies, NDI, live inputs, audio transitions, pre-flight report, optimize on import, macro guards and the scheduler, lookahead polish, distribution conventions | `docs/build-order.md` | not started | Specs wait until the pilot is scheduled. |
| v2 | Slide designer, timelines and clocks, custom transitions, CCLI reporting | `docs/build-order.md` | not started | Deferred. |

## Now

**Area 1, channel state and projection, on `area/projection`.** The code is done and
`swift test` is green; the review brief is written; the area stopped at waiting for Adam's
`approved`. Nothing from it is on `main`. The last session (docs only) added this page, the
session contract in `CLAUDE.md` and `/wrap-up`, and committed the Area 1 brief on `main`.

## Needs Adam

### Briefs waiting for approval

- **Area 1** — `docs/reviews/area-1-projection.md`. It asks:
  1. Approve with the spec corrections below applied? Recommended: yes. The wording items
     change no code on the branch; the pool-defaults gap goes to Area 2 and the `next`
     decoding to Area 3.
  2. Pause and resume: `play` after `pause` cannot be placed from `ShowState` alone.
     Recommended: leave `ShowState` as it is, let Spec 4 own per-instance playheads in the
     engine, and add one sentence to Spec 3 §4 Transport: "`play` after `pause` resumes
     from the engine's playhead; `startedAtFrame` is reset only by a write or `stop`".
     Alternative: a `pausedAtFrame` field, which would carry engine detail into lookahead
     and replay.
  3. Build order: keep Area 2 next (it fills in the rest of the Spec 1 types, the loader
     and the fixture library), then Area 3 on top of the `Command` enum as it stands.
     Alternative: Area 3 first.

### Spec interpretations made so far

Where a spec left more than one reading, what Area 1 chose, and the other reading. An
item stays here until Adam has answered it; the brief keeps the record afterwards.

| Spec | Left open | Chosen | Alternative |
| --- | --- | --- | --- |
| Spec 3 §2, §3 rule 8, §4 Slide | Whether `build` is a tracked attribute or part of slide content | A field on `SlideInstance`: content state, no origin, not reset at a list boundary | A `Tracked` attribute with origin and shadow |
| Spec 3 §4 Text, §9 row 5 | Identical text carrying a rider: pure `noop`, or do the riders apply? | Riders always apply; a write is `noop` only when nothing at all changes | Identical content is a pure `noop` (row 5 would fail) |
| Spec 3 §4 Decoder budget | The frame rate needed to turn a transition's ms into frames is not in the context | `ProjectionContext.rate` as `{num, den}`, ms rounded to the nearest frame | Assume 60 fps |
| Spec 3 §4 Decoder budget, §9 row 14 | What a cut does to the outgoing list | Every media write records the previous instance as outgoing, ending at the landing frame plus the transition's frames; a same-ref restart records nothing; only media enters the list | A cut records no outgoing instance (row 14 would not hold) |
| Spec 3 §6 effects table | No row for transport, end behaviour, lock or freeze, yet every command yields one result | A new `Effect.applied(Command)`: state changed with nothing to animate | Emit nothing (breaks totality) or `noop` (state did change) |
| Spec 3 §5 with Spec 2 §3 | `playlist "TITLE"` makes a playlist live without firing, which fits neither pointer shape | One `LivePointer` with optional fields; a loaded playlist has only `playlist` set and the first `next` fires cue 1 as a boundary | A third pointer shape for "loaded, nothing fired" |
| Spec 3 §6 | `machine` is "stacks, outputs, tracking switches", but `next` walks the playlist and resolves local copies | `Machine` also carries playlists, local lists and the default decoder cap; `Library` carries only the Spec 1 fields the projection reads | Put playlists and local copies in `Library`, or widen the context |
| Spec 3 §2 | `grade` has no "none" value beyond "the default grade is none" | `Tracked<Int>` with 0 meaning none, as Spec 2 §3's `grade 0` says | `Int?`, at the cost of every comparison |
| Spec 1 §6, Spec 2 §4 | The object form is given, the Swift shape is not | A `Command` enum with a case per vocabulary row and a hand-written `Codable`: `cmd` is `target.verb`, parameters are flat keys, riders are sibling keys, `Target` is a number or `all`, an unknown `cmd` decodes to `.unknown` | A struct of verb and parameter map; or failing to decode an unknown `cmd` |
| Spec 3 §4 | What a write asks for versus what is on the channel | Two types: `ContentExpression` (the request) and `ContentInstance` (the result, with landing frame, transport, end behaviour, missing) | One type for both |
| Spec 3 §4, §6 | When riders apply and in what order their effects appear | Riders apply before the transition is chosen, so a `track` transition rider governs its own write; `attribute` effects follow the `transition` effect; a redundant write still emits an `attribute` effect | Riders after the write; no effect on a redundant write |
| Spec 2 §3 `system clearall` | How a clear-all that passes lock clears | Each channel cleared with source `engine` and its own current transition, then attributes reset, in channel order | One cut to nothing with the default transition |
| Spec 3 §5 | `next` past an item whose list has no cues | Skipped like a header | A `noop` that stops on the empty item |
| Spec 3 §6 `boundary` | What "list entered, attributes reset" carries | `(list, reset: Bool)`; row 8's "no boundary reset" reads as `reset: false` | Per-attribute detail inside the boundary effect |
| Spec 2 §3 `stack N blackout` | "The output's blackout transition" when the stack is on several outputs or none | The first output by number currently showing the stack, else nil | Every showing output; or a setting on the stack |
| Spec 2 §3 popups | `clearafter` is a timer and timers are not state | `Effect.variable` carries `clearAfterMs` for the scheduler; `popups[N]` holds only the text | A deadline frame in state |
| Spec 2 §3 `audio N mute`, `channel N skip` and `back` | No home in `ShowState` | `passthrough`, like timers: audio-output mute is engine state (Spec 4 §11), audio sets are v1.5 | Add audio and set state to `ShowState` now |
| Spec 2 §7 guards | Where guard values read by name come from | State-derived values from the fold; `Timer N`, `Time`, `Date` from the context's `variables` closure; `Channel N Content` renders as "kind: label" | Every value from the context |
| Spec 1 §5 JSON | Swift writes integer-keyed maps as flat arrays | `IntKeyedCoding` writes objects with decimal string keys; `StackState.muted` is a sorted set | Swift's default encoding (breaks Spec 1 §5) |
| Spec 1 §10 fixture library | The on-disk library does not exist yet | `tests/OCoreTests/Fixtures.swift` builds it in code with fixed UUIDs | Build the on-disk library first (Area 2's job) |
| Spec 1 §6 with Spec 2 §3 | `macro` or `macro.run` as the command name | Decode both, print `macro.run` | Accept one name only |

### Spec corrections proposed

From the Area 1 brief, "Deviations and spec corrections". Each is what the spec says, what
the code does, and the fix proposed.

1. **Pool-item defaults.** Spec 3 §4 Media says in, out, loop, gain and sync fall back to
   the pool item's defaults; the context has no media index, so the code goes straight to
   none. Fix: Area 2 adds the media index to `ProjectionContext.library` and `write`
   consults it; until then the caller resolves defaults into the expression. The one
   functional gap.
2. **`{"cmd": "next"}`.** Spec 1 §6 shows it; the decoder accepts only Spec 2 §3's object
   names (`playlist.next`), so a Spec 1-style file loads `next` as `.unknown` and the
   projection answers `noop`. Fix: align Spec 1 §6's examples to the Spec 2 names, and
   Area 3's parser accepts the bare verbs on input.
3. **`build` in §2.** Listed as a tracked attribute; the code keeps it on the slide
   instance. Proposed wording for the §2 tracked-attributes row: `grade`, `transition`,
   `audioTransition`, `gain`, `chase` (reserved); and under Content: "`build` is part of
   slide content (§3 rule 8)".
4. **`applied` in §6.** Not in the effects table. Proposed row: `applied` — command —
   "State changed with nothing to animate (transport, end behaviour, lock, freeze); logged
   as `ok`".
5. **`rate` in §6.** `ProjectionContext.rate` is not in the context list. Proposed: add
   `rate` ("the machine's frame rate, `{num, den}`, so durations become frames").
6. **`machine` in §6.** Wider than written. Proposed: "`machine` (stacks, outputs,
   playlists and local copies, tracking switches, decoder cap default)".
7. **Minor.** `Effect.variable` carries `clearAfterMs` and `boundary` carries a Bool;
   readings rather than contradictions, but the §6 table could say so.

## Next

**Area 2 — Object model and library format** (branch `area/format`). The prompt, verbatim
from `docs/build-order.md`: the common preamble, then the area's own block.

```
Read docs/STATUS.md, then CLAUDE.md. Work on exactly one area from
docs/build-order.md, named below. Read its spec in full and only the sections of
other specs you need. Propose a plan before writing code and wait for my OK. Then
tests first, then the implementation, in small commits that name the spec section.
Every public function gets a doc comment quoting the spec section it implements.
When swift test is green, write the review brief from docs/reviews/TEMPLATE.md and
run /wrap-up, which commits the brief, the CHANGELOG.md line, the area's "in review"
status and docs/STATUS.md on main and leaves the code on the branch. Then stop.
Merge only when I write "approved".
```

```
Area: 2, object model and library format. Spec: docs/specs/1-objects-and-format.md.
Build in core/ (documents, loader, writer, validator, migrations) and formats/
(JSON schemas). Start by creating the fixture library in tests/fixtures/library-v1/
from the worked examples in §9, then the tests in §10 (round trip, identity,
cue addressing, validation report, migration, atomic writes, stack rule), then
the code. Reuse the types Area 1 created; extend, do not duplicate.
```

Areas 2 and 3 both build on Area 1's types, so neither starts until `area/projection` has
merged. Once it has, Area 3 (command vocabulary) depends only on the `Command` enum and
could run in parallel with Area 2 on its own branch; the brief recommends 2 then 3. Area 4
waits for Areas 1–3 and the DeckLink SDK. The specs for the areas marked "Spec needed
first" above can be written in Cowork at any time.
