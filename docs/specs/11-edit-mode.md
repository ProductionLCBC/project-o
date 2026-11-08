# Spec 11: Edit mode

2026-11-08 · @Adam Granby · Status: accepted 2026-11-08, with Adam's answers in §14 · Builds on Spec 1 (§2 portable objects, §3 machine-level objects, §6 cue encoding), Spec 2 (§3 the vocabulary, §4 the parser, §8 execution, §9 the API), Spec 3 (§3 tracking, §4 write semantics, §5 triggers, §7 the cue view), Spec 4 (§5 resources, §9 the stack pass, §10 thumbnails), Spec 5 (the edit path, its vocabulary, groups and typing, validation and undo), Spec 6 (§2 stacks and slots, §3 presets and boxes, §4 text styles and fonts, §5 variables), Spec 7 (§2 lists, §3 playlists), Spec 8 (§5 tiles, §7 the use query, §8 drop channels) and Spec 10 (§2 the two processes and the Mach channel, §3 the API, §4 the window, §6 the grid, §9 keys, §10 edits from show mode, §15 accessibility); written from the scope gaps doc's answers (E1–E9, C4) and its review (R5), the UX spec's edit-mode sections and the clickable demo's cue inspector

Area 14 builds it, apart from the text editor, which is Area 10's.

## 1. Purpose and scope

Edit mode is where a library is authored: the cues of a list, the text of a song, the stacks and channels of a machine, the presets that give text and pictures their place, and the small objects cues refer to (grades, transitions, audio transitions, text styles, macros). It is the UX spec's "Edit mode" sections made exact, with the scope doc's answers (E1–E9, C4, R5) and the clickable demo's cue inspector. Every change it makes is a Spec 5 edit, run by the engine, logged with its inverse and undone with `undo`. Nothing here is new behaviour on air: edit mode changes documents, and Spec 5 §2 says when each change shows.

**In scope:** the edit-mode frame (entry and exit, the pages, the edit bar, keys, the lock, editing what is live); the two queries the editors need from the engine (`render` and `uses`); the Cues page (the list's cues, the cue inspector, its palette and raw command view, multi-cue editing); the text editor and its paste rules; the stack editor; the channel sheet; the preset editor, with text styles authored in a box's properties; the small editors for grades, transitions, audio transitions, text styles and macros; their accessibility; what Areas 14 and 10 build, in the engine and the app.

**Out of scope:** show mode and settings (Spec 10), which this spec only joins where they open edit mode; the slide designer, timelines, Timecode triggers and chase (v2); builds, which belong to designed slides (v2); live inputs and their freeze (v1.5); the campus-override view of a preset and campus variants (cut by the planning doc, v1.5 with library mode); editing local copies (L2, v1.5 with library mode); macro guards (Spec 2 §7, v1.5); creating transitions (the transition editor the planning doc cut); the history view (v1.5).

**Rules every page follows:**

- **Edits only.** A control sends one Spec 5 edit, or one group of them, when it commits; the app writes nothing in the roots (C1). The page shows what the engine answers: a `library` event (Spec 5 §2) makes the page ask again for what it shows (Spec 10 §3), the Text page patching only the chunks the event names (§5), and a rejection puts the control back with the reason under it, as Spec 10 §11's fields do.
- **Fields commit** on Return or when they lose focus, sliders and colour wells when the drag ends, pickers when a choice is made. Only the text editor's chunks send while typing, at most four times a second, as Spec 5 §5 folds it; every other text field, a popup command's text included, sends once, on commit (Spec 10 §10).
- **Only what exists.** Pickers offer the objects this machine has, by number and label, and each type's own values: a box's transition picker offers transitions of type cut or dissolve, the box transitions v1 draws (Spec 1 §2), and an attribute whose tracking is off offers no "from here on" for anything new (Spec 3 §3 rule 7, §4).
- **Read-only, with the reason,** wherever the engine would refuse: a local copy (Spec 5 §3, `notInV1`); a library object (a list, a channel, a preset, a text style, a grade, a transition, an audio transition or a portable macro) on a `readOnlyMasters` machine (Spec 5 §7, `readOnlyLibrary`); a protected field (Spec 5 §6); and a list whose number another list shares when edits by that number reach the other one, which comes first (Spec 7 §2); that page offers to renumber the other (§4). Operator lock closes edit mode altogether (§2).
- **AppKit**, as CLAUDE.md divides the toolkits: the pages are editors, so they are AppKit, apart from the small editors' simple forms, which may be SwiftUI.

## 2. The edit-mode frame

**One window, six pages** (UX spec). Edit mode keeps the main window and its regions (Spec 10 §4). The left column (the Playlists and Library windows) and the media pool panel stay; the center becomes the page's editing space and the right column its tools. Across the top of the center and the right column, under the top bar, runs the **edit bar** (choice A-16): the page picker, Done, and at its right end the live preview, the go-to field, Next and Clear All (below). The pages, also in the View menu with ⌥⌘1 to ⌥⌘6:

| Page | Edits | Section |
| --- | --- | --- |
| Cues | The cues of one list: the list's filmstrip, the cue inspector, its palette and raw command view | §4 |
| Text | One list's text on one channel, as a document (Area 10) | §5 |
| Stacks | The machine's stacks and their slots, each output's default stack and transitions | §6 |
| Channels | The library's channels and their properties | §7 |
| Presets | Presets, their layouts and boxes, with text styles in a box's properties | §8 |
| Objects | Grades, transitions, audio transitions, text styles and macros | §9 |

`view.json` (Spec 10 §4) also keeps the last page and each page's selection, so edit mode reopens where it was left.

**Opening it.** Mode ▸ Edit (⌘2) or the top bar's Edit button opens the last page on what show mode had in hand: the list the grid browses, from its playlist or the Library window, and the selected cue, else the live cue if it is in that list, else the first. The pages keep where a list came from, which Fire (§4) and leaving use. Show mode also opens it on something:

- a double-click on a cue that isn't a text cue, or Edit Cue in a cue's menu, opens the Cues page on that cue (Spec 10 §6);
- Open in Text Editor, in a list header's menu or a list's menu in the Library window, opens the Text page on that list. It is named apart from the cue menu's Edit Text, which edits one cue in place in show mode (Spec 10 §10);
- Edit on a macro tile opens Objects on that macro (Spec 10 §7);
- Edit in Stack Editor on an output in Settings ▸ Outputs opens the Stacks page on that output (Spec 10 §11).

The app notes `editMode` with `on` true when edit mode opens and false when it closes (Spec 10 §3).

**Leaving it.** Done, Escape with nothing else to close (below), or Mode ▸ Show (⌘1) returns to show mode on the cue the Cues or Text page has selected: the grid browses where its list came from, the playlist or the Library window, and scrolls to it, firing nothing. An open field commits first (Spec 10 §10). If the engine refuses that commit, edit mode stays on the field with the reason, and a second Done or Escape leaves without it.

**The lock** closes edit mode (UX spec, S13). While operator lock is on, Mode ▸ Edit, the Edit button and every entry above are disabled with the reason (Spec 10 §12). When it comes on from elsewhere, edit mode closes to show mode on the same cue, and an open field's unsent text is offered in a sheet with Copy, since the engine would refuse it.

**The edit bar's right end** keeps the show running while editing (UX spec): a live picture of the thumbnail stack, 54 points high, from its preview surface (Spec 10 §2); the go-to field, which takes digit entry as in show mode and fires cue N of the live list, whatever the page shows, showing the live list's title while digits wait (Spec 10 §7, §9); Next (`next`); and Clear All (`system clearall`), red and set apart. Next and the go-to field fire within what is live; Fire, on the Cues page, is the one control that fires a cue of any list (§4). Nothing in edit mode applies an edit to live: a change shows when Spec 5 §2 says it does. The right column's show-mode controls (the preview, the next row, the tabbed panel and the strip) aren't shown in edit mode. The top bar is as in show mode (Spec 10 §8).

**Keys** follow Spec 10 §9, with one addition (choice A-3). In edit mode a focused filmstrip, canvas, or list in the center or the right column takes the arrow keys, with ⇧ or ⌥, and Delete and Forward Delete, as a text field takes typing; the left column keeps show mode's keys: the arrows move the selection, ⇧ extending it in the filmstrip, or nudge the selected box on a canvas (§8), and Delete removes what is selected, asking first wherever its menu would. So stepping through cues or nudging a box never fires `next` or `previous`, while every other binding still fires: Space sends `next`, and ⇧⎋ clears all everywhere but the key recorder and an open menu. The text editor is a text field (§5). Escape leaves a field first, then closes a popover, a sheet or the keys overlay, then clears waiting digits, then leaves edit mode.

**What is live.** Edit mode edits what the left column and the pages select, live or not; the live list, cue, stack and output carry the live dot. When an edit shows on air is Spec 5 §2's:

- a cue's commands and trigger at the cue's next fire (L3), but at once in a box at +1 to +3 on air, such as the confidence screen's, which shows what will happen (Spec 5 §2, Spec 6 §3);
- a list's metadata, and a cue's section and note, from the next frame wherever a field box or a context value shows them (P5, P12);
- a preset, a grade, a transition's timing, a stack or an output from the next frame (choice E-6).

The first edit in a run to something on air says so beside its control, naming where it shows: "On air on outputs 1 and 2: this shows at once."

**Undo.** Edit ▸ Undo and Redo send `undo` and `redo`, named from the `history` topic, as in show mode (Spec 10 §10). One step is one group: a split, a merge, a paste, a multi-cue change, a drag on a canvas, a second of typing (Spec 5 §5). The text editor's ⌘Z is the library's undo while the last change is the editor's own (choice A-5, §5); in any other text field it undoes the field's own typing until the field commits (Spec 5 §8, Spec 10 §10).

**Rejections and warnings.** A rejected edit puts its control back and says why in plain words, with Spec 10 §10's sentence for its code. An applied edit's `warnings` (Spec 5 §6) show as a yellow note beside the control until the object is next edited.

**Other clients.** A second station on the LAN, OSC, the command bar or a cue that holds an edit may change what a page shows. The page takes the change from the `library` event, except in a field that has the focus, which keeps its text until it commits; the engine's last writer wins (Spec 5 §2). A page whose object is deleted under it says "Deleted", with Undo while that delete is the history's top group.

## 3. What the editors ask of the engine

Edit mode reads the documents Spec 10 §3's queries return (`catalog`, `list`, `media`, `thumbnails`, `fonts`) and the preview surfaces (Spec 10 §2), and sends edits. It adds two queries (choices A-1 and A-9): `render`, so that what an editor shows is what the engine draws, and `uses`, for the "used by" the UX spec asks of every object. Like every query, each is answered with its request's `id` as `{"id": …, "type": "answer", …}`, and refused with Spec 10 §3's rejected result (a Spec 2 §9 addition, §12). `render` answers with a file on this Mac, so it is the local socket's only, refused on the LAN with `localOnly`; `uses` is local and LAN alike.

**`render`** draws a picture for an editor's canvas and answers with a file, as thumbnails are files (Spec 10 §3):

```json
{ "id": 61, "type": "query", "what": "render", "canvas": "inspector",
  "subject": { "kind": "cue", "listUuid": "a9f0…", "cue": "11aa…", "stack": 1 }, "width": 1280 }
{ "id": 61, "type": "answer", "file": "thumbnails/render/c3-inspector-61.png", "width": 1280, "height": 720,
  "overflow": [], "fallbackFonts": [] }
```

| `subject.kind` | Fields | Draws |
| --- | --- | --- |
| `cue` | `listUuid` (or `local`), `cue`, `stack` | The cue's projected state on that stack, Spec 3 §7's cue view, as the thumbnail job draws it (Spec 4 §10) |
| `layout` | `preset`, `layout` (`"*"` or a stack number), `stack` (for `*` only), `sample` | The layout with the sample standing in for the slot's channel (below): a stack's own layout at that stack's size and number, the `*` layout at the size and number of the stack `stack` names |
| `grade` | `grade` (or null), `media` | The item's poster or still through the grade, or as it is when `grade` is null, over black |

- **The sample** is what a channel could hold: `content`, one text write's `fields` (`{"kind": "text", "fields": {…}}`), one media item (`{"kind": "media", "ref": "sha256:…"}`) or nothing (`{"kind": "empty"}`); `next`, up to three more contents for boxes at +1 to +3; and optionally `listUuid` and `cue`, naming where the sample came from. Field boxes draw the text's fields, falling back to that list's metadata (Spec 6 §3); pixel boxes draw the media as its poster or still; static boxes draw their text, their context values reading that cue (Spec 6 §5); fallback boxes follow the content's kind as on air (Spec 4 §9). Without `listUuid` and `cue`, metadata and context values draw nothing.
- **Size.** `width` is 160 to 1920 pixels. The height follows the stack's size, or the item's for a grade. A stack's size is that of the output showing it, else of an output whose default stack it is, else 1920 by 1080, the size its stack pass and preview use (a Spec 4 §5 addition, §12).
- **What it reports.** For a layout, `overflow` lists each text box whose sample text overflows (Spec 6 §4) as `{ "box": 2, "offset": 0, "linesCut": 2 }`, and `fallbackFonts` each box whose font fell back to `fallbackFont`, with the font's name. Boxes are numbered by their place in the layout, from 0.
- **When.** The engine draws it on the thumbnail job's background queue, with the thumbnail job's code, ahead of thumbnails, and waits as that job does while the render thread is skipping aux passes (Spec 4 §10). A request names its `canvas`, up to 16 letters and digits, scoped to its connection, which may use eight canvases; a newer request for the same canvas replaces one still waiting, which is answered `{"superseded": true}`. A drag on a canvas therefore never queues a picture per pixel moved.
- **The files.** `machine/thumbnails/render/`, named by connection, canvas and request `id` (`c3-inspector-61.png`), keeping each canvas's newest two; the folder is emptied at launch, and a connection's files when it closes. Nothing else reads them.
- **Errors.** An unknown list, cue, preset, layout, grade or media id is `unknownObject`; a width outside 160 to 1920, a canvas name that isn't letters and digits or is longer than 16, or a connection's ninth canvas is `badValue`; a media item whose file is missing draws nothing for the pixel boxes, and the answer says `missing: true`.

**`uses`** lists what refers to a numbered object, counted over both roots' documents on this machine, as `mediaUse` counts media (Spec 8 §7):

```json
{ "id": 62, "type": "query", "what": "uses", "object": "preset", "preset": 3 }
{ "id": 62, "type": "answer", "more": false,
  "counts": { "channels": 1, "stacks": 3, "presets": 0, "boxes": 0, "outputs": 0, "audiooutputs": 0, "cues": 0, "macros": 0, "keys": 0, "media": 0, "machine": 0 },
  "uses": { "channels": [ { "channel": 2, "field": "defaultPreset" } ],
            "stacks": [ { "stack": 1, "slot": 2 }, { "stack": 2, "field": "defaultPreset" }, { "stack": 3, "slot": 1, "fallback": true } ] } }
```

- **Objects:** `channel`, `preset`, `textstyle`, `grade`, `transition`, `audiotransition`, `macro`, `stack`, `output` and `audiooutput`. Media keep `mediaUse` and lists `listUse` (Spec 10 §3).
- **References:** a channel's default preset, transitions and audio outputs; a stack's default preset and its slots' channels and presets; for a preset, also the slots that reach it by fallback (Spec 6 §2), marked `fallback`; a preset's layout for a stack; an output's default stack, transitions and key-fill partner, and the audio outputs that embed into an output; a box's style (`fromStyle`), transition and grade; a media item's default grade and channel; the commands, riders, guards and held edits of cues and macros, and the commands of key bindings and scheduler entries; the machine settings' startup and shutdown macros, thumbnail stack and drop channels.
- **Kinds and entries.** `channels`, `stacks`, `presets`, `boxes`, `outputs`, `audiooutputs`, `cues`, `macros`, `keys` (key bindings and scheduler entries), `media` and `machine`. A channel, stack, output or audio-output entry carries its number and the `field` or slot that refers; a preset entry its `preset` and `layout`; a box entry its preset, layout and place; a cue entry `listUuid` (or `local`), `list`, `cue`, its number and its label; a macro entry its `macro` and the command's place; a key entry its `device` and `key`, or a scheduler entry's place; a media entry its `media` id and `field`; a machine entry its `field`.
- **Limits:** `counts` covers everything, per kind; the entries stop at 500 in all, with `more` true beyond. The engine answers from its loaded documents, so the answer is as fresh as the last `library` event.

## 4. The Cues page

**The list.** The page edits one list: the one chosen in the left column, a list in the Library window or a linked item in a playlist. A local item's list opens read-only with "Local copies are edited from v1.5" (L2). The page's header names the list, its cue count and its version, with Open in Text Editor (§5), Fire (below) and Renumber… (`edit list N renumber M`, or Swap for a taken number). Edits name a list by its number, so when two lists share one they reach the list that comes first (Spec 7 §2): that list's page says "Another list shares number 57", and the other's opens read-only, offering to renumber the first, after which each has a number of its own.

**The filmstrip** (choice A-2) runs across the top of the center: one tile per cue, in order, each with the cue's thumbnail on the thumbnail stack (the engine's file, Spec 10 §6), its number and label, its section's colour as the left edge (Spec 10 §6's palette), its trigger glyph and, on the live cue, the live dot. It scrolls to keep the selected cue in view.

- **Selecting.** A click selects one cue and the rest of the page shows it. ⇧-click selects a range and ⌘-click adds or removes one: several cues selected is multi-cue editing (below). With the filmstrip focused, the arrows move the selection and ⇧ with them extends it (§2).
- **Moving.** Tiles drag to a new place: `edit list L cue C move K`, several in their order as one group. Move Earlier and Move Later in the menu do the same by keyboard.
- **A tile's menu:** Fire; New Cue After; Duplicate (`… duplicate`); Duplicate Section (`… section duplicate`); Move Earlier; Move Later; Delete (`… remove`, several as one group); Open in Text Editor, on this cue's chunk. The tile at the end, +, adds a cue at the end.
- **Delete** asks first only when the cues hold edits, or include the live cue or the armed one (choice A-11); otherwise undo is the way back. Delete or Forward Delete with the filmstrip focused is the same command.
- **A new cue** holds every channel, has a Go trigger, an empty label and note, and the section of the cue before it: `edit list L insert cues K {…}` with a uuid the app makes, so a group can name the cue it inserts (Spec 5 §4), and the page selects it.
- **An empty list** shows "No cues yet. Add one with +, or paste the song's text in the text editor" (§5).

**Fire** (choice A-13), in a tile's menu and the right column's header, sends what a click on that cue sends where the page's list came from (Spec 10 §6): `item N cue M` in its playlist, after `playlist "TITLE"` when that isn't loaded, or `list N cue M` from the Library window. The header says which ("Fires in Sunday"). As in show mode, it is disabled for a playlist its title doesn't load ("Rename to fire") and a list its number doesn't reach ("Renumber to fire"). A refire runs the whole cue again: its media restarts and its timers and macros run again (Spec 3 §4). Fire is the one control that fires a cue of any list; Next and the go-to field fire within what is live (§2).

**The canvas** under the filmstrip is the engine's picture of the selected cue's projected state (Spec 3 §7), from `render` with `subject.kind` `cue` at the canvas's width (§3), on the thumbnail stack or the stack its picker names. It is asked for again after each `library` event that names the list or anything it draws. A click on it fires nothing.

**The channel rows** under the canvas mirror the strip (UX spec): one row per channel, in number order, then a row for each channel number the cue writes that no channel has (E7), marked "No channel 7", whose only action is Hold, sent as `edit.remove` of those commands in one group. Each row shows the channel's number and label, a three-way control, what the cue writes and the attribute chips.

- **Write, Clear, Hold** (the UX spec's three states, Hold the default). Each sends one `edit.cueChannel` for that cue and channel (Spec 5 §4), keeping the channel's standalone attribute writes. Clear writes `empty`; Hold removes the content command. Leaving a write for Clear or Hold keeps each of its `track` riders as a standalone attribute write and drops its `once` riders, so what tracks from this cue on doesn't change (Spec 3 §3). Write on a held or cleared row opens the content popover (below), and the row writes nothing until something is chosen; a new pick for a write keeps its transition and audio-transition riders and the attribute writes, as a drop does (Spec 10 §10).
- **What it writes.** For media, the pool tile and name, with the missing overlay when the item is missing or deleted (Spec 10 §6). For text, the first line of its body. For a slide or an input, its kind and reference, not editable in v1.
- **The content popover.** For text, the body in a multi-line field (Return makes a line, ⌘Return commits, Escape discards) and a field for each other field the write has, with Add Field for `title`, `reference`, `copyright` or a custom name, and a Variables ▸ menu that inserts Spec 6 §5's names, which text content resolves; it sends on commit, as Spec 10 §10's in-place text does. Double-click on the row instead opens the Text page on this cue's chunk (UX spec). For media, the pool's search and tiles to pick from, and for the chosen item its trim (in and out) and loop as overrides on the write (choice A-6). Loop only turns looping on, since a write can't refuse an item's own loop (Spec 3 §4). Its gain and sync offset fall back to the item's defaults, the sync-offset UI being v1.5 (E9).
- **Drops.** A pool tile dropped on a row writes it there: the same `edit.cueChannel` Spec 10 §10 sends for a drop on a cue, keeping the transition and audio-transition riders and the attribute writes, with the item's default grade as a `grade G once` rider. A file from the Finder is imported, then written, as on a cue in show mode (Spec 10 §6, choice U-8).
- **Attribute chips:** grade, transition, audio transition (E9) and gain, each showing its value and its scope, "this cue only" (`once`) or "from here on" (`track`), with a faint + for one the cue doesn't write. A click opens a popover with the value (None or a grade; a transition whose type applies to pixels; an audio transition; decibels for gain), a duration where the command takes one, the scope, and Remove. On a write the chip is a rider; with Clear or Hold it is a standalone attribute command, which is always `track` (Spec 1 §6), so its popover offers no scope. Each change is one `edit.cueChannel`. Chase and build are v2.
- **Tracking off** (Spec 3 §3 rule 7). A new chip for that attribute is "this cue only". A standalone command reads "this cue only", since that is how it plays here, and an existing `track` rider keeps its scope when its value changes, so a master edited at a campus with tracking off still tracks at the campuses that track.

**The right column**, for one cue:

- **Header:** "Cue 3 of 14 · Great Is Thy Faithfulness", with the live tag on the live cue; ‹ and › (Previous Cue, Next Cue), which move the selection, never the pointer; and Fire.
- **Fields:** label, section (a combo box offering the list's sections and E3's names) and note, each an `edit.set` on commit.
- **The trigger block.** Go, or Time after previous (seconds, to a tenth); Timecode shows, disabled, as v2. Advance after (seconds, or none). Each is an `edit.set` of `trigger` or `advanceAfterMs`. When this cue's Time and the previous cue's advance-after are both set, or this cue's advance-after and the next cue's Time, the block says which one wins, the shorter (Spec 3 §5): "Cue 2's advance-after (8 s) and this cue's Time (12 s) both arm this cue; 8 s wins." Use Previous Video's Length fills Time with the duration of the previous cue's first media write in channel order, within its in and out points, as a number copied once (UX spec).
- **Commands:** the cue's commands other than its channel writes and attribute writes, in their order (stacks, outputs, macros, timers, popups, the system and any other), each as its plain name (Spec 10 §15) with a menu: Edit, Move Up, Move Down, Remove (`edit.set`, `edit.move` by position, `edit.remove` on `commands`, Spec 5 §4 as §12 corrects it). An edit held by the cue shows a warning that it changes the library when fired (Spec 5 §2). A command kept verbatim because it is unknown shows Spec 1 §6's warning and can only be removed.
- **The palette** (E4): Add ▸ offers, grouped by what they touch and only for what exists, Stacks and outputs (`output N stack M`, `stack N blackout`, `stack N mute CHANNEL`, each with on, off or toggle), Macros (`macro N`), Timers (`timer N set DURATION [up]`, `start`, `pause`, `reset`, for the machine's timer slots), Popups (`popup N set "TEXT" [clearafter S]`, `popup N clear`) and System (`system clearall`). Each opens a small form with pickers, and a popup's text has the Variables ▸ menu; Add inserts the command after the selected one, or at the end. Channels are the rows above, which the palette's Channels group focuses. There is no external group in v1 (E4), and the palette offers no edits.
- **Commands as text** (the UX spec's power toggle) swaps the rows and the commands list for one text area: the cue's whole command list, one command per line, in order, in canonical text, parsed as it is typed with OCore's parser (Spec 2 §4), each error beside its line. A multi-line body shows with Spec 2 §2's escapes. A command kept verbatim because it is unknown has no text form, so it shows as its JSON on one locked line and goes back as the object it was (Spec 1 §6). ⌘Return, or leaving the area, sends one `edit.set` of the cue's `commands` with the parsed list, but only while no line has an error: with one, nothing is sent, and leaving asks Keep Editing or Discard Changes, Discard never the default. Escape discards.

**Multi-cue editing** (E5). With several cues selected, the canvas shows the first, and the page becomes the reduced inspector (UX spec): section, the trigger block, and each channel row's attribute chips, without the three-way control or the content. A field whose cues differ reads "Mixed". A change sends one group with one edit per selected cue: `edit.set` for the section and the trigger, and for a chip `edit.cueChannel`, keeping each cue's own content state on that channel. "This cue only" applies to the selected cues that write content on that channel and skips the rest, saying how many it skipped, since on a cue that clears or holds the channel an attribute command always tracks. The pair warning counts every selected cue.

## 5. The text editor

The Text page shows one list's text on one channel as a single scrolling document, cue breaks as rules between chunks (UX spec). It is Area 10.

**Which text** (E1). The header's channel picker lists the channels, those whose `usualContent` is text first. The page opens on the lowest-numbered text channel (channel 2 on first run), or on the channel whose row was double-clicked in the Cues page. It edits the `body` field of that channel's text writes; other fields, other channels and other commands are left as they are, unless a chunk is emptied (R5, below).

**The document.** One chunk per cue, in the list's order, every cue a chunk, even one that writes nothing on this channel (E2). Between chunks, a break: a rule carrying the next cue's number. In the left margin, the section's label at the first chunk of each run of cues that share it, in the section's colour (Spec 10 §6). Beside each chunk, the cue's thumbnail on the thumbnail stack, the engine's file, which updates as the engine redraws it (the `thumbnails` topic), so the look of a typed line shows within a moment. The text itself is plain, in the system font: text has no look of its own here (UX spec). Spelling is underlined but never corrected, and text replacement is off, so "Thee" stays "Thee". Text still being composed (an accent, dictation) isn't sent until it is entered.

**A chunk shows** what the cue does on the channel, from the app's own fold of the list from its top (Spec 10 §6):

- **A text write:** its body, editable.
- **A clear:** an empty chunk, with "Clears" as its placeholder (R5).
- **Hold:** the line the channel holds at that cue, greyed, or "Holds nothing". Typing into a held text turns it into a write: a copy of the held write with the typing in its body (R5). Over held media ("Holds Video: Ocean loop") or nothing, the write is only what was typed.
- **Other content** written on this channel (media, a slide, an input): a row naming it ("Video: Ocean loop"), not editable. A designed slide's tagged text belongs to the slide designer (v2).

**Selection** stays within one chunk, so no keystroke ever reaches two cues. A second ⌘A selects the whole document, for Copy only. Typing, Delete, Cut or Paste over a selection that crosses a break does nothing and says "Select within one cue." Text can't be dragged, and Find has no Replace in v1.

**Typing** sends one `edit.cueChannel` for that cue and channel: the chunk's whole body, with the rest of what the cue says about the channel (its other fields, its riders, its attribute writes) as the latest `library` event left it. It sends at most four times a second while typing, and once when the chunk loses the caret; the engine folds a second of it into one edit and one undo step (Spec 5 §5). A chunk left empty is a clear (R5): the editor sends the clear when the chunk loses the caret empty, keeping the write's `track` riders as standalone attribute writes as the Cues page does (§4), and never sends an empty text write. A chunk the caret passes through without typing sends nothing.

**Near the live cue** (choice A-14). The chunks of the three cues after the live cue, in playlist order, can show at once in a box at +1 to +3, such as the confidence screen's (§2); near a song's end they are the next song's first cues (Spec 3 §7). They send when the caret leaves them, not while typing, and say "On the confidence screen", so half-typed words never reach the stage.

**Breaks** (E2). A chunk is bound to its cue by the cue's uuid, not by its place, so typing in a chunk changes only that cue's text write and never moves another cue's commands.

- **Split:** ⌥Return, or Edit ▸ Split Cue, at the caret. The text above stays with the cue; a new cue right after it takes the text below, in a write with the other fields of the one it was split from and none of its riders, with every other channel held and the label and section copied. One group: `edit.cueChannel`, then `edit.insert` with a uuid the app makes (Spec 5 §5, §4). At the end of a chunk the new cue's chunk is empty, which is a clear until something is typed into it.
- **Merge:** Backspace at the start of a chunk joins it to the chunk above, and forward Delete at the end of a chunk joins the one below to it. The first cue keeps its commands and the joined text, and the second cue is removed. A merge takes a fresh press: a held key stops at the chunk's edge. The editor asks first when the second cue has anything beyond its text on this channel (other commands, riders or attribute writes on this channel, a trigger other than Go, an advance-after or a note), or is the live or the armed cue: "Cue 5 also writes channel 1 and runs macro 3. Merging removes them." Merge is never the sheet's default. One group, `edit.cueChannel` then `edit.remove`.
- **Moving a break:** a break drags to another line boundary, moving those lines from one chunk to its neighbour: one group of two `edit.cueChannel` edits. A break never passes a chunk's last line.
- **What joins.** A split, a merge or a moved break works between chunks of text, clears and holds, a clear or a hold counting as empty text, which becomes a write when text moves into it, with the other fields of the write the text came from. None reaches into a row of other content: Backspace at the start of a chunk under such a row does nothing.

**Paste** (E2, E3, choice A-4) takes plain text; styled text pastes as its plain text, line by line.

- **Breaks.** A line that is empty or only spaces is blank, and a run of blank lines is one break.
- **Section lines.** A line that is only a section name isn't text: it is a break, as a blank line is, and sets the section of the chunk after it (E3). The names are E3's, case-insensitive, with an optional number (Intro, Verse, Verse 1, Pre-Chorus, Chorus, Bridge, Tag, Interlude, Instrumental, Outro, Ending), and may end in a colon or sit in brackets or parentheses ("Verse 1:", "\[Chorus\]"). A section line with no text before the next section line or the end, such as a bare "Instrumental", makes one empty cue in that section, which clears.
- **Repeats.** A repeat mark on its own line, or at the end of a section line ("(2x)", "2x", "x2"), repeats that section's cues so it runs that many times in a row, each copy with new uuids, since a list is played in order.
- **SongSelect's footer.** A closing block that starts with a line beginning "CCLI Song #" isn't lyrics: its song number fills the list's CCLI number and its © line its copyright, where they are empty, and the rest is dropped.
- **Into a list with no cues:** one cue per chunk, all in one group (Spec 5 §5), each holding every other channel, with its section as its label and its section. Pasting a lyric sheet into a new list makes the song in one step, and one undo takes it back.
- **Into a chunk** of a list that has cues: the paste goes in at the caret as if typed with a split at each break. The chunk keeps the text before the caret and the first paragraph; each later paragraph becomes a new cue after it, in a write with the other fields of the chunk's, the last one also taking the text that followed the caret. One group, with the chunk's own edit.
- **No breaks.** A paste of more than four lines with no blank lines and no section lines asks how to break it: Every Line a Cue, Two Lines per Cue or Keep in This Cue. A shorter one is typing.
- **Paste as Two-Line Cues** (⌥⌘V, choice A-15) makes a cue of every two lines within each paragraph, an odd last line alone, with the rest of the rules above, and never asks.

**An empty list** shows one empty chunk saying "Type or paste the song's text". The first character typed creates the first cue and its write as one group, and typing goes on from there.

**The right column:** the list's metadata (title, author, copyright, CCLI number, track through), each an `edit.set` on the list on commit, which field boxes and context values show from the next frame (Spec 5 §2, P12); and, for the chunk with the caret, its cue's label and section (a combo box with the list's sections and E3's names) and Hold, which returns the channel to hold on that cue, keeping `track` riders as §4 says.

**Undo** (choice A-5). ⌘Z and ⇧⌘Z are Edit ▸ Undo and Redo, the library's (Spec 5 §8), while the last change is this editor's own: its open second of typing, or the history's top step when it is a group this editor sent, which it knows from the results' `group` (Spec 10 §3). A step is a second of typing, a split, a merge, a moved break or a paste. ⌘Z sends the chunk's unsent text, then `undo`, which closes the run and takes it back (Spec 5 §5). Otherwise ⌘Z in the editor does nothing and names the last change ("The last change was to stack 1"), so it never undoes what another page, station or source did; Edit ▸ Undo, naming it, still undoes it. An undo or a redo replaces every chunk it names, the caret's included, keeping the caret's place in its text where it can. The text view keeps no undo of its own, so its text never parts from the library's.

**Keys.** The editor is a text field (Spec 10 §9): it takes every key but ⇧⎋, a binding that includes `ctrl`, and the function keys. Return makes a new line within the chunk; ⌥Return splits, as a slide break is made in the reflow editor operators know; ⌘Return leaves the editor, as it commits elsewhere; Tab and ⇧Tab move the focus on (Spec 10 §15). Escape leaves the editor and keeps what was typed, which has already been sent; ⌘Z takes it back. While the editor has the focus the top bar says "Editing text: ⌥Return splits · Esc leaves" (Spec 10 §8).

**Other clients.** A `library` event patches the chunks it names, never moving the caret or the scroll. The chunk with the caret keeps its text, takes the rest of its cue from the event, and says "Changed elsewhere" until it next sends. If its cue is removed elsewhere, its text stays, marked "Cue removed", with Add as New Cue and Copy, and nothing is sent until one is chosen. A local copy, or a list on a `readOnlyMasters` machine, opens read-only (§1).

**What is live.** Editing the live list is allowed: each cue shows its edit at its next fire (L3), and the three after the live cue at once on the confidence screen, hence the rule above.

## 6. The stack editor

The Stacks page edits this machine's stacks, and each output's default stack and transitions (UX spec, E6). Stacks and outputs are machine-level, so the page stays editable on a `readOnlyMasters` machine (Spec 5 §7), apart from its audio routing table, which edits channels.

**The center** shows the selected stack: above, its live picture, the stack's preview surface before blackout (Spec 10 §2), as its multiviewer tile shows it; below, its slots as a vertical list, the bottom slot at the bottom (UX spec). Each row has the channel's number and label, its preset and its opacity:

- **Preset:** a picker offering None, which means the stack's default, else the channel's, else Preset 1 (Spec 6 §2), or a preset by number and label (`edit stack S slot C preset P`). The row names the preset the slot resolves to, and its menu's Edit Preset opens the preset editor on it, at this stack's tab (§8).
- **Opacity:** a slider from 0 to 100% (`… opacity 0.8`).
- **No mute column** (choice A-12). Muting a slot is the strip's stack dots, at runtime (Spec 10 §7); the slot's stored `mute` stays as it was written.

Rows drag to a new place (`edit stack S slot C move K`), and Move Up and Move Down in a row's menu do the same by keyboard. A channel dragged in from the right column adds a slot where it lands (`edit stack S insert slots K {"channel": C, "preset": null, "opacity": 1, "mute": false}`); a channel the stack already holds is refused before the drop lands, since a channel appears once per stack (P13). A row's menu has Remove from Stack (`edit stack S slot C remove`). On a stack an output shows, adding or removing a slot asks first, since it changes the picture at once (Spec 5 §2): "Channel 3's content and its static boxes will show on output 1 now" or "Channel 2 is on air on output 1; removing its slot takes it off."

**The stack's own fields,** under the slots: label; base, black or transparent; default preset, None or a preset; and gamma blend, with "for matching an older look" (Spec 4 §9). Each is an `edit.set`. Its menu: New Stack (`edit stack create`, with an empty label the page shows as "Stack N" until one is typed); Duplicate (`edit stack S duplicate`); Renumber…, with swap for a taken number and Spec 5 §4's warning about the portable references that then name another stack, refused while an output shows the stack, and Swap while an output shows either stack (`onAir`, a Spec 5 §6 addition, §12); and Delete, refused while an output shows the stack (E-7) and asking first when anything refers to it, with the counts from `uses` (§3).

**The right column:**

- **Outputs:** each output with its number and label, its live stack, its default stack and its state from the `outputs` topic (Spec 10 §3); then, under "Not on an output", the stacks no output shows (UX spec). A click on an output selects the stack it shows; a click on a stack selects that stack.
- **The selected output's properties.** Its device, format, colour range and genlock, read-only with Change in Settings…, which opens Settings ▸ Outputs on it (E6, Spec 10 §11). Editable here: its default stack (`edit output N defaultStack M`), and its switch and blackout transitions (`edit output N transitions.switch T`, `… transitions.blackout T`), offering transitions that apply to pixels. Set as Default makes the output's live stack its default stack (UX spec).
- **Channels:** the library's channels, each draggable into the slot list, those the selected stack holds marked.
- **Audio routing:** a table of channels by audio outputs, each cell a checkbox that sends `edit channel N audioOutputs [...]` with the channel's new list (UX spec), keeping the numbers this machine has no audio output for, since another campus meets them (Spec 1 §2). It is the same field the channel sheet edits (§7).

## 7. The channel sheet

The Channels page edits the library's channels (UX spec). Channels are portable, so a channel edit reaches every campus the library syncs to.

**The center** is the channel list, each with its number, label, usual content and the stacks that hold it, and beside it the selected channel's form (UX spec):

- **Number.** Changing it sends `edit channel N renumber M`, which carries every reference in the library and this machine's root with it (Spec 1 §4, Spec 5 §4); a taken number offers Swap (`swap`). Before it sends, a popover says what doesn't follow: "OSC, console and Stream Deck maps that name channel 2 aren't changed, and other campuses' stacks and key bindings still name channel 2 until they're changed there" (UX spec). Renumber is refused while the channel has content in a stack an output shows, and Swap while either channel has content and either is in a stack an output shows (`onAir`, as for Delete), since content on air is held by its channel's number (Spec 3 §2).
- **Label.**
- **Default preset,** a preset by number and label (Spec 6 §2's last fallback before Preset 1).
- **Default transition**, **default audio transition** and **default gain** (decibels, within ±60), which the channel's attributes reset to (Spec 3 §3); an edit shows at the next list boundary, `channel N reset` or clear all (Spec 5 §2).
- **Decoder cap,** 2 or 3, with its cost: one more decoder session and its frame pool, about 100 to 200 MB at 4K (Spec 4 §5, §6).
- **Audio outputs:** a checkbox per audio output on this machine (`audioOutputs`), keeping the numbers this machine has none for (§6), the same field as the stack editor's table.
- **Text thumbnail,** body or first line: how the strip and the pickers show its text (Spec 1 §3, Spec 10 §7).
- **Usual content,** media, text, slide, live or any: the hint that picks the text channel for in-place editing and the text editor (Spec 10 §6, §5 here) and orders pickers.
- **Render size,** largest, or a width and height (Spec 1 §2).

Each field is an `edit.set` on commit, apart from the number.

**The right column** lists the stacks that hold the channel (UX spec), each with Remove from Stack, and Add to Stack ▸ for the others, which adds a slot at the stack's top, asking first on a stack an output shows (§6).

**Its menu:** New Channel (`edit channel create`, with the first-run channels' defaults, Spec 6 §9, and an empty label the page shows as "Channel N" until one is typed); Duplicate (`edit channel N duplicate`); Delete. A channel with content on an output's stack can't be deleted (E-7, `onAir`). Otherwise Delete asks first, with the counts from `uses`: "12 cues in 3 lists write channel 5. They stay in the lists, and the reference report flags them until they're edited" (E7).

## 8. The preset editor

The Presets page edits a preset's layouts and their boxes, and the text styles boxes carry (UX spec, E8, C4). Presets are portable: an edit reaches every campus that shares the library.

**Layouts** (E8). Across the top of the center, a tab for the `*` layout and one per stack this machine has, each naming the stacks it draws on this machine ("Any stack: 1 Main, 3 Side"; "2 Confidence"), with the live dot on those an output shows. A stack's tab without a layout of its own says "Uses the \* layout" and offers Copy from \*, which sets `layouts.S` to a copy of the `*` layout (`edit.set`). A stack's own layout offers Remove This Stack's Layout (`edit preset P unset layouts.S`), asking first. A layout for a stack this machine doesn't have stays in the preset, listed under "Other stacks", since it meets that number at other campuses (Spec 1 §2). The first edit in a run to a layout on air names its stacks and outputs, "and every campus that shares this preset" (§2).

**The canvas** is the layout at its stack's size (§3), the `*` layout at the size of the stack its picker names (the thumbnail stack at first). Its picture is the engine's (choice A-1): `render` with `subject.kind` `layout` and the sample (§3), asked for again after each edit. Over it the app draws each box's outline and handles, labelled with its binding ("body", "pixels", "static") and its offset when it isn't 0 ("+1").

- **Selecting.** A click selects a box, and so does a row of the box list, which is how boxes are chosen by keyboard; Tab and ⇧Tab leave the canvas (Spec 10 §15).
- **Moving.** Dragging moves the box and the handles resize it. With the canvas focused, the arrows nudge the selected box by one pixel of the stack, and with ⇧ by ten (§2); a held nudge sends one edit, when the key is released. Boxes snap to the canvas's edges and centre lines and to other boxes' edges, not while ⌘ is held. The outline follows the pointer; when the drag or the nudge ends, one `edit.set` of the box's `frame`, normalized to the stack's size (Spec 1 §2), and the picture follows.
- **Overflow and fonts.** A text box whose sample text overflows has a red outline and says how many lines were cut, from the render's `overflow` (Spec 6 §4). A box whose font fell back says so, from `fallbackFonts`: "DM Sans Bold isn't installed or bundled; drawn in the fallback font."

**The sample** (UX spec: real text and a real frame) is chosen under the canvas, and is the app's alone, never saved in the preset. Kind: text, media or empty.

- **Text:** the fields of the cue selected in the Cues page when it writes text, with that cue as the sample's `listUuid` and `cue` (§3); else a built-in sample, the first verse of "Great Is Thy Faithfulness" (1923, public domain), with a title and a copyright line. Either can be changed in the sample's own field. For boxes at an offset, the next cues' text, or the built-in sample's next verses.
- **Media:** a pool item, at first the pool's first video or image, as its poster or still (§3).

**The right column:**

- **The preset:** its number (renumber, or swap for a taken number) and label; New Preset (`edit preset create`, with an empty `*` layout), Duplicate (`edit preset P duplicate`, the UX spec's duplicate-from, opening the copy) and Delete, which asks first, with the counts from `uses`. Preset 1 can be edited but not deleted, renumbered or swapped (Spec 5 §6). The campus-override view is v1.5 (§1).
- **Used by,** from `uses` (§3): the channels that default to it, the stacks that default to it, the slots that name it, and the slots that reach it by fallback (Spec 6 §2). The engine's warning about a stack default preset with no pixel box or no body box at offset 0 (Spec 5 §6, Spec 6 §3) shows here.
- **Boxes,** in z-order with the top box first (the layout's `boxes` run bottom to top), each with its binding and its offset. Rows drag to reorder (`edit.move` on `layouts.L.boxes`, by position, a Spec 5 §4 addition, §12), and Move Up and Move Down in a row's menu do the same by keyboard. Add Box ▸ Pixels, Field ▸ (body, title, copyright, reference, or a custom name) or Static Text inserts a box at the top with a frame in the canvas's middle (`edit.insert`); a row's menu also has Duplicate, which inserts a copy above it, and Remove (`edit.remove`), which Delete does with the canvas or the list focused.

**The selected box's properties** (Spec 1 §2), each an `edit.set` of `layouts.L.boxes.I.FIELD` on commit:

- **Binding:** pixels, a field by name, or static text. Static text is a field with a Variables ▸ menu that inserts Spec 6 §5's names (`[Time]`, `[Date]`, `[Timer N]`, `[Popup N]`, `[Service In]` and the context values), sent on commit. Changing between pixels and text sets the whole box in one edit, so it never holds half of each: a box that becomes text gets `shrinkToFit` and text style 1's value (the type's defaults when there is no style 1), and one that becomes pixels gets `fit` and no style.
- **Frame:** x, y, width and height as percentages of the stack, the same values the canvas drags.
- **Fit:** for pixels, fill, fit, stretch or crop; for text, shrink to fit with its minimum size, or at most N lines at the style's size (Spec 6 §4).
- **Transition:** cut or dissolve, the box transitions v1 draws (Spec 1 §2), with a duration of its own or the transition's; and transition on variable change, which a popup box wants (UX spec).
- **Fallback:** draws only when no earlier box at the same offset drew (Spec 6 §3).
- **Offset:** 0 to +3; a box at an offset shows the channel as it will be after that many cues, a pixel box as a poster (Spec 6 §3). The schema's −2 and −1 show as v1.5.
- **Grade:** None or a grade, the box's own correction, apart from the channel's.

**The text style** of a text box (C4) is the box's inline style (Spec 1 §2), shown as a form:

- font, from the `fonts` query's families and faces, the engine's installed and bundled fonts (Spec 6 §4); size, with its unit, points on the 1080-line canvas or a percentage of the output's height; weight, or the axes of a variable font; colour; alignment and vertical alignment; line spacing; letter spacing; outline, its width and colour; shadow, its x, y, blur and colour; all caps. Each change sets one field of `textStyle`.
- **From a numbered style.** The form says which style the box came from (`fromStyle`), and "changed" once its values differ. Apply Style ▸ copies a numbered style's value into the box and sets `fromStyle` (one `edit.set` of `textStyle`). Re-apply copies the style's current value again. Save as Style… asks for a name and sends one group: `edit textstyle N create` with the box's style, then the box's `fromStyle` set to N. N is one more than the highest style number in the catalog or named by any box's `fromStyle`, the number the engine itself would pick (Spec 5 §4), so a new style never adopts a deleted one's boxes; a number taken meanwhile fails the group, and the app tries the next. A style is copied when applied (Spec 1 §2), so changing the box never changes the style.
- **Fonts in the app.** The app registers the bundled fonts for its own process too, from the engine's resources in the same bundle, so the font picker and the style form draw each face in itself. What goes on air is still the engine's drawing.

## 9. The small editors

The Objects page is the UX spec's one parameter-editor frame (C4). On its left, a list in groups (Grades, Transitions, Audio transitions, Text styles, Macros), each with its objects by number and label and, but for Transitions, a + that creates one. The rest of the center edits the selected object; the right column holds what every object shares:

- its number, with renumber, or swap for a taken one (Spec 5 §4), and its label;
- **Used by,** from `uses` (§3);
- Duplicate (the UX spec's duplicate-from) and Delete. Delete asks first, with the counts from `uses`: the references stay, and the reference report flags them (Spec 5 §4, E7). Transitions have neither, and can't be renumbered or swapped (Spec 5 §6).

**Grades** (C4). Each parameter is a slider with a number field and its identity marked (Spec 1 §2): brightness, contrast and saturation from 0 to 200% (100% is identity), hue from −180° to 180° (0°), opacity from 0 to 100% (100%), blur from 0 to the largest radius the grade pass takes (0), and tint, a colour well (white is identity), as Spec 4 §7 applies them. Each sends one `edit.set` when its drag ends. The preview is the engine's picture of a pool item through the grade beside the same item without it (`render` with `subject.kind` `grade`, and `grade` null for the second, §3), the item picked under the preview, at first the pool's first video or image. A grade on air changes from the next frame (Spec 5 §2).

**Transitions** (C4): transitions 1–3 only, as built (cut, dissolve and fade through a colour). Their duration (`ms`) and easing can be edited; their type and colour stay as built, and new transitions wait for the transition editor the planning doc cut. The preview is the easing curve drawn over the duration. A transition already running keeps the timing it started with (Spec 5 §2).

**Audio transitions** (E9, choice A-7): duration, easing, and the offset, signed and measured from the trigger, that makes J and L cuts (UX spec). New, Duplicate and Delete as for grades, the type picked from cut, crossfade and fade through silence.

**Text styles** (choice A-8): the numbered styles, edited with the style form of §8 (`edit textstyle N FIELD VALUE`). Used by lists the boxes that name the style in `fromStyle`. Re-apply to Boxes copies the style's value into every one of them, as one group of `edit.set`s of each box's `textStyle`, after saying how many. Deleting a style leaves each box its own copy; their `fromStyle` then names nothing, which the reference report flags.

**Macros** (UX spec):

- **Commands,** in order, each a row with its plain name (Spec 10 §15) and Edit, Move Up, Move Down and Remove, built with the cue inspector's palette (§4). A macro has no channel rows, so here the palette's Channels group adds channel commands: a write from the pool, a text write, clear, reset, and the grade, transition, audio transition and gain commands. Commands as Text works as in §4. A cycle, or a macro nested past the depth cap, is refused (`cycle`, Spec 5 §6).
- **Fields:** the tile's colour and label, for the Macros tab (Spec 10 §7). A marker shows its scope, computed: a macro that names a stack or an output belongs to this machine, and the engine moves its file to the machine root (Spec 1 §2, Spec 5 §2).
- **Run on Air** (choice A-10) commits an open field first, then sends `macro N` with source `ui`: at once while nothing is live, and after asking while something is. A macro that holds an edit says first "This also changes the library."
- **Used by:** cues, key bindings and scheduler entries, other macros, and the startup and shutdown macros.
- No guards: they are v1.5 (Spec 2 §7).

## 10. Accessibility and localization

Spec 10 §15 holds in edit mode, from the first build. What edit mode adds:

- **VoiceOver.** The filmstrip is a collection whose tiles say their number, label, section, trigger, and "live" on the live cue. The three-way control is a segmented control that names its state ("Channel 2 Foreground: write, text"), and a chip is a button whose label says its value and scope ("Grade 3, from here on"). On a canvas each box is an element that says its binding, offset and frame in percent, with actions to move and resize it by 1% of the stack. In the text editor, the caret entering a chunk announces its cue ("Cue 4, Chorus"), and a split, a merge or a moved break says what it did ("New cue 5 after cue 4"). A rejection and a warning are announced where they show.
- **Keyboard.** Every action has a keyboard path: the pages from the View menu (⌥⌘1 to ⌥⌘6); the filmstrip, lists and canvases with the arrows (§2); reordering with Move Earlier, Move Later, Move Up and Move Down; a box chosen in the box list and its frame typed in its fields; a selected thing's menu with ⌃Return (Spec 10 §15).
- **Colour is never alone.** A section's colour comes with its label, an overflowing box's red outline with how many lines were cut, a mixed value with "Mixed", a read-only page with its reason.
- **Reduce Motion** drops the canvas's snapping animation and the filmstrip's scrolling animation.
- **Localization.** Every string is in the app's catalog (Spec 10 §15). The section names, repeat marks and SongSelect's footer are matched on paste as the catalog lists them, English in v1, so a translated catalog brings its own. Commands in the commands lists read with Spec 10 §15's plain names.

## 11. The areas, and what they change on main

**Area 14** (branch `area/edit`) builds edit mode, all but the text editor. First, in the engine: the edits Spec 7 §7 gives it (channels, stacks, presets, text styles, grades, transitions and macros), with those of audio transitions and of an output's default stack and transitions (§6), their checks, warnings and inverses (Spec 5 §4–§6), a macro's move between the roots, and stack edits between ticks (Spec 5 §2); and the positional move of a box (§8, §12); then the `render` and `uses` queries (§3), on the query answer shape Area 19 builds (§12). Then, in the app, the frame (§2), the Cues page (§4), the stack editor (§6), the channel sheet (§7), the preset editor with text styles (§8) and the small editors (§9). It starts after Area 13, and so after the bench run, like everything in `app/`. Until it lands, show mode's Edit Cue, the double-click into edit mode and the macro tile's Edit stay disabled (Spec 10 §16); the cue menu's Edit Text, show mode's in-place editor, is Area 13's.

**Area 10** (branch `area/text`) builds the text editor (§5) as edit mode's Text page, with split, merge, moved breaks and paste as Spec 5 §5's groups, and Open in Text Editor in the list menus, which stays disabled until it lands. It starts after Area 14, whose frame and Cues page it joins.

**On main.** Nothing in `app/` yet; Area 13 makes the app. In the engine, the thumbnail job (Spec 4 §10) draws a cue's projected state on a stack with the normal stack pass, which `render` reuses at another width, and with a sample for a layout; the loaded documents (Spec 1 §5) are what `uses` walks; Spec 5's edit path, built by Area 9 with the list, cue, folder and playlist edits (Spec 7 §7) and the move by position (§12), carries every edit edit mode sends, and Spec 5 §5's folding the text editor's typing; Area 19 puts the queries on the API with their answer shape (§12).

**Fixtures.** The built-in sample text (§8) ships in the app's resources. Area 10's tests run split, merge, moved breaks and paste against the fixture library's lists (Spec 1 §10) on a scripted engine (Spec 10 §16), with lyric sheets as SongSelect, Word and a typed list leave them; Area 14's run its edits, `render` and `uses` against the fixture roots in the engine, and the pages against the scripted engine.

## 12. Corrections to Specs 1–10 and other documents

These are applied when this spec is accepted. This spec departs from the UX spec in these places: the canvases are the engine's pictures (choice A-1); the Cues page lists its cues in a filmstrip, which the UX spec doesn't have (choice A-2); edit mode's six pages are picked in an edit bar under the top bar, which also holds the small preview the UX spec gives the top bar, and Next, Clear All and the go-to field (choice A-16); a focused editor takes the arrow and delete keys in edit mode (choice A-3); the stack editor has no mute column (choice A-12); a cue can be fired from edit mode (choice A-13); Timecode triggers, chase and builds are v2, and the campus-override view v1.5; a transition's scrubbed preview waits with the transition editor, so v1 shows its easing curve; text styles also have a list of their own (choice A-8), beside C4's box properties.

**Spec 1**

- §5, in the layout, the `thumbnails/` line's "pool tiles in pool/ (Spec 8 §5)" becomes "pool tiles in pool/ (Spec 8 §5); edit mode's pictures in render/ (Spec 11 §3)".

**Spec 2**

- §9, the API envelope. After "the requests only the local socket takes, and the `group` and `applied` an applied edit's result carries." add "A query is answered with its request's `id` as `{"id": …, "type": "answer", …}` and the fields its definition gives, and refused with the rejected result Spec 10 §3 shows. Spec 11 §3 adds the `render` and `uses` queries."

**Spec 4**

- §5, the table. The stack texture row's "| The output size |" becomes "| The output size; for a stack no output shows, that of an output whose default stack it is, else 1920 by 1080 (Spec 11 §3) |". In the thumbnail and multiviewer row, "256 by 144 channel pictures, Spec 10 §2)" becomes "256 by 144 channel pictures, Spec 10 §2; editor pictures up to 1920 pixels wide, Spec 11 §3)".
- §10, Thumbnails. After "the job runs at most 30 thumbnails a second and waits while the render thread is skipping aux passes." add "The same job draws on request, ahead of thumbnails, the operator app's editor pictures: a cue at a chosen width, a preset layout with sample content and the overflow it reports, and a grade on a poster frame (Spec 11 §3)."

**Spec 5**

- §1. "the screens that issue edits (Spec 10 and the edit-mode spec);" becomes "the screens that issue edits (Spec 10 and Spec 11);".
- §4, the vocabulary table. "`edit playlist 2b2b… item 4d4d… move 0` | `edit.move` | Moves a child to a position in its array |" becomes "`edit playlist 2b2b… item 4d4d… move 0`; `edit preset 3 move layouts.2.boxes 1 3` | `edit.move` | Moves a child to a position in its array; a child without an address of its own, such as a box or a cue's command, is named by its array's path and its position (Spec 11 §4, §8) |". In the object form's examples, after `{ "cmd": "edit.renumber", "object": "channel", "channel": 2, "to": 5 }` add `{ "cmd": "edit.move", "object": "preset", "preset": 3, "path": "layouts.2.boxes", "from": 1, "at": 3 }`.
- §6, check 6. ", and a key within its device." becomes ", a key within its device, and a cue's uuid within its list, which the app picks for a cue it inserts (Spec 11 §4)."
- §6, check 7. "An object on air can't be deleted until it is off air" becomes "An object on air can't be deleted, renumbered or swapped until it is off air, a swap checking both objects, since ShowState holds them by number (Spec 11 §6, §7)".
- §8, Keys. "While a text field has focus, ⌘Z and ⇧⌘Z undo that field's own typing; the result reaches the engine as a new text edit (§5)." becomes "While a text field has focus, ⌘Z and ⇧⌘Z undo that field's own typing; the result reaches the engine as a new text edit (§5). Edit mode's text editor is the exception: there they are `undo` and `redo` (Spec 11 §5)."

**Spec 6**

- §1. "The preset editor and text-style authoring belong to the edit-mode spec (Area 14, C4)," becomes "The preset editor and text-style authoring belong to Spec 11 (§8, §9; Area 14, C4),".
- §4. "The app's font picker lists the engine's fonts, as the edit-mode spec will say." becomes "The app's font picker lists the engine's fonts, and the app registers the bundled ones for its own process to draw them (Spec 11 §8)."

**Spec 7**

- §1. "and the cue inspector and text editor to the edit-mode spec." becomes "and the cue inspector and text editor to Spec 11 (§4, §5)."
- §7. "Area 14 for what edit mode edits (channels, stacks, presets, text styles, grades, transitions and macros), Area 17 for settings (outputs, audio outputs, keys and the machine)" becomes "Area 14 for what edit mode edits (channels, stacks, presets, text styles, grades, transitions, audio transitions, macros, and an output's default stack and transitions, Spec 11 §11), Area 17 for settings (the rest of outputs, audio outputs, keys and the machine)".

**Spec 8**

- §7, the use query. "`{"type": "query", "what": "mediaUse", "id": "sha256:…"}` returns `{"cues": 12, "macros": 1, "presets": 0, "keys": 2}`" becomes "`{"id": 63, "type": "query", "what": "mediaUse", "media": "sha256:…"}` returns `{"id": 63, "type": "answer", "cues": 12, "macros": 1, "presets": 0, "keys": 2}`", since a request's `id` is the request's own (Spec 2 §9, as corrected above).

**Spec 10**

- §1. "edit mode, the text editor and the small editors (the edit-mode spec, Areas 10 and 14), apart from how show mode opens them;" becomes "edit mode, the text editor and the small editors (Spec 11, Areas 10 and 14), apart from how show mode opens them;".
- §3, the queries table: after the `fonts` row add "| `render`, `uses` | Spec 11 §3; `render` answers with a file on this Mac, so on the LAN it is `localOnly` |". In "Thumbnails and tiles are files", "The engine writes cue thumbnails and pool tiles in `machine/thumbnails/` (Spec 4 §10, Spec 8 §5)," becomes "The engine writes cue thumbnails, pool tiles and edit mode's pictures in `machine/thumbnails/` (Spec 4 §10, Spec 8 §5, Spec 11 §3),".
- §4. "and the run whose restore banner was dismissed (§14)." becomes "the run whose restore banner was dismissed (§14), and edit mode's last page and each page's selection (Spec 11 §2)." In the menus table, the Edit row's "Find in List ⌘F |" becomes "Find in List ⌘F; in edit mode's text editor, Split Cue ⌥Return and Paste as Two-Line Cues ⌥⌘V (Spec 11 §5) |", and the View row's "Reset Layout; Enter Full Screen |" becomes "Reset Layout; Enter Full Screen; in edit mode, its six pages, ⌥⌘1 to ⌥⌘6 (Spec 11 §2) |".
- §5. "which edit mode or the text editor then fills (the edit-mode spec)." becomes "which edit mode's Cues page or text editor then fills (Spec 11 §4, §5)." In a list's menu, "Duplicate (`edit list N duplicate`); Restore a Version… (§14);" becomes "Duplicate (`edit list N duplicate`); Open in Text Editor (Spec 11 §5); Restore a Version… (§14);".
- §6. "on any other cue it opens edit mode on it." becomes "on any other cue it opens edit mode's Cues page on it (Spec 11 §2)." "Edit Cue (edit mode);" becomes "Edit Cue (edit mode's Cues page, Spec 11 §4);". "Its menu: Remove from Playlist; Show in Library; Grade for Channel N ▸" becomes "Its menu: Remove from Playlist; Show in Library; Open in Text Editor (Spec 11 §5); Grade for Channel N ▸".
- §7. "Edit (edit mode's macro editor, which also makes, renames and removes macros: the edit-mode spec)." becomes "Edit (edit mode's macro editor, which also makes, renames and removes macros, Spec 11 §9)."
- §8. "Status, with a few buttons, the same in show and edit mode apart from what edit mode adds to it (the edit-mode spec)." becomes "Status, with a few buttons, the same in show and edit mode; edit mode's additions sit in its edit bar, under this one (Spec 11 §2)." "over in-place text," becomes "over in-place text and edit mode's text popover and commands as text, "Editing text: ⌥Return splits · Esc leaves" over edit mode's text editor (Spec 11 §4, §5),".
- §9, When bindings fire. Before "5. **A sheet or popover** takes Return and plain Escape." add the item "5. **In edit mode, a focused filmstrip, canvas, or list in the center or the right column** takes the arrows, with ⇧ or ⌥, and Delete and Forward Delete (Spec 11 §2).", the sheet's item becoming 6.
- §10. "live typing at four sends a second is the text editor's (Spec 5 §5, the edit-mode spec)." becomes "live typing at four sends a second is the text editor's (Spec 5 §5, Spec 11 §5)." "While a text field has the focus, ⌘Z and ⇧⌘Z undo its own typing instead (Spec 5 §8)." becomes "While a text field has the focus, ⌘Z and ⇧⌘Z undo its own typing instead (Spec 5 §8), apart from edit mode's text editor (Spec 11 §5)."
- §11. "show here read-only and are edited in the stack editor (E6)." becomes "show here read-only and are edited in the stack editor, which Edit in Stack Editor opens on it (E6, Spec 11 §6)." "Routing a channel to them is the channel sheet's (edit mode)" becomes "Routing a channel to them is edit mode's, in the channel sheet and the stack editor (Spec 11 §6, §7)".
- §15, Keyboard navigation. "A bound key always does its binding." becomes "A bound key always does its binding, apart from the arrows and Delete in edit mode's focused editors (Spec 11 §2)."
- §16. "in the engine, the edits of outputs, audio outputs, key bindings and the machine settings" becomes "in the engine, the edits of outputs (apart from their default stack and transitions, which are Area 14's, Spec 11 §11), audio outputs, key bindings and the machine settings". "Edit mode is Area 14's," becomes "Edit mode is Area 14's and its text editor Area 10's (Spec 11 §11),".

**`app/README.md`**: "it builds Spec 10 (`docs/specs/10-show-mode-ui.md`), which carries over what the clickable demo settled." becomes "it builds Spec 10 (`docs/specs/10-show-mode-ui.md`), which carries over what the clickable demo settled, and Spec 11 (`docs/specs/11-edit-mode.md`) for edit mode."

**`docs/build-order.md`**: rows 10 and 14 name `specs/11-edit-mode.md`; row 14 becomes "Edit mode, minimal: the Cues page with the inspector and palette, stack editor, channel sheet, preset editor with text styles, small editors for grades, transitions, audio transitions and macros; the render and uses queries"; the v1.5 row "Audio transitions: crossfade, fade through silence, J and L offsets, sync offset" becomes "Audio transitions: the sync-offset UI and the strip's split transition bar" (E9); the Area 9 block's edit path gains the move by position and the check that a cue's uuid is unique within its list, and the Area 19 block's queries their answer shape (Spec 2 §9, Spec 5 §4 and §6, as corrected above); the Area 17 block's engine edits of outputs leave out their default stack and transitions, which are Area 14's; and the prompt blocks for Areas 14 and 10.

**`docs/STATUS.md`**: rows 10 and 14 name Spec 11, and the Next block says the specs the scope gaps doc listed are all written.

## 13. Tests this spec implies

Written before the code, from this page: the engine's against the fixture roots (Spec 1 §10), the app's against a scripted engine (Spec 10 §16).

- **Area 9, what this spec adds.** A cue's command moves by position, with its inverse; a cue inserted with a uuid its list already has is refused.
- **Area 14, the engine's edits.** Each edit of a channel, stack, preset, text style, grade, transition, audio transition and macro, and of an output's default stack and transitions, applies with its inverse and its checks (Spec 5 §6); renumbering a channel with content on air, or a stack an output shows, is `onAir`, and so is a swap when either object is; Preset 1 and transitions 1–3 are protected; a macro that comes to name a stack moves to the machine root and back; a stack edit lands between ticks; a box moves by position.
- **Area 14, `render`.** A cue at 480 pixels matches its thumbnail; a layout draws each binding from a text, a media and an empty sample, with `next` at +1 to +3, metadata and context values from the sample's cue and nothing without one; `overflow` names each overflowing box and the lines it cut, and `fallbackFonts` each fallen-back font; a grade draws on a poster and a still, and a null grade draws the item as it is; a stack's size follows its output, then the output that defaults to it, then 1920 by 1080; a newer request for a canvas answers the waiting one `superseded`, and another connection's canvas of the same name is untouched; each canvas keeps its newest two files, a connection's go when it closes and the folder empties at launch; the file is named by connection, canvas and request `id`; on the LAN it is `localOnly`, and a bad width or canvas name, or a ninth canvas, is `badValue`; an unknown object is refused, and a missing file draws nothing with `missing`.
- **Area 14, `uses`.** Each kind of reference for each object type is found, across both roots, fallback slots included for a preset, each kind's entries in their shape (§3); `counts` covers everything while the entries stop at 500 with `more`.
- **Area 14, the frame.** Each way in lands on its page and object; leaving returns the grid to where the list came from, on the selected cue, and fires nothing; an open field commits first, and a refused commit keeps edit mode until a second Done; the lock disables every way in and closes edit mode, offering an unsent field's text; with the filmstrip, a canvas or a list in the center or the right column focused, the arrows and Delete never reach the bindings, while Space sends `next` and ⇧⎋ clears all, and in the left column the arrows fire their bindings; digits fire cue N of the live list whatever list is edited; Escape's order; `editMode` is noted both ways; `view.json` brings back the page and its selection; on a `readOnlyMasters` machine every library object's page is read-only with its reason, while stacks, outputs and machine macros stay editable.
- **Area 14, the Cues page.** A table of each control and the edit or group it sends: Write, Clear and Hold keeping the attribute writes, and leaving a write keeping its `track` riders as standalone writes; a new pick keeping the riders a drop keeps; a chip as a rider on a write and as a tracked command with Clear or Hold; with tracking off a new chip is "this cue only" and an existing `track` rider keeps its scope; a pool tile and a Finder file dropped on a row; trim, and loop only on; New Cue After with the app's uuid, Duplicate, Duplicate Section, Move Earlier and Later, Delete asking only for edits, the live or the armed cue; Fire sending what a show-mode click sends where the list came from, `playlist "TITLE"` first when that isn't loaded, and disabled for a title or a number that reaches another; the trigger block and both pair warnings; Use Previous Video's Length; each palette group, inserted after the selection; a command moved up and down by position; Commands as Text sending nothing while a line has an error, a verbatim command kept as its JSON; multi-cue chips skipping the cues that hold or clear, saying how many; the row for a channel number no channel has; a local copy read-only; of two lists sharing a number, the first editable with its note and the other read-only, offering to renumber the first; Renumber… and Swap in the header.
- **Area 14, the stack editor and the channel sheet.** A slot's preset and opacity; reordering by drag and by menu; a channel dragged in, one the stack holds refused, and adding or removing a slot on a shown stack asking first; Edit Preset opening the resolved preset; a stack's fields, create, duplicate, renumber and delete refused while shown, and swap while either stack is; an output's default stack and transitions, and Set as Default; the routing table and the sheet's audio outputs keeping numbers this machine lacks; renumber's popover and Swap, renumber refused on air and Swap when either channel is; Delete refused on air and asking with its counts otherwise; the routing table read-only on a `readOnlyMasters` machine.
- **Area 14, the preset editor.** Tabs naming the stacks each layout draws; Copy from \* and Remove; one frame edit when a drag or a held nudge ends; snapping and ⌘; Tab leaving the canvas; overflow and fallback from the render; adding, duplicating, removing and reordering boxes; each property's path; a binding change setting the whole box; Apply Style, Re-apply, and Save as Style picking the engine's number and retrying on a taken one; Preset 1 protected; Used by with fallback slots and the stack-default warning.
- **Area 14, the small editors.** A grade edit on release, its ranges and its preview beside the item as it is; transitions 1–3 with only duration and easing, and no New, Duplicate or Delete; an audio transition's offset, New, Duplicate and Delete; Re-apply to Boxes as one group after its count; a macro's Channels group, a cycle refused, the scope marker, and Run on Air committing a field, asking while something is live, and warning for a held edit.
- **Area 10, the text editor.** For a fixture list: a chunk for every cue in each state (a write, a clear, held text, held media, holding nothing, other content); typing sends whole bodies with the cue's latest riders, at most four times a second and once on leaving, and a second of it undoes as one step; composing text isn't sent; an empty chunk sends a clear on leaving, keeping `track` riders, and never an empty write; typing into held text copies the held write; the three chunks after the live cue send only on leaving, the next song's first chunks among them when the live cue is near a song's end; a selection never crosses a break, and the second ⌘A copies only; ⌥Return splits in the middle and at the end, the new write keeping the other fields and none of the riders, and ⌘Return leaves; a merge both ways on a fresh press only, asking when the second cue does more or is the live or the armed cue; a moved break; holds and clears joining as empty text, and nothing reaching other content; paste into an empty list as one group with sections, a section line breaking as a blank line does, a bare section's empty cue, repeats, and SongSelect's footer filling the CCLI number; a paste into a chunk splitting at breaks, the text after the caret in the last new cue; a long paste with no blank lines and no section lines asking, and Paste as Two-Line Cues never asking; ⌘Z sending waiting text then undoing the editor's own change, doing nothing and naming the last change when another page, station or source made it, and replacing the caret's chunk; another client's change patching other chunks, "Changed elsewhere" on the caret's, and "Cue removed" keeping its text; a local copy and a list on a `readOnlyMasters` machine read-only.
- **Areas 14 and 10, accessibility and strings.** Every control labelled and every change announced as §10 says; every action by keyboard; at 1440 by 900, under the accented pseudolanguage and one 40% longer, nothing clipped.

## 14. Resolved choices

These are the places where the scope doc, the UX spec and Specs 1–10 left room and the draft of this spec chose.

**Answered 2026-11-08.** Every choice takes the draft's answer ("Draft"), and the page above reads accordingly. Three independent reviews shaped the draft before Adam answered. They gave a focused filmstrip, canvas or list the plain arrows and Delete, so stepping through cues or nudging a box never fires a cue; made the text editor's ⌘Z send unsent typing first and undo only the editor's own last change; kept a write's `track` riders when its row turns to Clear or Hold; had the app pick a new cue's uuid, so one group can name the cue it inserts; made Fire send what a click sends where the list came from; made a section line in a paste break cues as a blank line does; had a swap check both of its objects, and the routing table keep the audio-output numbers this machine lacks; defined how a query is answered, kept `render` to the local socket and completed what `uses` finds; and gave Area 14 the edits Spec 7 §7 gives it, with a move by position for what has no address of its own, such as a box or a cue's command. The last review also added A-16.

| # | Choice | Draft said | Alternative | Answer |
| --- | --- | --- | --- | --- |
| A-1 | Who draws the editors' pictures | The engine, through a new `render` query: the cue inspector's canvas, the preset editor's canvas with sample content and its overflow, and a grade's preview, exactly as they go on air | The app draws approximations: box outlines with text in installed fonts, and no grade preview, with no new engine work | Draft |
| A-2 | How the Cues page shows the list's cues | A filmstrip of thumbnails across the top, where cues are selected, moved, added, duplicated and deleted | The cues listed in the left column's tree under their list, with those actions in its menus | Draft |
| A-3 | The arrow and delete keys in edit mode's editors | A focused filmstrip, canvas, or list in the center or the right column takes them, so stepping through cues or nudging a box never fires `next` or `previous`; Space and every other binding still fire | They stay show keys as everywhere else: ⌥ with the arrows moves the selection, and plain arrows fire their bindings | Draft |
| A-4 | Pasting text with blank lines into a song that has cues | Splits at each blank line into new cues after the chunk, as if typed with splits | The text goes into the chunk as it is; blank lines make cues only in an empty list | Draft |
| A-5 | ⌘Z in the text editor | The library's undo while the last change is the editor's own (a second of typing, a split, a merge, a moved break or a paste); any other change is left to Edit ▸ Undo | The text view's own typing undo, sent as new text edits (Spec 5 §8); splits, merges and pastes only through Edit ▸ Undo | Draft |
| A-6 | Trim and loop on one media write | The content popover sets in and out points, and turns looping on, for that write | None in v1: a write always plays the item with its defaults | Draft |
| A-7 | Editing audio transitions | Editable in v1 (duration, easing, offset), and made, duplicated and deleted, since the engine already plays them (E9) | As shipped until v1.5: none edited, made or deleted | Draft |
| A-8 | Text styles beyond a box's properties | A list in the Objects page as well, to rename, edit, duplicate, delete and re-apply to every box from a style | Only C4's apply, save as and re-apply inside a box's properties | Draft |
| A-9 | "Used by" | Lists and counts of what refers to an object, from a new `uses` query | Counts only, from the reference report | Draft |
| A-10 | A macro's Run on Air | At once while nothing is live; asks first while something is | Always at once, or always asks | Draft |
| A-11 | Deleting cues | Asks first only when the cues hold edits or include the live or armed cue; undo puts any cue back | Always asks | Draft |
| A-12 | The stack editor's mute column | None: muting is the strip's, at runtime, and the stored value stays as written | A Starts Muted column that seeds the stack's mutes when the engine starts, which needs a Spec 3 §2 correction | Draft |
| A-13 | Firing from edit mode | Fire, in a cue tile's menu and the inspector's header, sends what a click on the cue sends in show mode, in the playlist or Library window the list came from | No Fire: the go-to field fires cues of the live list, and anything else is fired from show mode | Draft |
| A-14 | Typing in the chunks just after the live cue | They send when the caret leaves them, since the confidence screen shows them at once; a cue fired while its chunk has the caret goes on air without the unsent text | They send while typing, like every chunk | Draft |
| A-15 | How a paste makes cues | ⌘V breaks at blank lines and section lines, asking when a long paste has neither; Paste as Two-Line Cues (⌥⌘V) pairs lines | ⌘V pairs lines by two within each paragraph, as two-line lyric slides are made, with ⌥⌘V breaking at blank lines only | Draft |
| A-16 | Where edit mode's controls sit | An edit bar under the top bar: the page picker and Done, and at its right end the live preview, the go-to field, Next and Clear All, so the top bar stays as in show mode | As the UX spec words it: the top bar gains a small preview of the default stack, Next, Clear All and the go-to field keep working by their keys, and the page picker and Done sit in the center's header | Draft |
