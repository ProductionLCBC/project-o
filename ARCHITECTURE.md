# Project O — Architecture

Project O is a Metal-native macOS presenter for churches, built around a small set of
numbered objects, one command vocabulary, and a playback engine that owns the screens.
This page is the model in one place. The specs in `docs/specs/` are the authority on
detail; when this page and a spec disagree, the spec wins and this page gets fixed.

## The model in five sentences

1. Content flows **cue → channel → stack → output**. A cue writes content to channels,
   each channel renders once to a texture, and each output composites its own ordered
   stack of channels.
2. **Everything is a command.** Keys, OSC, MIDI, macros, cues, the scheduler and the UI
   all emit one vocabulary (Spec 2). The UI composes commands; it has no private verbs.
3. **Numbers are identities, labels are display.** Every object type has its own
   number space; references are by number; renumbering rewrites references.
4. **Portable objects travel with the library; machine objects stay with the machine.**
   Channels, presets, lists, grades, transitions and macros sync between campuses;
   stacks, outputs, inputs, playlists and key bindings do not. They meet by number.
5. **Nothing edits live.** What is on a channel is an instance of a cue; edits take
   effect on the next fire. Channel attributes track (Spec 3) like a lighting console.

## Objects

| Portable (library) | Machine-level |
| --- | --- |
| Channel, Preset (one box layout per stack), Text Style, Grade, Transition, Audio Transition, Macro, List (master, with Cues) | Stack, Output, Audio Output, Input, Playlist, key bindings, machine settings |

Media is identified by content hash; authored documents (designed slides) by UUID.
Paths are never identity. Everything is plain JSON in two folder roots (Spec 1).

## Processes and modules

```
app/      Operator app (Swift, AppKit + SwiftUI). A client of the engine's API over localhost.
engine/   OEngine: the playback engine as its own process. Metal, VideoToolbox, Core Audio, DeckLink.
core/     OCore: objects, commands, channel state and the projection. Pure Swift, no Apple frameworks.
formats/  JSON schemas, the OFormats file adapter (the one place that touches disk for the Spec 1 roots) and the .pro importer. (The fixture library lives in tests/fixtures/, Spec 1 §10.)
tools/    Python importers and Planning Center tooling, as API clients.
docs/     specs/ (the authority), decisions/ (ADRs), the UX spec.
tests/    Unit, golden-image and soak scenarios. Public-domain content only.
```

`OCore` never imports `OEngine`. `OEngine` never defines its own notion of state; it
consumes `ShowState` and `Effect` from `OCore`. The app never renders show content;
previews arrive from the engine as shared IOSurfaces.

## The projection

One pure function, `project(state, commands, context) -> (state, effects)`, is the
only thing that changes channel state (Spec 3). The engine runs it live; the cue grid
runs it from the top of a list for thumbnails; the confidence stack runs it ahead of
the live position; a future timecode seek runs it to a point in time. It reads no
clock, touches no I/O, and is tested with a table of command sequences.

## The frame path

Per tick (Spec 4): control thread builds a frame plan from the ShowState → render thread
encodes channel passes (decode → linear light → grade → transition) → stack passes
(boxes, text, offset slots) → sink encodes → each output presents on its own cadence
(display vsync, or DeckLink scheduled playback on the card's clock).

- One master tick at the highest output rate; one rate family per machine.
- Decoded video never crosses the CPU: IOSurface → Metal texture → sink.
- Colour is handled once: everything becomes linear Rec.709 RGBA16Float, premultiplied,
  on the way in; sinks encode on the way out (10-bit). Blending is linear light.
- Text is rendered per stack by Core Text, per line, cached; the glyph-run layout is
  kept for later per-glyph animation.
- Audio never passes through a stack; the audio device clock is the A/V master.

## Engine rules (enforced by tests where possible)

- The render thread never takes a lock, allocates, touches a file or socket, or waits
  on a decoder or a drawable for more than one tick.
- Every output gets a frame every refresh; a missing frame is a repeat, never black.
- Failures are detected on the render thread and recovered on another. The audience
  sees the last good frame; the operator sees a badge; the log sees the detail.
- Every tick is measured; the soak rig fails a build that breaks the budget.
- All engine time is monotonic. The wall clock only stamps logs and resolves `[Time]`.

## Seams kept open on purpose

`RenderBackend` (Windows later), `ContentSource` (live inputs, Hap, designed slides,
audio sets), `Demuxer` (FFmpeg for exotic containers), `OutputSink` (NDI, recording),
`TransitionShader` (custom transitions), `TextRenderer` (glyph atlas / SDF),
`MasterClock` (LTC, MTC, Art-Net), `Encoder` (NDI formats). Each has exactly one
implementation in v1 and a protocol in its own file.

## What is fixed

The frame plan, the tick order, the colour pipeline, the resource rules, the command
vocabulary's shape, the file layout and the projection's purity. A future backend or
content kind reproduces these; it does not reinterpret them.

## Where to read next

- `docs/specs/1-objects-and-format.md` — every object, identity, the on-disk layout
- `docs/specs/2-commands.md` — grammar, vocabulary, OSC, API envelope, log entry
- `docs/specs/3-channel-state-and-projection.md` — state, tracking, the projection, test table
- `docs/specs/4-render-pipeline.md` — clocks, threads, passes, sinks, audio, failure, the spike
- `docs/ux-spec.md` — the UX and system design spec the above refine
- `docs/decisions/` — ADRs, one paragraph each
