# Spec 5: Editing

2026-11-04 · @Adam Granby · Status: accepted 2026-11-04, with Adam's answers in §12 · Builds on Spec 1 (objects and format) and Spec 2 (commands); written from the scope gaps doc's answers (C1, C2, L1, L3, L5, L7, E2, S7, S13, G6, M1)

It defines the `edit` family Spec 2 §3 reserves, and it is the first of the specs the scope gaps doc puts in order.

## 1. Purpose and scope

Every change to the library or to a machine's configuration is an `edit` command, run by the engine like any other command. Spec 2 §3 reserves the `edit` target and leaves its vocabulary to this spec. This spec defines where an edit runs and what it writes, how an edit names what it changes, the verbs and their inverses, groups and typing, validation, lock and library mode, edit undo and redo, and how edits meet changes that arrive on disk.

**Out of scope:** the screens that issue edits (the show-mode and edit-mode specs); the media commands `media import`, `media rebuild` and `media replace`, which change the media index through this same path but belong to the media-pool spec; runtime undo and the history view (v1.5); detach, promote, relink and editing local copies (library mode, v1.5); slide documents (v2); the app's own view settings in `machine/view.json` (S8), which are not edits; and secrets, which never travel in an edit (§7).

**Rules every edit obeys**

- An edit changes the library or a machine's configuration and never ShowState. §2 says when each kind of edit shows on air.
- The engine runs every edit and writes every file in both roots, except the app's `machine/view.json` (S8). The app and every other client only send commands (C1).
- An edit names what it changes by number, by uuid within its list or playlist, or by channel within a stack. Only array items with no identity of their own, such as the boxes in a layout, are named by position (§3).
- The engine works out each edit's inverse when it runs the edit, and the log keeps both (Spec 2 §9).
- An edit applies whole or is rejected before anything changes. A group of edits applies as one (Spec 2 §1, §8).
- Every applied edit is logged with kind `edit`, its source and its inverse.

## 2. Where an edit runs

**One queue.** An edit arrives through the API (the operator app is a client of it, Spec 2 §9), through the command bar, or over OSC as `/o/edit/...` (the text form with slashes, Spec 2 §6). It joins the engine's command queue on the control thread with every runtime command. An edit and a fire therefore never race: whichever arrives first lands first.

**From every source.** Every input path can send an edit, an undo, a redo or a restore, as Spec 2 §1 asks of every command (choice E-1, §12). That covers the UI, the API, the command bar, OSC, a key binding, MIDI and Stream Deck, a cue, a macro, the scheduler, and the startup and shutdown macros. Three rules keep that safe on a Sunday:

- **An edit in a cue is permanent.** Firing it changes the library for good, not just for this service. The change is saved, and on a writable machine it syncs like any other edit.
- **A failing edit doesn't stop the cue.** A cue, macro, key binding or scheduler entry may run an edit that lock, library mode or a since-changed library refuses. That edit yields `blocked` with its reason, like a write to a locked channel (Spec 2 §8), and the rest of the group runs; a cue still counts as fired. Edits sent from the UI, the API, the command bar or OSC are rejected as usual, so their groups stay all-or-nothing (§5).
- **Lookahead never edits.** The projection passes edits through untouched (Spec 3 §6). Lookahead, the +1 box and thumbnails therefore show a cue's edit only once the cue really fires.

Edits run by a cue, a macro, a key or the scheduler join the undo stack, one group per run (§8).

**When an edit shows on air.** The engine holds the loaded documents of both roots (Spec 1 §5). An edit changes the document in memory; ShowState never moves (§1). When the change shows depends on when the engine reads what changed:

- **Read when a cue fires**: a cue's commands and triggers, a list's cues, a playlist's items. These show on the next fire of the edited cue (L3). Lookahead and the +1 box show them at once, because they show what will happen. The cue's thumbnail is redrawn because its library version changes (Spec 4 §10).
- **Read every frame**: presets and their boxes, grades, transition and audio transition timing, stacks and outputs, and the list metadata, sections and notes that field boxes and context values show (P5, P12). These show from the next frame, which is what the stack editor's live render expects (UX spec). A transition already running keeps the timing it started with. Text on air keeps its old raster until the new one is ready, so a look edit never blanks a line for a tick (an addition to Spec 4 §9's cache rule). An edit to an output, an audio output or a stack the engine is using takes effect between ticks, the way Spec 4 §5 rebuilds resources. The show-mode spec decides which of these the app asks about first (S12).
- **Copied into ShowState at a reset**: a channel's defaults (transition, audio transition, gain). Spec 3 §2 stores the default values in each channel's attributes, so an edit to them shows at the next list boundary, `channel N reset` or clear all.

The UX spec says any edit takes effect on the next fire. The second group departs from that; it is choice E-6 in §12.

**The live pointer.** An edit never moves the pointer. The pointer follows its playlist item by the item's uuid (L3), so inserting or moving items around the live one changes nothing. If an edit removes the cue the pointer names (a merge, say, or a delete), `next` fires what followed it and `previous` what came before it; if it removes the item, the song finishes first. A deleted live list or playlist runs on from the copy the engine keeps of it, so the song or the service can finish (L3, Spec 7 §4).

**Writing.** The engine writes a changed document with Spec 1 §5's atomic write within one second of its last change. Typing therefore writes at most once a second, and the last keystroke always lands. Each write of a list master increments its `version`; when the previous file is also copied to `versions/` is choice E-3 (§12, Spec 1 §4).

An edit that changes where a file lives does so in the same write:

- a renumbered object or a renamed playlist renames its file;
- a list or folder moved to another folder is renamed on disk, which isn't a save, so no `version` goes up (L7, Spec 7 §2);
- a macro whose edit makes it name a stack or an output moves from the library root to the machine root (Spec 1 §2).

A group that touches several documents writes each one atomically. A crash between two files leaves each file whole, and the reference report (Spec 1 §8) names any reference the crash left behind.

**The revision.** The engine keeps one library revision per run. It starts at 1 at launch and goes up by one for every applied edit group and every reload from disk.

**The library event.** After each applied group or reload, subscribed clients get one event on the `library` topic:

```json
{ "type": "event", "topic": "library", "rev": 214, "cause": "edit", "group": "g-7f1a2b3c",
  "source": { "kind": "ui" },
  "changed": [ { "object": "cue", "list": 42, "cue": "22bb…", "paths": ["commands"] } ] }
```

`cause` is `edit`, `undo`, `redo` or `file`. The event names what changed and carries no object bodies; a client queries the objects it shows.

## 3. Addressing

**Numbered objects** are named by type and number, as everywhere else (Spec 1 §4): `channel 2`, `preset 3`, `textstyle 1`, `grade 5`, `transition 2`, `audiotransition 1`, `macro 12`, `list 42`, `stack 2`, `output 1`, `audiooutput 1`, `input 3`.

**Objects without a number** are named by uuid, within their parent where the uuid alone might not be unique:

- a cue, within its list: `list 42 cue 22bb…`. Spec 1 §4 keeps a cue's uuid stable but doesn't make it unique across the library, and a local copy carries its master's cues (Spec 1 §2);
- a playlist: `playlist 2b2b…`. Its title is its identity for people and for `playlist "TITLE"` (L5), but a rename changes the title, and the log must still say which playlist it was;
- a playlist item, within its playlist: `playlist 2b2b… item 4d4d…`, using the uuid the scope doc adds to items (L3).

Local copies (`lists-local/`) are loaded and run in v1 but not edited (L2). An edit addressed to one is rejected with `notInV1`.

The command bar accepts `list 42 cue 3`, `playlist "Sunday"` and `playlist "Sunday" item 4` as short forms. It expands them to uuids when it parses, just as it expands an abbreviated hash (Spec 2 §2). Only the uuid form is printed and logged, so `parse(print(x)) == x` needs no library.

**Parts of an object** are named by a path: field names as they appear on disk, joined by dots, with array positions as numbers from 0 and map keys as written. Examples: `label`, `defaults.transition`, `layouts.2.boxes.1.frame.x`, `layouts.*.boxes.0.textStyle`. Two kinds of part have names of their own:

- a slot, named by its channel, since a channel appears once per stack (P13): `stack 2 slot 3` is channel 3's slot;
- a key binding, named by its device and key: `keys keyboard "space"`.

Boxes in a layout and scheduler entries have no identity of their own and are named by position.

**Single documents** are named by kind: `machine` for the machine settings (`edit machine network.oscInPort 8001`) and `keys` for the key bindings.

**Media index entries** are named by id (`media sha256:…`). Only their `defaults` can be edited; the rest is read from the file (Spec 1 §7). An edit writes whichever index tier holds the entry: the library index, or the machine index for media that exists only on this machine (M11).

**Library folders** are real folders under `lists/` (L7), named by path: `folder "Worship/Hymns"`. A list's folder is where its file is, not a field, so it changes with its own verb: `edit list 42 folder "Worship/Hymns"` (§4).

**Values** are JSON in the object form. In the text form a value is a Spec 2 §2 token (integer, decimal, duration, string, ref or keyword), or a JSON literal for anything structured, such as `{"a": 1, "b": 1, "g": 1, "r": 1}`. `null` is a value, which clears a nullable field. Removing a key altogether, such as a per-stack layout or an optional key of a command object, is `unset` (§4).

## 4. The vocabulary

The text form is `edit OBJECT ADDRESS [VERB] [ARGUMENTS]`. When the word after the address is a path, the verb is `set`. That is the shape Spec 2 §3 reserves: `edit channel 2 label "Lyrics"`. The other verbs are reserved words that no field uses.

| Verb | Text form | Object `cmd` | What it does | Inverse |
| --- | --- | --- | --- | --- |
| set | `edit channel 2 label "Lyrics"` | `edit.set` | Sets one field at a path; a value equal to the current one is a `noop` | `edit.set` with the previous value, or `edit.unset` where the key was absent |
| unset | `edit preset 3 unset layouts.2` | `edit.unset` | Removes a map entry or an optional key | `edit.set` with the removed value |
| create | `edit preset 7 create`, optionally with a JSON body; `edit playlist create "Sunday"`; `edit folder "Worship/New" create` | `edit.create` | Creates a numbered object at a free number, a playlist, or a folder. A list can be created in a folder (Spec 7 §2). Without a body it takes the type's defaults and a fresh uuid | `edit.delete` |
| delete | `edit channel 5 delete` | `edit.delete` | Removes an object. References to it stay, and the reference report flags them (Spec 1 §8, E7). A folder is deleted only when empty | `edit.create` with the whole previous object, and a list's folder (Spec 7 §2) |
| renumber | `edit channel 2 renumber 5` | `edit.renumber` | Moves an object to a free number and rewrites references to it in the same write (Spec 1 §4; machine-level objects below) | `edit.renumber` back |
| swap | `edit channel 2 swap 5` | `edit.swap` | Exchanges two objects' numbers and both sets of references (Spec 1 §4) | The same swap |
| insert | `edit list 42 insert cues 2 {…}`; `edit list 42 cue 22bb… insert commands 3 {…}`; `edit preset 3 insert layouts.2.boxes 1 {…}` | `edit.insert` | Inserts a value into an array at a path and position | `edit.remove` of what was inserted |
| remove | `edit list 42 cue 22bb… remove`; `edit stack 2 slot 3 remove`; `edit preset 3 remove layouts.2.boxes 1` | `edit.remove` | Removes a child, by its own address or by position | `edit.insert` of the removed value at its old position |
| move | `edit list 42 cue 22bb… move 4`; `edit playlist 2b2b… item 4d4d… move 0` | `edit.move` | Moves a child to a position in its array | `edit.move` back |
| duplicate | `edit list 42 cue 22bb… duplicate`; `edit preset 3 duplicate 9` | `edit.duplicate` | Copies a child to just after itself with new uuids, or a numbered object to a free number (the UX spec's duplicate-from), or a playlist under a new title (Spec 7 §3) | `edit.remove` or `edit.delete` of the copy |
| archive | `edit playlist 2b2b… archive` | `edit.archive` | Files a dated, read-only copy of a playlist and leaves the playlist as it is (Spec 7 §5) | `edit.delete` of the copy |
| section | `edit list 42 cue 22bb… section duplicate`; `… section move 9`; `… section remove` | `edit.section` | Acts on the cue's section block, the run of consecutive cues that share its section label: `duplicate` copies the block to just after itself with new uuids (the UX spec's duplicate-section), `move` moves it, `remove` removes it. The engine runs it as one group of cue edits | That group's inverses |
| folder | `edit list 42 folder "Worship/Hymns"` | `edit.folder` | Moves a list's file to another library folder (L7) | `edit.folder` back |
| rename | `edit folder "Worship" rename "Music"` | `edit.rename` | Renames a library folder, or moves it when the new path has another parent (Spec 7 §2) | `edit.rename` back |
| channel | `edit list 42 cue 22bb… channel 2 write text "…"`; `… channel 2 clear`; `… channel 2 hold grade 5` | `edit.cueChannel` | Sets everything a cue says about one channel. That is its content state (write with content and riders, clear, or hold: the UX spec's three states) plus its standalone attribute writes (`grade`, `transition`, `audiotransition`, `gain`; Spec 1 §6), which can stand beside any of the three. Channel commands stay in channel-number order (Spec 2 §8) | `edit.cueChannel` with the previous state and attribute writes |

Positions in paths and in `insert`, `remove` and `move` count from 0, as JSON arrays do. Cue numbers, which people see, count from 1 (Spec 1 §4). A cue's commands for things other than channels (stacks, outputs, macros, timers, popups) are inserted, removed and moved in its `commands` array with the generic verbs. The raw command view can also set a cue's whole `commands` array as one value.

**What the log records.** When the engine picks something for an edit (a free number, a fresh uuid, the uuids of copies), the logged command records what it picked. A number it picks is one more than the highest of that type in use or named by any reference, so a new object never takes over references meant for a deleted one (Spec 7 §2). Redo (§8) runs the logged commands, so a redone group recreates the same numbers and uuids.

**Renumbering machine-level objects.** A stack, output, audio output or input belongs to one machine, but portable documents name machine-level numbers so that they meet them at every campus (Spec 1 §2). Presets key their layouts by stack, cues hold `output N stack M`, and channels list their audio outputs. Renumbering a machine-level object therefore rewrites references in the machine root only. It leaves portable documents alone and returns a warning listing the portable references that now name something else on this machine. This narrows Spec 1 §4's "every internal reference in the library and the machine root" to the root the object lives in.

**Object form.** Following Spec 2 §4, `cmd` is `edit.` plus the verb. The object's type is in `object`, and its number or uuid sits in a field named after the type, with its parent's beside it:

```json
{ "cmd": "edit.set", "object": "channel", "channel": 2, "path": "label", "value": "Lyrics" }
{ "cmd": "edit.cueChannel", "object": "cue", "list": 42, "cue": "22bb…", "channel": 2, "state": "write",
  "content": { "kind": "text", "fields": { "body": "There is no shadow\nof turning with Thee" } } }
{ "cmd": "edit.insert", "object": "list", "list": 42, "path": "cues", "at": 2,
  "value": { "advanceAfterMs": null, "commands": [], "label": "Verse 2", "note": "",
             "section": "Verse 2", "trigger": { "type": "go" }, "uuid": "33cc…" } }
{ "cmd": "edit.renumber", "object": "channel", "channel": 2, "to": 5 }
```

**The log entry** is Spec 2 §9's, with kind `edit`, undo class `edit`, and the inverse beside the command:

```json
{ "ts": "2026-11-08T08:41:12.004-05:00", "seq": 5120, "group": "g-1c2d3e4f",
  "source": { "kind": "ui" }, "kind": "edit", "undo": "edit", "result": "ok",
  "command": { "cmd": "edit.set", "object": "channel", "channel": 2, "path": "label", "value": "Lyrics" },
  "inverse": { "cmd": "edit.set", "object": "channel", "channel": 2, "path": "label", "value": "Foreground" },
  "text": "edit channel 2 label \"Lyrics\"" }
```

## 5. Groups and typing

**Groups.** Edits sent together (the API's `commands` with `group: true`, Spec 2 §9) apply in order as one group. Every edit in the group is validated first, against the state the earlier ones leave. If any one fails, none of them applies (Spec 2 §8). The edits in a group share one log group id, one `library` event and one undo step.

The text editor's split and merge are groups (E2), and so are the show-mode actions that touch several cues:

- **Split** at a break inside a chunk: `edit.cueChannel` writes the text above the break on the original cue. Then `edit.insert` adds a new cue right after it with the text below, the same label and section, and every other channel on hold.
- **Merge**, when a break is removed: `edit.cueChannel` writes the joined text on the first cue, then `edit.remove` removes the second. When the second cue also wrote other channels, the app warns before it sends the group.
- **Paste into a blank list**: one `edit.insert` per chunk, all in one group, so a pasted lyric sheet is one undo step.
- **The grid's per-channel grade picker** (S7): one `edit.cueChannel` per cue it adds a grade write to.

**Typing.** Edits that set the same text, from the same client, fold into one edit per second (C1, matching Spec 1 §5's one write a second). "The same text" means one `edit.set` path holding a string, or one cue's text write on one channel. A run starts with the first such edit and closes one second later. The engine then writes one log line and pushes one undo step, whose inverse is the value from before the run. If typing continues, the next edit starts a new run, and any other command from that client closes the run early. The app sends the field's whole text, not single keystrokes: at most four times a second while typing, and once when the field loses focus.

## 6. Validation and results

An edit is checked in this order. The first failure rejects it, and nothing changes.

1. **Lock and library mode** (§7).
2. **The object.** It exists, or, for `create`, its number or title is free. A local copy isn't editable in v1 (§3). An archived playlist takes only the edit that unarchives it and `delete`, since archived playlists are read-only until restored (UX spec); `duplicate` and `archive` read it without changing it, and renumbering or swapping a list rewrites its links (Spec 7 §5).
3. **The path.** It exists in the object's JSON Schema (`formats/schemas`, on `main` since Area 2) and is editable. `uuid`, `schema`, `app`, `kind`, `version`, `builtIn` and `number` never are; numbers change only through `renumber` and `swap`.
4. **The value.** It has the field's type and enum, and it is in range. That means Spec 1's ranges (a decoder cap of 2 or 3, box frames 0–1, an audio output delay of 0–1000 ms) and Spec 2 §8's (gain within ±60 dB, offsets within ±1000 ms, opacity 0–1). When an edit changes a cue's commands, commands kept verbatim because they are unknown (Spec 1 §6) pass through unchanged; only the commands the edit adds or changes are validated.
5. **References.** Every number the value names exists on this machine: a preset, transition, grade, channel, stack, output, audio output, macro or list. Every media id is in the index. Loading tolerates a broken reference and degrades it (Spec 1 §8). An edit never creates one, with three exceptions, all flagged by the reference report:
   - a delete leaves the references to what it removed (E7);
   - an undo or redo puts back exactly what was there, broken references included (§8);
   - a portable document may name a stack, output, audio output or input this machine lacks, since it meets those numbers at other campuses (Spec 1 §2).
6. **Uniqueness.** These must be unique: a number within its type, a playlist title on the machine ignoring case (L5), an item's uuid within its playlist (Spec 7 §3), a channel within a stack (P13), and a key within its device. `renumber` and `swap` also refuse a number that broken references still name, so they never adopt references meant for a deleted object. `create` may take such a number, and those references then resolve to the new object, apart from playlist links, which follow the list's uuid (Spec 7 §3); that is how undoing a delete reconnects them.
7. **Protected objects.** Preset 1 and Transitions 1–3 can't be deleted, renumbered or swapped, though both stay editable (the scope doc's review of P13). An object on air can't be deleted until it is off air: a channel with content in a stack that an output shows, or a stack that an output shows (choice E-7, §12). The live list is the exception. Deleting it is allowed, and the engine runs on from its kept copy so the song can finish (L3, Spec 7 §4). The live playlist can't be archived in place while it is live (Spec 7 §5).
8. **Structure.** A folder is deleted only when it's empty. A macro edit passes Spec 2 §5's cycle and depth checks. An edit held by a cue, macro, key binding or scheduler entry is validated when its holder is saved, like any edit (§2).

**Results**

| Result | When | Logged |
| --- | --- | --- |
| `ok` | The edit applied. It may carry `warnings`: a preset used as a stack default without a pixel box or a body box at offset 0 (the UX spec's preset editor), an object deleted while still referenced, a list deleted while a playlist links it, or portable references that a machine-level renumber left naming something else (§4) | Yes, with its inverse |
| `noop` | The edit would change nothing | Yes (Spec 2 §8) |
| `rejected` | A check above failed; the reason is `code: message` | No; answered at the API or the command bar only (Spec 2 §9) |

**Rejection codes:** `unknownObject`, `unknownPath`, `readOnlyField`, `badValue`, `unknownReference`, `duplicate`, `danglingReferences`, `protected`, `onAir`, `archived`, `notEmpty`, `cycle`, `operatorLock`, `readOnlyLibrary`, `conflict`, `notInV1`.

## 7. Lock, library mode and secrets

**Operator lock** (S13). While the lock is on, the engine refuses every `edit`, every undo and redo of an edit, and every restore (§9). The refusal comes from every source, OSC and the API included, with code `operatorLock`; runtime commands pass as they always do. Inside a cue, a macro, a key binding or a scheduler entry the refusal is a `blocked` result rather than a rejection (§2), so the rest of the group still runs. Settings changes are edits of machine objects, so a locked station's settings are read-only. Turning the lock off is the show-mode spec's passcode command, not an edit. Spec 3 §8 already makes this check at the API boundary for edit commands and edit undo; this spec adds redo and restores to it.

**Library mode in v1.** The engine honours `libraryMode` (Spec 1 §3). On a `readOnlyMasters` machine it refuses edits of library objects with code `readOnlyLibrary`: lists and their cues, library folders, channels, presets, text styles, grades, transitions, audio transitions, portable macros and the defaults of library media. Machine-level edits pass, including the defaults of media that exists only on this machine (M11). Two things that make read-only masters workable at a campus arrive with library mode in v1.5: roles that can exceed the machine's mode (the UX spec's librarian), and detach-and-edit. Until then the pilot machine runs `writable` (choice E-2, §12).

**Secrets.** The lock passcode and the API token never travel in an edit, a log line or a snapshot. The show-mode spec gives them their own commands, and only the engine handles those, against the Keychain (the scope doc's R2).

## 8. Undo and redo

**What undoes in v1** (C2). Only edits. Runtime undo and the history view are v1.5, so in v1 `undo` and `redo` (Spec 2 §3) always mean edit undo, and `history jump N` is rejected with `notInV1`.

**One linear stack per run.** The engine keeps the applied edit groups of this run, newest on top, up to the last 500 (choice E-4, §12). The stack starts empty at launch and is cleared at quit. Older states come back through the versions folder and the restore commands (§9).

**Undo** takes the top group and runs its inverses, last first, as one new group. That group is logged with source `restore` and an `undoes` field naming the group it reverses, and its `library` event has cause `undo`. The undone group moves to the redo stack.

**Redo** runs an undone group's logged commands again as one new group, so the numbers and uuids the engine picked the first time come back the same (§4). It is logged with source `restore` and a `redoes` field, and its event has cause `redo`. Any new edit clears the redo stack, so history stays linear (UX spec).

**An undo is validated like any edit**, except that it puts references back exactly as they were (§6). If an inverse would now break another rule (its number has since been taken, say), the undo is rejected with `conflict` and the group stays on the stack.

**A reload drops steps.** When a document is reloaded from disk (§10), every undo and redo step that touches it is dropped, with one log line. An undo therefore never overwrites a change that arrived by sync.

**Keys.** `undo` and `redo` can be bound to keys like any command (UX spec). While a text field has focus, ⌘Z and ⇧⌘Z undo that field's own typing; the result reaches the engine as a new text edit (§5).

## 9. Restores

The log-and-saving spec defines two restore commands (G6): `system restore list N version V` and `system restore snapshot ID`. Both run through the edit path:

- Each one is an edit group whose inverse puts back what it replaced. For a snapshot, the engine first takes a snapshot of the state it is about to replace.
- Each one is logged with kind `edit`, is refused under operator lock (§7), and can be undone like any edit.
- Restoring a list writes it like any save, so its `version` goes up and its versions file follows E-3 (Spec 1 §4).
- A restore changes the library and never ShowState. What it replaces shows on air by §2's rules, as an edit of the same things would.

The log-and-saving spec defines which documents a snapshot restore replaces, and how it treats outputs in use.

## 10. Changes that arrive on disk

Spec 1 §8 reloads a document that changes on disk, such as a master arriving by sync or a hand edit, and keeps nothing-edits-live. Edits add one case: the engine may hold unwritten edits to that document, inside the one-second write window (§2).

- **No unwritten edits.** The engine loads the arriving document, drops the undo and redo steps that touch it (§8), and sends a `library` event with cause `file`.
- **Unwritten edits.** The engine's edits win. It keeps the arriving file in `machine/conflicts/`, named with the time and the file's name, writes its own document, and logs both. The change that lost is one file copy away, as the UX spec's distribution section asks, and nothing is merged (choice E-5, §12).

`machine/conflicts/` sits in the machine root (a Spec 1 §5 addition): it is never synced, and the loader ignores it. A list file that moves to another folder and keeps its uuid is a move of that list (L7), not a deletion and a new list. A sync can deliver a move as a delete and a create, so a list file that disappears stays loaded for three seconds before it counts as deleted. When a list with unwritten edits has moved on disk, the engine writes them at the new path (Spec 7 §2, §7). The rule above applies to it like any other reload.

## 11. Tests this spec implies

Written before the code, from this page, against the fixture library (Spec 1 §10).

- **Inverse round trip.** For every verb on every object type in the fixtures, apply an edit and then its inverse. Every document is byte-identical to before, apart from a list's `version` and its versions files.
- **Undo and redo.** A sequence of groups undone back to the start returns the fixture library to its first state, apart from list versions. Redone, it returns to the end state with the same numbers and uuids. A new edit clears the redo stack.
- **Typing.** A second of text edits to one field folds into one log entry and one undo step. Typing for longer makes one step per second, and any other command from that client closes the run.
- **Groups.** A split, a merge and each section verb make one group, one log group and one undo step. A group with one invalid edit applies nothing.
- **Rejections.** A table with one row per rejection code: each yields `rejected` with that code, nothing changes, and nothing is logged.
- **Renumber and swap** of a portable object rewrite every reference through the edit path (shared with Spec 1 §10's identity test) and undo cleanly. A machine-level renumber leaves portable documents untouched and warns. Neither verb takes a number that broken references still name.
- **References.** An undo that restores a broken reference succeeds, and the reference report flags it. A portable document may name a stack this machine lacks.
- **Nothing edits live.** Editing the text of the cue on air changes no ShowState and no output frame, and the next fire of that cue shows the edit (L3). Editing a preset in use shows from the next frame without a blank tick (E-6). Editing a channel's default transition shows only after a reset.
- **The pointer.** Removing the live cue or item leaves `next` and `previous` working from its place. Inserting an item above the live one doesn't move it.
- **Lock.** With operator lock on, every edit, undo, redo and restore is refused from `ui`, `api` and `osc`, while runtime commands pass.
- **Library mode.** On a `readOnlyMasters` machine, library edits are refused, and machine edits pass, including the defaults of machine-only media.
- **Edits held by cues.** A cue holding an edit changes the library when it fires, as one undo step per fire. Under operator lock that edit is `blocked` and the rest of the cue runs. Lookahead and thumbnails never run it.
- **Disk.** A reload drops the undo steps that touch its document. A change arriving inside the write window lands in `machine/conflicts/`, and the engine's version is written.
- **Events.** Each applied group or reload sends exactly one `library` event, and the revision goes up by one.
- **Parse and print.** Every verb's text form round-trips (`parse(print(x)) == x`). Short forms expand to uuids with a library and are never printed.

## 12. Resolved choices

These are the places where the scope doc and Specs 1–4 left room and the draft of this spec chose. Adam answered each on 2026-11-04. E-1 takes the alternative, widened to every source ("ideally all commands can come from all sources"), and §2 gives the rules for edits held by cues. Every other choice takes the draft's answer (`Rec`), and the page above reads accordingly.

| # | Choice | Draft said | Alternative | Answer |
| --- | --- | --- | --- | --- |
| E-1 | Where edits may come from | The UI, the API, the command bar and OSC. A key binding may hold `undo` or `redo` (UX spec) but not an edit or a restore. A cue, a macro or the scheduler can hold none of them | Also allow a single edit in a key binding or a macro, such as a key that flips a setting | Alternative, ideally all commands can come from all sources |
| E-2 | Library mode in v1 | Honoured: `readOnlyMasters` refuses library edits, so the pilot machine runs `writable` until roles and detach-and-edit arrive in v1.5 | Ignored in v1: every machine edits masters | Rec |
| E-3 | When a list version is kept | A save copies the previous file to `versions/` only when the last copy is more than ten minutes old. A version then marks each editing session, and undo covers the steps inside it. `version` still counts every save. This changes Spec 1 §4's every-save rule | Every save keeps a version, as Spec 1 §4 says. Typing can then make one a second, and every one syncs to every campus | Rec |
| E-4 | Undo depth | The last 500 edit groups, cleared at quit | No limit within a run | Rec |
| E-5 | A change that arrives on disk while edits are unwritten | The engine's edits win; the arriving file goes to `machine/conflicts/`, and both are logged | The arriving file wins; the unwritten edits are dropped and logged | Rec |
| E-6 | When looks show | Read every frame, as the engine does today (Spec 4 §4): an edit to a preset, grade, transition timing, stack, output, or the list metadata a box shows, is on air from the next frame. Content waits for the next fire. This departs from the UX spec's "any edit takes effect on the next fire" | The UX spec's literal rule: looks also wait for the next fire, and each instance keeps the look it started with, which means storing looks in ShowState | Rec |
| E-7 | Deleting something on air | Refused with `onAir` for a channel with content on an output, and for a stack an output shows, until it's cleared or switched away. Deleting the live list is allowed (L3) | Allowed with a warning, as E7 allows for channels that cues still reference | Rec |
