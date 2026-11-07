# Spec 9: Log and saving

2026-11-07 · @Adam Granby · Status: accepted 2026-11-07, with Adam's answers in §11 · Builds on Spec 1 (§3 machine settings, §4 versions, §5 the layout and writing), Spec 2 (§3 the history and system rows, §5 sources, §9 the log entry and the API), Spec 3 (§2 ShowState, §3 lock, §8 restores), Spec 4 (§12 failure modes, §13 the black box), Spec 5 (§2 the write and the library event, §3 addressing, §6 validation, §8 undo and redo, §9 restores, §10 changes on disk), Spec 6 (§6 timers, §7 popups), Spec 7 (§2 versions, §4 the pointer and kept copies, §7 the edit path Area 9 builds) and Spec 8 (§2 and §6); written from the scope gaps doc's answers (G1–G6, C2) and its review (G6 with S13)

Area 12 builds it.

## 1. Purpose and scope

Everything already saves as it changes: Spec 1 §5 writes each document atomically, Spec 5 §2 writes an edit within a second, and Spec 1 §4 keeps a list version per editing session. This spec adds what sits on top: the logs on disk, snapshots of both roots, the last state that brings the screens back after a crash, edit undo and redo as Area 12 builds them, the two restore commands, and what is kept and for how long. On `main` since Areas 2 to 4 are the Spec 2 §9 entry with its one-line form, the atomic writer with its write plans, the versions folder, the `restoreLastState` and `snapshots` settings, the loader reading `state/last.json`, the black box and the engine's log; Area 9 adds the edit path, the debounced write and E-3's version cadence (Spec 7 §7).

**In scope:** the command log, the engine log and the black box on disk, their writers and their lines, notes from clients and from the engine (G4); snapshots, what they hold and when they're taken (G1, G2); `state/last.json` and restore-last-state (G5); what Area 12 builds of Spec 5 §8's edit undo and redo, with the `history` topic (C2); the restore commands and the queries behind their pickers (G6), and how kept versions are filed so a restore can trust them; retention (G3); a low or full disk and the `saving` topic (Spec 4 §12); fixtures; and the corrections this makes to Specs 1–8 (§9).

**Out of scope:** runtime undo, its per-command channel snapshots and the log entry's `snapshot` field (v1.5); the history view, its plain-language rows and `history jump` (v1.5); the restore pickers and confirmations themselves, and the badges, which belong to the show-mode spec; the layout a sync tool uses to send logs and snapshots upward (v1.5's distribution conventions); CCLI reporting over the log (later); and pre-flight (v1.5).

## 2. The logs

**Three logs**, each a JSON line per entry, each written by the engine alone (G4):

| File | What | Split |
| --- | --- | --- |
| `machine/logs/commands-YYYY-MM-DD.jsonl` | Every executed command, and the notes below | By the machine's local day, in Spec 1 §3's `timeZone` (choice G-8) |
| `machine/logs/engine-YYYY-MM-DD.jsonl` | What the engine's log writes, Spec 4 §12's detail (watchdog lines, recoveries, severe events, thermal and memory-pressure notes); a copy of each minute record (Spec 4 §13); and the media index changes of an import or the walk, by id (Spec 8 §2) | By local day |
| `machine/blackbox/blackbox-YYYY-MM-DD-HH.jsonl` | Every tick, present and minute record (Spec 4 §13) | By UTC hour |

The black box writes about 100 MB an hour, so its size cap keeps only hours of it (§7). It has its own folder and a file an hour so the cap holds within a day and a sync tool sending `logs/` upward doesn't carry it. The engine log is small and keeps the minute records and the engine's events for a Monday postmortem. The scope doc's review called the second file `metrics-…`; it is `engine-…` here because it carries the engine's log as well as metrics.

**Engine log lines** each carry `ts` and the run's uuid, so a postmortem can place a minute record in time and tell runs apart. `kind` says what follows: `start` (opening each run's part of the file, with the app version and the machine), `log` (with `level`, `category` and `message`, as the engine's log has them), `minute` (the minute record's fields) or `media` (an index change, with its operation and ids).

**How they're written.** The control thread hands each applied group's lines to a utility thread, which appends them in order, so nothing on the control or render threads waits for the disk. A group's lines go out in one write ending in a newline, and each file is synced once a second. When the engine opens a file whose last byte isn't a newline, as a crash or a power cut can leave it, it ends that line first. Readers skip a line that doesn't parse, so a crash loses at most the last second.

**What goes in the command log:**

| Line | When | `kind` |
| --- | --- | --- |
| Every executed command with its result (`ok`, `blocked`, `noop` or `steppedOn`), a macro's own line and a navigation line included | As Spec 2 §9 says | `runtime` or `edit` |
| An edit with its inverse; an undo or a redo with `undoes` or `redoes` | Spec 5 §8 | `edit` |
| A note a client sends, or one from the engine | Below | `note` |

Not in it: rejected commands, which are answered at the API and the command bar only (Spec 2 §9), and the index changes of an import or the walk, which aren't commands (Spec 8 §2).

**Runs.** `seq` counts from 1 at each launch. The engine's `start` note opens each run with the run's uuid, so a run and a `seq` name one line, whichever day's file it is in.

**Notes.** Some things worth a line aren't commands: a client's UI-only actions, which Spec 2 §9 calls browsing, and the engine's own events. A client sends `{ "id": 31, "type": "note", "note": { … }, "text": "…" }`; the engine stamps `ts`, `seq` and the client's source, writes the line, and answers `ok` with the `seq`. A note line carries `ts`, `seq`, `source`, `kind`, `note` and `text`, and `dropped` when notes were dropped before it; it has no `group`, `command`, `undo` or `result`:

```json
{ "ts": "2026-11-08T09:02:11.540-05:00", "seq": 312, "source": { "kind": "ui" }, "kind": "note",
  "note": { "event": "listOpened", "list": 42 }, "text": "Opened Great Is Thy Faithfulness" }
```

A note changes nothing and is never undone. Which actions the app notes is the show-mode spec's, such as opening a list or entering edit mode. `text` holds at most 1,000 characters and `note` at most 4 KB, or the note is refused with `badValue`. One client's notes are capped at ten a second (choice G-9): beyond that a note is answered `noop` and not written, and the next note written carries `dropped` with the count. The engine's notes have source `engine` (Spec 2 §5):

| `event` | Written | Fields |
| --- | --- | --- |
| `start` | At launch | `run` (its uuid), `app`, `machine`, `previous` (`clean`, `unclean` or `none`) |
| `stop` | When the engine stops on request, after the shutdown macro (§4) | `unsaved`: any document it couldn't write (§7) |
| `lastStateRestored` | After a restore of the last state (§4) | `writtenAt`; `state`, the ShowState put back, so a replay of the run starts from it; `left`, what didn't come back |
| `lastStateSkipped` | When the setting is on and the last state isn't restored (§4) | `writtenAt`, `reason` (`clean`, `old` or `restoredBefore`) |
| `snapshot` | After an automatic snapshot (§3) | `id`, `reason` |
| `conflict` | When a file arriving on disk loses to unwritten edits (Spec 5 §10) | `document`, `kept`: where the arriving file was kept |
| `stepsDropped` | When a reload or the media walk drops undo or redo steps (§5) | `groups`, `cause` (`file` or `media`) |
| `logToMemory`, `logToFile` | When a full disk moves the logs to memory and back (§7) | `lost`: lines that couldn't be kept |

**Captions.** Spec 6 §7 leaves to this spec whether a captioning feed's popup lines are kept in full. They are: three lines a second come to about 4 MB an hour, well inside §7's limits, and a full log is what CCLI reporting and a postmortem read.

**Privacy.** The command log carries content (lyrics, captions, a nursery call's name), and the engine log can carry file names. The black box carries numbers and ids only (Spec 4 §13), so it is the one to share outside the organization.

## 3. Snapshots

**What one holds** (G1). A snapshot is one zip file holding the documents of both roots, as the engine holds them at that moment, unwritten edits included. Inside the zip they sit under `library/` and `machine/` at the paths Spec 1 §5 gives them, with a manifest, `snapshot.json`:

```json
{ "schema": 1, "app": "0.1.0", "kind": "snapshot", "id": "2026-11-08-085959",
  "takenAt": "2026-11-08T08:59:59.120-05:00", "reason": "playlist",
  "machine": "7d1e…", "campus": "Manheim", "library": "c3f0…", "run": "51e2…", "seq": 4821,
  "folders": ["Hymns", "Worship/New"] }
```

`reason` is `launch`, `playlist`, `timer`, `command` or `restore`; `run` and `seq` name the last command logged before it; `folders` lists the library's folders, so an empty one survives a restore (Spec 7 §2). Left out: `media/`, `logs/`, `snapshots/`, `thumbnails/`, the black box, the machine's own media folder (`machine/media/`, Spec 8 §2) and the media cache, as G1 says, and also `versions/`, `conflicts/` and `state/` (choice G-6). The media is named by hash and kept versions are never written over (§6), so what's left is what is worth keeping, a few megabytes for a whole library.

**The file.** `machine/snapshots/<id>.zip`. The id is the local date and time to the second, `2026-11-08-085959`, with `-2` and on added for a second snapshot in the same second. The engine copies the documents on the control thread, so a snapshot is one consistent moment, then writes the zip on a worker at background priority, under a hidden name renamed when complete (Spec 1 §5). It uses deflate, so the Finder and `unzip` open it.

**When** (G2):

| When | `reason` |
| --- | --- |
| At launch, after the last state and before the startup macro (§4) | `launch` |
| When a playlist is loaded (`playlist "TITLE"`, Spec 7 §3), the v1 stand-in for a service start | `playlist` |
| Every ten minutes (choice G-4) | `timer` |
| On `system snapshot` | `command` |
| Before a snapshot restore replaces anything (§6) | `restore` |

An automatic snapshot (`launch`, `playlist` or `timer`) whose documents equal the newest snapshot's isn't written, so the ten-minute timer writes one only when something has changed. Automatic snapshots also pause while the disk is low (§7). `system snapshot` always writes one; its result arrives once the file is complete and names it: `{ "id": 40, "type": "result", "result": "ok", "snapshot": "2026-11-08-085959", "seq": 4830 }`.

**Settings.** `snapshots.cadence` and `snapshots.retention` (Spec 1 §3) have one value each in v1: `launchAndService`, the table above, and `7d-daily-weekly`, §7's rule. Any other value is kept as written, read as the v1 one, and reported.

## 4. The last state

**Written** (G5). `machine/state/last.json` holds ShowState (Spec 3 §2) as the engine last projected it, and some facts about the run that wrote it:

```json
{ "schema": 1, "app": "0.1.0", "kind": "state", "writtenAt": "2026-11-08T09:41:07.002-05:00",
  "run": "51e2…", "clean": false, "restored": false, "pendingClears": [3],
  "state": { "channels": { … }, "outputs": { "1": 1 }, "stacks": { … }, "pointer": { … },
             "armed": null, "popups": { … } } }
```

- At launch the engine writes it before it does anything else with the last state: with its run's uuid, `clean: false`, and `restored: true` when it is about to put that state back (below). If it isn't putting a state back, the file holds the empty state it starts from.
- After a runtime group, within a second, and at most once a second while groups keep coming, so a caption feed can't hold it back.
- At least once a minute while the engine runs, so `writtenAt` says when the run was last alive, not when the last cue was fired.
- When the engine stops on request, such as the app's quit or the Mac shutting down, it runs the shutdown macro, then writes the file at once with `clean: true`. A crash, a power cut or a force quit leaves `clean: false`.

`restored` stays `true` for the first minute after a restore, whatever runs in it, and is `false` after that. `pendingClears` lists the popup slots with a clear-after still counting (Spec 6 §7). Every write is atomic (Spec 1 §5) and happens whether or not `restoreLastState` is on. Edits never change ShowState (Spec 5 §2), so they don't write it. A full disk removes the file (§7). The new keys are optional, so the fixture's file reads as before.

**When it comes back** (choice G-1). At launch, with `restoreLastState` on, the engine restores the last state when all three hold: its run didn't end cleanly; it was written less than two hours ago, so the run was alive then; and it isn't `restored: true`, which would mean the engine stopped within a minute of putting it back, as it would if the state itself crashed it. Otherwise the launch starts empty, and a `lastStateSkipped` note says why. A state that crashes the engine is so restored once at most, and nobody has to touch a file to get the screens working again.

**What comes back**, the way Spec 3 §8 replaces ShowState:

- Content and tracked attributes with their origins, outputs on their stacks, stacks with their blackout and muted channels, and locks (choice G-3).
- Popups with their text, apart from those with a pending clear-after: they were on their way off, and a nursery call shouldn't stay up until someone notices.
- The pointer, as it was saved, whatever its shape: a cue fired, a playlist loaded with no cue fired, or a list fired from the library (Spec 3 §5). Where what it names has gone, Spec 7 §4 says what it does.
- Video and audio start again from their in-points: `startedAtFrame` is the frame of the restore, and the transport is as it was. Playheads come back with runtime undo (v1.5). For the restore, media counts as present when its file is at its location, without waiting for the walk to hash it; the walk settles it afterwards (Spec 8 §4).
- Every change is a cut, every restored channel's provenance is `restored` keeping its cue and list, and outgoing instances are dropped.
- `armed` is cleared. Timers aren't in ShowState and come back unset, as Spec 6 §6 says.
- A channel the library no longer has is left out, and content whose media no index knows, or whose file isn't there, comes back missing.

The engine then writes a `lastStateRestored` note carrying the state it put back.

**Launch order:**

1. The roots load (Spec 1 §8) and the media walk starts (Spec 8 §4).
2. The `start` note (§2).
3. `last.json` written for this run, then the last state put back or not.
4. The launch snapshot (§3).
5. The startup macro, unless the last state was restored (choice G-2).
6. The retention pass (§7).

The engine takes commands from step 5 on.

## 5. Edit undo and redo

Spec 5 §8 defines them, and Area 12 builds them (C2, Spec 7 §7):

- The stack of this run's applied edit groups, 500 deep, empty at launch and cleared at quit. `undo` runs the top group's logged inverses, last first, as one group with source `restore` and an `undoes` field; `redo` runs an undone group's commands again with `redoes`; a new edit clears the redo stack. An undo that would break a rule fails with `conflict` and stays on top.
- Steps are dropped, with a `stepsDropped` note, when a document they touch reloads from disk (Spec 5 §10) or the media walk maps an entry they name to another file or brings it back (Spec 8 §4).
- Operator lock refuses undo and redo of edits (Spec 5 §7), and `history jump N` is refused with `notInV1`.
- Undoing a restore runs the restore that is its inverse (§6). While a snapshot restore, or its undo or redo, works on the worker, later edits, undos and redos wait behind it (§6).

**The `history` topic.** So the app can enable Undo and Redo and name them, the engine sends an event when a client subscribes and whenever either stack changes:

```json
{ "type": "event", "topic": "history",
  "undo": { "group": "g-7f1a2b3c", "commands": 1, "text": "edit list 42 title \"Great Is Thy Faithfulness\"" },
  "redo": null, "seq": 5230 }
```

`text` is the group's first command in its canonical form and `commands` how many it has. Plain-language labels are the app's, and the history view is v1.5.

## 6. The restore commands

Two commands (G6), both run through the edit path as Spec 5 §9 says:

| Text | Object | Effect | Lock | Undo |
| --- | --- | --- | --- | --- |
| `system restore list N version V` | `system.restoreList` `{list, version}` | Replaces list N with one of its kept versions | passes | edit |
| `system restore snapshot "ID"` | `system.restoreSnapshot` `{id}` | Replaces the documents a snapshot covers with its copies | passes | edit |

N is the list's number, as edits name lists (Spec 5 §3). Each command is an edit group, logged with kind `edit` and its inverse, undone and redone like any edit, and refused under operator lock (Spec 5 §7, the scope doc's review of G6 with S13); held by a cue, macro, key binding or scheduler entry, a refusal is `blocked` and the rest of the group runs (Spec 5 §2). Its `library` event has cause `restore`. Both are refused with `diskFull` while the disk is full (§7). A restore puts documents back as they were, so it may leave a broken reference, which the reference report flags, as an undo may (Spec 5 §6).

**Kept versions** are filed by list uuid, at `library/versions/<list uuid>/vNNNN.json`, not by number as Spec 1 §5 and Spec 7 §2 have them (choice G-12). A version then always belongs to the list that made it: a renumber doesn't strand a list's versions, and a list that takes a freed number never shares another's folder. And no save writes over a kept version: a list whose `version` is at or below the highest kept for it saves one above that, whatever brought it there, a restore, a Finder copy of an old file or a sync that rolled it back. Area 9 writes versions first, so this lands with it.

**A list version:**

- The version is the file with that list's uuid and `version` V; without one, the command is refused with `unknownObject`.
- Everything in the version comes back but the list's number, uuid and folder, which stay as they are now, and its `version`, which goes above every kept one, as above.
- The current document is kept as a version first, whatever E-3's ten minutes say (Spec 1 §4), in the same write as the restored list and ahead of it. The inverse restores that version.
- A list on air takes the new content as any edit of it would: each cue on its next fire (Spec 5 §2).
- Only lists that exist can be restored (choice G-11): a deleted one comes back by undo in the same run, or by a snapshot restore.
- Refused with `notInV1` for a local copy (Spec 5 §3) and `readOnlyLibrary` on a `readOnlyMasters` machine (Spec 5 §7).

**A snapshot.** It replaces the documents people author with the snapshot's copies. It leaves alone the machine's setup, so a restore during a service never moves an output, and the media indexes, which the walk keeps true to the files (choice G-5):

| Replaced | Left as they are |
| --- | --- |
| `library.json`, channels, text styles, grades, transitions, audio transitions, presets, portable macros, the lists and their folders | `machine.json`, stacks, outputs, audio outputs, inputs and clocks |
| Key bindings and the scheduler, machine macros, playlists (archived ones too) and local copies | Both media indexes (Spec 8 §4) |

- A document the snapshot holds replaces the current one, or comes back with its uuid; a document of a replaced kind that the snapshot doesn't hold, such as a list made since, is deleted. Documents come back whole, so an archived playlist is replaced like any other, though Spec 5 §6 lets no edit change one. Each document is read as the loader reads it, migrations included (Spec 1 §8); one the app can't read refuses the restore with `badValue`, naming it. Restored lists take versions above every kept one.
- Every numbered object that both the snapshot and the two roots now hold, matched by uuid, must have the same number in both. The documents the restore leaves alone name objects by number: stacks name channels and presets, and the machine settings name macros. So a renumber or a swap since the snapshot refuses the restore with `conflict`, naming the objects; renumbering them back, or restoring a later snapshot, gets past it.
- Before it replaces anything, the engine takes a snapshot with reason `restore`, and the inverse restores that one.
- What changes shows on air by Spec 5 §2's rules, as edits of the same things would, and the pointer goes on from its kept copies when its playlist, item or list goes (Spec 7 §4). A restore that would delete a channel with content in a stack an output shows is refused with `onAir`, as Spec 5 §6 refuses that delete; the live list may go.
- A snapshot another machine took restores here like this machine's own, such as a replacement Mac taking the old one's playlists and key bindings; the `snapshots` query names its campus, so the confirmation can say whose it is. A snapshot of another library is refused with `badValue`.
- On a `readOnlyMasters` machine only the machine documents are replaced, and the result warns that the library was left as it was (choice G-7).
- Refused with `unknownObject` for an id with no file.

**On a worker.** A snapshot restore can't apply in one tick: the snapshot has to be read and checked and the one before it written, and that file is the inverse. So the restore is validated, the reading, checking and writing happen on a worker, and then the checks run again and the restore applies in one step on the control thread. Meanwhile runtime commands keep flowing, and edits, undos and redos wait in the queue behind it, so nothing lands in documents the restore is about to replace. In a group sent from the UI, the API, the command bar or OSC, the whole group waits and applies with it, or is rejected with it. Held by a cue, macro, key binding or scheduler entry, the rest of the group runs at once and the restore applies after it, or is logged `blocked` if it fails, as Spec 8 §2 does for a held `media delete`.

**Picking one.** The pickers and the confirmation are the show-mode spec's; two queries feed them:

- `{ "type": "query", "what": "versions", "list": 42 }` returns that list's kept versions, newest first, each with `version`, `keptAt` (the file's date), `title` and `cues`, how many it has.
- `{ "type": "query", "what": "snapshots" }` returns the snapshots in `machine/snapshots/`, newest first, each with `id`, `takenAt`, `reason`, `bytes`, and `machine` and `campus` from its manifest.

## 7. Keeping files, and a full disk

**Retention** (G3):

| Files | Kept |
| --- | --- |
| Snapshots | Every one for 7 days; then the newest of each day until 30 days old; then the newest of each week, Monday to Sunday, until a year old; none older. A snapshot an undo or redo step names is kept until the run ends |
| Command logs | 90 days and 2 GB in all; past either, the oldest go first. Today's file is never removed |
| Engine logs | 90 days and 1 GB in all, the same way |
| The black box | 512 MB in all, oldest first; only the current hour's file is spared, so the cap holds within a day |
| Versions and conflicts | Kept; nothing removes them in v1 |

Days and weeks are local ones. The retention pass runs at launch, after each snapshot, and when a day's or an hour's file starts.

**Sending them upward.** Logs and snapshots sit in the machine root, which is never synced (Spec 1 §5). A sync tool may send `logs/` and `snapshots/` up, as the UX spec's distribution wants; the engine depends on neither, and the layout for it comes with v1.5's distribution conventions.

**A low disk.** When free space on the machine root's volume falls under 1 GB (Spec 8 §3's line), automatic snapshots and the black box's tick and present lines pause, and the `saving` topic warns. The minute records go on in the engine log, and everything else is written as usual.

**A full disk** (Spec 4 §12). When a write fails for want of space:

- The engine removes `state/last.json`, which frees space and needs none, so a stale last state can't come back later. It isn't written again until the full state ends.
- The logs go to memory: the command log up to 64 MB of lines and the engine log up to 16 MB; the black box stops.
- Snapshots aren't written, and `system snapshot` and the restore commands are refused with `diskFull`.
- Edits keep applying, and the documents they change wait to be written (choice G-10).
- Every 30 seconds the engine tries the waiting writes again. When one succeeds, the full state ends: the waiting documents and `last.json` are written, the logs go back to their files in order, and `logToFile` notes any lines lost.
- When the engine stops on request, it tries once more. Documents it still can't write are named in its answer to the request that stopped it and in the engine's unified log (Spec 4 §12), since the logs on disk can't take them.
- Output is untouched.

**The `saving` topic.** What the app's badge reads, sent when a client subscribes and whenever a value changes:

```json
{ "type": "event", "topic": "saving", "unsaved": 0, "disk": "ok", "log": "file",
  "lastSnapshot": "2026-11-08-085959", "seq": 5231 }
```

`unsaved` counts the documents waiting to be written past their second; `disk` is `ok`, `low` or `full`; `log` is `file` or `memory`.

## 8. What Area 12 changes on main, and fixtures

**On `main`** since Areas 2 to 4: `LogEntry`, Spec 2 §9's entry with its line; the atomic writer and write plans; the versions file written on a list save; the `restoreLastState` and `snapshots` settings; `Machine.lastState` read from `state/last.json`; the black box writing `blackbox-<day>.jsonl` to the folder the command line names, the soak's output by default, and reading it back for the soak; and `EngineLog`, the engine's log in unified logging with a short memory. Area 9 adds the edit path, the debounced write and E-3's cadence, and with them the uuid folders and the no-overwrite rule of §6, since it writes versions first. Area 12 adds:

- The command log and the engine log: one file each per local day, a group's lines in one write, synced each second, a partial last line ended on opening, `seq` per run, and the engine's notes. `EngineLog` also writes its lines to the engine log.
- `LogEntry` gains note lines and the `undoes` and `redoes` fields (Spec 5 §8).
- The black box in `machine/blackbox/` in the engine's normal runs, a file an hour, with the same line repair and sync, the cap trimmed within the day and the pause on a low disk; the soak keeps `--blackbox`, and its reader reads the hourly files.
- Snapshots: the zip with its manifest, the cadence, the equal-content check, and `system snapshot` with its result.
- The last state: the writes, the clean and restored flags, the minute refresh, the pending clears, the two-hour limit, Spec 3 §8's replacement of ShowState in the engine (which runtime undo reuses in v1.5), and the launch order.
- Edit undo and redo, with the `history` topic.
- The two restore commands in the grammar, parser, printer and OSC form, with the two queries, the renumber check and the worker and queue handling of §6.
- Retention, the low and full disk, the `saving` topic, and the API's `note` request.

**Fixtures.** `tests/fixtures/library-v1/machine/state/last.json` gains `writtenAt`, `run`, `clean: false`, `restored: false` and `pendingClears: []`. `library/versions/042/v0016.json`, which carries list 42's uuid, moves to `library/versions/a9f00000-0000-4000-8000-00000000002a/v0016.json`, in Area 9 with the path change. Tests build snapshots from the fixtures as they run, so no zip is checked in, and every test that writes runs on a temporary copy. The clock, the time zone, free space and the file system's failures are seams, so tests need no real disk to fill and no waiting.

## 9. Corrections to Specs 1–8

These are applied when this spec is accepted. The scope doc's review already accepted `state/last.json` written after every runtime group (`docs/STATUS.md`); the rest follow from this page. This spec departs from the scope doc and the UX spec in five places: G5 had the last state replayed as one restore group, and here ShowState is replaced as Spec 3 §8 does and the state put back is logged in one note, since a restore isn't made of commands; G4's `metrics-…` file is the engine log here; G1's snapshot also leaves out versions, conflicts and the last state (choice G-6); the UX spec's timer snapshot runs "while edit mode is open", and this spec's every ten minutes when something changed (choice G-4); and the UX spec restores "the whole library from a snapshot", and this spec its playlists, key bindings, machine macros and local copies too (choice G-5).

**Spec 1**

- §3, Machine settings. "`restoreLastState` (bool, default false), `snapshots` `{cadence, retention}`," becomes "`restoreLastState` (bool, default false; brings the last state back after a run that didn't end cleanly, Spec 9 §4), `snapshots` `{cadence, retention}` (one value each in v1, Spec 9 §3),".
- §4, Versions. After "(Spec 5, choice E-3)." add "No save writes over a kept version: a list at or below the highest version kept for it saves one above that (Spec 9 §6)." Then "last write wins, and any kept version is one file copy away." becomes "last write wins, a kept version of a list comes back with `system restore list N version V` (Spec 9 §6), and any kept version is one file copy away."
- §5, the layout. The `versions/042/` line becomes `versions/<list uuid>/` with the note "previous versions of a list, filed by its uuid: v0017.json … (Spec 9 §6)". `state/last.json`'s note "channel state at last clean shutdown (restore-last-state)" becomes "ShowState for restore-last-state, with how the run that wrote it ended (Spec 9 §4)". The `logs/  snapshots/` line, "written by the app, read by nothing it depends on", becomes three lines: `logs/` "the command log and the engine log, a file a day each (Spec 9 §2)", `blackbox/` "the black box, a file an hour (Spec 9 §2)" and `snapshots/` "zips of both roots' documents (Spec 9 §3); all three are written by the engine and read by nothing it depends on".

**Spec 2**

- §3. The `system snapshot` row's effect, "Writes a library and machine snapshot now", becomes "Writes a snapshot of both roots' documents now (Spec 9 §3)". After that row add the two rows of Spec 9 §6's table, `system restore list N version V` and `system restore snapshot "ID"`, with their objects, effects, lock and undo as given there.
- §6, the mapping table. A new row: "| `system restore list 42 version 16` | `/o/system/restore` `s:"list 42 version 16"` |".
- §9, the log entry. "One JSON line per executed command, appended to the day's log file in the machine root." becomes "One JSON line per executed command or note (Spec 9 §2), appended to the day's log file, `machine/logs/commands-YYYY-MM-DD.jsonl`." "`kind` is `runtime` or `edit`;" becomes "`kind` is `runtime`, `edit` or `note` (Spec 9 §2);". The sentence that begins "Navigation that only browses" becomes "Navigation that only browses (not in the vocabulary above, UI-only) reaches the log as a note the app sends (Spec 9 §2)."
- §9, the API envelope. After "A `media import` result also carries the `job` its outcomes are reported under (Spec 8 §7)." add "Spec 9 adds the `note` request (Spec 9 §2), the `versions` and `snapshots` queries (Spec 9 §6), and the `history` and `saving` topics (Spec 9 §5 and §7)."

**Spec 3**

- §3, rule 9. "It is operator state, set only by `channel N lock` and `unlock`, and ignores boundaries, resets, clears and restores." becomes "It is operator state, set only by `channel N lock` and `unlock` and by restore-last-state, which brings back the locks it held (Spec 9 §4); it ignores boundaries, resets, clears and the restores of undo."
- §8, Restores. "**Restores** (v1.5) replace ShowState wholesale with a snapshot taken before a runtime command." becomes "**Restores** replace ShowState wholesale: in v1 restore-last-state does, from `state/last.json` (Spec 9 §4), and in v1.5 runtime undo does, from the snapshot taken before a runtime command." "Lock values are copied from the current state, not the snapshot." becomes "Lock values are copied from the current state, not the snapshot, except in restore-last-state, which brings the locks back because a fresh launch has none (Spec 9 §4)."

**Spec 4**

- §12, Last-good-frame copies. "a full disk turns logging into an in-memory ring and raises a badge, with output unaffected" becomes "a full disk turns logging into an in-memory ring and raises a badge, with output unaffected (Spec 9 §7)".
- §12, Process boundary. "relaunches it with `state/last.json` (when `restoreLastState` is on)" becomes "relaunches it with `state/last.json` (when `restoreLastState` is on and the run didn't end cleanly, Spec 9 §4)".
- §13. "drains the ring into the black box (JSON lines, rotated daily)" becomes "drains the ring into the black box (JSON lines in `machine/blackbox/`, a file an hour, with the minute records copied to the engine log, Spec 9 §2)". In Privacy, "so logs can be shared for debugging without exposing a service's content." becomes "so the black box can be shared for debugging without exposing a service's content; the command log and the engine log can't be (Spec 9 §2)."

**Spec 5**

- §2, Writing. "within one second of its last change." becomes "within one second of its last change, or, while the disk is full, as soon as it can (Spec 9 §7)."
- §2, the `library` event. "`cause` is `edit`, `undo`, `redo`, `file` or `media`, the last for the index changes an import or the media walk makes, which also raise the revision (Spec 8 §2)." becomes "`cause` is `edit`, `undo`, `redo`, `file`, `media` or `restore`: `media` for the index changes an import or the media walk makes, which also raise the revision (Spec 8 §2), and `restore` for the restore commands (Spec 9 §6)."
- §6, step 5. "with three exceptions" becomes "with four exceptions", and after the exception that ends "since it meets those numbers at other campuses (Spec 1 §2)." add a fourth: "a restore puts documents back as they were, broken references included (Spec 9 §6)."
- §6, Rejection codes. "`conflict`, `notInV1`, `noTrash` (Spec 8 §6)." becomes "`conflict`, `notInV1`, `noTrash` (Spec 8 §6), `diskFull` (Spec 9 §6)."
- §9. "The log-and-saving spec defines two restore commands (G6): `system restore list N version V` and `system restore snapshot ID`." becomes "Spec 9 defines two restore commands (G6): `system restore list N version V` and `system restore snapshot "ID"`." "Restoring a list writes it like any save, so its `version` goes up and its versions file follows E-3 (Spec 1 §4)." becomes "Restoring a list keeps the document it replaces as a version, whatever E-3 says, and its `version` goes above every kept one (Spec 9 §6)." "The log-and-saving spec defines which documents a snapshot restore replaces, and how it treats outputs in use." becomes "Spec 9 §6 says which documents a snapshot restore replaces, and how it treats outputs in use."

**Spec 6**

- §7, The log. "and the log-and-saving spec decides whether those lines are kept in full." becomes "and Spec 9 §2 keeps those lines in full."

**Spec 7**

- §2, The loader. "`versions/` stays flat, by list number." becomes "`versions/` holds a folder per list, filed by its uuid (Spec 9 §6)."

**Spec 8**

- §2, What's logged. "The black box records them (Spec 4 §13)." becomes "The engine log records them, by id (Spec 9 §2)."

**`docs/build-order.md`**

- The Area 9 block. "and the debounced write with E-3's version cadence" gains ", with kept versions filed by list uuid and never written over (Spec 9 §6)".

**`docs/STATUS.md`**

- The Area 12 row gives Spec 9 as its spec.
- Spec corrections proposed. The bullet "Spec 1 §5: `state/last.json` is written after every runtime group…" is applied and leaves the list, and in "Spec 2 §3 and §6: `stack all blackout` (Area 15); the restore commands (log-and-saving spec)" the restore commands are applied, leaving `stack all blackout`.

## 10. Tests this spec implies

Written before the code, from this page, against the fixtures. The clock, the time zone, free space and file-system failures are seams.

- **The logs.** Every executed command is one line, in order, in the local day's command log, with Spec 2 §9's fields; a group's lines go out in one write. Rejections aren't written; blocked, noop and steppedOn results are. A run opens with `start`, `seq` counts from 1, and a clean stop ends with `stop`. A line at 23:59:59.900 local and the next at 00:00:00.100 land in two files. A file left with a partial last line is ended before the next run writes, and the reader skips the fragment. The engine log gets the engine's log lines, each minute record and the walk's index changes by id, each with `ts` and the run; the command log gets none of them. The black box lands in `machine/blackbox/`, a file an hour.
- **Notes.** A client's note is written with the engine's `ts`, `seq` and the client's source and no group, command, undo or result, answered `ok` with its `seq`, and changes nothing; an oversized one is `badValue`; the eleventh in a second is answered `noop` and not written, and the next one written carries `dropped: 1`. Each engine note in §2's table is written when its event happens, with its fields.
- **Captions.** A feed of three popup sets a second for an hour writes every line.
- **Snapshots.** The zip holds exactly the documents §3 lists, unwritten edits included, under `library/` and `machine/`, with the manifest and its folders; it opens with `unzip`. One is taken at launch before the startup macro, on a playlist load, on the ten-minute timer when something changed and not when nothing did, on `system snapshot` (always, its result naming the id once the file is complete) and before a snapshot restore. Two in one second get `-2`. A half-written zip never shows under its final name. Automatic ones pause under 1 GB free.
- **The last state.** It's written at launch before the restore, within a second of a runtime group and at most once a second during a feed, at least once a minute, never for an edit, and with `clean: true` after the shutdown macro on a clean stop; a killed engine leaves `clean: false`. With the setting on, an unclean end and a state written under two hours ago, launch restores content, attributes with origins, outputs, blackout, mutes, popups without a pending clear, locks and the pointer in each of its three shapes; media restarts from its in-point and plays though the walk hasn't hashed it; changes are cuts with provenance `restored`; `armed` and outgoing instances don't come back and timers are unset; a vanished channel is left out and unknown media comes back missing; the startup macro doesn't run; `lastStateRestored` carries the state. An engine killed 20 seconds after a restore, with a caption line in between, starts empty next time with `restoredBefore`; one killed 40 minutes after a restore with nothing fired restores again. A clean end, a state written over two hours ago and the setting off each start empty and run the startup macro, the first two with `lastStateSkipped` and its reason.
- **Undo and redo** (Spec 5 §11's undo tests, now against the engine). The stack holds 500 groups, is empty at launch and runs `undoes` and `redoes` groups with source `restore`; a reload or the media walk drops the steps it should with a `stepsDropped` note; operator lock refuses both; `history jump` is refused with `notInV1`; the `history` topic is sent on subscribe and follows every change to either stack. Two quick undos after a snapshot restore undo it and then the group below, in that order, each against the state the one before left.
- **Versions.** A save keeps versions in the list's uuid folder; after a renumber they stay with the list, and a list that takes the freed number writes to its own folder. A list copied back over itself from an old version and then edited twice writes its next versions above every kept one, and no kept file changes.
- **List restore.** A kept version comes back with the list's current number, uuid and folder and a `version` above every kept one; the current document is kept first whatever the ten-minute rule says; undo brings back exactly what was replaced. No such version is `unknownObject`; a deleted list can't be restored; a local copy is `notInV1`; a `readOnlyMasters` machine is `readOnlyLibrary`; a full disk is `diskFull`; operator lock refuses it, and inside a cue it's `blocked`.
- **Snapshot restore.** Exactly the documents §6 lists are replaced, created or deleted, archived playlists included, and the rest are byte-identical; restored lists get versions above every kept one; a pre-restore snapshot is taken and undo restores it; an unreadable document and another library's snapshot each refuse with `badValue`; another machine's snapshot restores; a channel renumbered or swapped since refuses with `conflict`, naming it; deleting a channel on air refuses with `onAir`; the live list may go and the pointer goes on from its kept copy; a reference the restore breaks is flagged by the reference report; a `readOnlyMasters` machine replaces only the machine documents and warns. While the worker runs, cues keep firing and a lyric edit waits, then lands after the restore; a failure while the pre-restore snapshot is written leaves every document as it was; held in a cue, the cue's other commands run at once.
- **Queries.** `versions` and `snapshots` list newest first with their fields, a snapshot from another machine with its campus.
- **Retention.** Given snapshots over 400 days, exactly §7's set survives, plus any an undo or redo step still names; logs past their age or size go oldest first and today's never goes; the black box stays within its cap through a day of running; versions and conflicts are untouched.
- **A low or full disk.** Under 1 GB free, automatic snapshots and the black box's tick and present lines pause and everything else is written. After a write fails, `state/last.json` is removed, the logs go to memory and come back in order with any loss noted, snapshots pause, `system snapshot` and the restore commands are `diskFull`, and edits apply; when a retried write succeeds, the documents and the last state are written. A stop on a full disk names what it couldn't write in its answer. The `saving` topic is sent on subscribe and reports each change.

## 11. Resolved choices

These are the places where the scope doc and Specs 1–8 left room and the draft of this spec chose. Timers after a crash weren't a choice: Spec 6 §6 already leaves them unset after a relaunch.

**Answered 2026-11-07.** Every choice takes the draft's answer ("Draft"), and the page above reads accordingly. Two independent reviews shaped the draft before Adam answered. They added the guard that keeps a state that crashes the engine from coming back in a loop, filed kept list versions by uuid and stopped any save writing over them (G-12), moved a snapshot restore onto a worker with the queue held behind it, refused a restore across a renumber, and kept edits applying on a full disk; they also dropped a timers choice that Spec 6 already decides and added G-3, G-6, G-7 and G-12.

| # | Choice | Draft said | Alternative | Answer |
| --- | --- | --- | --- | --- |
| G-1 | When the last state comes back | After a run that didn't end cleanly and was alive within the last two hours, and not when the engine stopped again within a minute of putting it back, so a state that crashes the engine can't loop | On every launch while the setting is on, last night's final screen included, with the same guard against a loop | Draft |
| G-2 | The startup macro when the last state comes back | It doesn't run: the screens come back exactly as they were, and timers the macro would set stay unset (Spec 6 §6) | It runs first and the last state goes on top: its timers and edits apply, and what it does to the screens is replaced | Draft |
| G-3 | Channel locks after a crash | They come back with the state, since they were the operator's last word; Spec 3 §3 rule 9 is corrected to match | They stay off, as rule 9 has it now: a fresh launch starts unlocked | Draft |
| G-4 | The ten-minute snapshot | Every ten minutes when anything changed, from any source, so the engine needs no word from the app | Only while edit mode is open, as the UX spec and G2 say, which needs the app to tell the engine | Draft |
| G-5 | What a snapshot restore replaces | The documents people author: the library, key bindings, machine macros, playlists and local copies; never the machine's setup (its settings, stacks, outputs, audio outputs, inputs, clocks) or the media indexes | The library only, as the UX spec words it | Draft |
| G-6 | What a snapshot leaves out | Also versions, conflicts and the last state, so a snapshot doesn't carry a list's whole history | Only what G1 names: media, logs, snapshots and thumbnails | Draft |
| G-7 | A snapshot restore on a `readOnlyMasters` machine | It replaces the machine documents (playlists, key bindings, macros, local copies) and leaves the library, with a warning | Refused, like the library edits it would include | Draft |
| G-8 | The day of the command and engine logs | The machine's local day, so a Sunday's services are in Sunday's file | The UTC day, as the black box's hours are | Draft |
| G-9 | Notes from the app | Accepted, ten a second at most per client, for the browsing Spec 2 §9 wants logged | None in v1; browsing is logged once the history view arrives | Draft |
| G-10 | Edits while the disk is full | They keep applying and wait to be written, so a lyric fix still works mid-service; any not written by a stop are named in its answer | Refused until there is space, so nothing is held only in memory | Draft |
| G-11 | Restoring a list that was deleted | Not with `system restore list`: a deleted list comes back by undo in the same run, or by a snapshot restore, which also reverts every other authored document to that time | `system restore list` brings it back from its versions, which needs a query for deleted lists and a picker | Draft |
| G-12 | How kept versions are filed | By list uuid, so versions always belong to the list that made it; in the Finder the folders show uuids. This reverses Spec 7 §2's "by list number" | By list number, as Spec 7 §2 has it: readable in the Finder, but a list that takes a freed number shares the folder with another list's versions | Draft |
