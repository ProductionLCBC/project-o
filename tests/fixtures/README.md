# tests/fixtures/

Public-domain content only.

## `library-v1/` — the fixture library (Spec 1 §9, §10)

A complete first-run library plus the worked examples of Spec 1 §9, in the canonical form of
§5 (UTF-8, LF, two-space indent, keys sorted by code point, a container whose members are all
scalars or empty on one line, one object per line otherwise). Every later spec's tests start
from it, and the round-trip test requires the writer to reproduce every document byte for byte.

`library/` is the library root: `library.json`, the five catalog documents (channels 1–3:
Background, Foreground and Clock, the first-run set of Spec 6 §9), presets 1–4 (Default, built
in, with its `"*"` layout and the confidence layout `"2"`, whose second body box draws the next
cue at offset +1; Clock, one static `[Time]` box; Lower third, with a layout for stack 2; Credits,
field boxes for `title`, `author`, `copyright` and `ccli`, for the list-metadata fallback of Spec 6
§3), the portable macro 1 (Welcome, with a guard), list 42 (*Great Is Thy Faithfulness*, Thomas
Chisholm, 1923, public domain; the §9 two cues plus a Time-triggered third and a chorus with
riders) at version 17 with version 16 under `versions/a9f00000-0000-4000-8000-00000000002a/` (its
uuid, §5), list 7 (*Doxology*, Thomas Ken, 1674; a timecode trigger, a missing video, a slide
write, a macro call), and `media-index.json`.

`library/media/` holds synthetic media only: `backgrounds/dawn.mp4` (64×36, eight frames of a
colour wash, written by AVAssetWriter), `backgrounds/cross.png`, `local/cross-fast.png` (the same
bytes at a second path: one identity, Spec 1 §4), `local/announcement.png` (local-only media,
indexed in the machine root), a poster frame, and `slides/welcome.oslide` (the §7 envelope). The
index also lists `backgrounds/mountains.mp4`, which does not exist: the missing state of §7.

`machine/` is the machine root: settings, stacks (Spec 6 §9's: Main holds channels 1 and 2,
Confidence channels 2 and 3, neither with a default preset, so each slot takes its channel's
preset: the confidence stack draws Preset 1's `"2"` layout for channel 2 and the Clock for channel
3), two outputs, two audio outputs, one input, `clocks.json` (reserved), key bindings with one scheduler
entry, the machine index with a path override, the machine-level macro 2 (Preshow, which names a
stack and an output), three playlists named from their titles (Spec 7 §8: "Sunday", dated, in
`sunday.json`; "Sunday Night", which links list 42 twice, for the pointer tests; and "Sunday
2026-11-01", the archived copy of "Sunday"), each item with the uuid Spec 7 §3's `KIND:KEY:N`
rule gives it and each linked item with its list's uuid, a local copy of list 42 with
provenance, and `state/last.json`.

Identities are fixed: UUIDs are `XXXXXXXX-0000-4000-8000-NNNNNNNNNNNN` with a readable prefix
and the object's number at the end; media ids are the real SHA-256 of the files.

## `migrations/`

`list-schema-0.json` is the schema-0 fixture Spec 1 §10 asks for, invented for the test: a
cue's `trigger` was a bare string with its value beside it (`triggerMs`, `triggerTc`) and
`trackThrough` did not exist.

## `spike/` — the engine spike's roots (Spec 4 §15)

`spike/library/` is the library root the soak runs: the catalog documents and the four presets
copied from `library-v1/` byte for byte, one list (*Spike hymns*: Amazing Grace, Holy Holy Holy, Be Thou My
Vision, It Is Well with My Soul and Come Thou Fount, all public domain, two lines a cue, a clear
at the end of each hymn, and a last cue that cuts to the clapper) and `media-index.json` naming
six synthetic items: a ProRes 422 Proxy background that loops between its trims, an HEVC
background with a tone that is trimmed and holds at its end, a 10-bit HEVC background with a tone
that loops, a ProRes 4444 background with alpha, the clapper (a flash on frame 30 and a click at
one second) and a PNG still. The media itself is generated, not committed: `oengine
make-fixtures tests/fixtures/spike/library/media` (which `scripts/soak.sh` runs when the files
are missing) writes it with `FixtureMedia`, and the index carries fixed ids rather than content
hashes so the lists resolve on any machine. `spike/machine/` is the bench machine root: two
60p display outputs (the main one at 1920×1080 here; the bench edits it to 4096×2160 or an SDI
output), the two stacks of `library-v1/` and one audio output on the default device. Both spike
roots are in canonical form and covered by the round-trip and schema tests like `library-v1/`, and
the round-trip test checks that the shared documents still match. A bench machine that holds an
older copy of these roots needs a fresh copy from here (Spec 6 §9 changed the stacks and presets).

`../soak/spike.json` is the Spec 4 §15 script: the list on repeat with `next` every five seconds,
a stack switch and a blackout every ten minutes. Large soak media stays on the test bench.
