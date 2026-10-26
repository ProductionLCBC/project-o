# Specs

One page per area, numbered in build order. Each is written before its code and kept as the code's documentation. **Specs outrank code**: when they disagree, either the spec is corrected first or the code is wrong. The UX and system design spec they refine is `../ux-spec.md`.

| File | Area | Status |
| --- | --- | --- |
| `1-objects-and-format.md` | Every numbered object with its fields, the JSON documents and folder layout, portable versus machine-level, identity, validation and migration. | Accepted 2026-10-25 |
| `2-commands.md` | The grammar, the v1 vocabulary, text and object forms, sources, OSC addresses and feedback, guards, execution semantics, the log entry, the API envelope. | Accepted 2026-10-25 |
| `3-channel-state-and-projection.md` | ShowState, tracking rules, write semantics, the live pointer, the projection function, its three bases, the 24-row test table, the Swift shape. **The first code.** | Accepted 2026-10-25 |
| `4-render-pipeline.md` | Clocks, threads, the frame plan, resources, content sources, channel and stack passes, text, sinks, audio, failure modes, measurement, module shape, the engine spike. | Accepted 2026-10-25 |

## Still to write, in order

These can be written while the spike soaks: media pool; cues, lists and playlists; presets and text; show-mode UI (carrying over what the clickable demo settled); edit-mode UI, minimal; log and saving. The v1.5 and v2 specs (library mode, runtime undo, live inputs, NDI, audio transitions, slide designer, timelines) wait until the pilot is scheduled.

## Provenance

These pages were exported on 2026-10-25 from the Claude Docs where they were drafted and reviewed:

- UX and system design spec (`../ux-spec.md`): https://claude.ai/artifact/N5bsbuj2pDaJNBdi3TJMUX
- Specs 1–4: https://claude.ai/artifact/Gv6oJ5sSvzr9jBnMcaUpWh (one tab per spec)
- Planning doc (spec review, build order, working process): https://claude.ai/artifact/Pr5jArnzv7EXbKjGDf3Seq
- Clickable UI demo: https://claude.ai/artifact/S1GmeEwBMrouCAW2MFTtLt

From the first commit on, the copies in this repository are the ones the code is built against. Edit them here; the docs above are the review history.
