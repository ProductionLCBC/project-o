# Spec 1: Objects and format

2026-10-25 · @Adam Granby · Status: accepted 2026-10-25 · Source: the UX and system design spec, the Decisions tab and the Spec review tab of the planning doc

## 1. Purpose and scope

This spec defines every persistent object in Project O, how each is identified, and how the whole library and a machine's configuration are written to disk. Everything else (commands, state, rendering, UI) reads and writes these objects, so this document is written first and changes to it are the most expensive kind.

**In scope:** the object catalog with fields and types; identity rules (numbers, hashes, UUIDs, versions); the on-disk layout; JSON conventions; the encoding of cues and commands; the media index; validation and migration.

**Out of scope:** the command grammar and vocabulary (Spec 2), runtime channel state and tracking (Spec 3), rendering (Spec 4), and the sync transport, which is deliberately undecided; this spec only guarantees that the layout syncs cleanly as plain files.

**Principles this spec enforces**

- Numbers are identities, labels are display. Each object type has its own number space. Internal references are by number; renumbering updates them.
- Portable objects travel with the library; machine-level objects stay with the machine. The two meet by number, so channel 2 and stack 1 mean the same thing at every campus.
- Content is identified by what it is: media by content hash, authored documents by embedded UUID. Paths are never identity.
- Text Styles are templates. Applying one copies its values into a box or layer; the copy is then independent.
- Plain files, stable diffs. One JSON document per object or object group, sorted keys, atomic writes, and a schema version in every file, so Git, diff tools and a folder-syncing tool all behave.
- The app runs with no sync layer present. Sync is a folder convention on top of this layout, never something the format depends on.

**Resolved here from the UX spec's open points:** channel render size (largest including stack), the Text Style object (templates, copy on apply), per-stack layouts inside a preset, masks (a Preset feature, reserved in the schema for v1.5), cue numbering (positional, with a stable UUID per cue), the storage form of commands (structured objects with a canonical text form), and the time base (nanoseconds internally, milliseconds and rational frame rates on disk).

## 2. Portable objects

Portable objects live in the library and travel between campuses. Every one has `number` (integer, unique within its type, gaps allowed), `label` (display string, never used for lookup) and `uuid` (stable through renumbering, used by caches and sync). Fields marked *reserved* are present in the schema but unused by v1, so later versions need no migration.

**Channel**

| Field | Type | Notes |
| --- | --- | --- |
| `defaultPreset` | preset number | Falls back to Preset 1 if missing |
| `defaults.transition`, `defaults.audioTransition` | transition number, audio transition number | What tracked attributes reset to |
| `defaults.gain` | decibels, number | Default 0 |
| `decoderCap` | 2 or 3 | Default 2 |
| `audioOutputs` | array of audio output numbers | Machine-level numbers, met by number |
| `renderSize` | `"largest"` or `{width, height}` | Default largest; the largest output size among stacks that include the channel |
| `textThumbnail` | enum: `body`, `firstLine` | Thumbnail style for text content |
| `usualContent` | enum: `media`, `text`, `slide`, `live`, `any` | Hint for the cue picker |

**Preset** holds `layouts`, a map from stack number to a layout, plus one entry under `"*"` that applies to any stack not named. A layout is an ordered `boxes` array (bottom to top within the channel's group) and a `mask` (*reserved*: alpha image reference and crop). Because stacks are machine-level and presets are portable, the two meet by stack number: a preset's layout for stack 2 is used at every campus where stack 2 exists, and the `"*"` layout covers the rest. The preset editor opens each layout at its stack's output size. Preset 1 is built in with a single `"*"` layout: one pixel box filling the frame, then a fallback body box.

**Box** (child of a Preset layout)

| Field | Type | Notes |
| --- | --- | --- |
| `binding` | `{kind: "pixels"}`, `{kind: "field", name}`, or `{kind: "static", text}` | Field names: `body`, `title`, `copyright`, `reference`, or a custom name; static text may contain variables |
| `frame` | `{x, y, w, h}` normalized 0–1 of the stack's output size | Resolution-independent |
| `fit` | pixels: `fill`, `fit`, `stretch`, `crop`; text: `{policy: "shrinkToFit" or "maxLines", maxLines, minSize}` |  |
| `textStyle` | an inline Text Style value, plus `fromStyle` (style number or null) | Copied on apply; `fromStyle` only records provenance for re-apply |
| `transition` | `{ref: transition number, ms: override or null}` | References the same Transition objects channels use; v1 implements cut and dissolve for boxes, and text-specific types join the Transition type set later |
| `transitionOnVariableChange` | bool | Default false; a popup box wants true |
| `fallback` | bool | Renders only if no earlier box drew |
| `grade` | grade number or null | Per-box output correction, separate from channel grades |

**Text Style** (numbered, portable): `font` (PostScript name), `size` ({value, unit}: pt is points on a 1080-line canvas scaled with output height, the default; percent is a percentage of output height), `weight`, `color` (RGBA 0–1), `alignment`, `lineSpacing`, `letterSpacing`, `outline` `{width, color}`, `shadow` `{x, y, blur, color}`, `allCaps` (bool), variations (a map of OpenType axis tag to value, such as wght, wdth, opsz, for variable fonts; weight is the wght axis when the font is variable and the nearest instance when it is not). The same value type is embedded in boxes and in slide-designer text layers.

**Grade**: `hue`, `saturation`, `brightness`, `contrast`, `blur`, `tint` (RGBA), `opacity`. All numbers with a defined identity value, so a grade of all-identity is a no-op.

**Transition**: `type` (`cut`, `dissolve`, `fadeThroughColor`), `ms`, `easing` (`linear`, `easeIn`, `easeOut`, `easeInOut`), `color` (RGBA, fade-through only). Transitions 1–3 ship built in and are editable, not deletable. Each type declares `appliesTo` (`pixels`, `text`, or both), so one object set serves channel transitions and box transitions and the editor offers only applicable types: in v1, cut and dissolve apply to both, fadeThroughColor to pixels only, and later text-motion types (crawl, typewriter, per-word reveals) will apply to text only.

**Audio Transition**: `type` (`cut`, `crossfade`, `fadeThroughSilence`), `ms`, `easing`, `offsetMs` (signed; measured from the trigger).

**Macro**: `commands` (array of command objects, see section 6), `color`, `tileLabel`. `scope` is computed, not stored: a macro that references a stack or output is machine-level and is written to the machine root instead of the library.

**List** (a master): `title`, `author`, `copyright`, `ccli`, `trackThrough` (bool), `version` (integer, incremented on every save), `cues` (ordered array), `timeline` (*reserved*). A local copy is the same document with `provenance` `{masterUuid, masterVersion, detachedAt}` and lives in the machine root.

**Cue** (child of List): `uuid`, `label`, `section` (string label or null), `note`, `trigger` (`{type: "go"}`, `{type: "time", ms}`, or `{type: "timecode", tc}`), `advanceAfterMs` (or null), `commands` (array). Cue numbers are positions, not stored; see section 4.

## 3. Machine-level objects

Machine-level objects describe one machine's hardware, mappings and local show structure. They never sync between campuses. The same `number`, `label`, `uuid` rule applies.

**Stack**: `slots` (ordered array, bottom to top), `base` (`black` or `transparent`), `defaultPreset` (preset number or null). A slot is `{channel, preset (number or null), offset (integer, -2 to +3), opacity (0–1), mute (bool)}`. A channel appears at most once per stack at each offset (offset slots of one channel are distinct slots); the loader rejects duplicates. gammaBlend (bool, default false) selects encoded-space compositing for that stack (Spec 4 section 9).

**Output**

| Field | Type | Notes |
| --- | --- | --- |
| `kind` | `sdi`, `display`, `ndi`, `multiviewer` |  |
| `device` | string | A stable hardware identifier: DeckLink port persistent ID, display UUID, or NDI source name |
| `format` | `{width, height, rate: {num, den}, interlaced: bool}` | Interlace is handled in the sink by weaving a progressive render |
| `colorRange` | `full` or `limited` | Default full for displays, limited for SDI |
| `genlock` | `reference`, `freeRun` | SDI only |
| `defaultStack` | stack number | Loaded at launch |
| `keyFillPartner` | output number or null | Two SDI ports paired as one logical key/fill output; keyMode is shaped (premultiplied fill, the default) or unshaped |
| `transitions` | `{switch: transition number, blackout: transition number}` | Output-level: stack switches, blackout, per-slot mute |

**Audio Output**: `kind` (`device` or `sdiEmbedded`), `device` (Core Audio device UID, or the SDI output number), `channels` (array of device channel indices), `delayMs` (0–1000, for downstream video latency), fallbackDevice (a Core Audio device UID or null; used only while the primary device is absent, otherwise the output is silent until it returns).

**Input**: `kind` (`sdi`, `ndi`, `camera`, `screen`), `device`, `format`, `deinterlace` (bool), `colorRange`, `audioMap` (array), `bufferingMs`, `expected` (bool, for pre-flight).

**Playlist**: `uuid`, `title`, `serviceDate` (ISO date or null; a date is optional), `archived` (bool), `items` (ordered). An item is one of `{kind: "header", label}`, `{kind: "linked", list: list number}`, or `{kind: "local", localUuid}` pointing at a local copy in the machine root. Playlists carry no cues of their own. The playlist's name is its title; the pair of title and date must be unique on a machine (case-insensitive), and the UI prompts for a different name on a clash, so a weekly "Sunday" playlist is fine as long as each has its date. The tree sorts dated playlists by date and lists undated ones by name in their own group.

**Key bindings**: an array of `{device: "keyboard" or a MIDI or Stream Deck device id, key, command}`; the scheduler is the same array with `{when: {days, time}}` in place of `key`. Exportable as its own file so stations can be standardized.

**Machine settings** (one document): machine `uuid` and `campusName`, `defaultRole`, `operatorLock` (enabled flag; the passcode hash lives in the Keychain, never here), `libraryMode` (`readOnlyMasters` or `writable`), `mediaRoot`, `defaultImportFolder`, `fallbackFont`, `thumbnailStack`, `decoderCapDefault`, `tracking` (per-attribute booleans), `timers` and `popups` (slot counts), `timeFormat`, `timeZone`, `startupMacro`, `shutdownMacro`, `restoreLastState` (bool, default false), `snapshots` `{cadence, retention}`, `commandBar` (bool, default false), `network` `{oscInPort, oscOutTargets, apiPort, apiToken reference}`.

## 4. Identity

**Numbers.** Each numbered type has its own space of positive integers. Numbers are unique within a type and a library (or a machine, for machine-level types), gaps are allowed, and the default ordering everywhere is by number. A reference from one object to another is the target's number, nothing else.

**Renumbering** is a library edit, not a rename. When an object's number changes, every internal reference in the library and the machine root is rewritten in the same save. The editor warns that external references (OSC maps, console cues, Stream Deck profiles) cannot be followed. Moving to a number that is already taken offers a swap, which renumbers both objects and rewrites both sets of references. The `uuid` never changes, which is how caches, logs and version history recognise an object across renumbering.

**Cue addressing.** A cue's number is its 1-based position in its list, recomputed whenever cues are inserted, removed or reordered; it is never stored. A cue's `uuid` is stored and stable, and is what thumbnail caches, undo and the fire log reference. The two user-facing addresses from the UX spec are both resolved at the moment of use: `list 42 cue 3` through list number and position, `item 4 cue 3` through playlist position and cue position.

**Media.** A media file's identity is the SHA-256 of its bytes, written as `sha256:` followed by 64 lowercase hex characters, computed once at import and verified only when a file's size or modification time changes. Identical files anywhere under the root resolve to one identity. The index tracks renames and moves; a path is never identity.

**Authored documents** (designed slides and templates) change bytes on every edit, so each carries an embedded `uuid` in its JSON and is referenced as `slide:` followed by the UUID.

**Machines and libraries** each have a `uuid`, generated on first run and never changed; logs, snapshots and local-copy reports are tagged with the machine's.

**Versions.** Every List master carries an integer `version` that increments on each save. Saving writes the previous document to the versions folder (section 5) before overwriting, which is the whole version-history mechanism: last write wins, and any version is one file copy away. Local copies record the master's `uuid` and `version` they were cut from.

**Variables** are not objects. `[Timer 1]`, `[Popup 3]`, `[Time]` and the context values are resolved by name at render time; the only persisted facts about them are the slot counts in machine settings and the format strings embedded in text.

## 5. File layout and JSON conventions

Two roots, both plain folders the user can see: the **library root** (portable, synced down to campuses) and the **machine root** (local, never synced). The media root is a folder inside the library root by default and may be pointed elsewhere in machine settings.

```
library/
  library.json              schema, library uuid, name
  channels.json             all channels
  text-styles.json          all text styles
  grades.json               all grades
  transitions.json          all transitions
  audio-transitions.json    all audio transitions
  presets/                  one file per preset: 003-lower-third.json
  macros/                   portable macros, one file each
  lists/                    one file per master: 042-great-is-thy-faithfulness.json
  versions/042/             previous versions of list 42: v0017.json ...
  media/                    the media root (user subfolders, fonts/, imports/)
  media-index.json          hash to path, metadata, defaults (section 7)

machine/
  machine.json              schema, machine uuid, settings
  stacks.json  outputs.json  audio-outputs.json  inputs.json  clocks.json
  keys.json                 key bindings and scheduler
  media-local.json          local-only media and path overrides (section 7)
  macros/                   machine-level macros
  playlists/                one file per playlist: 2026-11-01-sunday.json, or sunday-night.json when undated
  lists-local/              local copies of masters, with provenance
  state/last.json           channel state at last clean shutdown (restore-last-state)
  logs/  snapshots/         written by the app, read by nothing it depends on
```

File names carry the number and a slug of the label for human reading only; the loader identifies a file by the `number` inside it and renames the file to match on save. Every document starts with the same header.

```json
{ "schema": 1, "app": "0.1.0", "kind": "list", ... }
```

**JSON rules**

- UTF-8, LF line endings, two-space indentation, keys sorted, one object per line in arrays of objects. The point is diffs that read.
- Keys are camelCase. Enums are lowercase strings. Booleans are real booleans, never 0 and 1.
- Times on disk are integer milliseconds (`ms` suffix), timecode is `"HH:MM:SS:FF"`, frame rates are `{num, den}` (so 59.94 is `{60000, 1001}`), dates are ISO 8601. Internally the engine uses nanoseconds; conversion happens at the file boundary.
- Colors are `{r, g, b, a}` floats 0–1 in sRGB. Normalized geometry is 0–1 of the containing size.
- References are plain numbers (`"preset": 3`), hashes are prefixed strings (`"sha256:..."`), authored documents are `"slide:<uuid>"`.
- Unknown keys are preserved on load and written back unchanged, so a newer app's files survive a round trip through an older one.

**Writing.** Every save writes to a temporary file in the same folder, fsyncs, and renames over the original, so a crash mid-write leaves the previous file intact. Saves are debounced per document; a list being typed into is written at most once a second and always on blur. The loader and the folder watcher ignore a sync tool's temporary and partial files (names beginning with a dot or ending in .tmp, and any file whose JSON does not parse yet), so a document arriving by sync is read only once it is complete. Continuous save means there is no save command anywhere in the UI.

**Why one file per list and per preset:** they are the objects that change most, and per-file granularity keeps sync conflicts and diffs confined to the thing that changed. The small catalog files (channels, grades, transitions) change rarely and are fine as single documents.

## 6. Cue and command encoding

A cue is an ordered list of commands, and so is a macro. Commands are stored as structured JSON objects, not as text, because a text-content write carries multi-line lyrics that a one-line grammar handles badly, and because validation and migration of structured data is straightforward. Every command object has exactly one canonical text form, defined in Spec 2, and the two are convertible in both directions without loss. The palette view and the raw command view therefore read the same array; the raw view shows the canonical text.

Each command object has `"cmd"` (a dotted name), its parameters, and an optional `"when"` guard (macros only in v1, reserved on cues). Channel writes carry their content and any attribute riders:

```json
{ "cmd": "channel.write", "channel": 1,
  "content": { "kind": "media", "ref": "sha256:9f2c...", "in": 0, "out": null, "loop": true },
  "transition": { "ref": 2, "ms": 500, "scope": "once" },
  "grade": { "ref": 5, "scope": "track" } }
```

Text content is inline, which is what keeps a song self-contained in its list file:

```json
{ "cmd": "channel.write", "channel": 2,
  "content": { "kind": "text", "fields": { "body": "Great is Thy faithfulness,\nO God my Father" } } }
```

**Content kinds** (`content.kind`): `media` (`ref` is a hash; optional `in`, `out` in ms, `loop`, `gain` override, `syncOffsetMs` override), `text` (`fields` map), `slide` (`ref` is `slide:<uuid>`, optional `build` index, default final), `input` (`input` number), and `empty` (a clear; `channel.clear` is sugar for it).

**Attribute riders** on a write: `transition`, `audioTransition`, `grade`, `gain`, `chase`, `build`, each with `scope` of `once` (this cue only) or `track` (from here on); the grade rider also takes an optional ms over which the change interpolates. A tracked attribute written on its own, without content, is its own command (`channel.transition`, `channel.grade`, `channel.gain`), so a cue can change a grade without touching content.

**Hold** is the absence of a command for that channel; nothing is stored for a held channel.

**Everything else** in the vocabulary is a plain command object with scalar parameters: `{"cmd": "output.stack", "output": 1, "stack": 4}`, `{"cmd": "timer.set", "timer": 1, "ms": 300000}`, `{"cmd": "next"}`. Macro references are `{"cmd": "macro", "macro": 12}`. Selection is never stored; the UI expands "selected" to absolute channel numbers before a command is recorded.

**Validation.** The loader checks each command against the vocabulary in Spec 2 and flags unknown commands or bad parameters on the cue rather than dropping them; the cue shows a warning chip and the command is kept verbatim so a newer version can still read it.

## 7. Media index and resolver

The media root is a plain folder tree the user organizes freely. The index maps identity to what the app knows about each file and is kept in two tiers: a **library index** (`library/media-index.json`, synced with the library, written only by machines in writable library mode) for media that belongs to the library, and a **machine index** (`machine/media-local.json`) for media that exists only on this machine plus any path overrides. Both can be rebuilt from the files if lost.

**Index entry**

| Field | Notes |
| --- | --- |
| `id` | `sha256:...` for files, `slide:<uuid>` for designed slides and templates |
| `path` | Relative to the media root, forward slashes; updated when the file moves |
| `kind` | `video`, `image`, `audio`, `audioSet`, `slide`, `template` |
| `size`, `modified` | For change detection without re-hashing |
| `durationMs`, `fps` `{num, den}`, `width`, `height` | Video and audio metadata read at import |
| `hasAudio`, `hasAlpha`, `codec` | Drive decoder choice and the pre-flight report |
| `poster` | Relative path to the extracted poster frame (PNG), used by offset slots and thumbnails |
| `defaults` | `trimInMs`, `trimOutMs`, `loop`, `gain` (dB), `grade` (number or null), `syncOffsetMs` (±1000), `defaultChannel` (number or null) |
| `addedAt`, `folder` | For sort and the folder rail |

**Why two tiers.** A single synced index would let a campus's local import write into a file the central library also writes, and last-write-wins would eventually eat someone's entry. A purely local index would force every campus to re-derive authored data (trim points, loop flags, default grades) that should travel with the library. Splitting them gives each file one writer: central owns the library index, the campus owns its local index.

**Lookup order.** Resolve an id in the machine index first, then the library index. When the library root is synced byte-for-byte, the library index already holds correct relative paths and the machine index is usually empty. When a campus relocates media (a different root, a faster drive), the machine index carries `overrides` from id to local path, and the library index is never edited. Local-only media (a campus announcement video) lives in the machine index with the same entry shape and promotes to the library index when the file is added to the library on a writable machine.

**Rebuild.** On demand, or when an index is missing, the app walks the root, hashes files whose size or modification time is unknown (a 10–20 GB campus library hashes in well under a minute on Apple Silicon), reads metadata, and extracts posters it lacks. A rebuild never discards defaults it still has entries for.

**Missing state** is computed, never stored: an id whose path no longer exists stays in the index, is shown with a missing badge wherever it is referenced, and is listed by pre-flight. A `replace media` command rewrites every reference from one id to another across lists, macros and presets, and records the mapping in the index so re-imports of the old file resolve to the new one.

**Import** copies any file dragged from outside the root into the default import folder, hashes it, reads metadata, extracts a poster frame, and writes the entry. Optimization (transcoding) is a later phase and will add a `derived` map to the entry for alternate encodings of the same id.

**Audio sets** are folders treated as one item: the entry's `tracks` array lists the member ids in play order, with a crossfade in ms.

**Designed slides and templates** are JSON files in the media root with the extensions `.oslide` and `.otemplate`. Their first-level keys are `uuid`, `schema`, `size` `{width, height}`, `layers` (text, shape, image, video, referencing pool ids), `fieldTags` (which text layers expose `body`, `title` and so on), `builds`, and for templates `editableLayers`. Their full schema belongs to the slide-designer spec; this spec fixes only the envelope and the identity rule.

**Fonts** live in `media/fonts/` so they sync with the library. Registration from that folder is deferred; v1 references fonts by PostScript name and uses whatever is installed, with the machine's fallback font substituting and the substitution reported.

## 8. Validation, migration and forward compatibility

**Schema versions.** `schema` is a single integer per document kind, starting at 1. It changes only when a field's meaning changes or a required field is added; adding an optional field never bumps it. The app knows the highest schema it writes and the lowest it can read.

**Migrations** are forward-only functions from schema N to N+1, applied in order on load, each one small and tested against a fixture from before the change. A document is migrated in memory and written back at the current schema the next time it is saved, never on load alone, so opening a library with a newer app is not itself a write.

**Unknown fields** are preserved: every object keeps an opaque bag of keys it did not recognise and writes them back unchanged. An older app can round-trip a newer library without losing data it does not understand, which is what makes mixed versions across 20 campuses survivable.

**Unknown commands** (section 6) are kept verbatim and flagged, never dropped.

**Reference checks** run on load and produce one report, which is also what the pre-flight command reads: references to numbers that do not exist (a cue writing a deleted channel, a slot naming a missing preset), duplicate channels in a stack, duplicate numbers within a type, media ids with no path, and fonts not installed. A broken reference degrades to the documented default (Preset 1, the channel default transition, an empty slot) and is reported; nothing refuses to load because of it.

**External changes.** When a document changes on disk under the app (a master arriving by sync, a hand edit), the app reloads it on the control thread and applies the nothing-edits-live rule: the live list keeps playing from its loaded cues, each cue picks up the new version on its next fire, and the cue grid marks the list as updated. A reload never touches channel state or the live pointer.

**Hard failures** are only malformed JSON and a schema newer than the app can read. Both leave the previous good state in place and surface a plain message naming the file.

**Concurrency.** Last write wins at the file level. Because each list and preset is its own file and every master save first copies the previous version aside, the worst case of two machines editing one master is a recoverable one-version rollback, never a merge.

## 9. Worked examples

The first-run library, as written by the app on a fresh install, with a two-cue song added.

**`library/channels.json`**

```json
{
  "app": "0.1.0",
  "channels": [
    { "audioOutputs": [1], "decoderCap": 2,
      "defaultPreset": 1, "defaults": { "audioTransition": 1, "gain": 0, "transition": 1 },
      "label": "Background", "number": 1, "renderSize": "largest",
      "textThumbnail": "body", "usualContent": "media", "uuid": "8d1e..." },
    { "audioOutputs": [1], "decoderCap": 2,
      "defaultPreset": 1, "defaults": { "audioTransition": 1, "gain": 0, "transition": 1 },
      "label": "Foreground", "number": 2, "renderSize": "largest",
      "textThumbnail": "body", "usualContent": "text", "uuid": "2b77..." }
  ],
  "kind": "channels", "schema": 1
}
```

**`library/presets/001-default.json`** (built in, copyable, not deletable)

```json
{
  "app": "0.1.0", "builtIn": true, "kind": "preset", "label": "Default", "number": 1, "schema": 1,
  "layouts": {
    "*": {
      "mask": null,
      "boxes": [
        { "binding": { "kind": "pixels" }, "fallback": false, "fit": "fit",
          "frame": { "h": 1, "w": 1, "x": 0, "y": 0 }, "grade": null,
          "transition": { "ms": null, "ref": 1 } },
        { "binding": { "kind": "field", "name": "body" }, "fallback": true,
          "fit": { "maxLines": 6, "minSize": 24, "policy": "shrinkToFit" },
          "frame": { "h": 0.8, "w": 0.9, "x": 0.05, "y": 0.1 }, "grade": null,
          "textStyle": { "alignment": "center", "allCaps": false, "color": { "a": 1, "b": 1, "g": 1, "r": 1 },
                         "font": "HelveticaNeue-Bold", "fromStyle": 1, "letterSpacing": 0, "lineSpacing": 1.1,
                         "outline": { "color": { "a": 1, "b": 0, "g": 0, "r": 0 }, "width": 0 },
                         "shadow": { "blur": 8, "color": { "a": 0.6, "b": 0, "g": 0, "r": 0 }, "x": 0, "y": 2 },
                         "size": { "unit": "pt", "value": 72 }, "weight": 700 },
          "transition": { "ms": 250, "ref": 2 }, "transitionOnVariableChange": false }
      ]
    }
  },
  "uuid": "c0de..."
}
```

**`library/lists/042-great-is-thy-faithfulness.json`**: cue 1 writes a background video and the first lyric; cue 2 holds the background and writes the next lyric.

```json
{
  "app": "0.1.0", "author": "Thomas Chisholm", "ccli": "18723", "copyright": "Public domain",
  "kind": "list", "number": 42, "schema": 1, "title": "Great Is Thy Faithfulness",
  "trackThrough": false, "uuid": "a9f0...", "version": 17,
  "cues": [
    { "advanceAfterMs": null, "label": "Verse 1", "note": "", "section": "Verse 1",
      "trigger": { "type": "go" }, "uuid": "11aa...",
      "commands": [
        { "cmd": "channel.write", "channel": 1,
          "content": { "kind": "media", "ref": "sha256:9f2c...", "loop": true },
          "transition": { "ms": 1000, "ref": 2, "scope": "once" } },
        { "cmd": "channel.write", "channel": 2,
          "content": { "kind": "text", "fields": { "body": "Great is Thy faithfulness,\nO God my Father" } } }
      ] },
    { "advanceAfterMs": null, "label": "Verse 1", "note": "", "section": "Verse 1",
      "trigger": { "type": "go" }, "uuid": "22bb...",
      "commands": [
        { "cmd": "channel.write", "channel": 2,
          "content": { "kind": "text", "fields": { "body": "There is no shadow\nof turning with Thee" } } }
      ] }
  ],
  "timeline": null
}
```

**`machine/stacks.json`**: stack 1 is the main look on output 1; stack 2 is the unassigned confidence stack from the first-run defaults.

```json
{
  "app": "0.1.0", "kind": "stacks", "schema": 1,
  "stacks": [
    { "base": "black", "defaultPreset": null, "label": "Main", "number": 1, "uuid": "5e5e...",
      "slots": [ { "channel": 1, "mute": false, "offset": 0, "opacity": 1, "preset": null },
                 { "channel": 2, "mute": false, "offset": 0, "opacity": 1, "preset": null } ] },
    { "base": "black", "defaultPreset": 2, "label": "Confidence", "number": 2, "uuid": "6f6f...",
      "slots": [ { "channel": 2, "mute": false, "offset": 0, "opacity": 1, "preset": null },
                 { "channel": 2, "mute": false, "offset": 1, "opacity": 1, "preset": 3 } ] }
  ]
}
```

Note the confidence stack: the UX spec says a channel appears at most once per stack, but offset slots of the same channel are distinct slots by design (the +1 slot shows the next cue). The rule is therefore *a channel appears at most once per stack at each offset*, and the loader enforces that form.

**`machine/machine.json`** (excerpt)

```json
{
  "app": "0.1.0", "campusName": "Manheim", "commandBar": false, "decoderCapDefault": 2,
  "defaultRole": "editor", "fallbackFont": "HelveticaNeue", "kind": "machine",
  "libraryMode": "readOnlyMasters", "mediaRoot": "../library/media",
  "network": { "apiPort": 8220, "apiToken": "keychain", "oscInPort": 8000, "oscOutTargets": [] },
  "operatorLock": { "enabled": false }, "popups": 4, "restoreLastState": false, "schema": 1,
  "snapshots": { "cadence": "launchAndService", "retention": "7d-daily-weekly" },
  "thumbnailStack": 1, "timeFormat": "h:mm a", "timeZone": "America/New_York", "timers": 4,
  "tracking": { "audioTransition": true, "chase": true, "gain": true, "grade": true, "transition": true },
  "uuid": "7a7a..."
}
```

## 10. Tests this spec implies

These are written before the format code, from this document, and are the definition of done for the area.

- **Round trip.** Load every fixture document, write it back, and diff: byte-identical output, including unknown keys and key order.
- **Fixture library.** A complete first-run library plus the worked examples above, in `tests/fixtures/library-v1/`, with public-domain content only. Every later spec's tests start from it.
- **Identity.** Renumbering a channel rewrites every reference in lists, presets, stacks and macros; a swap renumbers both; `uuid` survives. Hashing the same bytes at two paths yields one index entry.
- **Cue addressing.** Inserting, deleting and reordering cues renumbers positions and keeps `uuid`s; `list N cue M` and `item N cue M` resolve to the expected cue after each edit.
- **Validation report.** Each broken-reference case in section 8 produces exactly the documented degrade and one report line; malformed JSON and a too-new schema fail without touching the previous state.
- **Migration.** A schema-0 fixture (invented for the test) migrates to schema 1 in memory and is not written until a save.
- **Atomic writes.** A simulated crash between temp-file write and rename leaves the original readable.
- **Command encoding.** Every command object in the fixtures converts to canonical text and back without loss (shared with Spec 2's tests).
- **Stack rule.** Duplicate channel-and-offset pairs in a stack are rejected; distinct offsets of one channel are accepted.

## Resolved questions

- **Text size:** both units. `size` is `{value, unit}` with `pt` (points on a 1080-line canvas, scaled with output height) as the default and `percent` of output height as the option, so 20% means a fifth of the screen on any output.
- **Stack-size hint:** superseded. A preset now holds one layout per stack (section 2), each designed at that stack's output size, with a default layout for stacks not named, so no aspect hint is needed.
- **Index location:** two tiers, library and machine, as section 7 now describes, with the machine index consulted first.
- **Playlist naming:** the title is the name and the date is optional. Title plus date must be unique per machine; the UI prompts for a new name on a clash. The thing to watch is the weekly case: twenty "Sunday" playlists are fine only because each carries its date, so an undated "Sunday" can exist once.
