# Spec 7: Cues, lists and playlists

2026-11-04 · @Adam Granby · Status: accepted 2026-11-07, with Adam's answers in §11 · Builds on Spec 1 (§2 lists and cues, §3 playlists, §4 identity, §5 the file layout, §8 reloads), Spec 2 (§3 navigation, §6 feedback, §9 the fire record), Spec 3 (§5 the live pointer and triggers, §6 the projection), Spec 5 (editing) and Spec 6 (§5 context values); written from the scope gaps doc's answers (L1–L7) and its review (L3, L5, L7)

Area 9 builds it.

## 1. Purpose and scope

v1 runs a Sunday "from a linked playlist", and nothing yet creates one. This spec settles how lists and playlists are made, edited, filed, archived and loaded, and where `next` goes when an edit, a sync or a restore changes what is live. The runtime is already decided and on `main`: the pointer, list boundaries, `next` and `previous` across items and headers, Go and Time triggers with the armed state, advance-after, section jumps, the `fire` record, and thumbnails from the top of a list (Spec 3 §5–§7, Spec 2 §3 and §9). So are the objects (List, Cue, and a Playlist of linked, local and header items, Spec 1 §2–§4) and the edit vocabulary (Spec 5). Area 9 builds this spec, and with it the edit path of Spec 5 (§7).

**In scope:** list folders on disk (L7); list edits; a playlist's identity, file and loading (L5); playlist items, their uuids and their edits (L3); the live pointer and the armed trigger when what they name changes (Spec 5 §2, L3); archive (L4); local items (L2); the live position and the countdown as feedback (L6); the share of Spec 5 that Area 9 builds (L1); fixtures; and the corrections this makes to Specs 1, 2, 3, 5 and 6 (§9).

**Out of scope:** the screens. The Playlists and Library windows, the grid and the browsed-versus-live marker belong to the show-mode spec, and the cue inspector and text editor to the edit-mode spec. Also out: detach, promote and relink, the Archive tab and detach-all (v1.5, with library mode); template playlists and their import (v1.5, choice Q-12); Timecode triggers and timelines (v2); pre-flight (v1.5); edit undo and the restore commands (Area 12, Spec 5 §8–§9); and arrangements, which are cut for v1, so a repeated chorus is two cues (UX spec).

## 2. Lists and folders

**A list's folder is where its file is** (L7). The Library window's folder tree is the tree of folders under `lists/`: `lists/Worship/Hymns/042-great-is-thy-faithfulness.json` is list 42 in the folder "Worship/Hymns", and a file directly in `lists/` is in no folder. The List has no folder field. Clients get a derived `folder` with each list they query, and it is never written to the file. Folders are directories, so an empty folder exists, and a Finder reorganize or a sync shows up as the same moves in the app, as in the media root (Spec 1 §7).

- **Names.** A folder path is one or more names joined by `/`. A name can't be empty, start with a dot or contain a colon. Names compare without regard to case and keep the case they were typed in, as macOS does.
- **Files.** A list's file name is its number and a slug of its title, for people only (Spec 1 §5). The loader identifies a list by the number and uuid inside the file, and a save renames the file within its folder.
- **The loader** walks `lists/` and the folders in it, skipping any folder whose name starts with a dot, and ignores hidden files and anything that isn't `.json`. It records folders as well as files, so an empty folder survives a reload. `versions/` holds a folder per list, filed by its uuid (Spec 9 §6).
- **Moves.** A list file that turns up in another folder with the same uuid is the same list, moved (Spec 5 §10). A sync can deliver a move as a delete and a create, so a list file that disappears stays loaded for three seconds and counts as deleted only if no file with its uuid appears under `lists/` in that time. If the new file arrives before the old one goes, the two files hold one list for a moment, and the next rule keeps one until the other goes.
- **Two files, one list.** When two files hold the same list (the same uuid), one loads. The engine prefers the file whose name is the one it would write for that list, then the higher `version`, then the later modification date, then the path that sorts first. The other file is reported (Spec 1 §8), so a copy made in the Finder ("… copy.json") never replaces the original (choice Q-5).
- **Two lists, one number.** Two different lists with the same number both load, as on `main`. A playlist link finds the right one by its uuid (§3). Anything that names the number alone, such as `list 57 cue 3` or an edit, gets the one that comes first in the same order, and the report names the clash until one is renumbered (Spec 1 §8).
- **Other files are never replaced.** A save that would rename a list's file onto a name another file holds keeps its old name, and a move onto one is refused with `duplicate`.
- **Case.** On a case-sensitive volume two folders can differ only by case. The tree shows them as one folder, the report names them, and folder edits to that path are refused with `duplicate` until one is renamed.

**Folder edits** (Spec 5 §4):

| Edit | Effect |
| --- | --- |
| `edit folder "Worship/Hymns" create` | Creates the folder. Its parent must exist (`unknownObject` otherwise), so a deeper path is a group of creates |
| `edit folder "Worship/Hymns" rename "Music/Hymns"` | Renames the folder, or moves it when the parent changes, in one directory rename that carries everything in it |
| `edit folder "Worship" delete` | Deletes the folder when it is empty: no lists, no visible files and no folders other than hidden ones. Hidden files and folders go with it, as in the Finder, and an undo doesn't bring them back. Otherwise `notEmpty` |
| `edit list 42 folder "Worship/Hymns"` | Moves the list's file into an existing folder; `""` moves it to the top |

A rename is refused with `duplicate` when the new path exists, ignoring case, unless only the case changes; with `badValue` when the new path is inside the old one; and with `unknownObject` when the new parent doesn't exist. Since no edit creates a folder on the way, every folder edit's inverse is exact, apart from the hidden files a delete removes. Moving a list or a folder is a rename on disk, not a save: no `version` goes up and nothing is copied to `versions/` (a Spec 5 §2 correction, §9).

**List edits** are Spec 5's verbs on a list and its cues:

- **Create.** `edit list 57 create` makes list 57 at the top of `lists/`, or in the folder it names: `edit list 57 create folder "Worship/Hymns"`. Without a body the list has no cues, `trackThrough` off and `version` 1; a body's fields win, its cues and `version` included, so a delete's inverse brings a list back whole. Without a number, `edit list create`, the engine picks one. A number the engine picks, for a list or any other type, is one more than the highest of that type in use or named by any reference, so a new object never takes over references meant for a deleted one (a Spec 5 §4 correction).
- **Metadata.** `title`, `author`, `copyright`, `ccli` and `trackThrough` are set like any field.
- **Delete** removes the list's file. Linked items that name it stay, show as missing (choice Q-4) and are flagged by the reference report (Spec 5 §6's warning). The inverse puts the list back in its folder.
- **Renumber and swap** rewrite the links in every playlist, archived ones included, along with every other reference (Spec 1 §4).
- **Duplicate.** `edit list 42 duplicate`, or `… duplicate 57`, copies the list into the same folder with a new uuid for the list and every cue, the same title and `version` 1.
- **Cues** use the generic verbs on `cues`: insert, remove, move and duplicate, and set `label`, `section`, `note`, `trigger` and `advanceAfterMs`. They also use `section` for a section block and `channel` for write, clear and hold with attribute writes (Spec 5 §4).

## 3. Playlists

**Identity** (L5). A playlist's title is its identity on the machine: trimmed of spaces at either end, never empty, and unique without regard to case. `playlist "TITLE"` therefore names one playlist, and Spec 2 §3 loses its `[DATE]` argument. A startup macro or a console map loads `playlist "Sunday"` and gets whichever playlist carries that name this week. A title held in a macro, a key binding, a scheduler entry or a cue is looked up when it runs, so a rename never rewrites one, and the reference report flags one that names no playlist. A `playlist.load` stored with a `date`, from before this spec, loads by its title and ignores the date. `serviceDate` stays as optional metadata: it sorts the tree, dated playlists by date and undated ones by title in their own group (Spec 1 §3), and it is never part of the identity. `serviceTime` feeds `[Service In]` (Spec 6 §5).

**Clashes on disk.** Edits keep titles unique, but files can arrive that clash: a hand-made file, a restored snapshot, or the dated "Sunday" files Spec 1 §3 allowed until now. Two files with the same playlist uuid load as one: the file named with the plain slug of its title, then the later modification date, then the path that sorts first; the other is reported. Two playlists with the same title both load. `playlist "TITLE"` loads the one whose file has the plain slug, or else the one whose path sorts first, which no save changes, and the report names the clash until one is renamed.

**Files.** A playlist's file name is a slug of its title, made the way list file names are (Spec 1 §5): `playlists/sunday.json`. A title with no letters or digits uses the playlist's uuid. When that name belongs to another playlist's file, the engine takes the first free one of `sunday-2.json`, `sunday-3.json` and so on, and keeps it until the title changes. The loader identifies a playlist by the uuid inside the file.

**Items** gain a `uuid` (L3), unique within the playlist, and a linked item also records its list's uuid (choice Q-9):

```json
"items": [
  { "kind": "header", "label": "Pre-service", "uuid": "4a4a…" },
  { "kind": "linked", "list": 42, "listUuid": "a9f0…", "uuid": "4d4d…" },
  { "kind": "local", "localUuid": "9c9c…", "uuid": "5e5e…" }
]
```

- **A linked item** finds its list by `listUuid`, so it still finds the list after a renumber or a swap made on another machine, and the number in the file is corrected at the playlist's next save. When no list has that uuid, the item is missing, even if another list now has its number. An item without a `listUuid`, from a hand-made file, finds its list by number and records that list's uuid at the next save.
- **An item without a uuid**, from a hand-made file, gets one at load: a UUIDv5 with the playlist's uuid as its namespace and, as its name, the UTF-8 text `KIND:KEY:N`. KIND is `header`, `linked` or `local`; KEY is the label as written, the list number in decimal, or the local uuid in lowercase; N counts the earlier items with the same kind and key, from 0, and counts on while the result is already in the playlist. So the first item linking list 42 is `linked:42:0`. The same file always gets the same uuids, so the pointer and `state/last.json` stay valid across reloads, and they are written at the playlist's next save, never on load alone (Spec 1 §8). An item whose uuid repeats an earlier item's is treated as having none, and is reported.
- **Positions** still count every item, headers included, from 1, as `main` does: `item 4 cue 3` is the fourth item's third cue, and an address that lands on a header is rejected.

**Linked items** show their master's current content. An edit to a master shows in every playlist that links it, archived ones included, at each cue's next fire (UX spec, Spec 5 §2). A linked item whose list is missing or has no cues is skipped by `next` and `previous`, as a header is, and a missing one is flagged by the reference report (choice Q-4).

**Local items** (L2) load and run from `lists-local/` and show their badge. v1 creates none and edits none: inserting one, or editing one, is `notInV1` (Spec 5 §3).

**Playlist edits** (Spec 5 §4, L1):

| Edit | Effect |
| --- | --- |
| `edit playlist create "Sunday"` | A new playlist with no items, no date or service time, not archived |
| `edit playlist P title "Sunday Night"` | Renames it, and its file. An empty title is `badValue` and one in use is `duplicate`; a change of case alone is allowed |
| `edit playlist P serviceDate "2026-11-08"`, `… serviceTime "10:30"` | Sets the date or the service time; `null` clears either |
| `edit playlist P duplicate "Sunday Night"` | Copies it under a new title, with new uuids for the playlist and every item: the same items and `serviceTime`, no `serviceDate`, not archived (choice Q-2). A local item in the copy points at the same local list |
| `edit playlist P archive` | Files a dated, read-only copy and leaves P as it is (§5) |
| `edit playlist P archived true`, `… archived false` | Archives P in place, or restores it (§5) |
| `edit playlist P delete` | Deletes it, archived or not. The live playlist can be deleted: the engine's copy of it runs on until the pointer leaves it (§4) |
| `edit playlist P insert items 3 {"kind": "linked", "list": 42}` | Inserts an item; the engine adds its `uuid` and `listUuid` and logs them (Spec 5 §4). A header is `{"kind": "header", "label": "Worship"}` |
| `edit playlist P item I remove`, `… item I move 0` | Removes or moves an item |
| `edit playlist P item I label "Worship"` | Renames a header |

P is the playlist's uuid and I the item's (Spec 5 §3). The command bar takes `playlist "Sunday"` and `item 4` and expands them, as Spec 5 §3 says. An item inserted with a uuid already in the playlist is `duplicate`. The object form of `create`, `duplicate` and `archive` may carry the uuids they make; the engine picks any that are missing and logs them, so a redo makes the same ones.

## 4. The live pointer

**The pointer** is `{playlist, itemUuid, listUuid, cueUuid}` and names the last cue fired, as Spec 3 §5 has it. Only the item changes: it was a position and is now the item's uuid (L3), under the new key `itemUuid` so that an older state file can't be misread (a Spec 3 §5 correction). A list fired directly from the library has no playlist or item. Browsing never moves the pointer, and neither does an edit, a reload or a library restore (Spec 5 §2 and §9, Spec 1 §8): the engine works out where the pointer stands each time it reads it.

**Its place** is where its cue is now: its item in the playlist and its position in its list. Inserting, removing or moving other items or cues changes nothing, and a song linked twice stays on the right copy. Moving the live cue or the live item takes the place with it, since the pointer follows both by uuid (L3).

**When what it names is gone.** An edit, a sync or a library restore can remove the live cue, item, list or playlist. Spec 5 §2 promises that `next` then fires what followed and `previous` what came before. The engine keeps that promise with **kept copies** of the live list and the live playlist. Whenever the pointer moves, and after every applied edit group, reload or library restore, the engine copies from the library the list and the playlist the pointer names, but only a version that still holds what the pointer names: the list its cue, the playlist its item. Otherwise it keeps the copy it has, so each copy is the last version that held the pointer's cue or item. A fire's copies come from the library the fire read, before any edit the fired cue holds is applied (Spec 5 §2). The engine passes the copies to the projection and the validator alongside the library (Spec 3 §6).

| Gone | Where the place is |
| --- | --- |
| The cue | Just after the nearest cue before it, in the kept copy of its list, that the list still has; at the top of the list if there is none |
| The item | The song finishes first (choice Q-7). The pointer keeps its place in its list, and the item's place in the playlist is just after the nearest item before it, in the kept copy, that the playlist still has, or at the top of the playlist |
| The list | Its kept copy stands in for it, so the song can finish (L3); the item that linked it shows as missing |
| The playlist | Its kept copy stands in for it until the pointer leaves it, so the service can finish |

`next` fires the first cue after the place and `previous` the last cue before it. Both cross items and skip headers and items with no cues, as Spec 3 §5 says. Through a gone item, `next` runs to the end of the song's list and then goes on from the item's place. A list boundary still compares the fired cue's list with the pointer's `listUuid`, which only a fire changes: moving into another song after the live one was removed is still a boundary, and the tracked attributes reset as Spec 3 §3 says.

The kept copies are engine memory, not ShowState. They follow from the library's history, so a replay that rebuilds the library rebuilds them, and `state/last.json` doesn't carry them. When the copies were taken after what the pointer names had already gone, at a launch or a state restore (restore-last-state, and runtime undo in v1.5, Spec 3 §8), the engine can't tell where the pointer stood. `next` and `previous` then do nothing, and `cue N` is rejected if the live list can't be found, until the operator fires a cue, so nothing unexpected goes to air.

**What reads the pointer** reads its place:

| Read | Nothing loaded | A playlist loaded, no cue fired | A cue fired |
| --- | --- | --- | --- |
| `next` | Nothing | The first cue of the first item with cues | The first cue after the place |
| `previous` | Nothing | Nothing | The last cue before the place |
| `cue N` | Rejected: no list is live | Rejected: no list is live | Cue N of the live list |
| Lookahead and +1 boxes | Empty | From the first cue | From the place |
| Context values in static boxes (Spec 6 §5) | Empty | Empty, but `[Service In]` reads the playlist | The live list and cue, from the kept copies when they are gone |
| `[Next Title]` | Empty | The first list's title | The next list after the item's place |

**The armed trigger** gains the item's uuid beside the cue's, `{itemUuid, cueUuid, atFrame}`, so a song linked twice arms the right copy. The trigger is live while its cue is still the one `next` would fire. When the engine clock reaches `atFrame`, the engine sends `next` if the trigger is live and `disarm` if it isn't, both with source `scheduler`, as `main` sends `next` now (choice Q-8). A countdown therefore never fires anything but the cue it announced. An edit after which the armed cue is no longer the one `next` would fire, such as a cue put between the live one and the armed one, or the armed cue moved or removed, makes the countdown lapse: feedback shows it disarmed straight away (§6), the engine disarms it at its time with a log line, and the operator fires on by hand. An edit that makes it next again before its time brings the countdown back. An edit to a trigger or an advance-after takes effect the next time a trigger arms.

`disarm` is a new runtime command (Spec 2 §3, corrected in §9). It clears the armed trigger with a `pointer` effect whose `armed` is empty, so nothing fires on its own; with nothing armed it is a `noop`. An operator can bind it to a key to hold a timed sequence.

## 5. Archive

The UX spec archives a playlist with an explicit command, and an archived playlist is read-only until it is restored, still showing its masters' current content. A weekly playlist runs into two problems with that. Its title is its identity (L5), so an archived "Sunday" would hold the name that next week's needs. And it is usually live, often loaded by the startup macro, while the UX spec disables archive for a live playlist. So v1 archives in two ways (choice Q-1):

- **`archive` files a copy.** `edit playlist P archive` makes a read-only copy of P under a dated title and leaves P exactly as it was. The copy has new uuids for itself and its items, and keeps everything else, `serviceDate` and `serviceTime` included. Since P doesn't change, `archive` works while P is live, and its inverse deletes the copy. The weekly flow is one command: after the service, archive "Sunday", which files "Sunday 2026-11-01", then change this week's songs in "Sunday", and its date if it carries one. A startup macro that loads `playlist "Sunday"` never changes.
- **`archived true` archives in place.** It suits a one-off such as "Easter 2026". It is refused with `onAir` while that playlist is live, as the UX spec disables it, so load another playlist first. `archived false` restores either kind.

**The dated title.** `archive` takes a title, or makes one: P's title, a space, and its `serviceDate`, or the day it runs in the machine's time zone when P has none, written `2026-11-01`. A title that already ends with that date doesn't get it twice. If the result is taken, a space and `(2)`, `(3)` and so on follow it. The logged command records the title, so a redo makes the same one (Spec 5 §4).

**Read-only.** Every edit to an archived playlist is refused with `archived` (Spec 5 §6), except `archived false` and `delete`: an archive can be removed outright, and that is how an `archive` is undone. Two other changes reach it, since neither changes what it records: `duplicate` and `archive` read it and change only their copies, and renumbering or swapping a list rewrites its links like any reference, so an archive keeps naming the same songs. It still shows its masters' current content (UX spec). Detach-all, for a true snapshot, comes with the Archive tab in v1.5 (L4).

**Hidden but loadable.** The Playlists window hides archived playlists behind a filter (L4, the show-mode spec). An archived playlist can still be loaded by its title and run as it is, since loading is not an edit (choice Q-6).

## 6. Feedback

Consoles and clients follow the live position and the countdown (L6). The engine sends them on a fire, a load, an arm and a disarm, and after any applied edit group or reload that changes what they carry: the live item's or cue's number, the playlist's title or the cue's label, a removal of what the pointer names, or a countdown that lapses or comes back (§4).

- **Positions.** `/o/live/item` and `/o/live/cue` send the live item's and cue's numbers as they are now, not as they were when the cue fired. While the live item is gone and its song finishes, `/o/live/item` sends 0, as for a library list, and the cue keeps its number and label. When the live cue is gone, `/o/live/cue` sends the number of the cue just before its place, or 0 at the top, so `next` fires the number after it, and `/o/live/label` sends that cue's label. Before a cue fires, the item and cue are 0 and the label is empty; `/o/live/playlist` sends the playlist's title, or an empty string when none is loaded.
- **The countdown.** `/o/live/armed` carries `i:item` `i:cue` `i:ms`: the positions of the cue that will fire and the milliseconds left when the message is sent. It is sent when a trigger arms and when an edit moves those positions, and with no arguments when the trigger disarms, lapses or fires. `item` is 0 with a library list live, and for a cue in a gone item. It joins Spec 2 §6's table and goes to every target on change.
- **The `live` event** is sent at the same moments. It names the pointer by both handles, in Spec 5's style (a list by number, everything else by uuid), with the positions the OSC messages send, what is gone and the armed trigger. The show-mode spec adds anything else the UI needs from this topic (S2).

```json
{ "type": "event", "topic": "live", "playlist": "2b2b…", "item": "4d4d…", "list": 42, "listUuid": "a9f0…",
  "cue": "22bb…", "position": { "item": 4, "cue": 3 }, "gone": [],
  "armed": { "item": "4d4d…", "cue": "33cc…", "position": { "item": 4, "cue": 4 }, "inMs": 8000 }, "seq": 5131 }
```

`gone` lists what has been removed, of `cue`, `item`, `list` and `playlist`. `armed` is `null` while no trigger is live, and `inMs` is measured when the event is sent. L6 asks for "the engine time it fires". The engine's clock is the machine's monotonic clock, which a console or a client on another machine can't read, so both carry the milliseconds left, and each counts down on its own clock from when it receives them (choice Q-11).

## 7. The edit path Area 9 builds

Area 9 is the first area to apply edits in the engine (L1), so it builds Spec 5's edit path along with this spec's edits (choice Q-10):

- **Spec 5 §2:** the one queue, edits from every source under its three rules, the revision and the `library` event, and the write within a second of the last change, with Spec 1 §4's version cadence (E-3), since Area 9's writes are the first that keep list versions (choice Q-3).
- **§3–§6:** addressing, the verbs with their inverses, groups and typing, validation and results, for lists and cues, folders and playlists. The other objects' edits come with the areas that edit them: Area 14 for what edit mode edits (channels, stacks, presets, text styles, grades, transitions and macros), Area 17 for settings (outputs, audio outputs, keys and the machine), and Area 8 for media defaults.
- **§7:** operator lock and library mode. The engine refuses edits while the machine's `operatorLock.enabled` is on; the passcode, and the commands that turn the lock on and off, are Area 18's. Library mode is honoured as Spec 5 §7 says, and the pilot machine runs `writable`.
- **§10:** changes that arrive on disk, with the conflicts folder. When a list with unwritten edits has moved on disk, the engine's edits still win, and it writes them at the new path.

Area 9 logs each applied edit with its inverse in the Spec 2 §9 entry `main` already builds; Area 12 adds the log file. Area 12 then builds Spec 5 §8, edit undo and redo over the logged inverses, and §9, the restore commands, along with snapshots and `state/last.json`.

## 8. Fixtures

Area 9 rewrites the lists and playlists of `tests/fixtures/library-v1/` to this shape, and updates the playlist schema in `formats/schemas` for an item's `uuid` and a linked item's `listUuid`:

- List 42 moves into a folder, `lists/Hymns/042-great-is-thy-faithfulness.json`, and list 7 stays at the top, so both cases load. An empty folder, `lists/Christmas/`, is held in git by a hidden `.keep` file that the loader ignores.
- The "Sunday" playlist moves to `playlists/sunday.json`, keeping its date, with a `uuid` on every item and a `listUuid` on every linked one.
- A second playlist, "Sunday Night", links list 42 twice, for the pointer tests, and an archived copy of "Sunday", "Sunday 2026-11-01", joins them.
- The spike fixtures stay as they are: their one list sits at the top of `lists/`, which is valid, and `tests/soak/spike.json` runs unchanged.

Tests that need files the fixture shouldn't hold, such as two files for one list, a hand-made playlist without uuids or a hidden folder, make them in a temporary copy.

## 9. Corrections to Specs 1, 2, 3, 5 and 6

These are applied when this spec is accepted, as Spec 5's and Spec 6's were. The scope doc's review already accepted a playlist's title as its identity, the item uuid the pointer follows, real subfolders and `/o/live/armed` (`docs/STATUS.md`); the rest follow from this page. The UX spec stays as written. This spec departs from it in three places: the Archive tab and template playlists wait for v1.5; a playlist's date is optional, so the tree sorts the dated ones by date and the rest by title; and archiving a copy works while the playlist is live (§5).

**Spec 1**

- §2, List. After "`timeline` (*reserved*)." add: "Its folder in the library is the folder under `lists/` that its file is in (section 5, Spec 7 §2)."
- §3, Playlist. "An item is one of `{kind: "header", label}`, `{kind: "linked", list: list number}`, or `{kind: "local", localUuid}` pointing at a local copy in the machine root." becomes "Every item has a `uuid`, unique within the playlist, and is one of `{kind: "header", label}`, `{kind: "linked", list: list number, listUuid}`, or `{kind: "local", localUuid}` pointing at a local copy in the machine root (Spec 7 §3)." Then "The playlist's name is its title; the pair of title and date must be unique on a machine (case-insensitive), and the UI prompts for a different name on a clash, so a weekly "Sunday" playlist is fine as long as each has its date." becomes "The playlist's name is its title, unique on a machine ignoring case; its date is optional metadata and never part of its name (Spec 7 §3)."
- §5, the layout. `lists/`'s note "one file per master: 042-great-is-thy-faithfulness.json" becomes "one file per master, in folders that are the library's folders: Hymns/042-great-is-thy-faithfulness.json". `playlists/`'s note "one file per playlist: 2026-11-01-sunday.json, or sunday-night.json when undated" becomes "one file per playlist, named from its title: sunday.json".
- §5, after the layout. "the loader identifies a file by the `number` inside it and renames the file to match on save." becomes "the loader identifies a file by the `number` inside it, or a playlist's by its `uuid`, and renames the file to match on save, keeping a list in its folder (Spec 7 §2–§3)."
- §5, Writing. "(names beginning with a dot or ending in .tmp, and any file whose JSON does not parse yet)" becomes "(names beginning with a dot or ending in .tmp, anything in a folder whose name begins with a dot, and any file whose JSON does not parse yet)".
- §8, Reference checks. "duplicate numbers within a type," becomes "duplicate numbers within a type, two files holding one list or playlist, two playlists with one title, a playlist load that names no playlist (Spec 7 §2–§3),".
- §8, External changes. After "A reload never touches channel state or the live pointer." add: "A list file that disappears stays loaded for three seconds in case it reappears in another folder, which makes it a move (Spec 7 §2). Where `next` goes when a reload has removed the live cue, item or list is Spec 7 §4's."
- Resolved questions, Playlist naming. The bullet becomes "**Playlist naming:** the title is the name, unique per machine, and the date is optional metadata. Archive files a dated copy, so a weekly "Sunday" keeps its name (Spec 7 §5)."

**Spec 2**

- §3. The row "| `playlist "TITLE" [DATE]` | `playlist.load` | Makes a playlist live at its first cue without firing it | passes | none |" becomes "| `playlist "TITLE"` | `playlist.load` | Makes a playlist live with no cue fired; the first `next` fires its first cue (Spec 7 §3–§4) | passes | none |".
- §3. A new row after it: "| `disarm` | `playlist.disarm` | Clears the armed trigger, so nothing fires on its own; the engine sends it when a trigger's cue is no longer next at its time (Spec 7 §4) | passes | none |".
- §6, Feedback. In the first row, "Live position changes" becomes "Live position changes, including an edit that renumbers it (Spec 7 §6)". A new row after it: "| `/o/live/armed` | `i:item` `i:cue` `i:ms`, or none | A trigger arms, or an edit moves its cue; no arguments when it disarms, lapses or fires (Spec 7 §6) |".

**Spec 3**

- §5. "**The pointer** is `{playlist, item, listUuid, cueUuid}` or, when a master was fired directly from the library, `{list, cueUuid}` with no playlist." becomes "**The pointer** is `{playlist, itemUuid, listUuid, cueUuid}`, where `itemUuid` is the playlist item's uuid, or, when a master was fired directly from the library, `{listUuid, cueUuid}` with no playlist (Spec 7 §4)."
- §5, `next` and `previous`. "crossing item boundaries, skipping headers, and doing nothing past either end." becomes "crossing item boundaries, skipping headers and items whose list is missing or has no cues, and doing nothing past either end. When an edit, a reload or a library restore has removed what the pointer names, they go from its place (Spec 7 §4)."
- §5, Triggers. "`armed = {cue: next, at: fireFrame + ms}` on the following cue" becomes "`armed = {item, cue: next, at: fireFrame + ms}` on the following cue". After "A manual fire of any cue disarms whatever is armed." add: "When the clock reaches `at`, the engine sends `next` if the armed cue is still the one `next` would fire, and `disarm` otherwise (Spec 7 §4)." In the next paragraph, "so lookahead can show what will fire and when" becomes "so lookahead can show what will fire and when, while that cue is still the next one (Spec 7 §4)".
- §6, ProjectionContext. After "`library` (channels, presets, transitions, grades, lists, and the media index whose entry defaults a media write falls back to; read only)," add "`kept` (the engine's copies of the list and playlist the pointer names, Spec 7 §4),". Under Commands, "pointer moves (`next`, `previous`, `cue`, `item`, `list`, `section`, `playlist`)" becomes "pointer moves (`next`, `previous`, `cue`, `item`, `list`, `section`, `playlist`) and `disarm`".

**Spec 5**

- §2, The live pointer. "If an edit removes the cue or item the pointer names (a merge, say, or a delete), `next` fires what followed it and `previous` what came before it. A deleted live list or playlist keeps its loaded copy until the pointer leaves it, so the song or the service can finish (L3)." becomes "If an edit removes the cue the pointer names (a merge, say, or a delete), `next` fires what followed it and `previous` what came before it; if it removes the item, the song finishes first. A deleted live list or playlist runs on from the copy the engine keeps of it, so the song or the service can finish (L3, Spec 7 §4)."
- §2, Writing. "a list moved to another folder moves its file (L7);" becomes "a list or folder moved to another folder is renamed on disk, which isn't a save, so no `version` goes up (L7, Spec 7 §2);".
- §4, the verbs. `create`'s "Creates a numbered object at a free number, a playlist, or a folder." gains " A list can be created in a folder (Spec 7 §2)." `duplicate`'s "or a numbered object to a free number (the UX spec's duplicate-from)" gains ", or a playlist under a new title (Spec 7 §3)". `rename`'s "Renames a library folder" becomes "Renames a library folder, or moves it when the new path has another parent (Spec 7 §2)". `delete`'s inverse, "`edit.create` with the whole previous object", gains ", and a list's folder (Spec 7 §2)". A new row after `duplicate`: "| archive | `edit playlist 2b2b… archive` | `edit.archive` | Files a dated, read-only copy of a playlist and leaves the playlist as it is (Spec 7 §5) | `edit.delete` of the copy |".
- §4, What the log records. After "the logged command records what it picked." add: "A number it picks is one more than the highest of that type in use or named by any reference, so a new object never takes over references meant for a deleted one (Spec 7 §2)."
- §6, The object. "An archived playlist takes only the edit that unarchives it, since archived playlists are read-only until restored (UX spec)." becomes "An archived playlist takes only the edit that unarchives it and `delete`, since archived playlists are read-only until restored (UX spec); `duplicate` and `archive` read it without changing it, and renumbering or swapping a list rewrites its links (Spec 7 §5)."
- §6, Uniqueness. "a playlist title on the machine ignoring case (L5)," becomes "a playlist title on the machine ignoring case (L5), an item's uuid within its playlist (Spec 7 §3),". Then "and those references then resolve to the new object" becomes "and those references then resolve to the new object, apart from playlist links, which follow the list's uuid (Spec 7 §3)".
- §6, Protected objects. "The live list is the exception. Deleting it is allowed, and the engine keeps its loaded copy so the song can finish (L3)." becomes "The live list is the exception. Deleting it is allowed, and the engine runs on from its kept copy so the song can finish (L3, Spec 7 §4). The live playlist can't be archived in place while it is live (Spec 7 §5)."
- §10. After "A list file that moves to another folder and keeps its uuid is a move of that list (L7), not a deletion and a new list." add: "A sync can deliver a move as a delete and a create, so a list file that disappears stays loaded for three seconds before it counts as deleted. When a list with unwritten edits has moved on disk, the engine writes them at the new path (Spec 7 §2, §7)."

**Spec 6**

- §5, the v1 set. `[Next Title]`'s "It skips headers, and is empty after the last list or with no playlist" becomes "It skips headers and items whose list is missing or has no cues, as `next` does, and is empty after the last list or with no playlist (Spec 7 §4)".

**`docs/STATUS.md`**, with the draft's answers to Q-3 and Q-10:

- The Area 12 row. "debouncing, the log file, snapshots and `restoreLastState` remain" becomes "the log file, snapshots and `restoreLastState` remain; the debounced write and the version cadence are Area 9's (Spec 7 §7)".
- The paragraph on Spec 5's engine side. "alongside the debounced write and the versions folder" becomes "alongside the log file", and "The exact split goes into those areas' blocks when their specs are written." becomes "Area 9 builds the edit path with the list, cue, folder and playlist edits, and the debounced write with the version cadence; the other objects' edits come with Areas 8, 14 and 17 (Spec 7 §7)."
- Spec corrections proposed. The first bullet, and `/o/live/armed` in the fourth, are applied and leave the list.

## 10. Tests this spec implies

Written before the code, from this page, against the fixtures as Area 9 rewrites them (§8).

- **Folders.** A list in a folder loads in that folder, and an empty folder survives a reload. A file moved between folders with its uuid is a move, also when it arrives as a delete and a create within three seconds, and no version goes up. Create, rename, move and delete work with exact inverses, and a rename is one directory rename. A rename onto an existing path, into itself or under a missing parent is refused, and a change of case alone is allowed. A folder holding only hidden files deletes, and one holding a visible file is `notEmpty`. Hidden folders aren't walked.
- **Two files, one list.** Of two files with one uuid, the engine's own file name beats a Finder copy, then the higher version wins, then the later date; the loser is reported, and a save or move never replaces it. A copy that arrives before the original goes still ends as a move. Two lists with one number both load, a link finds each by uuid, and `list 57 cue 3` gets the first.
- **Lists.** Create at a number, in a folder, with a body, and without a number (one past the highest used or referenced). Metadata. Delete while a playlist links the list: the item is missing, flagged and skipped by `next`, and the inverse puts the list back whole, in its folder, with its version. Renumber rewrites the links in active and archived playlists. Duplicate gives new uuids in the same folder.
- **Playlists.** Titles are trimmed, unique ignoring case, never empty, and can change case. File names come from titles, with the first free suffix, kept until the title changes. `playlist "Sunday"` loads by title, and a stored load with a date ignores it. Two files with one uuid load once; two playlists with one title both load, the title loads the one with the plain slug however often either is saved. A hand-made file's derived item uuids match the `KIND:KEY:N` rule, are the same at every load, and are written at the next save. A linked item finds its list by uuid after a renumber, and is missing when only its number survives. Positions count headers, and an address on a header is rejected. An item whose list is empty is skipped. Inserting a local item is `notInV1`. Duplicate keeps the items and `serviceTime`, with new uuids and no date.
- **The pointer.** Inserting, removing or moving other items or cues leaves it alone, a list linked twice stays on the right copy, and moving the live cue takes the place with it. With the live cue removed, by a delete or a merge, `next` and `previous` fire its old neighbours; after a section remove that takes the neighbours too, they fire the nearest cues that remain, and with every cue before it gone, the place is the top. The same holds when the change arrives by reload, and when other cues or items were moved or inserted between the fire and the removal. With the live item removed, the song finishes, and `next` then goes on to the item that followed it, also when the item before it was moved since. With the live list or playlist deleted, the kept copy runs on for `next`, `cue N`, lookahead and `[Live Title]`, with any edit made to it before the delete. After any of these, firing into the next song is a boundary, so a tracked grade from the song on air resets. Applying the removal's logged inverse puts the pointer back on the cue without firing it. In each case above, lookahead's first cue and `[Next Title]`'s list are the cue and list `next` fires. After a relaunch with the live cue gone, `next` and `previous` do nothing.
- **The armed trigger.** It fires its cue at its time, with source `scheduler`. A cue inserted between the live and armed cues lapses it: feedback shows it disarmed, and at its time the engine sends `disarm`, not `next`. Removing the inserted cue before then brings the countdown back. A changed trigger counts from the next arming. `disarm` clears the trigger with a `pointer` effect, and is a `noop` with nothing armed.
- **Archive.** `archive` leaves the playlist unchanged, also while it is live, and files a read-only copy titled with its date, or today's, with `(2)` after a space on a clash and never the date twice; its inverse deletes the copy. `archived true` on the live playlist is refused with `onAir`. Other edits to an archived playlist are refused with `archived`, apart from restoring, deleting, duplicating and archiving, and a list renumber still rewrites its links. An archived playlist loads by its title.
- **Feedback.** `/o/live/item` and `/o/live/cue` follow an insert above the live item. With the live cue gone they send the number and label of the cue before the place; with the live item gone, item 0 and the live cue's own number. A retitled playlist and a relabelled live cue are resent. `/o/live/armed` arrives on arming with the positions and the milliseconds, again when an edit moves them, and empty on disarm, lapse and fire. The `live` event carries both handles, the positions, `gone` and `armed`.
- **The edit path.** Spec 5 §11's tests for the edits Area 9 builds: inverse round trips, typing, groups, rejections, lock, library mode, edits held by cues, disk, events, and parse and print. Their clauses about undo steps, redo, restores and the `conflict` code wait for Area 12.

## 11. Resolved choices

These are the places where the scope doc and Specs 1–6 left room and the draft of this spec chose.

**Answered 2026-11-07.** Every choice takes the draft's answer ("Follow draft" for Q-1, "Draft" for the rest), and the page above reads accordingly. Two independent reviews shaped the draft before Adam answered: they replaced the first draft's live pointer with the one in §4, changed Q-1, Q-4 and Q-5, and added Q-7 to Q-12. The first draft's Q-7, uuids for hand-made items, became a fixed rule (§3).

| # | Choice | Draft said | Alternative | Answer |
| --- | --- | --- | --- | --- |
| Q-1 | How a weekly playlist is archived | `archive` files a dated, read-only copy and leaves the playlist as it is, so it works while live and "Sunday" keeps its name; `archived true` still archives a one-off in place | Only in place, as the UX spec has it: refused while live, with the date added to the title so the name is free for next week | Follow draft |
| Q-2 | What a duplicated playlist keeps | Its items and `serviceTime`, with new uuids; no `serviceDate`; not archived | Everything, the date included, which then needs changing by hand | Draft |
| Q-3 | Who builds the edit writer: the one-second write and E-3's version cadence | Area 9, which applies the first edits and can't keep them without it | Area 12, where `docs/STATUS.md` lists debouncing now, with Area 9 writing each change at once until then | Draft |
| Q-4 | A linked item whose list is missing or has no cues | Skipped by `next` and `previous`, like a header, as `main` does; a missing one is flagged | `next` stops there and does nothing until the list returns or the item is removed | Draft |
| Q-5 | Two files holding the same list (one uuid) | The engine's own file name wins, then the higher version, then the later date; the other is reported and never written over | Neither loads until one is fixed | Draft |
| Q-6 | Loading an archived playlist | Allowed by its title; it runs as it is | Refused until it is restored | Draft |
| Q-7 | The live item removed from the playlist | The song finishes: `next` runs to the end of its list, then goes on from where the item was | `next` goes straight on to the next item, as Spec 5 §2 reads now | Draft |
| Q-8 | An edit that changes which cue comes next while a trigger is armed | The countdown lapses: it shows as disarmed, and at its time the engine sends `disarm`, so nothing fires that wasn't announced | The trigger fires the cue it armed wherever that cue now is, skipping any cue put in between | Draft |
| Q-9 | How a linked item names its list | By number and by the list's uuid, so a renumber or swap made on another machine doesn't change which song an item plays. The cost: a list deleted and made again under a new uuid leaves its items missing, and v1 has no relink, so they are removed and added again | By number only, as now: a renumber made centrally retargets this machine's playlists | Draft |
| Q-10 | Area 9's share of Spec 5 | The edit path, with the edits of lists, cues, folders and playlists (L1); the other objects' edits come with Areas 8, 14 and 17 | The edit path with every object type's edits, all in Area 9 | Draft |
| Q-11 | What the countdown carries | The milliseconds left when it is sent; each client counts down on its own clock | The engine time it fires, as L6 words it, which a client can use only with a reading of the engine's clock | Draft |
| Q-12 | Template playlists, which central distributes and campuses import | v1.5, with distribution; in v1, duplicate covers starting from an old playlist | v1, with an import command and a template file format | Draft |
