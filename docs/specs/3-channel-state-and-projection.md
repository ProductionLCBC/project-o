# Spec 3: Channel state and projection

2026-10-25 · @Adam Granby · Status: accepted 2026-10-25 · Builds on Spec 1 (objects) and Spec 2 (commands); Spec 4 (render pipeline) consumes the state this spec defines

## 1. Purpose and scope

This spec defines what is on a channel at any moment, how commands change it, and the single function that computes it. That function, the projection, is a pure fold of commands over state: given a state and a list of commands it returns the next state and a list of effects, with no clock, no I/O and no Apple frameworks. The engine runs it live; the cue grid runs it from the top of a list to draw thumbnails; the confidence stack runs it ahead of the live position; a future timecode seek runs it to a point in time. One function, four callers.

**In scope:** the state model; tracked attributes and tracking rules; write semantics for every content kind and attribute; the live pointer and cue triggers as they affect state; the projection's signature, inputs and effects; the three bases it is run from; lock and sources; the test table.

**Out of scope:** how frames are produced from the state (Spec 4), where the clock comes from, media playhead arithmetic beyond recording when playback began, and runtime undo snapshots (v1.5; this spec only ensures the state is a plain value that can be snapshotted).

**Why pure.** A pure projection can be run thousands of times a second to draw thumbnails, run ahead for lookahead without touching the live engine, replayed from the log to reproduce a Sunday problem on a Monday, and unit-tested with a table of command sequences. It is also the first real code in the project and the safest place to learn Swift: no concurrency, no GPU, just values in and values out.

## 2. The state model

**ShowState** is one value holding everything the projection reads or writes: `channels` (a map from channel number to ChannelState), `outputs` (live stack per output), `stacks` (blackout flag and per-slot mutes), `pointer` (the live position, section 5), `armed` (a pending Time or advance-after trigger, or none), and `popups` (slot text, because popup writes change rendered text). Timers are not in ShowState; they advance with the clock and are read through the variable provider when a guard needs them.

**ChannelState** has three groups of fields, and the groups have different lifetimes.

| Group | Fields | Lifetime |
| --- | --- | --- |
| Content | `content` (an instance, below) and `provenance` (the cue uuid that wrote it, or `restored`, or `ui`) | Holds until the next write, across list boundaries; outgoing (the previous instance and the frame its transition ends, kept for the decoder budget) lives here too |
| Tracked attributes | `grade`, `transition`, `audioTransition`, `gain`, `chase` (reserved), `build` | Each holds until written again, or until a list boundary resets it to the channel default |
| Operator state | `lock` | Outside tracking entirely; never reset, never restored by undo |

Each tracked attribute is stored with how it was set: `{value, origin}` where origin is `default`, `tracked` (from a `track` write) or `once` (from a rider on the current content write). The origin is what lets the cue grid colour a chip as new, held or redundant, and what lets a `once` value fall back when the content changes.

**Content instances**

| Kind | Fields | Notes |
| --- | --- | --- |
| `empty` | none | What `clear` writes; the channel renders nothing |
| `media` | `ref`, `inMs`, `outMs`, `loop`, `gainOverride`, `syncOffsetMs`, `startedAtFrame`, `transport` (`playing`, `paused`, `stopped`), `endBehavior` (`loop`, `hold`, `clear`), `missing` (bool) | `startedAtFrame` is the engine frame on which playback began; the playhead is derived from it by the engine, never stored |
| `text` | `fields` (map) | No look of its own; presets render it |
| `slide` | `ref`, `build` (integer), `missing` | `build` defaults to the slide's final state |
| `input` | `input` (number), `frozen` (bool) | Live sources (v1.5) |

**Defaults** come from the Channel object (Spec 1): `defaults.transition`, `defaults.audioTransition`, `defaults.gain`; the default grade is none; the default build is final; `chase` defaults to off. A fresh ShowState has every channel `empty` with every attribute at `{default value, origin: default}`, every output on its default stack, nothing blacked out, and no live pointer.

## 3. Tracking rules

Tracking is the lighting-console idea that a cue only has to say what changes. These rules make it predictable.

1. **Each attribute tracks independently.** A cue that writes content and says nothing about grade leaves the grade exactly as it was, origin included.
2. **`track`****writes hold.** A `track` rider or a standalone attribute command sets `{value, origin: tracked}` and the value survives every later content write until something writes that attribute again or a boundary resets it.
3. **`once`****writes are scoped to their content.** A `once` rider sets `{value, origin: once}` for the duration of the content it rode in on. When the content next changes without its own rider for that attribute, the attribute falls back to what it would have been without the rider: the previous tracked value if one exists, else the default. The projection keeps that fallback as `shadow` beside the once value so the fall-back is exact, not recomputed.
4. **Content holds across lists; attributes reset at list boundaries.** When the live pointer enters a different list (section 5), every tracked attribute on every channel returns to `{default, origin: default}` unless the list being entered has `trackThrough` set, in which case nothing resets. Content is never touched by a boundary.
5. **Clear is content-only.** `channel N clear` writes `empty` and leaves every attribute as it was, so the next write inherits the tracked grade and transition. The clear itself dissolves to transparent using the channel's current transition attribute.
6. **Clear all resets.** `system clearall` writes `empty` to every channel and resets every tracked attribute to default. `channel N reset` resets one channel's attributes and leaves its content.
7. **Per-attribute tracking switches.** Machine settings can turn tracking off for an attribute. With tracking off, every write of that attribute behaves as `once` regardless of its stored scope, so a master authored with `track` riders still plays correctly on a machine that has tracking off; the editor hides the `track` option for that attribute.
8. **Build is an attribute of slide content.** A `build` rider or `channel N build K` changes the build index of the current slide; it has no meaning for other content kinds and is ignored with a `noop` effect.
9. **Lock is not tracked.** It is operator state, set only by `channel N lock` and `unlock`, and ignores boundaries, resets, clears and restores.

**What a chip colour means.** The cue grid asks the projection for each cue's state and the state before it. An attribute whose value changed and whose origin is `tracked` or `once` from this cue is *new*; one whose value is unchanged and was not written by this cue is *held*; one written by this cue to the value it already had is *redundant*, a write worth removing. Content follows the same three rules.

## 4. Write semantics

A write replaces the channel's content instance, applies its riders, and emits a `transition` effect that tells the engine what to animate between. The rules below decide what instance results and whether a transition happens at all.

**Media.** A new instance with `startedAtFrame` set to the frame the write lands on, `transport: playing`, and `inMs`, `outMs`, `loop`, `gainOverride`, `syncOffsetMs` taken from the content expression, falling back to the pool item's defaults, then to none. `endBehavior` starts as `loop` when the expression says loop, otherwise `hold`. If the same media ref is already on the channel, the instance restarts from its in-point and the effect is a dissolve from the current frame rather than from the previous content.

**Text.** A new instance with the written fields. If the fields are identical to the current text, the result is `noop`: no state change, no transition. Fields not written are absent, not inherited.

**Slide.** A new instance with `build` from the rider or the slide's final state. The same slide ref with a different build changes only `build` and emits a `build` effect (animate to that build), not a transition; the same slide and build is a `noop`.

**Input.** A new instance for the numbered input; writing the same input is a `noop`.

**Empty.** The clear. The transition effect runs from the current content to transparent.

**Missing media.** A ref whose file the resolver cannot find still produces the instance, with `missing: true`. The engine renders nothing for the pixel path and the strip shows the badge. The projection does not need the resolver; the caller passes a set of missing ids with the input.

**Decoder budget.** Each media write counts against the channel's cap: the incoming instance plus any outgoing instance still mid-transition. The projection tracks `outgoing` instances with the frame their transition ends, which it can compute from the transition duration and the landing frame. A write that would exceed the cap drops the oldest outgoing instance and emits `steppedOn` with the dropped ref; the engine cuts that content out immediately.

**Transition selection.** The effect's transition is, in order: the write's `once` rider, else the channel's current transition attribute (tracked or default). The same order applies to the audio transition. A `cut` emits a transition effect with zero duration so callers can treat every write uniformly.

**Attribute writes without content** (`channel N grade 5`, `channel N gain -6`, `channel N transition 2 500`) change only the attribute, with origin `tracked`, and emit an `attribute` effect. A grade change carries an optional duration: with none it applies on the next frame; with one, the engine interpolates each grade parameter from the old values (none counts as identity) to the new over that time, which is why the attribute effect carries ms. A gain change ramps over 50 ms in the engine to avoid clicks, an engine detail and not state.

**Transport.** `play`, `pause` and `stop` change `transport`; `stop` also resets the playhead by setting `startedAtFrame` to the landing frame and `transport: stopped`, which the engine renders as the poster frame. `end loop | hold | clear` sets `endBehavior`. These are `noop` on non-media content.

**Popups** write `popups[N]`; the effect is `variable` so boxes that opted into transitioning on change can do so.

## 5. The live pointer and triggers

**The pointer** is `{playlist, item, listUuid, cueUuid}` or, when a master was fired directly from the library, `{list, cueUuid}` with no playlist. It names the last cue fired, not a cursor: browsing in the UI never moves it. Firing any cue moves it there and makes that cue's list live.

**Firing** a cue means: compute the list boundary (below), run the cue's commands as one group with source `cue`, set the pointer, then arm the next trigger. A fired cue is logged once with its `fire` record even if every one of its commands was blocked by lock.

**List boundary.** A boundary occurs when the fired cue's `listUuid` differs from the pointer's current one, or when the pointer was empty. At a boundary, before the cue's commands run, every tracked attribute on every channel resets to default unless the list being entered has `trackThrough`. Firing a cue in the same list, in any order, is never a boundary.

**`next`****and****`previous`** operate on playlist positions: the cue after or before the pointer's, crossing item boundaries, skipping headers, and doing nothing past either end. With a library list live (no playlist), they stay inside that list; `next` on its last cue does nothing. Firing a playlist cue again resumes the playlist pointer there.

**Triggers** live on the cue being fired and arm after the fire:

| Trigger | Arms | Fires when |
| --- | --- | --- |
| Go | nothing | The operator or a command fires the cue |
| Time | `armed = {cue: next, at: fireFrame + ms}` on the following cue | The engine clock reaches `at` |
| Advance-after | the same, set by the firing cue | The engine clock reaches `at`; when both the firing cue's advance-after and the next cue's Time are set, the shorter wins and the editor warns |
| Timecode | nothing in v1 | v2 |

A manual fire of any cue disarms whatever is armed. A cue with a Timecode trigger ignores Time and advance-after aimed at it (v2). Untimed cues keep their timers and chain from whatever fired before them.

**Armed state is in ShowState** (`armed`) so lookahead can show what will fire and when, and so a restored state after undo carries no stale timer: restores always land with `armed` cleared.

**Section jumps** (`item N section "chorus"`) fire the first cue whose `section` matches, case-insensitive; no match is `rejected`.

## 6. The projection function

```swift
func project(_ state: ShowState,
             _ commands: [Command],
             context: ProjectionContext) -> (ShowState, [Effect])
```

**ProjectionContext** carries everything the fold needs that is not state and not a command, all of it plain data: `frame` (the engine frame the group lands on), `library` (channels, presets, transitions, grades, lists; read only), `machine` (stacks, outputs, tracking switches), `missing` (the set of media ids the resolver cannot find), `source` (Spec 2's source record for lock decisions), and `variables` (a closure or table that resolves `[Timer 1]` and friends for guards). Nothing in the context is mutable and nothing has a side effect.

**Commands** are the Spec 2 objects. The projection handles every command that touches ShowState: channel writes and attribute writes, transport, clear and reset, output and stack commands, popups, pointer moves (`next`, `previous`, `cue`, `item`, `list`, `section`, `playlist`), and `macro` by inlining the macro's commands with their guards. Commands that do not touch state (`timer`, `history`, `system preflight`, `system snapshot`, `edit`) pass through as a `passthrough` effect for the caller to act on, so the fold stays total: every command in, one result out.

**Effects** are what the engine and the UI act on. They are the only output besides the new state.

| Effect | Carries | Who acts |
| --- | --- | --- |
| `transition` | channel, from instance, to instance, transition ref, ms, audio transition ref, ms, offset | Engine starts the visual and audio transitions |
| `build` | channel, from build, to build | Engine animates the slide |
| `attribute` | channel, attribute, old, new, ms (grades only) | Engine applies the gain, or interpolates the grade over ms; UI updates chips |
| `stackSwitch`, `blackout`, `mute` | output or stack, old, new, transition ref | Engine runs the output transition |
| `variable` | popup slot, text | Engine re-rasterizes affected boxes |
| `boundary` | list entered, attributes reset | UI shows the reset in the strip |
| `pointer` | old, new, armed | UI moves the live marker; the scheduler arms or disarms its timer |
| `steppedOn` | channel, dropped ref | Engine cuts the content; strip flashes; log records it |
| `blocked` | channel, command | Log records it; the strip shows a lock glint |
| `noop` | command | Nothing, but logged |
| `passthrough` | command | The caller (engine, history, scheduler) handles it |

**Determinism.** Two calls with equal state, commands and context return equal results. The function never reads the clock (the frame is an input), never allocates outside the values it returns, and never touches a file, a socket or a GPU. The core module that contains it imports nothing from Apple frameworks, which also makes it the part that compiles unchanged on Windows if that day comes.

**Validation happens before projection.** The projection assumes commands have passed Spec 2 validation; it still guards every lookup and treats anything unexpected as `noop` rather than trapping, because a presenter must never crash on a bad cue.

## 7. The three bases

The same function, run from three different starting states.

**Cue view and thumbnails.** Start from a fresh ShowState, treat the list's first cue as a boundary into that list, and fold cue 1 through cue K. The result is what the default stack would show if the list ran from the start, which is the UX spec's definition of a cue thumbnail and of the chip colours. Results are cached per `(cue uuid, stack, library version)` and invalidated when the cue, any preset or any grade it references, or the list's `trackThrough` changes. The fold is cheap enough to run for a whole list on every edit; thumbnails themselves (Spec 4) render lazily from the cached states.

**Lookahead for offset slots.** Start from the live ShowState and fold the next K cues from the pointer, crossing item boundaries and applying list boundaries exactly as a real fire would, with `frame` held at the current frame so nothing appears to play. A `+1` slot shows channel N's content in the resulting state; a channel with no write in those cues shows what it has now, which is the "hold" behaviour a confidence monitor wants. Past the end of the playlist the slot is empty. Negative offsets (v1.5) read from a ring buffer of the ShowState after each fired cue, kept by the engine, not computed.

**Timecode seek** (v2). Fold the list's cues whose Timecode triggers fall at or before the target time, in order, from the state at the list's start, and apply the result in one step with every transition effect collapsed to a cut, so a seek never replays a minute of dissolves.

**Live.** The engine's own use is the fourth, trivial case: fold the group that just arrived onto the live state and act on the effects.

## 8. Lock, sources and restores

The projection needs one fact about where a command came from: whether lock applies. The context's `source.kind` supplies it.

- With `source.kind` of `cue` or `timeline`, a `write`, `clear` or tracked attribute write to a locked channel produces a `blocked` effect and leaves the channel unchanged. The rest of the group still runs.
- With any other source (`ui`, `key`, `osc`, `midi`, `macro`, `api`, `commandbar`, `scheduler`, `restore`), lock is ignored. A macro fired by a cue inherits `cue` as its source kind, so lock cannot be dodged by wrapping a write in a macro.
- `channel N lock` and `unlock` are themselves never blocked.

**Restores** (v1.5) replace ShowState wholesale with a snapshot taken before a runtime command. The projection is not involved except to re-derive effects: the engine diffs old and new state and synthesizes `transition` effects as cuts, `attribute` effects for every changed attribute, and a `pointer` effect, then marks every restored channel's `provenance` as `restored`. Lock values are copied from the current state, not the snapshot. `armed` is cleared.

**Operator lock** (the role, not the channel flag) never reaches the projection; it is enforced at the API boundary by refusing edit commands and edit undo.

## 9. Test table

Each row is one unit test, written before the projection. Frames are at 60 fps; channel defaults are transition 1 (cut), no grade, gain 0; `A`, `B`, `C` are media ids; `S` is a slide.

| # | Given | Commands | Expect |
| --- | --- | --- | --- |
| 1 | Fresh state, frame 100 | `channel 1 write media A` | Content A, `startedAtFrame` 100, playing; one `transition` effect empty to A, ref 1, 0 ms |
| 2 | After 1, frame 400 | `channel 1 write media A` | Same ref, `startedAtFrame` 400; `transition` effect marked restart from current frame |
| 3 | Fresh | `channel 2 write text "x"` twice | Second command yields `noop`; one state change total |
| 4 | Fresh | `channel 2 grade 5 track`, then `channel 2 write text "y"` | Grade 5 with origin `tracked` after both; content y |
| 5 | After 4 | `channel 2 write text "y" grade 6 once`, then `channel 2 write text "z"` | Grade 6 (`once`, shadow 5) after the first; grade 5 (`tracked`) after the second |
| 6 | Fresh | `channel 2 write text "y" transition 2 500 once`, then `channel 2 write text "z"` | First effect uses ref 2, 500 ms; second effect uses ref 1, 0 ms; attribute ends at default |
| 7 | Pointer in list L1, grade 5 tracked on channel 2 | Fire a cue in list L2 (`trackThrough` false) | `boundary` effect; grade default; content unchanged |
| 8 | As 7 but L2 has `trackThrough` | Fire a cue in L2 | No reset; grade 5 remains; no `boundary` reset list |
| 9 | Channel 1 playing A, grade 5 tracked | `channel 1 clear` | Content empty; grade still 5; `transition` effect to empty with the current transition |
| 10 | Several channels with content and tracked attributes | `system clearall` | Every channel empty, every attribute `{default, default}` |
| 11 | Channel 1 playing A, grade 5 tracked | `channel 1 reset` | Grade default; content A unchanged, `startedAtFrame` unchanged |
| 12 | Channel 2 locked | Cue group writes channel 2 | `blocked` effect; channel 2 unchanged; other channels in the group written |
| 13 | Channel 2 locked | Same write with source `osc` | Write applies |
| 14 | Cap 2; A playing; frame 100 | `write B transition 2 1000 once` at frame 100, then `write C` at frame 110 | After B: outgoing A ends at frame 160. After C: `steppedOn` A; outgoing is B; content C |
| 15 | Tracking switch for grade off | `channel 2 grade 5`, then `channel 2 write text "y"` | Grade 5 (`once`) after the first; default after the second |
| 16 | Pointer on the last cue of the last item | `next` | `noop`; pointer unchanged; nothing armed |
| 17 | Pointer on the last cue of item 3; item 4 is a header, item 5 a different list | `next` | Pointer on item 5 cue 1; `boundary` effect; header skipped |
| 18 | Live: channel 2 text y; next two cues write channel 2 z then nothing | Lookahead +1, +2 | Both resolve to z; +3 past the end resolves to empty |
| 19 | Fresh | `write slide S build 2`, then `write slide S build 3`, then `write slide S build 3` | `transition` then `build` 2 to 3 then `noop` |
| 20 | Cue 1 fired at frame 100; cue 2 has Time 5 s | fire cue 1, then `cue 7` manually at frame 200 | After fire: `armed` {cue 2, frame 400}. After manual fire: `armed` cleared |
| 21 | Cue 1 has advance-after 8 s; cue 2 has Time 5 s | fire cue 1 at frame 100 | `armed` at frame 400 (the shorter wins) |
| 22 | Channel 1 playing A | `channel 1 stop` | `transport: stopped`, `startedAtFrame` = landing frame; a text channel given `stop` yields `noop` |
| 23 | Any state | `timer 1 set 5:00` | `passthrough` effect; state unchanged |
| 24 | Any state and context | Same inputs twice | Identical outputs (determinism) |

## 10. The Swift shape

This is the first code in the repository, and it sets the pattern for the core.

**Module.** A Swift package target named `OCore` with no dependency on AppKit, Metal, AVFoundation or CoreAudio; Foundation is allowed only for `UUID`, `Date` parsing at the file boundary, and `Codable`. A build rule (a test that greps imports, or a package manifest that lists no Apple frameworks) fails the build if anything else creeps in. This is the portability rule from the Decisions tab made mechanical.

**Types.** Everything is a value type.

```swift
struct ShowState: Codable, Equatable, Sendable { ... }
struct ChannelState: Codable, Equatable, Sendable { ... }
enum ContentInstance: Codable, Equatable, Sendable { case empty, media(Media), text(Fields), slide(Slide), input(Input) }
struct Tracked<Value: Codable & Equatable>: Codable, Equatable { var value: Value; var origin: Origin; var shadow: Value? }
enum Command: Codable, Equatable, Sendable { ... }          // Spec 2 objects
enum Effect: Equatable, Sendable { ... }                     // section 6
struct ProjectionContext: Sendable { ... }                   // section 6
func project(_ state: ShowState, _ commands: [Command], context: ProjectionContext) -> (ShowState, [Effect])
```

`Codable` on ShowState is what makes snapshots, `state/last.json` and log replay free. `Equatable` is what makes the test table a list of `XCTAssertEqual` calls. `Sendable` is what lets the engine hand a state to the render thread without a lock.

**Rules for the agent writing it.** No classes in `OCore`. No `Date()` or clock reads; the frame is an argument. No `fatalError` or force-unwraps on anything that came from a file or a command; unknown input is a `noop` effect. Every public function has a doc comment that quotes the section of this spec it implements, so a reviewer can check code against spec one paragraph at a time.

**Tests this spec implies.** The 24 rows of the test table as individual tests; a property test that `project` is deterministic over random command sequences from the fixture library; a round-trip test that `ShowState` encodes and decodes to an equal value; a replay test that folds a recorded log from the fixture and arrives at the recorded final state; and the import-rule build check.

**Done means:** all of the above pass in CI on a hosted runner, with no Apple framework in the module, before any rendering code is written.

## Resolved questions

**Once shadows at a boundary: a boundary clears both value and shadow.** Here is what it looks like across two songs, following channel 1's grade. Song 1 wants a warm look (grade 5) for the whole song and a dramatic look (grade 7) for the bridge only; song 2 has no grades of its own.

| Fire | Command on channel 1 | Grade afterwards |
| --- | --- | --- |
| Song 1, cue 1 | `write media A grade 5 track` | 5, tracked |
| Song 1, cue 2 | `write media A` (chorus, no rider) | 5, tracked (held) |
| Song 1, cue 3 | `write media B grade 7 once` (bridge) | 7, once, shadow 5 |
| Song 1, cue 4 | `write media A` (last chorus, no rider) | 5, tracked (fell back to the shadow) |
| Song 2, cue 1, `trackThrough` off | boundary, then `write media C` | default (none): the warm look does not bleed into song 2 |
| Song 2, cue 1, `trackThrough` on (a medley) | no boundary reset, then `write media C` | 5, tracked: the medley keeps the look |

The case the question was really about: if song 1 ended on the bridge (grade 7 once, shadow 5) and song 2 were entered with `trackThrough` off, clearing only the value would leave a stale shadow of 5 that could never be reached, since nothing reads a shadow once the origin is default. Clearing both keeps the state honest. With `trackThrough` on, both survive, so song 2's first write without a rider falls back to 5, exactly as cue 4 did.

**Provenance** stays in ChannelState for v1: one UUID per channel, free to keep, and it makes the strip's "which cue put this here" instant.

**Lookahead across a boundary** shows reset attributes, as confirmed; the confidence stack reflects what will actually happen.
