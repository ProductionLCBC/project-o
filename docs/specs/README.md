# Specs

One page per area, numbered in build order. Each is written before its code and kept as the code's documentation. **Specs outrank code**: when they disagree, either the spec is corrected first or the code is wrong. The UX and system design spec they refine is `../ux-spec.md`.

| File | Area | Status |
| --- | --- | --- |
| `1-objects-and-format.md` | Every numbered object with its fields, the JSON documents and folder layout, portable versus machine-level, identity, validation and migration. | Accepted 2026-10-25 |
| `2-commands.md` | The grammar, the v1 vocabulary, text and object forms, sources, OSC addresses and feedback, guards, execution semantics, the log entry, the API envelope. | Accepted 2026-10-25 |
| `3-channel-state-and-projection.md` | ShowState, tracking rules, write semantics, the live pointer, the projection function, its three bases, the 24-row test table, the Swift shape. **The first code.** | Accepted 2026-10-25 |
| `4-render-pipeline.md` | Clocks, threads, the frame plan, resources, content sources, channel and stack passes, text, sinks, audio, failure modes, measurement, module shape, the engine spike. | Accepted 2026-10-25 |
| `5-editing.md` | The `edit` command family: where an edit runs and when it shows on air, addressing, the verbs and their inverses, groups and typing, validation and results, operator lock and library mode, edit undo and redo, restores, changes that arrive on disk. | Accepted 2026-11-04 |
| `6-presets-and-text.md` | Stacks and slots with the offset on the box, presets and Preset 1's confidence layout, field boxes and list metadata, text styles (anchor, units, overflow), fonts, the variable language and the v1 set, timers, popups and captions, their feedback, the first-run library. | Accepted 2026-11-04 |
| `7-cues-lists-and-playlists.md` | List folders on disk and list edits, a playlist's identity, file and items, the live pointer and the kept copies that place it when what it names is gone, the armed trigger and `disarm`, archive as a dated copy, live feedback and the countdown, the share of Spec 5 that Area 9 builds. | Accepted 2026-11-07 |
| `8-media-pool.md` | The media commands and who runs them, import (staging, hash first, the kinds v1 takes), the walk with its hash cache and how it tells a move from a re-export or a restore, the two indexes and the machine's own media folder, where media may live, poster frames and pool tiles, delete and replace with their inverses, the `media` topic and the use query, drop channels. | Accepted 2026-11-07 |

## Still to write, in order

In the order the scope gaps doc settled with Adam on 2026-11-04: log and saving (Area 12); show-mode UI with its settings section and the operator lock (Areas 13, 17 and 18, carrying over what the clickable demo settled); edit-mode UI, minimal (Areas 10 and 14). Each is drafted as a tab of the specs doc below and exported here once Adam accepts it. The v1.5 and v2 specs (library mode, runtime undo, live inputs, NDI, audio transitions, slide designer, timelines) wait until the pilot is scheduled.

## Provenance

These pages were exported from the Claude Docs where they were drafted and reviewed, on 2026-10-25 except Specs 5 and 6, exported on 2026-11-04, and Specs 7 and 8, exported on 2026-11-07:

- UX and system design spec (`../ux-spec.md`): https://claude.ai/artifact/N5bsbuj2pDaJNBdi3TJMUX
- Specs 1–8: https://claude.ai/artifact/Gv6oJ5sSvzr9jBnMcaUpWh (one tab per spec)
- Scope gaps doc (the scope of every area that waited on a spec, as Adam settled it on 2026-11-04; Spec 5 onward is written from its answers): https://claude.ai/artifact/2wd3EJdEYcY1uf3zpvFtW6
- Planning doc (spec review, build order, working process): https://claude.ai/artifact/Pr5jArnzv7EXbKjGDf3Seq
- Clickable UI demo: https://claude.ai/artifact/S1GmeEwBMrouCAW2MFTtLt

From the first commit on, the copies in this repository are the ones the code is built against. Edit them here; the docs above are the review history.
