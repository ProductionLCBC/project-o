# Spec 8: Media pool

2026-11-07 · @Adam Granby · Status: accepted 2026-11-07, with Adam's answers in §12 · Builds on Spec 1 (§3 machine settings, §4 identity, §5 the layout, §7 the media index and resolver, §8 validation), Spec 2 (§2 the grammar, §3 the vocabulary, §8 missing media, §9 the API), Spec 3 (§4 media writes and missing media, §6 the projection's context), Spec 4 (§5 poster frames, §6 content sources, §10 thumbnails) and Spec 5 (edits of media defaults, lock, library mode and undo); written from the scope gaps doc's answers (M1–M11) and its review (M2 with M11)

Area 8 builds it.

## 1. Purpose and scope

The pool is how media gets into a show: a volunteer drags a video in, it gets an id, a poster and a tile, and a cue can use it. Identity, the two index tiers, lookup order, the computed missing state and the entry's fields are settled (Spec 1 §4 and §7). On `main` since Area 2 are the index types, a resolver that reads every path under the media root, SHA-256 hashing, and a missing set computed once at launch; the engine reads poster files and decodes what Spec 4 §6 plays. This spec settles who does the file work and how: the media commands, import, the walk that keeps the index true to the disk, where each file lives and how it's found, poster frames and pool tiles, deleting and replacing, what a client sees while it happens, and the drop channels. It also lists what Area 8 changes in the code on `main` (§9).

**In scope:** the media commands (M1); import, with duplicates, name clashes, folders and the kinds v1 takes (M4–M6); the walk, the watcher and the machine's hash cache (M7); the two indexes, the machine's own media folder (M11) and where media may live; poster frames (M2) and pool tiles (M3); deleting a used item (M9) and replacing a file (M10); the drop channels (M8); the `media` topic and the use query; edits of an item's defaults, which Spec 7 §7 gives to this area; fixtures; and the corrections this makes to Specs 1–5 (§10).

**Out of scope:** the Media pool tab itself (the folder rail, search, filters, tiles, drags, the delete confirmation and the Replaced filter), which belongs to the show-mode spec; optimize-on-import, audio sets and Hap (v1.5); the cases that syncing to a read-only campus creates, which wait for library mode (v1.5, §2, choice M-7); promoting local media into the library (v1.5); font registration (deferred, Spec 1 §7); designed slides and templates beyond indexing their files, including a slide's tile and a drop channel for slides (the slide designer, v2); live sources in the pool (v1.5); and pre-flight's media report (v1.5).

## 2. Who does the file work

**The engine does all of it** (M1). Importing, walking the media folders, hashing, reading metadata, extracting posters, making tiles, moving files to the Trash and rewriting references happen in the engine process, on a worker at background priority, never on the control or render threads (Spec 4 §3). The app never writes into the roots (C1): it sends commands, and reads tiles and posters as files.

**The commands** (a Spec 2 §3 addition, §10). Channel lock doesn't apply to any of them, so Spec 2's lock column reads `passes`:

| Text | Object | Effect | Lock | Undo |
| --- | --- | --- | --- | --- |
| `media import "PATH"` | `media.import` `{path}` | Imports a file or a folder (§3). The result is `ok` with a `job` id once PATH is readable; the files' outcomes follow on the `media` topic (§7) | passes | none |
| `media rebuild` | `media.rebuild` | Walks the media folders now (§4) | passes | none |
| `media replace HASH HASH` | `media.replace` `{old, new}` | Points every reference at the new item and records the mapping (§6) | passes | edit |
| `media delete HASH` | `media.delete` `{id}` | Moves the item's files to the Trash and keeps its entry as deleted (§6) | passes | edit |
| `media undelete HASH {…}` | `media.undelete` `{id, files}` | Delete's inverse: puts the files back and clears the deletion | passes | edit |
| `media unreplace HASH HASH {…}` | `media.unreplace` `{old, new, refs, mapping, defaults}` | Replace's inverse: puts back the references, the mapping and the new item's defaults as they were | passes | edit |

HASH is `sha256:` and the hex, abbreviated as Spec 2 §2 allows. The two inverses carry their recorded details as a JSON body, as Spec 5's edit forms do; the pool never offers them, and edit undo sends them.

**Who may send them.** Every source, as Spec 5's E-1 lets every source edit (choice M-4). Operator lock refuses every media command but `media rebuild` with `operatorLock`, as it refuses edits (Spec 5 §7). Inside a cue, a macro, a key binding or a scheduler entry, any refusal of a media command is `blocked` with its reason and logged, and the rest of the group runs, as Spec 5 §2 has it for edits; a held `media delete` applies once its files have moved (§6), after the rest of its group. A holder's media commands are checked when it's saved, for their form and that their ids resolve (Spec 5 §6, step 8).

**What's logged.** A media command is logged when it's applied, like any command (Spec 2 §9). The index changes an import job or the walk makes later aren't commands: they reach the control thread through the one queue (Spec 5 §2), bump the library revision and send the `library` event with cause `media`, but they aren't in the command log and never join the undo stack, so ⌘Z after a drag undoes the last edit, not the import (choice M-5). Operator lock doesn't stop them, as it doesn't stop a file arriving by sync. The engine log records them, by id (Spec 9 §2). `media replace`, `media delete` and their inverses are ordinary edits, undone and redone through Spec 5 §8.

**Two kinds of machine** (M11):

| | Writable machine | `readOnlyMasters` machine |
| --- | --- | --- |
| An import goes to | The library index, its file into the media root | The machine index, its file into `machine/media/` |
| The walk writes | The library index for the media root and the machine index for `machine/media/`, their posters and the cache | The machine index, its posters and the cache |
| `media replace` and `media delete` | Any item | Machine-index items; library items are refused with `readOnlyLibrary` |

The pilot runs `writable` (Spec 5, E-2), and campuses run `readOnlyMasters` once library mode arrives in v1.5. So v1 gives a read-only machine these plain rules and nothing more: it never writes the library, and its library entries count as missing until the synced index and the synced files agree. The cases sync order creates, such as an index arriving hours before a re-exported file, or a missing library file brought on a USB stick, are settled with library mode (choice M-7).

**`machine/media/`** is the machine's own media folder, never synced (choice M-1). Keeping local files out of the synced media root means a campus's announcement video never syncs up to central, and a one-way sync never deletes it. It holds local-only media, which a `readOnlyMasters` machine imports into it, and the files overrides point at.

**Where a file is.** The resolver returns a location, a folder plus a path, not just a path under the media root:

- a library entry's `path` is relative to the media root;
- a machine-index entry's `path` is relative to `machine/media/`;
- an override (Spec 1 §7) is a path relative to `machine/media/`, or an absolute one, and wins over its entry's `path`. Overrides are written by hand in v1; the walk never treats their files as entries and never removes an override.

**Where media may live** (choice M-8). The engine reads the library and machine roots, the media root, override targets, its staging folder and whatever path a `media import` names (§3). macOS asks each process before it reads the Desktop, Documents and Downloads folders, external drives and network volumes, and it asks an ad-hoc-signed engine again after every update (ADR 0007). So in v1 the media root and override targets sit on the startup volume, outside those three folders: setting `mediaRoot` anywhere else is refused with `badValue`, and the reference report lists an override that points elsewhere. The library and machine roots have the same need.

**Resolving an id.** An id first follows the `replaced` maps, the machine index's and then the library's, whether or not an index still holds an entry for it, until it reaches an id neither maps. A chain that comes back to an id it has passed stops at the id before the repeat, and the reference report names the loop; only a hand edit can make one (§4). The entry for the last id gives the location.

**Present or missing.** An entry is present when the hash known for its location equals its id, and it isn't deleted (§6). The hash is known from this machine's cache record for that location when the file's size and modification date match it, otherwise from the entry's own size and date when they match, otherwise by hashing the file (§4). A slide's id is its embedded uuid, so a slide is present when the file at its location parses and carries that uuid. Missing state is worked out this way per location, again after every walk and whenever either index reloads, not once at launch.

## 3. Import

**What happens to each file:**

1. **Staged.** A file dropped from outside both folders is first copied by the app into its staging folder, `~/Library/Application Support/Project O/Staging/`, outside both roots, and imported from there; on the same volume the copy is a clone, which takes no time or space. The engine never reads a dropped file where it lies, since that may be a place macOS guards (§2). A drag that brings no file, from Photos, Mail or a browser, is received into the same folder. The engine moves a staged file into place rather than copying it when it can, removes a staged file once its import is done, and empties the folder at launch. A `media import` sent from elsewhere names its own PATH; one the engine can't read is rejected with `unreadable`.
2. **Hash first** (M4). The engine reads the file and hashes it. A hash the index already knows isn't copied: the import resolves to that item, with outcome `known`. A hash that a `replaced` map names resolves to its replacement (Spec 1 §7). A deleted or missing item's own hash brings the item back: the file is copied in, and the entry takes the copy's path and keeps its defaults, which brings its references back (§6).
3. **The kind.** The file must be one v1 takes (below), or it's refused with `unsupported`, naming the format.
4. **Copy.** The file goes into the import folder (`defaultImportFolder`) of the folder the table below names. A name that a file holds, or that another entry's path holds even while its file is missing, gets a space and `2`, `3` and so on before its extension, as the Finder names copies, so an import never shares a path with another entry or replaces it as a re-export does (§4). The copy is written under a hidden name and renamed when complete, so the walk never reads half of it, and is checked against the hash: a file that changes while it's imported is refused with `changed`. An import that would leave less than 1 GB free on its volume is refused with `diskFull`.
5. **Index.** The engine reads the metadata Spec 1 §7 lists (duration, frame rate, size, audio, alpha, codec), extracts the poster (§5), writes the entry with empty defaults, `addedAt` and `folder`, records the file in the cache, and makes the pool tile.

**Where an import goes:**

| The file | Writable machine | `readOnlyMasters` machine |
| --- | --- | --- |
| From outside both folders | Copied into the media root; a library entry | Copied into `machine/media/`; a machine entry |
| Already in the media root | Indexed where it is; a library entry | `known` if the library index lists it, otherwise refused with `notListed` |
| Already in `machine/media/` | Indexed where it is; a machine entry | Indexed where it is; a machine entry |
| The id of a missing or deleted library item | Copied into the media root, and the item comes back | Refused with `readOnlyLibrary` |

**A dropped folder** (M5) imports its files recursively and keeps its subfolders under the import folder: dropping `Easter/` puts `Easter/Openers/countdown.mov` at `imports/Easter/Openers/countdown.mov`. Hidden files and folders are skipped, and a file v1 doesn't take is refused without stopping the rest. A folder as one audio set is v1.5.

**The kinds v1 takes** (M6), found by opening the file, not from its extension:

| Kind | Takes | Notes |
| --- | --- | --- |
| Video | ProRes (the 422 family and 4444), HEVC (8- and 10-bit, with or without alpha) and H.264, in `.mov`, `.mp4` or `.m4v` | What VideoToolbox decodes for Spec 4 §6. Hap is v1.5 |
| Image | PNG, JPEG, HEIC, TIFF; GIF as a still, its first frame | Read with ImageIO |
| Audio | WAV, AIFF, M4A (AAC or ALAC), MP3 |  |
| Slide, template | `.oslide`, `.otemplate` | Indexed by their uuid (Spec 1 §7); the slide designer (v2) makes them |

Anything else is refused with `unsupported`, so a `.mov` holding a codec v1 can't play never reaches a cue.

## 4. The walk

**When.** The engine walks the media root and `machine/media/` at launch, on `media rebuild`, and whenever its watcher reports a change under either folder, which covers an import's own copies (M7). A file is read once its size and modification date have held for two seconds, and a file that doesn't open yet as a kind v1 takes, such as a video still being exported, is left for a later walk, so a file half-written is never indexed. Hashing runs at background priority. An import indexes its own copy; the walk its watcher then starts finds the entry already there, since both apply their changes through the one queue.

**What it skips:** hidden files and folders (names starting with a dot, so `.posters/`), a sync tool's temporary files (Spec 1 §5), `fonts/` (Spec 1 §7), the files overrides point at, and kinds v1 doesn't take, which the reference report lists.

**The cache.** `machine/media-cache.json` holds a record for every file the engine has hashed: its folder (the media root or `machine/media/`), path, size, modification date and hash. It starts with the header every document has (Spec 1 §5), with kind `mediaCache`, and the loader leaves it alone. A file whose size and date match its record isn't hashed again, so a file whose dates a checkout or a sync tool changed is hashed once, not at every launch.

**What it does with each file.** It compares what it finds with the index, and with what it found last time, which the cache records. A file whose known hash is the id of the entry at that path is left alone. For any other file it works out the hash, then applies these rules in order:

- **An id the other folder's index holds** is left alone and reported: the walk never adds to one index an id the other holds. Moving media between the library and the machine, either way, comes with library mode (choice M-7).
- **A deleted item's id**, found anywhere in its own folder, brings the item back at that path, with its defaults, where its index is one this machine writes (§6).
- **A move.** An indexed id found at a path where the last walk didn't see it, while its entry's path no longer holds it, is a move: the entry takes the new path and folder, and keeps its defaults (Spec 1 §7). So a file renamed away and a new one saved under its name are a move and then a new item.
- **A landing.** Once moves are settled, a file with another id at a path an entry still holds replaces that entry (choice M-2). The old entry's `path` becomes empty, so it counts as missing, and the index that holds it records old → landed in its `replaced` map. A new id becomes a new item there with the old item's defaults: the usual re-export. A known id keeps its own defaults and loses any mapping that leaves it, so restoring a file from any number of versions back reverses the re-exports and the walk never makes a loop; its entry takes the path unless its own file is still where the entry says, which makes this file a copy. References aren't rewritten: they now resolve to the landed file and its defaults.
- **Copies.** Identical files at two paths in one folder are one entry, which keeps its path while its file is there; the other copy is reported. If the entry's file goes, a landing included, the entry takes the copy's path.
- **A new id at a path no entry holds** is a new entry with empty defaults.

The walk extracts missing posters and reads missing metadata. It never removes an entry a reference may need: a file that's gone leaves its entry missing (Spec 1 §7), and defaults are never lost to a walk. Only the launch walk prunes, before anything can be undone: replaced entries whose file is gone and that nothing on this machine names, with their posters. Their mappings stay, so anything still naming them resolves.

**The walk and undo.** When the walk maps an entry to another file or brings a deleted one back, it drops every undo and redo step that names that entry, with one log line, as a reload drops the steps that touch a document (Spec 5 §8). An undo therefore never fights a file someone put back or saved over.

**On a `readOnlyMasters` machine** the walk writes nothing in the library. It works out presence for the library entries, indexes `machine/media/`, and keeps its cache. A file in the synced media root that the library index doesn't list is left alone until the synced index lists it.

## 5. Posters and tiles

**The poster** (M2) is the frame at the video's default in-point (`defaults.trimInMs`, or 0), taken exactly, because that's the frame the engine stands it in for when a write lands before its first decoded frame (Spec 4 §6). It's a PNG fitted within 1920 × 1080, with alpha when the video has it; the engine loads it at half the channel render size anyway (Spec 4 §5), and a 4K library doesn't sync 4K PNGs. Only video has a poster file: an image is its own poster, which the poster loader reads and downsizes, and audio has none.

- **Where.** `.posters/<hex>-<in>.png` beside the media it belongs to, `<hex>` being the hash without `sha256:` and `<in>` the in-point in milliseconds: in the media root for library media, so it syncs and a campus never extracts its own, and in `machine/media/` for local-only media (the scope doc's review of M2 with M11). The entry's `poster` holds that path, relative to the same folder as its `path`; it's null until extracted, and when extraction fails, which is reported.
- **When.** At import, by the walk when one is missing, and after an edit changes `defaults.trimInMs`. The new in-point gives the poster a new name, so every cache keyed by the path follows the change, and a machine that receives the edit before the new PNG shows no poster for a moment rather than the old one. The old file goes once the new one is written.
- **Who.** The machine that writes the entry's index, so library posters are written only on a writable machine. The poster loader doesn't remember a poster it couldn't find, and a change under `.posters/` makes it look again and redraws the tiles and thumbnails that went without it, so a poster that arrives by sync after its entry appears without a relaunch.

**Pool tiles** (M3) are 480 px wide PNGs at `machine/thumbnails/pool/<hex>-<in>.png` (`<in>` is 0 for an image), made from the poster for video and from the image for an image. Audio has no tile: the pool draws its kind glyph and duration. Tiles are a machine cache, never synced, and made again when missing.

**Defaults.** `edit media sha256:… defaults.trimInMs 1500` and the other defaults are Spec 5 edits, applied to whichever index holds the entry (Spec 5 §3); Area 8 builds them (Spec 7 §7).

## 6. Delete and replace

**Delete** (M9). The pool asks first, naming how many cues use the item, which the engine answers with the `mediaUse` query (§7). Then `media delete HASH`:

1. **Checks.** An item on air is refused with `onAir`, as Spec 5 refuses deleting an object on air: one whose file a channel has open, for its content, an outgoing transition or a prefetched reader, or that a channel's content now resolves to. A channel keeps the file it opened at its write, so after a replace it can still be playing the old item. A file on a volume with no Trash is refused with `noTrash`, which only a media root off the startup volume can meet (choice M-8). Library mode and operator lock apply (§2).
2. **Moves.** The worker moves the item's file, and any identical copy the walk found, to the Trash. If one move fails, the files already moved go back and the delete is rejected.
3. **Applies.** If the item went on air while its files moved, they go back and the delete is refused with `onAir`. Otherwise the entry stays, with `deletedAt` set and its `path` empty, and the command is logged with where each file came from and where the Trash put it. Every reference to the item shows the missing badge rather than becoming an unknown id, including references on machines this one can't count. The pool lists a deleted item with its missing overlay while anything uses it, and hides it once nothing does (the show-mode spec). Importing the same bytes again, or the walk finding them, a Put Back from the Trash included, brings it back with its defaults (§4); a `readOnlyMasters` machine leaves a library item's deletion to central.

**In a group.** A group that holds a `media delete` (Spec 5 §5) is validated whole; then every file it deletes moves; then the checks run again, and the group applies in one step. Any failure puts every moved file back and rejects the group.

The inverse, `media undelete`, moves the files back to where they came from and clears `deletedAt`. It never overwrites a file now at one of those paths, giving the restored one a numbered name instead, as an import does (§3), and checks each file against the id; if the Trash has been emptied, the undo fails with `conflict` (Spec 5 §8).

**Replace** (M10) is the re-exported video on a Sunday morning. `media replace OLD NEW` takes two ids in the index; to replace with a file not yet imported, the app imports it first and sends `media replace` when the import's `done` event names the new id. It rewrites every reference to OLD in the lists, presets, macros, key bindings and scheduler entries this machine writes, and records `OLD → NEW` in the `replaced` map of the index that holds OLD. Anything still naming OLD then resolves to NEW: a local copy, which v1 never edits (Spec 5 §3), a re-import of the old file, or a reference on a machine that didn't rewrite it (Spec 1 §7).

- NEW takes OLD's defaults when it has none of its own, every default empty as an import leaves them; an item someone has set up keeps its own (choice M-3).
- OLD's entry and file stay. The pool hides replaced items behind a Replaced filter (the show-mode spec), where they can be deleted.
- NEW can't be OLD or a deleted item. If NEW's chain already leads back to OLD, as when a replacement is reversed, the mapping that leaves NEW is removed first, so no loop forms.
- The logged command lists the references it rewrote, each named as Spec 5 §3 addresses it, the mappings it removed or added, and NEW's defaults before the command. Its inverse, `media unreplace`, puts all three back, so references that already named NEW keep it.
- On a `readOnlyMasters` machine, replacing library media is refused with `readOnlyLibrary`, and replacing local-only media rewrites machine documents only (§2).

## 7. Feedback and queries

**The `media` topic** carries the work as it happens: one event per file as a job moves through hashing, copying, reading and the poster, a final outcome per file, and the walk's progress. It also carries changes in an item's missing state, which aren't index changes.

```json
{ "type": "event", "topic": "media", "job": "j-3c1d9a20", "op": "import", "file": "Welcome.mov",
  "state": "copying", "progress": 0.42, "seq": 5200 }
{ "type": "event", "topic": "media", "job": "j-3c1d9a20", "op": "import", "file": "Welcome.mov",
  "state": "done", "outcome": "imported", "id": "sha256:9f2c…", "seq": 5207 }
{ "type": "event", "topic": "media", "op": "missing", "id": "sha256:55c8…", "missing": true, "seq": 5210 }
```

`outcome` is `imported`, `known` or `refused`, a refusal with its `reason` (`unsupported`, `changed`, `diskFull`, `notListed` or `readOnlyLibrary`). Index changes themselves ride Spec 5's `library` event with cause `media`, naming the media by id. A command's own rejections are Spec 2 §9's `code: message` results: `unreadable`, `unknownObject`, `onAir`, `noTrash`, `readOnlyLibrary`, `operatorLock`, `badValue` and `conflict`.

**The use query** answers the delete confirmation: `{"type": "query", "what": "mediaUse", "id": "sha256:…"}` returns `{"cues": 12, "macros": 1, "presets": 0, "keys": 2}`, counted over the library and machine documents on this machine, key bindings and scheduler entries included, with references that resolve to the item through a `replaced` map.

**A file that comes back** plays from the next write. A channel that showed it as missing keeps rendering nothing, with the badge, because the instance carries its missing state from the write (Spec 3 §4, Spec 4 §12).

## 8. Drop channels

`dropChannels` is a new machine setting (M8): `{video, image, audio}`, each a channel number or null. An item's `defaults.defaultChannel` overrides it. The pool's double-click and its drops use them, as the show-mode spec says. First run writes `{"video": 1, "image": 1, "audio": null}`: channel 1 is the background, and a first-run machine has no channel meant for audio, so the pool asks (choice M-6). It is edited like any machine setting (Spec 5, Area 17).

## 9. What Area 8 changes on main, and fixtures

**On `main`**, beyond the new commands, the walk, the watcher, the cache, the posters, the tiles, the `media` topic, the query and the defaults edits:

- **The resolver** returns a location (§2) and follows both indexes' `replaced` maps to the end of the chain, with the repeat check, instead of the library map alone and eight steps at most. The machine index gains its own `replaced` map, and an entry gains `deletedAt`.
- **Missing state** is worked out per location, with the cache, after every walk and index reload. The projection's `missing` set, the thumbnail job and the id set the OSC parser uses to expand abbreviated hashes all take the current one, where today each is computed once at launch. The reference report names a deleted item only while something references it.
- **Opening media**: video, stills and audio open at the resolved location, not under the media root alone.
- **The poster loader** reads at the entry's location and caches by the poster's path, doesn't cache a miss, reads an image as its own poster, and downsizes to half the channel render size (Spec 4 §5).
- **Thumbnails** are keyed on the resolved id, poster path and presence of the media a list uses (Spec 4 §10, corrected in §10), so a re-export or a trim edit redraws the lists that use the item, and an import elsewhere redraws none.
- **Media writes** in the projection take their defaults from the entry the ref resolves to (Spec 3 §4 and §6, corrected in §10), so cues still naming a replaced id play the new file with the new item's defaults.

**Formats.** `media-local.json`'s paths and overrides now read against `machine/media/`. Spec 1 §8 bumps a schema when a field's meaning changes, but nothing outside the fixtures has written a `media-local.json` yet, so Area 8 rewrites the fixture and keeps schema 1.

**Fixtures.** Area 8 rewrites `tests/fixtures/library-v1/` to this shape:

- `dawn.mp4`'s poster moves from `library/media/posters/dawn-55c84469.png` to `library/media/.posters/<hex>-0.png`, and its entry follows. `mountains.mp4`'s entry, whose video and poster are both absent for the missing badge, names `.posters/<hex>-1500.png`.
- The machine-only `announcement.png` and the override target `cross-fast.png`, the same bytes as `backgrounds/cross.png`, move from `library/media/local/` to `machine/media/`, and the machine index's path and override follow.
- `machine.json` gains `dropChannels`.

`tests/fixtures/spike/` stays as it is. The fixture's machine runs `readOnlyMasters`, so tests of a writable machine set `libraryMode` to `writable` in their copy. A launch on any fixture walks it and writes tiles and the cache, and can write the machine index, so every test that launches the engine on a fixture runs on a temporary copy.

## 10. Corrections to Specs 1–5

These are applied when this spec is accepted. The scope doc's review already accepted an import that hashes before it copies and a poster at the in-point kept beside its index tier (`docs/STATUS.md`); the rest follow from this page. This spec departs from the UX spec in two places, both waiting for the slide designer: a slide's tile showing its final build state, and a drop channel for slides. Optimize-on-import and audio sets wait for v1.5, as the scope doc settled.

**Spec 1**

- §3, Machine settings. "`mediaRoot`, `defaultImportFolder`," becomes "`mediaRoot`, `defaultImportFolder`, `dropChannels` (a channel per media kind for drops from the pool, Spec 8 §8),".
- §5, the two roots. "and may be pointed elsewhere in machine settings." becomes "and may be pointed elsewhere in machine settings, on the startup volume and outside the Desktop, Documents and Downloads folders (Spec 8 §2)."
- §5, the layout. `media/`'s note "the media root (user subfolders, fonts/, imports/)" becomes "the media root (user subfolders, fonts/, imports/, and .posters/ for poster frames, Spec 8 §5)". After the `media-local.json` line add "`media/` local-only media and the files overrides point at, never synced (Spec 8 §2)" and "`media-cache.json` a cache of the size, date and hash the media walk last found for each file (Spec 8 §4)". `thumbnails/`'s note gains "; pool tiles in pool/ (Spec 8 §5)".
- §7, the first paragraph. "a **machine index** (`machine/media-local.json`) for media that exists only on this machine plus any path overrides" gains " (that media lives in the machine's own folder, `machine/media/`, Spec 8 §2)". "the `replaced` map that `replace media` records" becomes "the `replaced` map that `media replace` and the walk record (Spec 8 §4 and §6)". "`machine/media-local.json` holds `entries` and `overrides` (id to local path)" becomes "`machine/media-local.json` holds `entries`, `overrides` (id to a path relative to `machine/media/`, or absolute) and its own `replaced` map".
- §7, the entry table. `path`'s note "Relative to the media root, forward slashes; updated when the file moves" becomes "Relative to the media root, or to `machine/media/` for a machine-index entry; forward slashes; updated when the file moves, and empty once another file took its place or the item was deleted (Spec 8 §4 and §6)". `poster`'s note "Relative path to the extracted poster frame (PNG), used by offset boxes and thumbnails" becomes "For video, the frame at the default in-point as a PNG at `.posters/<hash>-<in>.png`, relative like `path`; null for images and audio, and until extracted (Spec 8 §5). Used by offset boxes and thumbnails". After the `addedAt`, `folder` row add "| `deletedAt` | Set when `media delete` trashed the file; the entry stays, so references show missing (Spec 8 §6) |".
- §7, Lookup order. "When a campus relocates media (a different root, a faster drive), the machine index carries `overrides` from id to local path" becomes "When a campus relocates media (a different root, or a faster drive once v1's limit on where media may live is lifted, Spec 8 §2), the machine index carries `overrides` from id to a path relative to `machine/media/` or an absolute one". "Local-only media (a campus announcement video) lives in the machine index with the same entry shape and promotes to the library index when the file is added to the library on a writable machine." becomes "Local-only media (a campus announcement video) lives in the machine index with the same entry shape, and its file in `machine/media/`; promoting it to the library comes with library mode in v1.5. A replaced id resolves through the `replaced` maps to the end of its chain (Spec 8 §2)."
- §7, Rebuild. "On demand, or when an index is missing, the app walks the root," becomes "At launch, on `media rebuild` and whenever its watcher sees a change, the engine walks the media root and `machine/media/` (Spec 8 §4),".
- §7, Missing state. "an id whose path no longer exists stays in the index" becomes "an id whose file no longer exists, no longer holds its bytes or was deleted (Spec 8 §6) stays in the index", and "A `replace media` command rewrites every reference from one id to another across lists, macros and presets" becomes "A `media replace` command (Spec 8 §6) rewrites every reference from one id to another across lists, presets, macros, key bindings and scheduler entries".
- §7, Import. "copies any file dragged from outside the root into the default import folder, hashes it, reads metadata, extracts a poster frame, and writes the entry." becomes "hashes any file dragged from outside the root, copies it into the default import folder unless the hash is already known, reads metadata, extracts a poster frame, and writes the entry (Spec 8 §3)."
- §8, Reference checks. "media ids with no path" becomes "media a reference names that is unknown, missing or deleted once resolved (Spec 8 §2)".

**Spec 2**

- §2, the grammar. In the grammar block, "| item | system" becomes "| item | system | edit | media", adding the `edit` target that §3 reserves, and "integer | decimal | duration | string | ref | keyword" gains " | hash | json". The Tokens table gains two rows after `ref`: "| hash | `sha256:` and the hex, abbreviated to its first 12 hex characters in the command bar as in a ref | `sha256:9f2c...` |" and "| json | a JSON object or array: a structured value (Spec 5 §4) or a recorded inverse (Spec 8 §2) | `{…}` |".
- §3. In the paragraph before the tables, "are logged but not undoable." becomes "are logged but not undoable; *edit* commands carry their inverse and are undone by edit undo (Spec 5 §8)." After the `system snapshot` row, the six rows of Spec 8 §2's table, from `media import "PATH"` to `media unreplace`, with their objects, effects, lock and undo as given there.
- §6, the mapping table. A new row: "| `media rebuild` | `/o/media/rebuild` |".
- §9, the API envelope. After the examples add: "A `media import` result also carries the `job` its outcomes are reported under (Spec 8 §7)."

**Spec 3**

- §4, Media. "falling back to the pool item's defaults" becomes "falling back to the defaults of the pool item the ref resolves to (Spec 8 §2)".
- §6, ProjectionContext. "and the media index whose entry defaults a media write falls back to; read only" becomes "and the media index, each id's defaults read from the entry Spec 8 §2 resolves it to, in either index; read only".
- §6, Commands. "Commands that do not touch state (`timer`, `history`, `system preflight`, `system snapshot`, `edit`)" becomes "Commands that do not touch state (`timer`, `history`, `system preflight`, `system snapshot`, `edit`, `media`)".
- §8, Operator lock. "by refusing edit commands, edit undo and redo, and the library restore commands (Spec 5 §7, §9)" becomes "by refusing edit commands, the media commands but `media rebuild` (Spec 8 §2), edit undo and redo, and the library restore commands (Spec 5 §7, §9)".

**Spec 4**

- §10, Thumbnails. "(presets, grades, text styles, transitions, channels and the media index's poster paths) plus the list's own version" becomes "(presets, grades, text styles, transitions and channels), the resolved id, poster path and presence of each media item the list's cues use (Spec 8 §9), and the list's own version".

**Spec 5**

- §1, Out of scope. "the media commands `media import`, `media rebuild` and `media replace`, which change the media index through this same path but belong to the media-pool spec" becomes "the media commands of Spec 8, which change the media index through this same path".
- §2, A failing edit doesn't stop the cue. After "so their groups stay all-or-nothing (§5)." add "Any refusal of a media command held this way is `blocked` too (Spec 8 §2)."
- §2, the `library` event. "`cause` is `edit`, `undo`, `redo` or `file`." becomes "`cause` is `edit`, `undo`, `redo`, `file` or `media`, the last for the index changes an import or the media walk makes, which also raise the revision (Spec 8 §2)."
- §6, step 5. "Every media id is in the index." becomes "Every media id resolves to an entry in either index (Spec 8 §2)."
- §6, Rejection codes. "`conflict`, `notInV1`." becomes "`conflict`, `notInV1`, `noTrash` (Spec 8 §6)."
- §7, Operator lock. "the engine refuses every `edit`, every undo and redo of an edit, and every restore (§9)" becomes "the engine refuses every `edit`, every media command but `media rebuild` (Spec 8 §2), every undo and redo of an edit, and every restore (§9)".
- §7, Library mode. "and the defaults of library media" becomes "and the defaults of library media, which `media replace` and `media delete` of library media join (Spec 8 §2)".
- §8, One linear stack per run. After "up to the last 500 (choice E-4, §12)." add "`media replace` and `media delete` join it like any edit; the index changes an import or the media walk makes aren't edits and never do (Spec 8 §2)."
- §8, A reload drops steps. After "An undo therefore never overwrites a change that arrived by sync." add "The media walk drops the steps that name an entry it maps to another file or brings back (Spec 8 §4)."

**`docs/STATUS.md`**

- The Area 8 row gives Spec 8 as its spec.
- Spec corrections proposed. The bullet "Spec 1 §7: an import hashes before it copies…" is applied and leaves the list, and in "Spec 2 §3 and §6: `stack all blackout` (Area 15); the media and restore commands (the specs that own each)" the media commands are applied, leaving "the restore commands (log-and-saving spec)".

## 11. Tests this spec implies

Written before the code, from this page, against the fixtures as Area 8 rewrites them (§9). Free space, the watcher's events, the Trash and the clock are seams, so the tests run without real volumes or waits. Clauses that need edit undo wait for Area 12, which builds it (Spec 7 §7); they're marked (Area 12).

- **Import.** A file is hashed before it's copied. A known hash isn't copied and comes back `known`; a replaced hash resolves to its replacement; a missing or deleted item's own hash brings it back. A name that a file or another entry holds, a missing entry included, gets a numbered name. A dropped folder keeps its subfolders, skips hidden files and refuses an unsupported file without stopping. Kinds come from the content: a `.mov` with a codec v1 can't play is refused. The copy appears only when complete and matches the hash; a file changed mid-import is refused; a full volume refuses with `diskFull`. A staged file is moved in and cleaned up, Staging is emptied at launch, and an unreadable PATH is rejected with `unreadable`. Each row of §3's table holds, on both kinds of machine.
- **Logging.** An import's and a walk's index changes raise the revision and send `library` events with cause `media`, and aren't in the command log; ⌘Z after an import undoes the edit before it (Area 12).
- **The walk.** It runs at launch, on `media rebuild` and from the watcher; a growing file waits until it has held for two seconds, and a half-written video that won't open isn't indexed. Hidden folders, temporary files, `fonts/` and override targets are skipped. The cache spares a second hash when dates differ from the index, and the same path in both folders keeps two records. A move keeps the defaults. A file exported over an item becomes a new item with its defaults, and the old id's cues play it, also when an identical copy of the old file sits elsewhere in the media root; a stall mid-export still ends with the old id resolving to the finished file. A file restored over the export, from one version back or several, makes no loop, and cues naming any version play it. A file renamed away and a new one saved under its name is a move and a new item. Eight weekly re-exports in place still resolve from the first id to the last, and a hand-made loop in the map stops and is reported. Identical copies are one entry. A vanished file leaves its entry missing with its defaults. A deleted file put back from the Trash brings its item back and drops the delete's undo step (Area 12 for the step). Pathless, unnamed replaced entries are pruned by the launch walk only, and their ids still resolve. A file whose id the other folder's index holds is left alone and reported. On a `readOnlyMasters` machine nothing in the library is written, and an unlisted file in the media root is left alone.
- **Where media may live.** `mediaRoot` on another volume, or under the Desktop, Documents or Downloads folders, is refused with `badValue`, and an override there is reported.
- **Resolver.** Library, machine and override locations, absolute overrides included, resolve to the right file. An entry whose location holds other bytes is missing, even when the file's dates match a cache record for another hash. A slide is present by its uuid. Missing state follows a walk and an index reload without a relaunch. A write of a replaced id takes the defaults of the item it resolves to, and a later edit of that item's defaults reaches it.
- **Posters.** The frame at the default in-point, fitted within 1920 × 1080, with alpha when the video has it, at `.posters/<hex>-<in>.png` beside its media. A `defaults.trimInMs` edit gives a new poster under a new name, and only the thumbnails of lists using the item redraw. A poster that arrives after its entry shows, in its tile and in thumbnails, without a relaunch. Images are their own poster, audio has none, and only a writable machine writes library posters.
- **Tiles.** 480 px wide, from the poster or the image; none for audio; a new tile with a new poster.
- **Defaults.** Each default edits the index that holds the entry; a library item's defaults are refused with `readOnlyLibrary` on a `readOnlyMasters` machine.
- **Delete.** Every copy goes to the Trash and the entry stays, deleted and pathless, with its references missing. An item on air is refused with `onAir`, also when a channel plays it through a replaced id, still plays its file after a replace, or a reader holds it prefetched; a volume with no Trash refuses with `noTrash`; a move that fails, or an item that goes on air while its files move, leaves everything in place. A group holding several deletes applies whole, or puts every file back. `media undelete` brings the files and the entry back, never over a file now at one of their paths, and fails with `conflict` once the Trash is emptied (Area 12 for the undo). A `readOnlyMasters` machine refuses library items.
- **Replace.** References are rewritten across lists, presets, macros, key bindings and scheduler entries, local copies follow the mapping, and a re-import of the old file resolves to the new one. A new item with empty defaults takes the old ones, one with its own keeps them. Reversing a replacement removes the mapping and makes no loop. `media unreplace` puts the references, the mappings and the defaults back exactly (Area 12 for the undo).
- **Lock and held commands.** Operator lock refuses every media command but `media rebuild`. Inside a cue or a scheduler entry, any refusal of a media command, operator lock's or another such as `unreadable` or `onAir`, is `blocked` and logged while the rest of the group runs, and a held `media delete` applies after the rest of its group.
- **Feedback.** The `media` topic's states and outcomes, missing changes, and `mediaUse` counting keys, scheduler entries and references through a `replaced` map.
- **Drop channels.** `dropChannels` loads, round-trips and is written on first run as §8 says.

## 12. Resolved choices

These are the places where the scope doc and Specs 1–7 left room and the draft of this spec chose.

**Answered 2026-11-07.** Every choice takes the draft's answer ("Draft"), and the page above reads accordingly. On M-8 Adam added "maybe look into alternative later": in v1 the media root stays on the startup volume, and a media root elsewhere is looked at again when builds are signed (ADR 0007). Three independent reviews shaped the draft before Adam answered. They moved the cases that syncing to read-only campuses creates to library mode (M-7), settled how the walk tells a move from a re-export or a restore and how a delete meets undo, dropped three of the first draft's choices that earlier specs already decide (deleting keeps the entry, as M9 says; a returning file plays from the next write, as Specs 3 and 4 say; the poster size buys nothing on air), and added M-4, M-7 and M-8.

| # | Choice | Draft said | Alternative | Answer |
| --- | --- | --- | --- | --- |
| M-1 | Where local-only media lives on a `readOnlyMasters` machine | `machine/media/`, never synced, so a campus's own video never syncs up or gets deleted by a one-way sync | Inside the synced media root, in a folder the sync tool is set to leave alone | Draft |
| M-2 | A file saved where an item's file was, such as a re-export over the old one | It replaces the item: the walk maps the old id to the new file, so cues play it with the old defaults, and saving the old file back reverses it; references aren't rewritten | The old id goes missing until someone runs `media replace` | Draft |
| M-3 | The defaults after `media replace` | The new item takes the old one's defaults when it has none of its own, as an import leaves it; one someone set up keeps its own | The new item always keeps its own defaults | Draft |
| M-4 | Who can send the media commands | Every source, as E-1 lets every source edit; operator lock still refuses them | Only the app and the API, which authenticate, so an OSC message on the network can't import or delete files; undo and redo of media commands then need the same limit | Draft |
| M-5 | Edit undo for imports | No: an import can run for minutes and isn't on the undo stack; `media delete` removes a mistaken one. Delete and replace can be undone | Each import undoable as one step, which needs a way to undo a job still running | Draft |
| M-6 | First-run drop channels | Video and image to channel 1; for audio the pool asks, since a first-run machine has no channel meant for audio | Audio to channel 1 as well | Draft |
| M-7 | Campus sync cases: an index arriving before its file, a missing library file brought on a USB stick, a file central hasn't indexed yet | Settled with library mode in v1.5, since the pilot runs writable; until then a read-only machine shows such items missing | Settled now, adding a fallback to an earlier version's bytes, rescue overrides and in-memory indexing to Area 8 | Draft |
| M-8 | Where the media root can be in v1 | On the startup volume, outside the Desktop, Documents and Downloads folders, so the engine never needs a macOS permission that each ad-hoc-signed update takes away (ADR 0007); `mediaRoot` anywhere else is refused | Anywhere, an external drive or a network share included; after each update, someone at the machine grants the engine access again before it can read the media | Draft, maybe look into alternative later |
