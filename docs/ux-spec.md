# Project O — UX and system design spec

Oct 24, 2026 · @Adam Granby

## Overview and principles

Project O is a Metal-native macOS presenter with DeckLink output, built on a small set of numbered objects and one command vocabulary; the UI is a thin layer over that vocabulary. Content flows cue → channel → stack → output. A cue writes content to channels, each channel renders once to a texture, each output composites its own ordered stack of channels.

- Everything is a command. Keys, OSC, MIDI, Stream Deck, macros, cues and timecode all emit the same vocabulary; the UI composes and shows commands but never does anything the vocabulary can't.
- Numbers are identities, labels are display. Channels, stacks, presets, grades, transitions, macros, lists, cues, inputs, outputs, audio outputs, timers and clock sources are each numbered within their type. Renumbering updates internal references and warns about external ones.
- Portable versus machine-level. Channels, lists, presets, grades, transitions and portable macros travel with the library. Stacks, outputs, inputs, playlists and key bindings stay with the machine. The two meet by number, so input 3 and stack 1 mean the same thing at every campus.
- Nothing edits live. What is on a channel is an instance of a cue; any edit takes effect on the next fire.
- Tracking. Channel state is a set of attributes (content, grade, transition, audio transition, gain, chase). A cue writes some and holds the rest. Tracked attributes reset at list boundaries.
- Render once, composite per output. Transitions and grades happen inside the channel texture; stacks, previews and thumbnails are composite and downscale passes.
- Average users see actions, power users see commands. The command bar and raw command lists are optional and off by default, panels carry no tutorial text, and actions beyond the primary ones live in right-click menus.

&#91;embedded content: content flow · cue to channels to stacks to outputs\]

Each channel renders once; stacks pick an order per output, and an unassigned stack such as Confidence still renders for the multiviewer. Audio never passes through a stack.

## Channels and content kinds

A channel is a numbered, content-agnostic route that renders once to an RGBA texture; every stack samples that texture. Two ship by default: channel 1 (background) and channel 2 (foreground). Users add, rename and renumber the rest.

**Channel definition (portable, in the library)**

- Number (stable identity, gaps allowed; the strip's default view orders by number) and label.
- Default preset (see Outputs, stacks and presets).
- Defaults that tracked attributes start from: transition, audio transition, gain.
- Decoder cap: 2 by default, 3 as an option for channels that carry video.
- Audio routing: which numbered audio output(s) this channel feeds.
- Thumbnail style for text content, and a usual-content hint the cue picker uses.

**Channel state at runtime (tracked per attribute)**

- Content, grade, transition, audio transition, gain, chase, and build for designed slides.
- Lock is operator state, outside tracking.

**Content kinds** are disjoint in what they provide, so a preset box always knows what it can draw.

| Kind | Provides | Notes |
| --- | --- | --- |
| Media file (video, image) | Pixels, plus audio if the file has a track | Referenced by content hash |
| Audio-only media | Audio | No picture side to transitions |
| Text | Fields: body, title, copyright, reference, custom | No look of its own; presets render it |
| Designed slide | Pixels; a text layer with a field tag also provides that field | Referenced by embedded UUID; rendered live so builds can animate |
| Live source (`input N`) | Pixels, plus audio if present | NDI, SDI, camera, capture |

Audio never passes through stacks. It routes from the channel to numbered audio outputs, including each SDI output's embedded audio.

**Variables** are live text values that resolve wherever text is rendered: text content, preset box text, designed-slide text layers and popup templates. They update in place every frame.

- Syntax: type and number in square brackets, `[Timer 1]`, `[Popup 1]`; system values have no number: `[Time]`, `[Date]`, `[Timecode]`, `[Service In]`. An optional format follows the name: `[Timer 1 mm:ss]`, `[Time h:mm a]`. Doubled brackets print a literal bracket.
- Context values come from the live list and cue: `[Live Title]`, `[Next Title]`, `[Section]`, `[Cue Note]`, `[Copyright]`, `[CCLI]`.
- Timers and popups are command-driven: `timer 1 set 5:00`, `timer 1 start`, `popup 1 set <text>`, `popup 1 clear after 30`.
- A popup slot can be set over OSC like any command, which is how captions work: an external captioning system sends `popup 3 set <text>` and a box on the broadcast stack shows `[Popup 3]`. The app does no caption processing of its own.
- An empty variable renders nothing, and a box whose resolved text is empty hides, so a Messages channel shows nothing until a popup is set.
- Variable updates render in place without a transition by default; a field box can opt into transitioning when its text changes, which a popup box wants and a timer box doesn't.
- A preset box can carry static text with variables (`[Time] · [Timer 1]`), so a stage clock needs no content on any channel.

## Cues, triggers and tracking

A cue is an ordered command list with a label, section, note and thumbnail. A channel write is just one more command, so firing a cue means running its commands, and the cue editor and macro editor are the same component.

**Three states per channel per cue**

- Write: content goes to the channel.
- Clear: empty content goes to the channel (clear is a write).
- Hold: the cue says nothing about the channel; it keeps what it had. Hold is the default for every channel in a new cue.

**Attribute writes** (grade, transition, audio transition, gain, chase, build) ride on a channel write in one of two forms: this cue only (a parameter on the write) or from here on (a tracked write that holds until something writes the attribute again).

**Triggers** live on the cue being fired.

| Trigger | Fires when |
| --- | --- |
| Go | The operator (or a command) says so |
| Time | N seconds after the previous cue's trigger |
| Timecode | The list's clock reaches HH:MM:SS:FF |

- Advance-after on the firing cue is the same timer seen from the other side. When a pair is set, the shorter wins and the editor warns.
- A manual Go disarms any pending timer.
- A cue with a Timecode trigger ignores Time and advance-after aimed at it. Untimed cues keep their timers and chain from whatever fired before them, so timecoded anchors can be followed by untimed cues.
- "When the video ends" is not a trigger. The editor can prefill a Time value from the previous cue's media duration, as a copied number.

**Tracking rules**

- Each attribute tracks independently; a cue that writes content and says nothing about grade leaves the grade alone.
- Tracked attributes reset to channel defaults when the live pointer enters a new list, unless the list is marked track-through. Content holds across lists.
- Clear is content-only. Clear all also resets attributes. `channel N reset` returns one channel's attributes to defaults.
- Each attribute has a tracking switch in settings. Off means every cue uses the channel default unless it carries a one-off write; the from-here-on option disappears for that attribute, and existing tracked writes in masters behave as one-offs.

**Write semantics**

- Writing the media already on the channel restarts it from its in-point with a dissolve from the current frame.
- Writing identical text is a no-op with no transition.
- Writing the same designed slide with a different build index animates to that build instead of restarting.

**Two views of one cue.** Average users see a palette of pre-made commands, contextual to what exists; power users see the raw ordered list. Both views read the same data, and anything added in one shows in the other, even a command the palette can't author.

## Lists and playlists

A list is a flat sequence of cues held in the shared library as a master; a playlist is a machine-local service made of references to masters and local copies. Arrangements are cut for v1, so a repeated chorus is two cues and the second can carry different media.

**Lists (masters)**

- Cues in order, each with its own content on every channel and its own time.
- Sections are labels only: a color group in the grid, a jump target (`item 4 section chorus`), and a duplicate-section action that copies a block of cues.
- Metadata: title, author, copyright, CCLI number. Text boxes can bind to these fields, so a copyright slide is not hand-authored.
- The list's timeline lives on the master (see Timelines and clocks).
- A local copy carries its master's provenance and is otherwise its own list; the inspector never shows the master alongside.

**Playlists (machine-local)**

- Carry a service date and sort by it; headers group items (pre-service, worship, message) and are skipped by next.
- Each item is linked (edit-through-reference to the master) or local (a copy), with a visible badge.
- Item commands: detach (make local), promote (save a local copy to the library as a new master), relink (discard the copy and point at a master). Detach-all over a playlist is the same command applied to every item.
- Past playlists keep updating from their masters. Anyone wanting a true snapshot uses detach-all; archive is an explicit command, and archived playlists are read-only until restored.
- A central template playlist embeds any local copies it contains; importing one creates a local playlist, and re-importing is an explicit replace, never a background sync.

**Addressing and the live pointer**

- Two handles per cue: a library address (`list 42 cue 3`) that is stable, and a playlist position (`item 4 cue 3`) that next operates on.
- Next crosses item boundaries; past the end of the playlist it does nothing.
- Clicking a cue in a browsed list fires it and makes that list live.
- A list fired directly from the library becomes live with lookahead confined to it; next at its last cue does nothing; firing a playlist cue again resumes the playlist pointer there.

## Outputs, stacks and presets

An output is a numbered piece of machine hardware, a stack is the ordered set of channels it composites, and a preset is how one channel lands on one stack. Stacks are machine-level; presets are portable; they meet by channel number.

**Outputs (machine-level, numbered)**

- Kinds: DeckLink SDI port, display, NDI out, multiviewer. Two SDI ports can pair as one logical key/fill output fed by a stack with a transparent base.
- Each output has a default stack loaded at launch. One stack can feed many outputs. `output N stack M` switches live and uses the output's own transition (default cut for stack switches, fade for blackout).
- Each SDI output's embedded audio is a numbered audio output like any other.
- Hardware properties (format, interlace at the DeckLink, color range, genlock) live in settings; the stack assignment lives in the stack editor.

**Stacks**

- An ordered list of slots, bottom to top. A slot holds a channel number, an optional preset reference, an optional cue offset, opacity and a mute flag. No channel appears twice in a stack.
- A stack-level default preset applies to any slot that names none.
- The base is black or transparent. Stacks not assigned to any output still render and show in the multiviewer as previews.
- Blackout is a per-stack override that mutes every slot; per-slot mute is the same mechanism for one channel.

**Presets (portable, numbered)**

- A preset is a list of boxes. Each box binds to pixels (with a fit mode) to one field, or to static text that may contain variables (text boxes have a text style, a fit policy such as shrink-to-fit or max lines, and its own transition, default cut). A box can be marked fallback: it renders only if no earlier box drew.
- A channel's boxes render as one group at the channel's position in the stack; boxes never interleave across channels.
- Preset 1, Default, ships built in: pixels if provided, else body. It is not deletable but can be copied.
- Resolution order for a slot: slot preset, else stack default, else the channel's default preset, else Default. Stack default outranks channel default so a confidence stack can turn every channel into plain text without touching each slot.
- The preset editor warns when a preset used as a stack default lacks either a pixel box or a body box.
- A per-box grade exists for output correction (broadcast levels) and is separate from channel grades.

**Offset slots**

- A slot with offset +K shows the tracked state channel N would have after folding the next K cues over the current state, anchored to the last fired cue, crossing item boundaries, empty past the end.
- Negative offsets read from a ring buffer of resolved states per fired cue. Range is -2 to +3.
- Offset slots render static (poster frame for video) and cut rather than transition.

**Alpha**

- RGBA throughout: text over transparency, alpha media (ProRes 4444, HAP Alpha, PNG) preserved, empty slide areas transparent.
- Premultiplied alpha and linear-light blending, decided once before the first shader.

## Grades, transitions and audio

Grades, transitions and audio transitions are numbered, portable objects referenced from cues and channels; at runtime each is a tracked channel attribute. Picture and sound are handled separately so L and J cuts are ordinary settings.

**Grades**

- Parameters: hue, saturation, brightness, contrast, blur, tint, opacity. Applied as one shader pass when the channel texture is produced, so every stack and thumbnail sees it at no extra cost per output.
- Set by a cue (one-off or tracked) or at runtime: `channel 2 grade 5` is a tracked write that holds until something writes grade again, which lets a lighting console drive it over OSC.
- A pool item's default grade and a list's per-channel grade are authoring conveniences: they insert an explicit grade write into the cue, shown as a chip. Nothing applies a grade implicitly at runtime.

**Transitions (picture)**

- Built in for v1: cut, dissolve, fade through a color, each with duration and easing. Custom transitions later are more numbered objects with a shader and parameter block; nothing else changes.
- The transition happens inside the channel texture, between outgoing and incoming content, so every pixel box on every stack sees the same one. Field boxes render text per stack and carry their own transition on the preset.
- Three ways to set it: the channel default, a one-off on the write, or a tracked write from here on. Clear dissolves to transparent on the same setting.
- Output-level transitions are separate and cover stack switches, blackout and per-slot mute.

**Engine budget**

- Outgoing content stays alive until the dissolve ends, so a video-to-video dissolve runs two decoders on one channel. The cap is 2 per channel, 3 as a per-channel option; the property sheet states the cost and pre-flight flags it on an underpowered station.
- A write that exceeds the cap cuts the oldest content out, flashes the cell's transition bar red, and logs a stepped-on event.

**Audio transitions and gain**

- Audio transition is its own attribute with the same three forms. Types: cut, crossfade, fade through silence, with duration, easing and an offset.
- The offset is measured from the trigger, not from the picture: a J cut delays the picture transition, an L cut delays the audio transition. Both work identically from a keypress, a Time trigger or timecode, because nothing starts before the write.
- The strip's transition bar splits into picture and sound when audio has its own timing.
- Gain is a tracked attribute: `channel 2 gain -6`. A pool item's default volume inserts a gain write, like the grade default.
- Sync offset: each pool item carries a sync offset of ±1000 ms, overridable on the write, for a clip that is itself out of sync. Positive delays the audio; negative delays that channel's video by the same amount, at the cost of latency, and the UI says so. Downstream latency (LED processors, projectors, a broadcast chain) is corrected by the per-output delay in settings instead.
- Blackout is video only. Muting audio is a separate command on the audio outputs, and "mute all audio" ships as a built-in macro.

## Command model, macros and the projection function

Every operator action is a command addressed by number, and every input path emits the same vocabulary. One projection function, which folds commands over channel state, serves the cue view, lookahead, timecode seek and thumbnails.

**Vocabulary (examples, not the full set)**

| Command | Effect |
| --- | --- |
| `channel 3 clear` · `channel 3 reset` | Write empty content · return attributes to defaults |
| `channel 2 grade 5` · `channel 2 transition 2 0.5` · `channel 2 gain -6` | Tracked attribute writes |
| `channel 2 play` · `pause` · `stop` · `lock` | Transport and lock (stop = pause and rewind) |
| `output 1 stack 4` · `blackout stack 2` | Output and stack control |
| `next` · `previous` · `item 4 cue 3` · `list 42 cue 3` · `item 4 section chorus` | Playlist and library navigation |
| `timer 1 set 5:00` · `timer 1 start` | Timers and popups (variables) |
| `undo` · `redo` · `history jump N` | History |

**Sources** that emit commands: the UI, key bindings, OSC in, MIDI and Stream Deck, macros, cues, timelines, the scheduler (time-of-day triggers such as 9:55 on Sundays), the startup and shutdown macros, and the optional command bar.

**Macros**

- A numbered command list with a name, a tile color and label. Portable unless it references stacks or outputs, in which case it is machine-level.
- The clears tab is a grid of pinned built-in macros (clear all, blackout stack and all, mute all audio, reset); per-channel clears come from selection in the strip, and anything finer is a user macro. The macros tab is the user's own grid, and both are the same component.
- Guards: any command in a macro can carry one condition, such as `when [Timer 1] is 0:00`, `when [Output 1 Stack] is 2` or `when [Channel 2 Content] is empty`. Comparisons are equals, not equals, greater, less, empty and not empty, against a variable or a read-only state value exposed as one. No else and no loops; an else is a second line with the opposite guard. The palette shows a guard as a chip.
- Startup and shutdown macros run at launch and at quit; a service start is a scheduled macro, not a separate feature.

**Selection** is a UI-only token, never an address. "Clear selected" expands to `channel 2 clear, channel 5 clear` at the moment of pressing. Macros and OSC use absolute numbers so a macro never depends on what someone had highlighted. Stack selection and channel selection are independent.

**Lock** blocks writes that originate from cues and timelines. UI buttons, OSC, macros and history restores pass, including clear all. Lock is never part of tracking.

**Blackout** is a per-stack override using the output's transition; per-slot mute is the same thing for one channel, toggled from the stack dots in the channel strip.

**Projection** folds write, clear and attribute commands; it ignores commands that don't touch channel state. Three bases:

- Cue view and thumbnails: tracked state from the top of the list, starting empty, so cue 1's background appears on every later thumbnail; cached per cue and stack, invalidated when the cue, a preset or a grade changes.
- Lookahead (offset slots): tracked state from what is actually on the channels now.
- Timecode seek: fold the cues up to the new time and apply the result in one step, never replay them.

**Pre-flight** is a command run on a playlist that lists missing media, missing fonts and the fallback in use, expected inputs that are absent, cues that write to deleted channels, stacks and outputs this machine lacks, clock types with no hardware mapping, media not optimized on import or failing its sync check, and decoder caps the station can't sustain.

## Timelines and clocks

A timeline is another view of a list, not a separate structure: cues with Timecode triggers sit on the ruler, chased media clips are writes whose playhead follows the clock, and a playlist timeline places list timelines in service time. Timecode is one more command source.

**List timeline (on the master)**

- Holds the clock type, a native offset (the track starts at 01:00:00:00), the time for each cue that has a Timecode trigger, and chased clips.
- Cues without a time sit in an unplaced tray and remain manual. Dragging a cue onto the ruler sets its trigger; dragging it off clears it. List order must equal time order; the editor warns otherwise.
- A clip is a write with the transport mode set to chase: the playhead is clock time minus the clip's start. Chase is an attribute, so a cue can also carry a chased video with an anchor offset.
- Lanes are the channels, numbered to match the strip, with cue markers in a row above.
- Chase follows within a tolerance and hard-seeks past a threshold; DeckLink genlock does the rest. While a channel chases, its cell shows "chasing TC" and the clock owns its transport.

**Clocks**

- Types: LTC, MTC, Art-Net, internal. The list names the type it needs; the machine maps the type to hardware (which audio input carries LTC, which MIDI port, which Art-Net universe).
- Internal starts from zero on Go of the first cue or an explicit start command, and answers pause, resume and locate.
- Only the live list's timeline listens. Moving to the next item arms its timeline and releases the previous one.

**Playlist timeline (machine-local)**

- A container of blocks, one per list, that maps each list's local time into playlist time. Placement modes: native (the block starts at the list's own offset, the every-hour convention with no remapping), offset (a set start), chained (starts where the previous block ends, using the list's duration: last cue time or longest clip end, overridable).
- Lists not placed on it stay independent and listen only while live.
- When it runs, the active block is whichever contains the current time, so timecode selects the song as well as the cue. Overlapping blocks warn in the editor.
- It has its own clock type; lists inside inherit it.

**Where it is edited.** The show-mode timeline tab is view and transport only (locate, play, pause, running position). Moving cues or clips happens in edit mode's timeline tab, which keeps nothing-edits-live true for timelines. A learn mode that records fires against incoming timecode is deferred.

## Media pool and identity

The pool is an index of a media root on disk, not the folder tree itself, so users reorganize subfolders freely and no cue breaks. Identity is portable: the same file resolves to the same ID at every campus.

**Identity**

- Imported files take their ID from a content hash. The index tracks renames and moves within the root; identical files anywhere resolve to one ID.
- Authored documents (designed slides, slide templates) carry an embedded UUID, since every edit changes their hash.
- A per-machine resolver maps ID to path under this machine's root. A "replace media" command remaps references from an old hash to a re-exported file's new one.
- Fonts live in the synced media root so presets render the same everywhere; a machine-level fallback font (default: a system font) is used when one is missing, and pre-flight reports the substitution.

**Import and folders**

- Subfolders are the user's; a default import folder is pinned at the top of the folder rail.
- Anything dragged in from outside is copied into the default folder, never referenced in place. Import offers to optimize: transcode to the preferred codec and the output frame rate, constant frame rate, muxed by timestamp so audio stays in sync, with a post-transcode check that audio and video durations agree.
- A missing file stays listed with a missing state rather than disappearing; the same state shows on any cue or channel referencing it.

**Items**

- Files: video, image, audio-only, and audio sets: a folder treated as one media object that plays its tracks in order with crossfades and auto-advance, with skip and previous as channel commands. Designed slides and templates are pool items with their own kind filter.
- Live sources appear as a Sources group showing inputs by number and label (timers and the clock are variables, not sources); dropping one on a cue writes `input N`.
- Per-item defaults: trim, loop, volume (inserts a gain write), grade (inserts a grade write). Default channel for drops is a per-kind setting with a per-item override.
- Thumbnails are cached; the pool thumbnail of a slide shows its final build state.

## Roles, library mode and distribution

Three roles cover everyone, the machine sets the default, and masters are protected at campuses by a mode rather than by permissions on individual items. Local copies are the release valve: central order lives in the masters, local flexibility lives in the fork.

| Role | Can | Notes |
| --- | --- | --- |
| Editor | Fire, clear, switch stacks, change playlists and local copies, enter edit mode | The default |
| Operator | Fire, clear, switch stacks, runtime undo | A lock mode: persists across launches, needs a credential to leave; blocks edit mode, in-place edit and edit undo |
| Librarian | Everything an editor can, plus write masters |  |

**Library mode (machine setting)**

- At campuses masters are read-only by default. Trying to edit a linked list offers "detach and edit" in one step rather than refusing.
- A role can exceed the machine mode: a librarian logged into a campus station writes masters.
- Local copies are reported upward so the central team can see a campus's version, adopt it, and relink the campus to the updated master.
- "Where used" on a master lists the playlists referencing it, shown before editing.

**Distribution**

- Down: masters, presets, grades, transitions, portable macros, media and fonts.
- Up: logs, local-copy reports, snapshots.
- Playlists stay local; central distributes template playlists, imported explicitly.
- Masters save continuously; conflicts resolve last-write-wins with a version history on every object, so a bad edit is one revert away. No merge system.

## Logging, history, undo and backups

Every command is logged with its source and time; the history view is this session's slice of that log, and undo reads from it. Everything saves continuously, with snapshots on top for restoration.

**Log**

- One entry per command: source (key, UI, OSC, cue, timeline, macro, restore), timestamp, kind (edit or runtime). Navigation commands are recorded but marked non-undoable.
- A fire snapshots the list's title and CCLI number at fire time, since masters change later. CCLI reporting is a query over the log, built later.
- Stepped-on transitions are logged.
- Logs sync upward.

**History view**

- Plain-language rows by default ("Cleared Backgrounds", "Fired cue 3 of Great Is Thy Faithfulness"); the raw command behind the same power toggle the cue inspector uses.
- Filter to edits or runtime; jump to a point within either. No jump across both at once, and no removal of one command from the middle.

**Undo**

- Edits undo by inverse command, linearly, with redo. Jumping to a point reverts the touched objects; on a master that is a new version.
- Runtime undo restores state: every runtime command snapshots the channels before it runs, including each item's playhead and the live playlist position. Undoing an accidental next brings the background back, resumes the video where it was, and moves the pointer back. Restores cut by default.
- A restore passes lock and shows as "restored" in the strip's provenance, not as the original cue.
- `undo`, `redo` and `history jump N` are bindable. Operator lock allows runtime undo and blocks edit undo.

**Autobackup**

- Continuous save of masters, playlists, stacks and settings; no save button.
- Snapshots of the library and machine config at launch, before each service start, and on a timer while edit mode is open, retained with rotation (every one for a week, then daily, then weekly), synced upward.
- Restore at two grains: one object from its version history, or the whole library from a snapshot. Both are commands and appear in history.
- A restore-last-state option at startup, off by default, reapplies the last session's channel state after a crash mid-service.

## Main window: layout and left column

The main window keeps the positions ProPresenter users know: navigation on the left, cues in the center, everything that is live or controllable on the right, and a status-only bar across the top. The right column reads top to bottom as what the screen shows, what you can do about it, what is feeding it.

| Region | Contents |
| --- | --- |
| Left column | Playlists window over Library window (Lists and Archive tabs) |
| Center | Cue grid over a tabbed bottom panel (Media pool, Timeline) |
| Right column | Preview, next/last row, tabbed panel (transport, clears, macros, popups), channel strip |
| Top bar | Status only: where you are, timecode, health |

- Every divider position, the pool's tile size and the grid header's show/hide choices are machine-level view settings, remembered across launches, with one reset-layout command. A simplified operator layout later is just a saved set of these values.
- The left column is a browser rather than a control surface, so keyboard focus can live in its search fields without affecting next or clear.

**Playlists window**

- A tree sorted by service date; one playlist expanded at a time by default; each row shows its lists with linked or local badges, and headers.
- Browsed versus live: the live playlist, item and cue carry a persistent marker across the tree, the grid shows whatever is browsed, and a one-click "back to live" returns the grid to the firing position.
- Archive is an explicit command on the playlist's right-click menu, disabled while that playlist is live.

**Library window**

- Lists tab: a user-editable folder tree, nesting allowed, with inline rename, drag to move lists and folders, and new or delete on the right-click menu; search across the whole tab at the top, metadata on each master, "where used", and firing directly from a master with lookahead confined to it.
- Archive tab: the same tree as the active window, read-only until restored; archived playlists still show current master content; detach-all is available there for a true snapshot.

## Main window: center column

The center is the cue grid over a bottom panel with Media pool and Timeline tabs, split by a draggable divider. The grid shows the browsed playlist as one continuous scroll, a header row per list with the service headers between them, so a service reads top to bottom; browsing a master from the library shows that list alone. The grid answers "what will the screen look like"; the strip in the right column answers "what is on each channel".

**Grid header**

- The header carries the playlist name and little else. List actions (detach, promote, relink, where used, remove) live on the list header's right-click menu, cue actions (fire, edit, duplicate section, note, trigger) on the cue's. Search within the list, grid density, and which cell elements show (chips, trigger glyph, note) stay in the header.
- Per-channel grade pickers for the list, which insert grade writes into the first cue that writes each channel.

**Cue cell**

- A thumbnail of the cue's projected result on the machine's default stack, computed as tracked state from the top of the list.
- A row of per-channel chips in number order, each in one of three states and colored by what it does: a new value being written, held from a previous cue, or a write that repeats the value already tracked in (a redundant write worth removing). A small dot on a chip marks attribute writes (grade, transition, gain, chase), listed on hover.
- Label, section color as a left edge, trigger glyph (Go, Time, TC) with the live countdown once armed, note indicator, and the list's linked or local state.
- Double-click on a text cue edits its text in place; the change applies on the next fire. Operator lock blocks it.
- Clicking any cue fires it and makes its list live.

**Media pool tab**

- Left: a narrow folder rail with the default import folder pinned on top and the Sources group below the folders.
- Header: search, kind filter (video, image, audio, slide, live), sort by name or date added, tile size, import button, a "used in this list" filter.
- Tiles: thumbnail, name, duration badge on timed items, kind glyph, missing overlay that keeps the tile in place.
- Single click selects and shows resolution, duration and the item's defaults in the header. Double-click or a fire button sends it to its default channel. No single-click firing.
- Drag up onto a cue writes it into that cue on the channel chosen in a popover (remembered per kind); drag right onto a channel cell goes live immediately, with a hover state that says so.

**Timeline tab**

- Show mode: view and transport only, with the running position. Editing happens in edit mode's timeline tab.
- Shows the browsed thing: a list's own timeline when a list is selected in the left column, the playlist timeline with its blocks when the playlist is.

**Divider**

- Three snap states: collapsed (pool header plus one scrolling strip of recent and favorited items, so drag-to-channel still works), default at about a third, expanded. Double-click toggles collapsed and default.
- Minimum grid height keeps the header and one row of cues visible; drags are ignored while an in-place edit is open.

## Main window: right column

The right column holds everything live and every control, top to bottom: preview, next/last, the tabbed panel, and the channel strip. On a laptop the middle panel collapses and the strip takes the slack, since the preview and the strip are the two things an operator can't work without.

**Preview**

- Shows the selected stack, starting from the machine's default stack; a stack picker and a multiviewer toggle.
- The multiviewer shows any stacks, assigned or not; each tile names the stack and the outputs it feeds, a tile with no output is a preview, and the selected stack stays highlighted since it is the blackout target.
- Every tile is a downscale pass of a texture that already exists.

**Next/last row**

- Previous, a large next, and a go-to-cue field that takes a number and fires on enter. Most operators are expected to use the keyboard.

**Tabbed panel**

- Transport: for the selected channel. One channel selected shows the scrubber plus the instance's end-of-media behavior (loop, hold last frame, clear); several selected shows batch play/pause/stop only; a chasing channel shows the chase indicator instead.
- Clears: the built-in macro grid (clear all, blackout stack and all, mute all audio, reset). Per-channel clears come from selecting channels in the strip; anything finer is a user macro.
- Macros: the user's own grid. Same component as Clears.
- Popups: one row per popup slot with a text field, send and clear, an optional clear-after time, and templates with fill-in fields. Sending sets the variable; wherever `[Popup N]` appears in rendered text, it updates.

**Channel strip**

- Header: clear all as its own wide, distinct button with a gap beside clear selected (enabled only with a selection, heavier when one exists), plus select all and select none, and a view dropdown: all channels in number order, or one stack's channels in that stack's order, top layer first, with the channel numbers unchanged on the badges. No hold-to-confirm on clear all; it is also the panic button.
- Selection works without modifier keys: the number badge toggles a channel into the set; clicking the thumbnail selects that channel alone.
- Each cell shows: number badge and label; the content thumbnail (body text for text content, the frame for media, the slide for slides); kind glyph; audio meter when the content has a track; stack dots for which stacks include it, which double as per-stack mute toggles; remaining time on timed content; "chasing TC" while chased; the transition bar, split into picture and sound when audio has its own timing, flashing red when stepped on; grade and lock glyphs; red no-signal on a live input without signal.
- Contextual buttons: media shows play/pause, stop (pause and rewind to the start, poster frame stays), clear; text and slides show clear only; live sources show clear and freeze. All are commands, so OSC and macros get them for nothing.
- Clicking the thumbnail shows which cue put the content there, or "restored" with the history entry after an undo.
- Dropping a pool item on a cell writes it to that channel immediately.

## Top bar and keyboard

The top bar is status only, persistent in both modes, and the keyboard is a rebindable table from keys to commands with one focus rule.

**Top bar**

- Left: show/edit toggle; the live playlist, item and cue as text; "back to live" when the grid is browsing elsewhere; a role and lock badge.
- Center: timecode readout when a timeline is armed, with clock state (locked, free-running, no signal in red), and the armed auto-trigger countdown.
- Right: one dot per output labelled with its current stack (green linked and outputting, red otherwise; click opens the output's details); a group for inputs so a dropped camera is visible; an activity dot that flashes on each received remote command; time of day.
- Nothing here is a control except the output click; clear all and blackout stay in the strip.

**Keyboard**

- A binding is a key to a command; the table is the whole feature. Macros bind like next does. MIDI and Stream Deck inputs use the same table with a device column.
- Bindings are machine-level with an exportable profile so stations can be standardized centrally.
- Defaults: space and right arrow next, left arrow previous, one clear-all key. No per-channel clear keys ship: individual channels are cleared by selecting them in the strip, and anything finer is a user macro bound to a key. Digits then enter fires that cue number in the live list. Section jumps ship unbound.
- Focus rule: every binding is global except while a text field is active, when unmodified single keys type and only modified bindings fire. Escape leaves any field.
- Bindings are absolute (`channel 2 pause`), never "pause selected".
- Safeguards: warn when next or clear all is unbound; a hold-to-show help overlay of the current map.
- The command bar (type a command, press enter) is off by default and enabled in settings.

## Edit mode: frame, stack editor, channel sheet, preset editor

Edit mode is one window in which the center becomes the editing space and the right column becomes the tools for whatever is selected; the left column stays as navigation and the media pool stays at the bottom. All authoring happens here, so the "pages" are views within one mode.

**Frame**

- Entry: the top-bar toggle, or double-click on a cue to open with it selected. Exit: escape or done, returning to show mode on the same cue.
- The top bar gains a small preview of the default stack; next, clear all and the go-to-cue field keep working, so refiring a cue just edited is one keystroke. No apply-to-live.
- Operator lock blocks edit mode entirely.

**Stack editor**

- Center: the selected output's stack as a vertical slot list, bottom at the bottom; each row shows channel number and label, preset reference, offset, opacity and mute; drag to reorder, drag a channel in from the right column to add a slot; a live render of the stack above it.
- Right column: the output list with each output's current and default stack and health, grouped with "not assigned" for stacks on no output; the channel list; the output's properties (format, interlace, DeckLink settings, stack-switch and blackout transitions); the stack-level default preset; the audio routing table.
- "Set as default" promotes the live stack to the launch default.

**Channel property sheet**

- A form beside the channel list; the right column keeps the stack list so you can see which stacks include the channel.
- Fields: number and label, default preset, default transition and audio transition, default gain, decoder cap (2 or 3, with its cost stated), audio routing, thumbnail style for text, usual-content hint.
- Renumbering: internal references follow; a "referenced externally by number" warning covers OSC, console and Stream Deck maps; a taken number offers a swap.

**Preset editor**

- Center: a canvas at a chosen stack's output size with sample content (real text and a real frame), a picker to try other content kinds, boxes drawn and arranged directly with their binding shown.
- Right column: the box list in z-order; the selected box's properties (binding to pixels, a field, or static text with variables, position and size, fit mode or fit policy, text style, the field box's transition, fallback flag); number and name; "used by" across channels and stacks with the stack-default warning; a view of which campuses' stacks override it.
- Duplicate-from, so a campus variant starts from the standard.

## Edit mode: cue inspector, text editor, slide designer, small editors

The cue inspector is where write/clear/hold, the palette and the triggers meet; the text editor and slide designer author the two content kinds that aren't files; grades, transitions and macros share one parameter-editor frame.

**Cue inspector**

- Center: a canvas of the cue's projected result on the default stack with a stack picker; below it one row per channel mirroring the strip, each with a three-way control (write, clear, hold), the content thumbnail for a write, and attribute chips (grade, transition, gain, chase, build). Hold is the default. Drop media on a row to set a write; double-click a text write to open the text editor in place of the canvas.
- Right column: label, section, note; the trigger block (Go, Time, Timecode, advance-after, with the pair warning); the palette, grouped by what it touches (channels, stacks, outputs, macros, external) and offering only things that exist; attribute chips offer "this cue only" or "from here on"; the power toggle swaps the palette for the raw ordered command list.
- Multi-cue editing: with several cues selected, a reduced inspector (trigger, section, attribute chips) applies to all.
- A local copy is edited as its own list; the master is never shown alongside.

**Text editor**

- Center: the whole list's text as one scrolling document, cue breaks as horizontal rules, section labels in the margin, a projected thumbnail beside each chunk. Moving a break splits or merges cues; a split creates a new cue with hold on everything. Pasting a lyric sheet makes breaks on blank lines.
- Designed-slide cues appear as non-editable rows, since their tagged text is edited in the designer.
- Right column: the list's metadata fields, a section picker for the chunk. No fonts; text has no look of its own here.

**Slide designer**

- Canvas at a chosen size (default 1920 by 1080) with text, shape, image and video layers using pool references; alignment, distribution, layer ordering. Text layers resolve variables such as \[Timer 1\] or \[Time\] live, which is how a branded countdown slide is built.
- Field tags: a text layer can be tagged body, title, reference or custom, which exposes that text to presets while it stays painted in the pixels; a tagged layer gets a marker on the canvas. The main stack's preset must not also draw the field, which is why Default is pixels-else-body.
- Builds: element animations (build in, build out, emphasis, and looping animations such as a crawl, with durations and delays) grouped into steps, each chained or waiting. A slide with four steps has states 0 to 4. A write carries a build index, defaulting to the final state; dropping a slide with builds into a list offers one cue per build (5, 5a, 5b…) or a single cue that lets the slide's own chaining run. Next always means next cue.
- Right column: layer list in z-order, layer properties, build list with a canvas scrubber. Save-as-template with chosen text layers marked editable.

**Grades, transitions, macros**

- Grades and transitions: a live preview on sample pool content (a transition scrubs between two items with the picture and audio bars), parameters, number and name, "used by", duplicate-from.
- Macros: the command list built with the same palette as the cue inspector; number, name, tile color and label; a portable or machine-level scope marker; a test button that runs it on the live engine; "used by" for cues and keys.

## Settings

Settings hold the machine's hardware, mappings and policies; nothing here is authoring. Names from hardware enter the system only at this edge and are mapped to numbers once.

| Area | Contents |
| --- | --- |
| Inputs | Numbered list of DeckLink SDI inputs, NDI sources (live discovery), USB cameras, screen or window capture; per input: label, format, deinterlace, color range, audio channel mapping, buffering; "expected on this machine" for pre-flight |
| Variables | Time format and time zone, countdown-to-service from the playlist date, timer and popup slot counts |
| Outputs | Numbered list of SDI ports, displays, NDI out, multiviewer; format, frame rate, interlace, color range, genlock; key/fill pairing; each SDI output's embedded audio as a numbered audio output |
| Audio outputs | Numbered list including embedded SDI audio; per-output delay up to 1000 ms for downstream video latency; system default on first run |
| Clock sources | Hardware mapping per type: which audio input carries LTC, which MIDI port carries MTC, which Art-Net universe |
| Network | OSC in/out ports, MIDI devices, sync targets for library, media, logs and snapshots |
| Key bindings | The key-to-command table with a device column, plus the scheduler as the same table with a time column (day and time of day to command or macro); import and export |
| Roles and library mode | Machine default role; operator lock; masters read-only or writable here |
| Media | Media root, default import folder, fallback font |
| Thumbnails and engine | Default stack for thumbnails and preview; decoder cap defaults |
| Tracking | Per-attribute tracking switches |
| Startup and backup | Startup and shutdown macros; restore last state (off by default); snapshot cadence and rotation; sync target |
| Command bar | Off by default |

Operator lock lives here as the one setting a locked station cannot open without a credential.

## First-run defaults

A fresh install works on every output with no configuration and demonstrates the model in the first minute; the first-run copy says these are yours to rename, number and extend.

| Object | Default |
| --- | --- |
| Channels | 1 background, 2 foreground |
| Preset 1 | Default: pixels if provided, else body; not deletable, copyable |
| Stacks | One per detected output, channels in number order, assigned as that output's default; stack 1 is the main look on output 1 |
| Stack 2 | Confidence: a plain-text stack default preset, slots for channel 2 at offset 0 and +1, with a static \[Time\] box in its preset; left unassigned so it appears in the multiviewer as a preview |
| Audio | Every channel routed to the system default audio output |
| Transitions | Cut, dissolve, fade through color as transitions 1–3; channel default cut |
| Role | Editor; operator lock off |
| Library mode | Read-only masters at a campus install, writable at a central install |
| Keys | Space and right arrow next, left previous, one clear-all key |
| Startup | Outputs load default stacks, channels empty, attributes at defaults, no playlist live; restore-last-state off |
| Layout | Pool divider at default; grid header showing thumbnail, chips, label and trigger |

## Deferred features and open questions

Everything below is out of v1 by decision, or still needs a number the design can't supply yet.

**Deferred**

- Arrangements (section order as a reference-level override); a flat list with duplicate-section covers v1.
- A lyric-to-slides generator that chunks a song's text by a ruleset; the existing Planning Center lyric-doc tooling is the seed.
- Planning Center service import that builds a playlist from a plan.
- Custom transitions as shader objects; the referencing model already allows them.
- CCLI auto-reporting as a query over the fire log.
- Timeline learn mode (record fires against incoming timecode).
- A whole-service timecode show where the clock also selects the item, built on the playlist timeline.
- Bibles, a remote app (third parties use OSC), slide-for-slide import of existing libraries, Windows.
- A saved simplified operator layout, expressed as a set of view settings.
- The OSC address scheme: it follows the command vocabulary one to one, and the exact path shape is set when the commands are implemented.
- Three-decoder hardware thresholds for the pre-flight warning: a later hardware problem.
- Chase tolerance and hard-seek threshold, in frames: engine tuning during implementation.

**Open questions**

- [ ] Snapshot rotation numbers once storage per station is known.
- [ ] Whether slide templates need placeholder media as well as editable text.
