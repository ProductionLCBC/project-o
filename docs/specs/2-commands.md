# Spec 2: Commands

2026-10-25 · @Adam Granby · Status: accepted 2026-10-25 · Builds on Spec 1 (objects and format); Spec 3 (channel state and projection) defines what channel commands do to state

## 1. Purpose and scope

Everything an operator, a cue, a macro, a key, a console or a remote app does to Project O is a command. This spec defines the command language once: its grammar, its v1 vocabulary, how commands are stored (Spec 1) and spoken (OSC, the API, the command bar), where they come from, and what happens when they run. Spec 3 defines what channel commands do to channel state; this spec defines everything up to that boundary.

**In scope:** the canonical text grammar; the full v1 runtime vocabulary; the mapping between text and command objects; sources and selection expansion; the OSC address scheme and feedback; macro guards; execution rules (validation, errors, lock, ordering); the log entry; the API envelope.

**Out of scope:** library edit commands (the editing spec defines their inverses and the edit log; this spec fixes only their shape), timeline and timecode commands (v2), and the UI's palette, which is a view over this vocabulary.

**Rules every command obeys**

- A command names its target by number, never by label. `channel 2 clear`, never `channel Foreground clear`.
- Every command has exactly one canonical text form and one object form, convertible both ways without loss.
- Commands are absolute. "Selected" is expanded to numbers before a command exists, so a macro, a cue or a log entry never depends on what someone had highlighted.
- Every input path emits the same vocabulary and nothing else. The UI composes and shows commands; it has no private verbs.
- A command either runs or is rejected with a reason before anything changes. There are no partial runs.
- Every executed command is logged with its source, and the log is the only history the app has.

## 2. Canonical text grammar

One command per line. Words are separated by spaces; case is ignored for keywords and significant inside quoted strings.

```
command   := target [number] verb [argument...] [rider...]
target    := channel | stack | output | audio | timer | popup | macro | history | playlist | list | item | system
verb      := a keyword from the vocabulary table
argument  := integer | decimal | duration | string | ref | keyword
rider     := transition REF [DURATION] SCOPE | audiotransition REF [DURATION] SCOPE
           | grade REF [DURATION] SCOPE | gain DECIBELS SCOPE | chase SCOPE | build INTEGER
scope     := once | track
```

Some verbs have no target number (`next`, `previous`, `undo`), and a few targets take two numbers (`item 4 cue 3`). The vocabulary table lists each exact form.

**Tokens**

| Token | Form | Examples |
| --- | --- | --- |
| integer | digits, optional sign | `2`, `-1` |
| decimal | digits with a point | `0.5`, `-6` (gain is decimal decibels) |
| duration | `MM:SS`, `H:MM:SS`, or a number of seconds; written to the object as ms | `5:00`, `0:30`, `1.5` |
| timecode | `HH:MM:SS:FF` | `01:00:00:00` |
| string | double-quoted, JSON escapes (`\n`, `\"`, `\\`) | `"Great is Thy faithfulness,\nO God my Father"` |
| ref | `media sha256:<hex>`, `slide:<uuid>`, `input N`, `text <string>` | `media sha256:9f2c...` |
| keyword | an unquoted word from a fixed set | `on`, `off`, `toggle`, `loop`, `once`, `track` |

**Content expressions** follow `write`: `media sha256:... [in DURATION] [out DURATION] [loop] [gain DECIBELS] [sync MS]`, `text "..."` for a body-only write or `text body "..." title "..."` for several fields, `slide:<uuid> [build N]`, `input N`, or `empty`. Hashes may be abbreviated to their first 12 hex characters in the command bar and are expanded on parse; stored and logged forms are always full.

**Riders** sit at the end of a write in any order, each ending in its scope. `once` applies to this write only; `track` holds until something writes the attribute again. A rider without a scope is an error, not a default, so the two meanings never get confused in a cue. Inside a media write, `gain DECIBELS` with no scope after it is the content's gain override; with a scope it is the rider. A standalone attribute write (`channel N transition`, `audiotransition`, `grade`, `gain`) is always tracked (Spec 3 §3 rule 2): the parser accepts a trailing `track`, rejects `once`, and prints neither.

**Examples**

```
channel 1 write media sha256:9f2c... loop transition 2 1.0 once
channel 2 write text "There is no shadow\nof turning with Thee"
channel 2 grade 5
channel 2 grade 5 2.0
channel 2 gain -6
channel 2 clear
channel 2 reset
output 1 stack 4
stack 2 blackout on
next
item 4 cue 3
list 42 cue 3
item 4 section "chorus"
timer 1 set 5:00
popup 3 set "Nursery: please come to room 12" clearafter 30
macro 12
```

## 3. The v1 vocabulary

The complete runtime vocabulary for v1. **Lock** says what happens when the target channel is locked: *blocked* means the command is refused when its source is a cue or a timeline and runs from any other source; *passes* means lock never applies. **Undo** is the history class: *runtime* commands snapshot channel state before they run (undo restores it, from v1.5), *none* are logged but not undoable. `N` is a channel number or the word `all`.

**Channels**

| Text form | Object | Effect | Lock | Undo |
| --- | --- | --- | --- | --- |
| `channel N write CONTENT [riders]` | `channel.write` | Writes content; riders write attributes once or tracked | blocked | runtime |
| `channel N clear` | `channel.clear` | Writes empty content; attributes untouched | blocked | runtime |
| `channel N reset` | `channel.reset` | Tracked attributes back to channel defaults; content untouched | passes | runtime |
| `channel N transition R [DURATION]` | `channel.transition` | Tracked transition write | blocked | runtime |
| `channel N audiotransition R [DURATION]` | `channel.audioTransition` | Tracked audio transition write | blocked | runtime |
| `channel N grade R` [DURATION] | `channel.grade` | Tracked grade write, interpolated over the optional duration (instant by default); `grade 0` means none | blocked | runtime |
| `channel N gain DECIBELS` | `channel.gain` | Tracked gain write | blocked | runtime |
| `channel N play`, `pause`, `stop` | `channel.transport` | Transport on the instance; stop is pause and rewind, poster frame stays | passes | runtime |
| `channel N end loop`, `hold`, `clear` | `channel.endBehavior` | What the instance does when media ends | passes | runtime |
| `channel N lock`, `unlock` | `channel.lock` | Operator state, outside tracking | passes | none |
| `channel N freeze on`, `off` | `channel.freeze` | Live sources only (v1.5) | passes | runtime |
| `channel N skip`, `back` | `channel.track` | Audio sets only (v1.5) | passes | runtime |

Also in the channel family: `channel N build K` (`channel.build`), which changes the build index of the current designed slide, is a `noop` on other content, passes lock, and is runtime-undoable.

**Stacks and outputs**

| Text form | Object | Effect | Lock | Undo |
| --- | --- | --- | --- | --- |
| `output N stack M` | `output.stack` | Switches the output's live stack with its switch transition | passes | runtime |
| `stack N blackout on`, `off`, `toggle` | `stack.blackout` | Mutes every slot with the output's blackout transition; video only | passes | runtime |
| `stack N mute CHANNEL on`, `off`, `toggle` | `stack.mute` | Mutes one channel's slot in that stack | passes | runtime |

**Playlist and library navigation**

| Text form | Object | Effect | Lock | Undo |
| --- | --- | --- | --- | --- |
| `next`, `previous` | `playlist.next`, `playlist.previous` | Fires the next or previous cue; crosses item boundaries; nothing past the end | passes (the cue's writes obey lock) | runtime |
| `cue N` | `playlist.cue` | Fires cue N of the live list | passes | runtime |
| `item N cue M` | `playlist.goto` | Fires that cue and makes its item live | passes | runtime |
| `item N section "NAME"` | `playlist.section` | Fires the first cue of that section in item N | passes | runtime |
| `list N cue M` | `list.goto` | Fires that cue in a library master; the list becomes live with lookahead confined to it | passes | runtime |
| `playlist "TITLE" [DATE]` | `playlist.load` | Makes a playlist live at its first cue without firing it | passes | none |

**Timers, popups and audio**

| Text form | Object | Effect | Lock | Undo |
| --- | --- | --- | --- | --- |
| `timer N set DURATION` | `timer.set` | Sets and stops | passes | none |
| `timer N start`, `pause`, `reset` | `timer.start`, `timer.pause`, `timer.reset` | Runs, pauses, returns to the set value | passes | none |
| `popup N set "TEXT" [clearafter SECONDS]` | `popup.set` | Sets the slot; every `[Popup N]` box updates | passes | runtime |
| `popup N clear` | `popup.clear` | Clears the slot | passes | runtime |
| `audio N mute on`, `off`, `toggle` | `audio.mute` | Mutes a numbered audio output; `audio all` for every one | passes | runtime |

**Macros, history and system**

| Text form | Object | Effect | Lock | Undo |
| --- | --- | --- | --- | --- |
| `macro N` | `macro.run` | Runs the macro's commands in order; each inner command is logged and judged on its own | per inner command | per inner command |
| `undo`, `redo` | `history.undo`, `history.redo` | Runtime or edit undo depending on the filter in view; operator lock allows runtime, blocks edit | passes | none |
| `history jump N` | `history.jump` | Jumps to a point within the current filter | passes | none |
| `system clearall` | `system.clearAll` | Clear content and reset attributes on every channel; the panic button, no confirmation | passes | runtime |
| `system preflight` | `system.preflight` | Runs the pre-flight report on the live playlist | passes | none |
| `system snapshot` | `system.snapshot` | Writes a library and machine snapshot now | passes | none |

**Edit commands** share the shape `edit TARGET N FIELD VALUE` (`edit channel 2 label "Lyrics"`), each carrying its inverse in the log entry. The editing spec defines them; this spec reserves the `edit` target so the grammar, the log and the API already accommodate them.

## 4. Text and object forms

The object form is what is stored (Spec 1) and sent over the API; the text form is what the command bar, the raw command view, the log view and OSC addresses use. One function each way, and `parse(print(x)) == x` for every object.

**Mapping rules**

- `cmd` is `target.verb` in camelCase; the target's number becomes a field named after the target (`"channel": 2`, `"output": 1`, `"timer": 1`). Two-number commands name both (`"item": 4, "cue": 3`).
- Keyword arguments become enum strings (`"state": "on"`, `"mode": "stop"`); numeric arguments keep their names from the vocabulary table (`"stack": 4`, `"db": -6`).
- Durations are written in text as `MM:SS` or seconds and stored as integer `ms`. Every spelling parses in every field; printing is canonical per field: in and out points and timers print clock style (`0:02`, `5:00`, `1:02:03` from an hour, `0:01.5` for a fraction), transition, audio transition and grade durations print seconds with a decimal point (`1.0`, `0.25`). Timecode stays a string.
- Content expressions become the `content` object defined in Spec 1 section 6; riders become the `transition`, `audioTransition`, `grade`, `gain`, `chase` and `build` fields with `scope`.
- Strings are JSON strings in both forms; the text form escapes them the same way JSON does.
- Printing is canonical: lowercase keywords, one space between tokens, full hashes, riders in the fixed order transition, audiotransition, grade, gain, chase, build. Any accepted spelling parses; only the canonical spelling is printed.

**Example, both ways**

```
channel 1 write media sha256:9f2c... in 0:02 loop transition 2 1.0 once grade 5 track
```

```json
{ "cmd": "channel.write", "channel": 1,
  "content": { "kind": "media", "ref": "sha256:9f2c...", "in": 2000, "loop": true },
  "transition": { "ref": 2, "ms": 1000, "scope": "once" },
  "grade": { "ref": 5, "scope": "track" } }
```

**Short forms** are accepted by the parser and expanded: `ch` for `channel`, `tr` for `transition`, abbreviated hashes, and a bare cue number in the live list (`7` for `cue 7`). None are ever printed.

## 5. Sources

Every command enters through one of these paths and is tagged with its source for the log and for lock decisions. No path has a private vocabulary.

| Source | How commands arrive | Notes |
| --- | --- | --- |
| `ui` | Buttons, clicks and drags in the operator app compose a command object and submit it through the local API | Selection expansion happens here, before submission |
| `key` | The key-binding table maps a key (with device) to one command; the scheduler is the same table keyed by day and time | Bindings are absolute: `channel 2 pause`, never "pause selected" |
| `osc` | OSC messages mapped one-to-one by the address scheme in section 6 | The primary external control path |
| `midi`, `streamdeck` | The binding table with a device column; a note, CC or button maps to one command | MIDI is v1.5 if cheap |
| `macro` | A macro's commands run in order; each inner command is logged with source `macro` and the macro number | A macro can call another macro; depth is capped at 8 and cycles are rejected at save |
| `cue` | Firing a cue runs its commands in order with source `cue`, the list and cue uuid | Subject to channel lock |
| `timeline` | v2; same rules as `cue` | Subject to channel lock |
| `scheduler` | Time-of-day entries in the binding table | Runs with source `scheduler` |
| `startup`, `shutdown` | The startup and shutdown macros from machine settings | Logged as such |
| `commandbar` | Typed text, parsed, shown canonically before Enter | Off by default |
| `api` | WebSocket clients, including the operator app itself over localhost | Section 9 |
| `restore` | Undo and history restores | Pass lock; show as "restored" in provenance |

One more source, `engine`, covers commands the engine issues to itself: the end-of-media `clear` from Spec 4, fallback and recovery actions. They are logged like any other, pass lock, and are never user-visible as buttons.

**Selection expansion.** `selected` is a UI token, never a command argument. When the operator presses a button that acts on the selection, the UI expands it to one command per selected channel at that moment (`channel 2 clear`, `channel 5 clear`) and submits them as a group, so the log shows exactly what happened and a macro recorded from the UI contains absolute numbers. Stack selection and channel selection are independent tokens with the same rule.

**Groups.** Commands submitted together (a cue's commands, a macro's, a UI expansion) carry a shared `group` id in their log entries, so undo treats them as one step and the history view shows them as one row that expands.

## 6. OSC

The OSC address is the text form with slashes: `/o/TARGET/NUMBER/VERB`, and the arguments are the rest of the command. Anyone who can read the vocabulary table can write the OSC without a second document.

**Addresses**

| Command | OSC |
| --- | --- |
| `channel 2 grade 5` | `/o/channel/2/grade` `i:5` |
| `channel 2 write media sha256:... loop transition 2 1.0 once` | `/o/channel/2/write` `s:"media sha256:... loop transition 2 1.0 once"` |
| `channel 2 clear` | `/o/channel/2/clear` (no arguments) |
| `output 1 stack 4` | `/o/output/1/stack` `i:4` |
| `stack 2 blackout toggle` | `/o/stack/2/blackout` `s:"toggle"` |
| `next` | `/o/next` |
| `cue 7` | `/o/cue` `i:7` |
| `item 4 cue 3` | `/o/item/4/cue` `i:3` |
| `timer 1 set 5:00` | `/o/timer/1/set` `s:"5:00"` or `i:300` (seconds) |
| `popup 3 set "text" clearafter 30` | `/o/popup/3/set` `s:"text"` `i:30` |
| `macro 12` | `/o/macro/12` |
| `system clearall` | `/o/system/clearall` |

**Argument rules.** Typed OSC arguments map positionally to the verb's arguments: integers for numbers and seconds, floats for decibels and decimal durations, strings for text and keywords. As an alternative for any command, a single string argument is parsed as the remainder of the text form, which is how a write with riders travels in one message; a single string is read as the remainder first and as the typed argument when that fails, so a caption's plain text still lands in `popup N set`. Both spellings reach the same command object; the log records the object. The address words are case-insensitive like keywords, and the `ch` and `tr` short forms expand there too. A value that does not survive a 32-bit float (`-6.1` dB) is sent and accepted as a double (`d`); integers and whole seconds are `i`.

**Bundles** run as one group (section 5), in order, and either all validate or none run.

**Feedback.** The engine sends state changes to every configured OSC target (machine settings) and to any client that registers with `/o/register s:host i:port`, which lasts 60 seconds and is renewed by repeating it. Feedback addresses mirror state, not commands:

| Address | Arguments | When |
| --- | --- | --- |
| `/o/live/playlist`, `/o/live/item`, `/o/live/cue`, `/o/live/label` | `s`, `i`, `i`, `s` | Live position changes |
| `/o/channel/N/content` | `s:kind` `s:label` | Content changes, including clear |
| `/o/channel/N/state` | `s` (`empty`, `playing`, `paused`, `held`, `missing`) | Transport or content changes |
| `/o/channel/N/remaining` | `i:ms` | Once a second while timed content plays, only to clients that subscribed to that channel's remaining time (see below) |
| `/o/output/N/stack` | `i` | Stack switches |
| `/o/stack/N/blackout` | `i:0 or 1` | Blackout changes |
| `/o/timer/N` | `s:formatted` `i:ms` | Once a second while running, and on set |
| `/o/popup/N` | `s` | Set or cleared |
| `/o/lock/N` | `i` | Channel lock changes |

High-rate feedback is opt-in per address: a client sends /o/subscribe s:"/o/channel/2/remaining" to start receiving it and /o/unsubscribe with the same address to stop; subscriptions expire with the client's registration. Everything else in the table is sent to every target on change. Any client may ask for a current value with `/o/query` `s:"/o/channel/2/state"` and receives the feedback message once. Errors go back to the sender as `/o/error` `s:address` `s:reason`.

**Ports** default to 8000 in; out targets carry their own host and port. The `/o` prefix is fixed so console maps written for one campus work at every campus.

## 7. Guards

Any command in a macro can carry one guard. A guard is a comparison between a readable value and a constant; the command runs only when it holds. There is no else and no loop: an else is a second line with the opposite guard.

```
guard := when VALUE OPERATOR CONSTANT | when VALUE is empty | when VALUE is not empty
value := [Timer N] | [Popup N] | [Time] | [Date] | [Live Item] | [Live Cue] | [Live Title]
       | [Channel N Content] | [Channel N State] | [Output N Stack] | [Stack N Blackout] | [Channel N Lock]
operator := is | is not | greater than | less than
```

Examples:

```
when [Timer 1] is 0:00 channel 2 clear
when [Output 1 Stack] is 2 output 1 stack 1
when [Channel 2 Content] is empty channel 2 write text "Welcome"
```

In the object form a guard is a `when` field: `{"var": "Timer 1", "op": "is", "value": "0:00"}`. Values compare as durations when both sides parse as durations, as numbers when both parse as numbers, otherwise as case-insensitive strings. `[Channel N Content]` reads as the content kind plus its label (`"text: Verse 1"`), so `is empty` is the useful comparison.

Guards are evaluated at the moment the command would run, inside the macro's group, against the state as earlier commands in the same group have changed it. The palette shows a guard as a chip; the raw view shows the `when` clause. Guards on cue commands are reserved in the schema and rejected by the v1 validator, so the field exists without the behaviour.

## 8. Execution semantics

A command passes through four stages: parse, validate, execute, log. The first two can reject; the last two cannot fail silently.

**Validate** checks, in order: the target number exists (or is `all`); referenced objects exist (a preset, a transition, a macro); arguments are in range (gain within ±60 dB, offsets within ±1000 ms, opacity 0–1); content references resolve in the media index (a missing file is allowed and produces the missing state, an unknown id is rejected); macro depth and cycles. A group validates as a whole: one bad command rejects the group, and the rejection names the command and the reason.

**Lock.** A channel's lock blocks `write`, `clear` and tracked attribute writes whose source is `cue` or `timeline`. The blocked command is logged with result `blocked` and the cue still counts as fired; its other channels run. Every other source passes. Lock never enters tracking and is never restored by undo.

**Missing media.** A write of an id whose file is missing succeeds: the channel enters the missing state, shows the badge, and renders nothing for the pixel path while text fields, if any, still render. Pre-flight is the place this is meant to be caught.

**Decoder budget.** A write that would exceed the channel's decoder cap cuts the oldest content out, logs a `steppedOn` event with the write, and flashes the strip's transition bar red.

**Ordering within a group.** Commands run in array order, and later commands see earlier ones' effects. Within one cue the convention is content writes in channel-number order; the editor keeps that order and the validator does not require it.

**Timing.** Commands take effect on the next engine frame boundary after they are accepted, so a group of writes lands on the same frame. A `transition` rider's duration starts at that boundary; an audio transition offset is measured from the same point, which is what makes J and L cuts identical from a key, a Time trigger or timecode.

**Idempotence rules from the UX spec** are honoured at execution, not at validation: writing the media already on a channel restarts it from its in-point with a dissolve from the current frame; writing identical text is a no-op with no transition; writing the same designed slide with a different build index animates to that build.

**Results.** Every executed command yields one of `ok`, `blocked`, `noop` or `steppedOn`; a rejected command yields `rejected` with a reason and is logged only at the API and command-bar boundary, never in the runtime log.

## 9. The log entry and the API envelope

**Log entry.** One JSON line per executed command, appended to the day's log file in the machine root. The history view is this session's slice of it; runtime undo (v1.5) reads the `snapshot` reference.

```json
{ "ts": "2026-11-01T09:14:03.117-05:00", "seq": 4821, "group": "g-7f1a2b3c",
  "source": { "kind": "cue", "list": "a9f0...", "cue": "11aa...", "playlist": "2b2b..." },
  "kind": "runtime", "undo": "runtime", "result": "ok",
  "command": { "cmd": "channel.write", "channel": 1, "content": { "kind": "media", "ref": "sha256:9f2c..." } },
  "text": "channel 1 write media sha256:9f2c...",
  "snapshot": "s-4821",
  "fire": { "listTitle": "Great Is Thy Faithfulness", "ccli": "18723" } }
```

`fire` appears only on the first command of a cue group and snapshots the list's title and CCLI number at fire time, since masters change later; CCLI reporting is a query over these lines. `kind` is `runtime` or `edit`; edit entries carry `inverse`, another command object, and `undo: "edit"`. `group` is `g-` and eight hex characters, made by the engine. A macro's own line is logged with `undo: "none"`, followed by each inner command under the same group with source `macro` and the macro's number; a cue fired by `next` or any other navigation is logged as the navigation line, then the cue's commands as their own cue group. A command rejected at the API or command-bar boundary is answered with result `rejected` and a `reason` of the form `code: message`; it never reaches the runtime log. Navigation that only browses (not in the vocabulary above, UI-only) is logged with `undo: "none"`.

**API envelope.** The WebSocket API carries the same objects. A client sends a request and receives a response with the same `id`; the engine pushes `event` messages for state changes to subscribed clients. The operator app is a client of this API over localhost.

```json
{ "id": 17, "type": "command", "command": { "cmd": "channel.clear", "channel": 2 } }
{ "id": 17, "type": "result", "result": "ok", "seq": 4822 }
{ "id": 18, "type": "commands", "commands": [ ... ], "group": true }
{ "id": 19, "type": "subscribe", "topics": ["live", "channels", "timers", "commands"] }
{ "type": "event", "topic": "channels", "channel": 2, "state": "empty", "content": null, "seq": 4822 }
{ "id": 20, "type": "query", "what": "state" }
```

**Auth and discovery.** The engine listens on the LAN with a token from the Keychain; the first message on a connection must be `{"type": "auth", "token": "..."}` or the socket closes. The service advertises over Bonjour as `_projecto._tcp` with the machine's campus name, so a remote finds it without an address. Nothing listens beyond the local network, and there is no cloud relay.

**The****`commands`****topic** streams every executed command object with its sequence number to subscribers. It exists for two future uses that cost nothing to reserve: a warm-standby engine on a second Mac that subscribes and applies the same commands against the same library, and external loggers or CCLI tooling that want the fire stream live rather than from files.

**Versioning.** The envelope carries `"api": 1` in the auth reply. Adding fields never bumps it; changing a field's meaning does.

## 10. Tests this spec implies

- **Round trip.** For every row of the vocabulary table, a text example parses to the expected object and prints back to the canonical text; `parse(print(x)) == x` over a corpus that includes every rider, every short form, abbreviated hashes, escaped strings and both duration spellings.
- **Rejections.** Table-driven: unknown target, missing rider scope, out-of-range gain, unknown media id, macro cycle, guard on a cue command. Each yields `rejected` with the documented reason and nothing changes.
- **Selection expansion.** A UI action on channels {2, 5} produces exactly `channel 2 ...` and `channel 5 ...` in one group, in number order.
- **OSC mapping.** Every vocabulary row maps to its address and back; typed-argument and single-string forms produce the same object; a bundle with one invalid message runs nothing.
- **Feedback.** Each state change in section 6 emits exactly one message per registered target; `/o/query` returns the same payload; registration expires after 60 seconds without renewal.
- **Lock.** A locked channel refuses `write`, `clear` and tracked attribute writes from `cue` and `timeline` sources, logs `blocked`, and accepts the same commands from every other source.
- **Groups.** A cue's commands land on one frame boundary; a macro's commands run in order with each inner command logged under the macro's group id.
- **Log.** Every executed command produces one line with the fields in section 9; the first command of a cue group carries `fire`.
- **API.** A connection without auth closes; a command yields a result with the same id; subscribed clients receive events with monotonic `seq`.

## Resolved questions

- **`cue N`** fires in the live list, never the browsed one.
- **`audio all mute`** is a first-class command form; nothing in the vocabulary depends on built-in macros, which may change.
- **Bonjour service name** `_projecto._tcp` is a placeholder that follows the product name.
- **Per-channel remaining time** is opt-in: a client subscribes per channel with `/o/subscribe` (or the API's `subscribe` with a channel list) and receives it once a second only while subscribed, so nothing is chatty by default.

Correct
