# Spec 6: Presets and text

2026-11-04 · @Adam Granby · Status: accepted 2026-11-04, with Adam's answers in §12 · Builds on Spec 1 (§2 presets, boxes and text styles; §3 stacks), Spec 3 (§2 provenance, §4 text writes, §7 lookahead) and Spec 4 (§8 text; §9 the stack pass); written from the scope gaps doc's answers (P1–P14, R3, R4, C4, C5) and its review (P13; P12 with P5; P14)

Areas 6 and 11 build it.

## 1. Purpose and scope

This spec finishes how a channel lands on a stack and how text gets its look and its live values. Specs 1 and 4 decided most of it, and `main` has built much of that since Areas 2, 4 and 5. This page records what the scope gaps doc changed and settles what it left open. Area 6 builds §2–§4 and the first-run content of §9; Area 11 builds §5–§8 (§11).

**In scope:** stacks and slots once the offset moves to the box (P13); presets, boxes and Preset 1; field boxes that fall back to the list's metadata (P12), and the provenance that tells them which list; the text style's vertical anchor, units and overflow (P1–P3); fonts, bundled and installed (P14); the variable language and the v1 set (P5–P7, P11); timers that count down and up (P8, R3); popups and captions (P10); the timer and remaining-time feedback; the first-run library and stacks (P13); and the corrections all this makes to Specs 1–5 (§10).

**Out of scope:** the screens. The preset editor and text-style authoring belong to Spec 11 (§8, §9; Area 14, C4), and the Popups tab's timers group to Spec 10 §7 (P9). The first-run writer, which detects outputs and numbers them (S3), is Spec 10 §13's. Also out: popup templates (v1.5, S6); masks and negative offsets (v1.5); text-motion transitions and per-glyph animation (later; Spec 4 §8 keeps the door open); designed slides, whose text layers will resolve the same variables (v2); `[Timecode]` (v2); fonts from the media root (deferred, Spec 4 §8); and guards, which read some of the same values (v1.5, Spec 2 §7).

**Already settled, and kept as written** (C5):

- Spec 1 §2: the Preset (one layout per stack number, plus `"*"`), the Box (binding, frame, fit, an inline text style with `fromStyle`, transition, `transitionOnVariableChange`, fallback, grade) and the Text Style (its fields, a size in `pt` on a 1080-line canvas or in percent, variable-font axes).
- Spec 4 §8: Core Text layout, the two fit policies, per-line raster and the cache.
- Spec 4 §9: the resolution order, the three bindings, fit modes, fallback boxes, box transitions, per-box grade, opacity and mute.

**On `main`:** the stack pass with fit modes, opacity and mute; one `SlotResolver` shared by the live plan and the thumbnail job; the +1 slot, which becomes the +1 box, with its text rasterized one cue ahead; `[Time]`, `[Date]` and `[Popup N]` in static boxes only, behind the once-a-second gate, with any other bracketed name printing nothing; `popup N set` over OSC.

## 2. Stacks and slots

A slot is `{channel, preset, opacity, mute}`. Its `offset` moves to the box (§3, P13), so a channel appears at most once per stack again, as the UX spec first said. Everything else about a stack stands (Spec 1 §3): `slots` bottom to top, `base`, `defaultPreset` and `gammaBlend`.

**Duplicates.** The engine uses the first slot for a channel and ignores any later one. A later slot stays in the document as read and is reported on every load (Spec 1 §8), as `main` already does. An edit that names the channel's slot (Spec 5 §3) reaches the first.

With one slot per channel, a slot's mute and opacity belong to one channel. `stack N mute CHANNEL` (Spec 2 §3) names one slot without ambiguity, and ShowState keeps each stack's mutes as a set of channels, as `main` does (Spec 3 §2 is corrected to say so, §10). Blackout stays a mix at the sink (Spec 4 §9, §10), and `stack all blackout` arrives with Area 15.

**Resolving a slot** is unchanged (Spec 4 §9): the slot's preset, else the stack's default, else the channel's default, else Preset 1; then that preset's layout for this stack's number, else its `"*"` layout. Each box in the layout draws the slot's channel at the box's own offset (§3).

**No migration.** Removing the slot's `offset` changes a field's meaning, which would bump the stacks schema under Spec 1 §8. No app has written a stacks document outside this repository, so the schema stays 1 by exception, recorded here. Area 6 rewrites the fixtures that carry the old shape (§9), and the bench machine root, a copy of the spike fixtures, is copied again from them. A stacks document that still has `offset` on a slot keeps it as an unknown key (Spec 1 §8), which the engine ignores; an old +1 slot is then a duplicate.

## 3. Presets and boxes

**A box's offset.** The Box gains `offset`, an integer that defaults to 0 and is written on every box, 0 included (Spec 1 §5 writes every known key). At 0 the box draws its slot's channel as it is now. At +K it draws the channel as it will be once the next K cues have fired, in the state Spec 3 §7's lookahead folds. That fold crosses item boundaries, and past the playlist's end the box draws nothing, whatever its binding. The schema accepts −2 to +3, so v1.5 needs no migration. v1 draws 0 to +3 (P4), and a negative offset draws nothing until v1.5 adds the ring buffer. Outside −2 to +3, the reference report flags the box and it draws nothing.

**Offset boxes outside the live state.** In a projected state, such as a thumbnail or the cue inspector's canvas (Spec 3 §7's cue view), a +K box folds the next K cues of the same list from the cue being drawn. That fold has no playlist, so past the list's end the box draws nothing.

**An offset box shows a still.** As offset slots did (Spec 4 §9), a pixel box at an offset shows the pool item's poster frame, a text box shows the text in the lookahead state, and the box cuts rather than transitions. The engine rasterizes the text one cue beyond each offset box ahead of time, as `main` does for the +1 slot, so a `next` never waits on text. One slot can now show current and next text on one stack, which is what a confidence monitor wants (Preset 1, below).

**Fallback boxes** look only at earlier boxes with the same offset. A fallback body box at +1 draws when no earlier +1 box drew, whatever the boxes at 0 did (P13).

**Field boxes** draw a field of the channel's text content: the write's `fields` map, under the box's name (Spec 1 §2). If the write has no such field, a box named `title`, `author`, `copyright` or `ccli` falls back to the list's metadata of the same name (P12). A copyright slide is therefore a text write with no fields, under a preset whose boxes name those four. A preset with a `title` box also shows the song's title beside every lyric of that list, unless a write carries its own `title`.

- "The list" is the one §5 names for the content: the list whose cue wrote it, or the state's pointer for content no cue wrote.
- A field box draws only for text content. On media or an empty channel it draws nothing; designed slides add their tagged layers in v2.
- A field that is empty once its variables resolve (§5) hides the box, like any empty text.

**Static boxes** draw their own text, with its variables resolved, whatever the channel holds, even when it is empty. That is how a stage clock needs no content (UX spec). Slot mute, opacity and blackout apply to them as to any box, so `channel N clear` and `system clearall` leave a clock showing, and muting its slot hides it. At an offset, a static box draws only while the lookahead reaches that far.

**Preset 1** is built in and editable, and it can't be deleted, renumbered or swapped (Spec 5 §6). Its definition lives in code on `main` and changes with this spec. It holds two layouts:

- `"*"`, as before: a pixel box filling the frame, then a fallback body box.
- `"2"`, the confidence layout (P13): a body box at 0 for the current cue and a body box at +1 for the next.

A text channel on stack 2 with no other preset therefore shows its current and next text there, and stack 2 needs no default preset. Preset 1 is portable, so stack 2 means the confidence stack at every campus. A campus that puts its background video on stack 2 loses the video there, since the `"2"` layout has no pixel box, until it gives that slot a preset of its own (the scope doc's review of P13).

**The preset editor's warning** (UX spec, Spec 5 §6), about a stack default preset with no pixel box or no body box, counts only boxes at offset 0.

## 4. Text styles, fit and fonts

**Vertical anchor** (P1). The Text Style gains `verticalAlignment`, beside `alignment`: `top`, `center` or `bottom`, defaulting to `center` and written on every style, inline ones included. It places the block of lines in the box: the first line at the box's top, the block centred, or the last line at the box's bottom. A box has no override of its own. A box that needs a different anchor carries its own inline style, as it does for every other field (Spec 1 §2).

**Units** (P2). `outline.width`, `shadow.x`, `shadow.y`, `shadow.blur` and `letterSpacing` are points on the 1080-line canvas, scaled with the output's height like a `size` in `pt`. A style therefore looks the same on a 4K wall and a 1080p monitor. `lineSpacing` is a multiple of the font's line height (ascent, descent and leading), where 1.0 is normal, and `fit.minSize` is in points on the same canvas. `main` has drawn this way since Area 4, except for the padding of each line's bitmap. That padding is sized from the unscaled shadow, which can clip a shadow above 1080 lines, so Area 6 scales it too.

**Overflow** (P3). Text can still overflow in two ways: `shrinkToFit` doesn't fit at `minSize`, or the N lines of `maxLines` are taller than the box. Either way the engine draws at that size and keeps the whole lines that fit, counted from the top. The last one ends in an ellipsis, as `maxLines` already does when it cuts text, and the overflow is reported for the editor and pre-flight. An overflowing block starts at the box's top whatever its anchor, so the first lines show. Nothing draws outside the box except a kept line's own outline and shadow. P3 said to clip to the box, and whole lines are this spec's reading of it (choice T-8). Each policy ignores the other's field, as on `main`: `maxLines` never shrinks the text, and `shrinkToFit` has no line limit.

**Tabular digits.** A box whose text names `[Time]`, `[Timer N]` or `[Service In]`, itself or inside a popup it shows, lays out its digits with the font's tabular figures (`tnum`) when the font has them. A running clock then stays put instead of shifting sideways every second (choice T-10). The text job carries the flag, and the text cache's key includes it (Spec 4 §8).

**Fonts** (P14). The engine registers a set of OFL-licensed fonts bundled with it. It registers them for its own process, at launch and before the first raster, so a font such as DM Sans resolves at every campus with nothing installed. Installed fonts resolve as before.

- If a bundled font's PostScript name is also installed, the engine uses the installed copy and logs the clash once (choice T-7).
- A missing font falls back to the machine's `fallbackFont` and is recorded for pre-flight (Spec 4 §8). Pre-flight's "fonts not installed" now means fonts that are neither installed nor bundled.

The fonts and their licences sit together in the engine's resources, and which fonts to bundle is choice T-6. The app's font picker lists the engine's fonts, and the app registers the bundled ones for its own process to draw them (Spec 11 §8). Fonts in the media root stay deferred.

## 5. Variables

**Syntax.** A variable is a name in square brackets, then optionally a format, then, for a timer, optionally the word `overrun`: `[Time]`, `[Time HH:mm]`, `[Timer 1]`, `[Timer 1 overrun]`, `[Timer 1 mm:ss overrun]`. Names match in any case, but formats must match exactly. Doubled brackets print one bracket, so `[[Time]]` prints `[Time]` (UX spec). Brackets around anything that isn't a v1 name print as written, so a lyric's `[Chorus]` or `[x2]` shows unchanged, where `main` prints nothing (choice T-1). A timer or popup number above the machine's count is still a v1 name. It resolves empty and the reference report notes it, since presets travel between campuses with different counts.

**The v1 set** (P5, P6):

| Variable | Value | Default format |
| --- | --- | --- |
| `[Time]` | The wall clock, in the machine's time zone | The machine's `timeFormat`, `h:mm a` on first run |
| `[Date]` | Today, in the machine's time zone | `MMMM d` (choice T-9) |
| `[Timer N]` | Timer N's value (§6); empty while unset | `m:ss` |
| `[Popup N]` | Popup slot N's text (§7); empty while clear | — |
| `[Live Title]` | The list's `title` | — |
| `[Next Title]` | The title of the next list in the live playlist. It skips headers and items whose list is missing or has no cues, as `next` does, and is empty after the last list or with no playlist (Spec 7 §4) | — |
| `[Section]` | The cue's `section` | — |
| `[Cue Note]` | The cue's `note` | — |
| `[Copyright]` | The list's `copyright` | — |
| `[CCLI]` | The list's `ccli` | — |
| `[Service In]` | The time until the live playlist's service (below) | `m:ss` |

"The cue" and "the list" are those of the state being drawn (below). `[Timecode]` is v2.

**Formats** (P7) are a fixed set, so every campus renders alike:

| Kind | Formats | Examples |
| --- | --- | --- |
| Durations: `[Timer N]`, `[Service In]` | `m:ss`, the default (Spec 2 §4's clock style, with hours from an hour); `mm:ss`; `h:mm:ss` | `4:59` and `1:02:03`; `04:59` and `75:00`; `0:04:59` |
| `[Time]` | `h:mm a`, `HH:mm`, `h:mm:ss a` | `10:30 AM`, `10:30`, `10:30:15 AM` |
| `[Date]` | `MMMM d`, `EEEE, MMMM d`, `yyyy-MM-dd` | `November 8`, `Sunday, November 8`, `2026-11-08` |

- A format outside the set, or `overrun` on anything but a timer, renders with the default and is logged once per box. So does a machine `timeFormat` outside the `[Time]` set.
- Month and day names are English in v1.
- A countdown shows whole seconds rounded up, and a count-up shows them rounded down, so a countdown reads `0:00` exactly when it reaches zero.
- `overrun` makes a countdown show the time past zero after a minus sign, in whole seconds rounded down: `0:00` for the first second past zero, then `-0:01`, `-0:02` (§6).

**`[Service In]`** (P6, R4) counts down to the live playlist's service time: the playlist's new `serviceTime`, an optional `HH:MM` in the machine's time zone (§10). On a dated playlist it counts to that time on its `serviceDate`; on an undated one, to that time today. Once the time arrives it shows `0:00`, and an undated playlist starts counting again at midnight, toward the next day's time (choice T-3). It reads only the live playlist, whatever state is being drawn. It is empty when no playlist is live or the live one has no `serviceTime`. Like `[Time]` and `[Date]`, it reads the wall clock (a Spec 4 §2 correction, §10).

**Which state a value reads** (the scope doc's review of P12 and P5). Context values and list metadata come from the state being drawn: the live state, an offset box's lookahead state, or a thumbnail's projected state. They never come from whatever happens to be live, which would put the wrong song's title in a thumbnail or a +1 box.

- In text content, a value reads the content's provenance: the cue that wrote it and the list that cue was fired from. A write by a macro that a cue ran records that cue and its list, and a restored channel keeps the cue and list it had (Spec 3 §2 and §8, corrected in §10). Content no cue wrote, from the UI, a key, OSC, the API or the scheduler, reads the state's pointer instead.
- An identical text write from another cue or list still updates the provenance, with no transition. Song B's copyright slide therefore never shows song A's title just because their fields match (a Spec 3 §4 correction, §10).
- In a static box, a value reads the state's pointer: its cue and its list.
- `[Next Title]` reads the state's pointer in both cases, since only the pointer knows the playlist position. A projected state has no playlist, so in a thumbnail it is empty. `[Service In]` reads the live playlist.
- `[Time]`, `[Date]`, `[Timer N]` and `[Service In]` read the same in every state, and lookahead never runs a timer. A thumbnail shows them as they were when it rendered, and it is never redrawn because they change.
- `[Popup N]` reads the state's own popup text (Spec 3 §2), so a +1 box shows a popup that the next cue sets. The variables inside that text read the same state.

**Where variables resolve.** In static box text and in text content, wherever text is rendered (UX spec), and in a popup's text, one level deep (choice T-2). A variable inside a popup's text resolves when a box shows the popup, so `popup 1 set "Doors close in [Timer 1]"` counts down. It reads the same state as that box. A `[Popup N]` inside a popup's text prints as written, so resolution never goes deeper than one level.

**Empty values** (UX spec, P11). A variable with no value renders nothing, and a box whose whole resolved text is empty hides. Static text around an empty variable still shows: `Nursery: [Popup 1]` shows just "Nursery:" while the slot is clear, so the label belongs in the popup's text.

**When a box adopts a new value.** A box whose text names variables is laid out again only when its resolved text changes (Spec 4 §8). How soon depends on what changed:

- A context value changed by a fire shows at once (choice T-5). A change to the list's metadata, sections or notes by an edit already shows from the next frame (Spec 5 §2).
- A popup also shows at once, but at most ten times a second. A new value is adopted on the first frame at least 100 ms after the box's previous adoption, and the value adopted then is the newest (P10).
- The clock, a timer or `[Service In]` alone changes the box at most once per wall-clock second, the gate `main` has used since Area 5.
- A box's first value, and a value going empty, show at once, as on `main`.

A box with `transitionOnVariableChange` runs its box transition between the old text and the new; the rest swap (Spec 4 §8). A value that arrives while that transition still runs starts a new one from the incoming text, as `main` does. A popup box for announcements usually wants the flag on (Spec 1 §2), and a caption box, which changes several times a second, wants it off.

## 6. Timers

Timers are slots 1 up to the machine's `timers` count, which is 4 on first run. A higher number is rejected, as any unknown target is (Spec 2 §8). Timers live in the engine, outside ShowState (Spec 3 §2), and run on its monotonic clock (Spec 4 §2), so a change to the wall clock never moves them. Nothing about them is saved (Spec 1 §4): after a relaunch every timer is unset until a cue, a macro, a key or the operator sets it.

| Command | Effect |
| --- | --- |
| `timer N set DURATION` | Sets a countdown from DURATION, stopped |
| `timer N set DURATION up` | Sets a count-up from DURATION, usually `0:00`, stopped (R3) |
| `timer N start` | Runs it from its current value |
| `timer N pause` | Holds its current value |
| `timer N reset` | Returns it to its set value, stopped (choice T-11) |

`up` is new to Spec 2 §3's grammar. In the object form it is `"up": true`, written only when true, like `loop` (Spec 1 §5). A timer command that would change nothing yields `noop` (Spec 2 §8): `start` on a running timer, `pause` on one that isn't running, `reset` on a stopped timer already at its set value, and any command but `set` on an unset timer. Every timer command is logged with `undo: none`, and the projection passes it through (Spec 3 §6).

**Counting down** (P8). The timer runs from its set value toward zero, and at `0:00` its display holds. So `[Timer 1]` reads `0:00`, and the v1.5 guard `when [Timer 1] is 0:00` holds. Underneath, the timer keeps running past zero until it is paused, reset or set again. `overrun` shows that time (§5), the feedback reports it as negative milliseconds, and the timer's state stays `running` (§8). P8 says the timer stops at `0:00`; running on underneath is what lets `overrun` count (choice T-12).

**Counting up** (R3). The timer runs from its set value, with no limit, until it is paused, reset or set again: a stopwatch. `overrun` means nothing on a count-up and renders as the default.

## 7. Popups and captions

Popups are slots 1 up to the machine's `popups` count, which is 4 on first run, and their text lives in ShowState (Spec 3 §2). `popup N set "TEXT" [clearafter SECONDS]` and `popup N clear` change it (Spec 2 §3), and every box that names `[Popup N]` follows (§5). A slot number above the count is rejected (Spec 2 §8).

- **`clearafter`** clears the slot that many seconds after the set. A later `popup N set` replaces any pending clear with its own, or cancels it if it has none, and `popup N clear` cancels it too. The clear is logged as a `popup N clear` from source `engine` (Spec 2 §5), so replaying the log reproduces it.
- **Captions** (UX spec). An external captioning system sends `popup N set` over OSC as often as it likes, and a box on the broadcast stack shows `[Popup N]`. The engine does no caption processing of its own. A box takes a popup's new value at once, at most ten times a second (§5), so captions run at most a tenth of a second and a frame behind, not a line behind (P10).
- **Variables in popups.** A popup's text resolves its variables one level deep when a box shows it (§5, choice T-2), so `popup 1 set "Doors close in [Timer 1]"` counts down. Brackets around anything that isn't a v1 name still print as written (T-1), so a caption's `[MUSIC]` shows as sent.
- **Clear-all.** `system clearall` leaves popups as they are, since Spec 2 §3 and Spec 3 §3 define it on channels. `popup N clear` clears one slot, and the Clears tab's Clear Popups tile clears them all (choice T-4, Spec 10 §7).
- **The log.** Popup commands are runtime commands (Spec 2 §3), so each one is logged. A captioning system can send several a second, and Spec 9 §2 keeps those lines in full.

## 8. Feedback

Spec 2 §6 and §9 name the timer and remaining-time feedback; this section gives their values.

- **OSC.** `/o/timer/N` carries `s:` the value in the timer's default format and `i:` its value in milliseconds. On a countdown, `i` goes negative past zero; on a count-up, it includes the starting value. It is sent once a second while the timer runs, and after every timer command that changes the timer. Spec 2 §6 says only "on set" (§10). An unset timer sends `s:""` alone.
- **API.** The `timers` topic sends one event per timer on the same cadence, with the API's `seq` like every event (Spec 2 §9). `state` is `unset`, `stopped`, `running` or `paused`, and `direction` is `down` or `up`. An unset timer has `null` for `direction`, `setMs` and `valueMs`, and `""` for `text`.

```json
{ "type": "event", "topic": "timers", "timer": 1, "state": "running", "direction": "down",
  "setMs": 300000, "valueMs": 298000, "text": "4:58", "seq": 4830 }
```

- **Remaining time.** `/o/channel/N/remaining` (Spec 2 §6) is built in Area 11 as Spec 2 defines it: once a second while timed content plays, and only to clients that subscribed to that channel.
- **Popups.** `/o/popup/N` reports a set or a clear (Spec 2 §6), unchanged. The API's `popups` topic is Spec 10 §3's, with the other topics the app uses (S2).

## 9. First run

These are the first-run library and stacks (P13 and the review's note on it). They replace the UX spec's first-run rows for channels, Preset 1 and stack 2. The engine writes them on a fresh install, and detects and numbers the outputs (S3), as Spec 10 §13 says. Area 6 makes Preset 1's built-in definition and the fixtures match them.

| Object | First run |
| --- | --- |
| Channels | 1 Background (`usualContent` media); 2 Foreground (text); 3 Clock (`usualContent` any, default preset 2). All three are routed to audio output 1, as the UX spec routes every channel |
| Preset 1, Default | Built in. `"*"`: a pixel box filling the frame, then a fallback body box (Spec 1 §9). `"2"`: a body box for the current cue in the upper part of the frame, and a smaller grey body box at +1 below it |
| Preset 2, Clock | `"*"`: one static `[Time]` box in the top right corner |
| Text styles | 1 Body and 2 Caption, as in the fixtures, each with `verticalAlignment` `center` |
| Stack 1, Main | Channels 1 and 2, no default preset; output 1's default |
| Stack 2, Confidence | Channels 2 and 3, no default preset; on no output, so it shows in the multiviewer |
| Stacks 3 and up | One per further output, with channels 1 and 2, numbered as Spec 10 §13 says (S3) |

Channel 3's `usualContent` is `any`, so channel 2 stays the only text channel and the text editor's default (E1). On stack 1, channels 1 and 2 resolve to Preset 1's `"*"` layout through their default preset. On stack 2, channel 2 resolves to Preset 1's `"2"` layout and channel 3 to the Clock preset. The confidence stack therefore shows the current and next lyric with the time above them, and the clock needs nothing on any channel.

**The fixtures.** Area 6 rewrites both fixture roots to this shape:

- `tests/fixtures/library-v1/`, Spec 1 §10's first-run library and worked examples. It gains channel 3 and Preset 1's `"2"` layout. Preset 2 becomes Clock, replacing Confidence. Preset 3, Lower third, stays as the example of a preset with a per-stack layout and a grade, and its `title` box now falls back to the list's title (§3). A new preset 4, Credits, holds `title`, `author`, `copyright` and `ccli` boxes for the P12 tests. `stacks.json` becomes the one below, and the text styles gain `verticalAlignment`.
- `tests/fixtures/spike/`, the spike's configuration (Spec 4 §15), the same way. The soak scenario's confidence stack then shows the next lyric through Preset 1's `"2"` layout.

Fixture documents keep the fixed uuids they have, and new ones get fixed uuids in the same pattern, as Preset 1's is in code. The JSON Schemas in `formats/schemas/` (stacks, preset, text styles) change to match, since Spec 5 §6 checks edit paths against them.

**`library/presets/001-default.json`**: the `"*"` layout is Spec 1 §9's, with `"offset": 0` on both boxes. Beside it, the `"2"` layout:

```json
"2": {
  "boxes": [
    { "binding": { "kind": "field", "name": "body" }, "fallback": false,
      "fit": { "maxLines": 6, "minSize": 24, "policy": "shrinkToFit" },
      "frame": { "h": 0.56, "w": 0.94, "x": 0.03, "y": 0.11 }, "grade": null, "offset": 0,
      "textStyle": { "alignment": "left", "allCaps": false, "color": { "a": 1, "b": 1, "g": 1, "r": 1 },
                     "font": "HelveticaNeue-Bold", "fromStyle": 1, "letterSpacing": 0, "lineSpacing": 1.1,
                     "outline": { "color": { "a": 1, "b": 0, "g": 0, "r": 0 }, "width": 0 },
                     "shadow": { "blur": 0, "color": { "a": 0, "b": 0, "g": 0, "r": 0 }, "x": 0, "y": 0 },
                     "size": { "unit": "pt", "value": 64 }, "variations": {}, "verticalAlignment": "top",
                     "weight": 700 },
      "transition": { "ms": null, "ref": 1 }, "transitionOnVariableChange": false },
    { "binding": { "kind": "field", "name": "body" }, "fallback": false, ..., "offset": 1, ... }
  ],
  "mask": null
}
```

The +1 box matches the first apart from `offset` 1, its frame (`y` 0.7, `h` 0.27), the `maxLines` policy with 3 lines, a grey colour (0.7) and a size of 40 points.

**`library/presets/002-clock.json`**

```json
{
  "app": "0.1.0", "builtIn": false, "kind": "preset", "label": "Clock",
  "layouts": {
    "*": {
      "boxes": [
        { "binding": { "kind": "static", "text": "[Time]" }, "fallback": false,
          "fit": { "maxLines": 1, "minSize": 12, "policy": "shrinkToFit" },
          "frame": { "h": 0.09, "w": 0.28, "x": 0.69, "y": 0.01 }, "grade": null, "offset": 0,
          "textStyle": { "alignment": "right", "allCaps": true, "color": { "a": 1, "b": 1, "g": 1, "r": 1 },
                         "font": "HelveticaNeue-Medium", "fromStyle": 2, "letterSpacing": 0.5, "lineSpacing": 1.2,
                         "outline": { "color": { "a": 1, "b": 0, "g": 0, "r": 0 }, "width": 1 },
                         "shadow": { "blur": 0, "color": { "a": 0, "b": 0, "g": 0, "r": 0 }, "x": 0, "y": 0 },
                         "size": { "unit": "percent", "value": 4.5 }, "variations": { "wdth": 110, "wght": 500 },
                         "verticalAlignment": "center", "weight": 500 },
          "transition": { "ms": null, "ref": 1 }, "transitionOnVariableChange": false }
      ],
      "mask": null
    }
  },
  "number": 2, "schema": 1, "uuid": "c0de..."
}
```

**`library/channels.json`** gains channel 3:

```json
{ "audioOutputs": [1], "decoderCap": 2,
  "defaultPreset": 2, "defaults": { "audioTransition": 1, "gain": 0, "transition": 1 },
  "label": "Clock", "number": 3, "renderSize": "largest",
  "textThumbnail": "body", "usualContent": "any", "uuid": "3c3c..." }
```

**`machine/stacks.json`**

```json
{
  "app": "0.1.0", "kind": "stacks", "schema": 1,
  "stacks": [
    { "base": "black", "defaultPreset": null, "gammaBlend": false, "label": "Main", "number": 1,
      "slots": [ { "channel": 1, "mute": false, "opacity": 1, "preset": null },
                 { "channel": 2, "mute": false, "opacity": 1, "preset": null } ],
      "uuid": "5e5e..." },
    { "base": "black", "defaultPreset": null, "gammaBlend": false, "label": "Confidence", "number": 2,
      "slots": [ { "channel": 2, "mute": false, "opacity": 1, "preset": null },
                 { "channel": 3, "mute": false, "opacity": 1, "preset": null } ],
      "uuid": "6f6f..." }
  ]
}
```

## 10. Corrections to Specs 1–5

These are applied when this spec is accepted, as Spec 5's were. The scope doc's review already accepted the offset move, Preset 1's stack-2 layout, the vertical anchor, instant popups and the bundled fonts (`docs/STATUS.md`); the rest follow from this page.

The UX spec stays as written, as before. This spec departs from it in these places:

- Offsets live on boxes, not slots: its Stacks line ("an optional cue offset"), "Offset slots", "Lookahead (offset slots)", and the stack editor's offset column, which moves to the preset editor's box properties.
- Variables: context values come from the state being drawn, not only the live list and cue, and values change at §5's pace, not "every frame". Popup templates are v1.5 (S6).
- Preset 1 is editable as well as copyable, and it gains a `"2"` layout.
- Settings' "countdown-to-service from the playlist date" becomes the playlist's `serviceTime`.
- First run: channel 3, Clock; stack 2 is always the confidence stack, with no default preset; further outputs get stacks from 3 up.

**Spec 1**

- §2, Preset. "Preset 1 is built in with a single `"*"` layout: one pixel box filling the frame, then a fallback body box." becomes "Preset 1 is built in and editable, and can't be deleted, renumbered or swapped (Spec 5 §6). Its `"*"` layout is one pixel box filling the frame, then a fallback body box; its `"2"` layout is the confidence stack's: a body box for the current cue and one at +1 for the next (Spec 6 §3)."
- §2, Box. A new row: `offset`, an integer from −2 to +3, default 0, written on every box: "Draws the slot's channel as it will be after this many cues (Spec 6 §3); v1 draws 0 to +3." The `fallback` row's "Renders only if no earlier box drew" becomes "Renders only if no earlier box at the same offset drew".
- §2, Text Style. `verticalAlignment` (`top`, `center` or `bottom`; default `center`) joins the field list after `alignment`, and the paragraph gains: "`outline.width`, the shadow's `x`, `y` and `blur`, and `letterSpacing` are points on the 1080-line canvas, scaled like `size`; `lineSpacing` is a multiple of the font's line height."
- §3, Stack. "A slot is `{channel, preset (number or null), offset (integer, -2 to +3), opacity (0–1), mute (bool)}`. A channel appears at most once per stack at each offset (offset slots of one channel are distinct slots); the loader rejects duplicates." becomes "A slot is `{channel, preset (number or null), opacity (0–1), mute (bool)}`. A channel appears at most once per stack; the engine uses the first slot for a channel and reports the rest (section 8). A box's `offset` shows a channel at a later cue (section 2)."
- §3, Playlist. `serviceTime` (`HH:MM` or null, in the machine's time zone, read by `[Service In]`, Spec 6 §5) joins the fields after `serviceDate`. The cues-lists-playlists spec, which rewrites this paragraph, keeps it.
- §5, JSON rules. "write `loop` only when true" becomes "write `loop`, and a timer's `up`, only when true".
- §7. In Fonts, "v1 references fonts by PostScript name and uses whatever is installed" becomes "v1 references fonts by PostScript name and uses those installed or bundled with the engine (Spec 6 §4)". In the index table, "used by offset slots and thumbnails" becomes "used by offset boxes and thumbnails".
- §8, Reference checks. "fonts not installed" becomes "fonts neither installed nor bundled".
- §9. `channels.json` gains channel 3. `001-default.json`'s boxes gain `"offset": 0`, and it gains the `"2"` layout. `stacks.json` becomes Spec 6 §9's, and the note beneath it goes. The Clock preset is Spec 6 §9's.
- §10, Stack rule. "Duplicate channel-and-offset pairs in a stack are rejected; distinct offsets of one channel are accepted." becomes "A second slot for a channel in a stack is ignored and reported."

**Spec 2**

- §3, timers. `timer N set DURATION` becomes `timer N set DURATION [up]`, which "Sets a countdown, or with `up` a count-up, and stops it". `reset`'s effect becomes "returns to the set value and stops".
- §6. `/o/timer/N/set` takes `s:"up"` after the duration. The cadence of `/o/timer/N`, "Once a second while running, and on set", becomes "Once a second while running, and after every timer command that changes it; `i` is the value in milliseconds, signed for a countdown (Spec 6 §8)".

**Spec 3**

- §2, ShowState. "per-slot mutes" becomes "the muted channels".
- §2, Content. "`provenance` (the cue uuid that wrote it, or `restored`, or `ui`)" becomes "`provenance` (the cue uuid that wrote it and the uuid of the list it was fired from, also for a write by a macro the cue ran; or `restored`, keeping the cue and list it had; or the source kind, such as `ui`)".
- §4, Text. "If the fields are identical to the current text, the result is `noop`: no state change, no transition." becomes "If the fields and the provenance are identical to the current ones, the result is `noop`: no state change, no transition. Identical fields from another cue or list update the provenance alone, with no transition (Spec 6 §5)."
- §7. "**Lookahead for offset slots.**" becomes "**Lookahead for offset boxes.**", "A `+1` slot shows" becomes "A `+1` box shows", and "the slot is empty" becomes "the box is empty". The cue view paragraph gains: "An offset box in a projected state folds that many more cues of the same list, and draws nothing past its end (Spec 6 §3)."
- §8, Restores. "marks every restored channel's `provenance` as `restored`" becomes "marks every restored channel's `provenance` as `restored`, keeping the cue and list it had".

**Spec 4**

- §2. "the wall clock is read only to stamp log lines and resolve \[Time\]" becomes "the wall clock is read only to stamp log lines and resolve \[Time\], \[Date\] and \[Service In\]".
- §4 and §9. "Offset slots" becomes "Offset boxes". In §5's poster frame row, "For offset slots and thumbnails" becomes "For offset boxes and thumbnails".
- §8, Fit policies. "Horizontal alignment comes from the style; the style has no vertical anchor yet, so the lines are centred vertically in the box until the presets-and-text spec adds one (defaulting to centre, so nothing moves when it does)." becomes "Horizontal and vertical alignment come from the style (`alignment`, `verticalAlignment`). Text that overflows at `minSize`, or N lines taller than the box, keeps the whole lines that fit from the top, the last ending in an ellipsis, and reports the overflow (Spec 6 §4)."
- §8, Cache. The key "(field text, text style value, box pixel width, box pixel height, fit policy, output scale)" gains "tabular digits". "Lookahead pre-rasterizes the next cue's text for every due stack" becomes "Lookahead pre-rasterizes, for every due stack, the next cue's text and, for each offset box, the text one cue beyond its offset".
- §8, Variables. "and no more than once a second" becomes "at the pace Spec 6 §5 sets: at once for context values, at most ten times a second for a popup, and at most once a wall-clock second for the clock, timers and `[Service In]`".
- §8, Fonts. "v1 resolves PostScript names against installed fonts" becomes "v1 resolves PostScript names against installed fonts and the OFL fonts bundled with the engine, which it registers for its own process at launch (Spec 6 §4),".
- §9. The field row's source becomes "The cached line textures for (this channel's field text with variables resolved, or the list's metadata when the write lacks the field, Spec 6 §3; this box; this stack)". In **Fallback boxes**, "no earlier box in the same channel's group" becomes "no earlier box at the same offset in the same channel's group".
- §15. "the +1 offset slot" becomes "the +1 offset box". In the Configuration, "Channel 1 background, channel 2 foreground." becomes "Channel 1 background, channel 2 foreground, channel 3 clock.", and "plain-text stack default preset, channel 2 at offset 0 and +1, a static `[Time]` box" becomes "channel 2 through Preset 1's stack-2 layout (a current and a +1 body box) and channel 3's static `[Time]` box (Spec 6 §9)". "The confidence stack's +1 slot" becomes "The confidence stack's +1 box".

**Spec 5**

- §6, Results. "a preset used as a stack default without a pixel box or a body box" becomes "a preset used as a stack default without a pixel box or a body box at offset 0".

**ARCHITECTURE.md**

- "(boxes, text, offset slots)" becomes "(boxes, text, offset boxes)", and "The wall clock only stamps logs and resolves `[Time]`." becomes "The wall clock only stamps logs and resolves `[Time]`, `[Date]` and `[Service In]`."

## 11. Tests this spec implies

Written before the code, from this page, against the fixtures as Area 6 rewrites them (§9).

**Area 6**

- **Stacks.** A second slot for a channel is ignored, reported and kept in the document. `stack N mute CHANNEL` mutes that channel's one slot.
- **Offsets.** Body boxes at +1, +2 and +3 give Spec 3 §9 row 18's results, with nothing at +3 past the end. A negative offset draws nothing, and one outside −2 to +3 is flagged and draws nothing. An offset box cuts. In a thumbnail, a +1 box shows the list's next cue, and nothing past its last.
- **Fallback.** A fallback body box at +1 draws when the +1 pixel box draws nothing, whatever the boxes at 0 drew.
- **Preset 1 on stack 2.** The first-run confidence stack shows the current and next lyric and the time. On the playlist's last cue the +1 box is empty. The capture matches the projected state on every `next` (the spike's check, now on boxes).
- **Provenance.** A cue's write records its cue and list, and so does a write by a macro that cue ran. An identical text write from another list updates the provenance with no transition, and the same cue firing again stays a `noop` (Spec 3 §9 row 3).
- **Field fallback.** A text write with no fields, under preset 4, draws the list's metadata, and a write's own field wins. Back-to-back empty-field writes from two lists show the second list's metadata, live and at +1. Content from the UI falls back to the pointer's list. Media draws no field box.
- **Static boxes.** A static box draws on an empty channel and after `channel N clear`, hides when its slot is muted, and at +1 draws nothing past the end.
- **Anchor, units, overflow.** Goldens for top, centre and bottom. A style rendered at 1080 and 2160 lines matches within a pixel, shadow included. `shrinkToFit` at `minSize`, and `maxLines` taller than the box, keep the whole lines that fit from the top, end the last in an ellipsis, draw nothing outside the box and report the overflow.
- **Fonts.** A bundled font resolves with nothing installed. An installed font of the same name wins and is logged once. A missing font falls back and is recorded.
- **Fixtures.** The rewritten fixtures load and write back byte for byte (Spec 1 §10), and Preset 1's built-in definition matches `001-default.json`.

**Area 11**

- **Parsing.** A table of variable texts: names in any case, each format, `overrun` alone and after a format, doubled brackets, names that print as written, a timer number above the count resolving empty, and an unknown format falling back with one log line.
- **Values.** Each v1 variable is read from a live state, a +1 lookahead state and a thumbnail's state. Context values follow provenance in content and the pointer in static boxes. `[Next Title]` skips headers, is empty after the last list, and is empty in a thumbnail. A +1 box shows a popup the next cue sets.
- **`[Service In]`.** Dated and undated playlists, before, at and after the time, and across midnight. It is empty with no `serviceTime` and with no playlist live.
- **Adoption.** Popup sets at 30 a second are adopted no closer than 100 ms apart and always end on the newest value. Captions sent ten times a second each show within 100 ms and a frame. A clock box changes once a wall-clock second. A context value changes on the fire's own frame. First and empty values show at once.
- **Tabular digits.** A counting timer's line keeps its width from value to value, and the cache keeps a tabular and a proportional raster of the same text apart.
- **Timers.** Set, start, pause and reset, counting down and up. A countdown holds `0:00`, and `overrun` shows `0:00` for the first second past zero, then `-0:01`. A jump in the wall clock moves no timer. After a relaunch every timer is unset. The `noop` cases, and a timer number above the count rejected.
- **Popups.** `clearafter` clears and is logged from source `engine`, and a later set replaces or cancels the pending clear. A variable in a popup's text resolves, a `[Popup N]` inside it prints as written, and other bracketed text shows as sent. `system clearall` leaves popups.
- **Feedback.** `/o/timer/N` and the `timers` topic arrive once a second while a timer runs and after each command that changes it, with the values of §8. `/o/channel/N/remaining` arrives once a second, and only at clients that subscribed to that channel.
- **Parse and print.** `timer 1 set 0:00 up` round-trips (`parse(print(x)) == x`) and maps to OSC.

**What each area builds.** Area 6 builds §2–§4, Preset 1's built-in definition, the fixtures and schemas of §9, and the provenance's list with the identical-text rule in `core/` (Spec 3 §2, §4), which its field boxes need. Area 11 builds §5–§8, with `timer … up` in `core/`. Both are engine-side and can be built before the bench run. Area 11's context values read the provenance Area 6 adds, so Area 6 comes first.

## 12. Resolved choices

These are the places where the scope doc and Specs 1–5 left room and the draft of this spec chose.

**Answered 2026-11-04.** T-2 takes the alternative: a popup's text resolves its variables one level deep, and §5, §7 and §11 say so. T-1's answer, "Plaintext", is the draft's choice. Every other choice takes the draft's answer, and the page above reads accordingly.

| # | Choice | Draft said | Alternative | Answer |
| --- | --- | --- | --- | --- |
| T-1 | Brackets around something that isn't a v1 variable | Printed as written, so a lyric's `[Chorus]` or `[x2]` shows | Printed as nothing, as `main` does today | Plaintext |
| T-2 | Variables inside a popup's text | Shown as sent: nothing inside a popup resolves, so captions stay literal. The UX spec lists popup templates among the places variables resolve, but templates are v1.5 (S6) | Resolved one level, so `popup 1 set "Doors close in [Timer 1]"` counts down | Alternative |
| T-3 | `[Service In]` once the time arrives | Holds `0:00`; an undated playlist starts counting again at midnight, toward the next day's time | Counts to the next occurrence straight away (R4 as written), so it reads `23:59:59` as the service starts | Rec |
| T-4 | Clear-all and popups | Untouched: `system clearall` clears channels, as Specs 2 and 3 define it, and the clears tab can carry a "clear popups" macro | `system clearall` also clears every popup, so the panic key takes a wrong caption off. This changes Spec 2 §3, Spec 3 §3 rule 6 and §9 row 10, and the projection in `core/` | Rec |
| T-5 | How soon a context value shows after a fire | At once, so `[Section]` changes with the lyric | At most once a wall-clock second, with the clock: one gate, but up to a second late | Rec |
| T-6 | Which fonts are bundled | DM Sans alone, a variable font from thin to black | A small set: DM Sans, a serif and a condensed face for lower thirds | Rec |
| T-7 | A bundled font that is also installed | The installed copy wins, and the clash is logged once | The bundled copy wins, so every campus renders alike | Rec |
| T-8 | Overflow (P3's "clip to the box") | Whole lines: the lines that fit, the last ending in an ellipsis | Clip at the box's edge, which can cut a line through its middle | Rec |
| T-9 | `[Date]`'s default format | `MMMM d` (November 8) | `yyyy-MM-dd`, as `main` prints today, or `EEEE, MMMM d` | Rec |
| T-10 | Tabular digits in clock and timer boxes | On, whenever the box names `[Time]`, `[Timer N]` or `[Service In]` and the font has them | Off: digits keep the font's own spacing, and a centred clock shifts as it counts | Rec |
| T-11 | `timer N reset` | Back to the set value, stopped, like `set` | Back to the set value, still running if it was | Rec |
| T-12 | A countdown at zero | Shows `0:00` and keeps running underneath, so `overrun` can count and the feedback keeps coming | Stops at zero as P8 says (state `stopped`, feedback ends), while `overrun` boxes count on from the moment it stopped | Rec |
