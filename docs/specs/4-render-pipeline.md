# Spec 4: Render pipeline

Oct 25, 2026 · @Adam Granby · Status: accepted 2026-10-25 · Consumes ShowState and Effects from Spec 3; defines the engine the spike builds

## 1. Purpose and scope

This spec defines how a ShowState becomes pixels on every output and sound on every audio output, every frame, for hours. It is the engine the spike builds and the part of Project O where mistakes are expensive, so it is written to be conservative where a Sunday depends on it and deliberately open where the future needs room: new content kinds, new transition types, per-glyph text, Hap, NDI, live inputs, a Windows backend.

**In scope:** clocks and pacing; threads; the per-frame plan and its passes; GPU resources; video decode and content sources; the channel pass; text rasterization; the stack pass; output sinks (display, DeckLink, NDI, multiviewer, thumbnails); audio; failure and recovery; measurement; module shape; the spike's pass criteria.

**Out of scope:** the UI that shows any of this; the operator app's own rendering; the slide designer's layer model (its *render* hook is reserved here); timeline and chase (v2).

**The five guarantees**

1. **Every output gets a frame every refresh.** If a new frame is not ready, the previous frame is presented again and a drop is counted. Nothing is ever presented half-rendered, and nothing is ever black unless a cue asked for it.
2. **Decoded video never crosses the CPU.** Frames go from the decoder's IOSurface to a Metal texture and stay on the GPU until a sink that needs CPU bytes (DeckLink, NDI) reads them back asynchronously.
3. **The render thread never waits on anyone.** It takes no locks, allocates nothing, touches no file, and reads state through a single pointer swap. Anything that could block happens on another thread and hands over finished results.
4. **Colour is handled once, in one place.** Every source becomes linear-light Rec.709 RGBA16Float, premultiplied, on the way in; every sink encodes on the way out. No pass in between knows about gamma, matrices or ranges.
5. **Everything is measured.** Every frame records its timings and every output records its drops, so the soak rig can prove the first four guarantees rather than assume them.

## 2. Clocks and frame pacing

**One master tick.** The engine runs on a single tick whose rate is the highest output rate on the machine, counting fields for interlaced outputs. With a 4K30 LED wall and 1080i60 sides the tick is 60 Hz; the wall consumes every second tick, the sides consume two ticks per frame (one per field). Every tick increments the frame counter that Spec 3 uses as `frame`, and command groups land on tick boundaries.

**One rate family per machine.** All outputs must share a family: integer (60, 30) or fractional (59.94, 29.97). A machine with a 30 fps output and a 59.94 output cannot be paced from one clock without periodic repeats, so pre-flight reports it as an error for outputs on the master clock and a warning for a display that cannot match the family, since it will drift against it. HDMI and DisplayPort sides should be set to 60p or 59.94p where the processor allows; the interlaced path exists for the ones that cannot.

**Where the tick comes from**

| Machine has | Master clock | Why |
| --- | --- | --- |
| Any DeckLink output with a genlock reference | The DeckLink hardware clock, locked to reference | The whole broadcast chain shares it; output is frame-accurate |
| A DeckLink output, no reference | The DeckLink hardware clock, free-running | Still a hardware clock; displays follow it |
| Display outputs only | The primary output's CADisplayLink | The best clock available without hardware |

The render thread's wake-up is a timer disciplined to the master clock: each tick it reads the master's time (DeckLink hardware reference time, or the display link's target timestamp), corrects its phase, and never free-runs for more than one tick without a reference reading. If the master clock disappears (a card unplugged), the engine falls back to the next row in the table within one second and logs it. All engine time is monotonic (mach absolute time); the wall clock is read only to stamp log lines and resolve \[Time\], so an NTP adjustment mid-service can never move a frame.

**Decoupled presentation.** The render thread renders; sinks present. Each output owns a ring of three completed frames and presents the newest one on its own cadence (its vsync, or its scheduled DeckLink slot). When the master tick and a display's vsync are not the same clock they drift, which shows up as one repeated or skipped frame every few minutes on that display; this is accepted on display outputs, counted in the metrics, and is the reason SDI, not HDMI, is the frame-accurate path.

**Render only what is due.** A stack pass runs on a tick only if an output that consumes it is due that tick; a channel pass runs if any due stack samples that channel. A 30 fps wall therefore costs 30 channel renders a second, not 60, even on a 60 Hz tick.

**Budget.** At 60 Hz the tick is 16.7 ms. Targets: CPU encode under 2 ms, GPU time under 8 ms (half the tick), present at the next vsync. Glass to glass is then about three frames on a display and three to four on SDI (two scheduled ahead). The soak rig fails a build whose p99 GPU time exceeds the budget.

**Media time** is not the tick. A/V sync is anchored to the audio device clock (section 11); the video pass picks, for each playing instance, the decoded frame whose presentation time is the latest at or before the instance's media time. Instances without audio run a media clock derived from the tick so they stay deterministic.

## 3. Threads and queues

| Thread | Priority | Owns | Hands over |
| --- | --- | --- | --- |
| Control | user-interactive | The live ShowState, the command queue, the projection, timers, OSC and API I/O | A new immutable ShowState plus the frame plan for the next tick, via one atomic pointer swap |
| Render | real-time (time-constraint policy) | Encoding GPU work for one tick: channel passes, stack passes, sink conversions | Completed frames into each sink's ring; metrics into the black box ring |
| Decode, one per playing instance | user-initiated | A VideoToolbox session and its frame queue | Decoded IOSurface frames into a lock-free queue, 3–4 deep |
| Audio render callback | real-time (Core Audio's own) | Mixing and routing for one audio device | PCM to the device; the audio clock reading, published atomically |
| Text raster | utility | Core Text layout and Core Graphics raster | Finished text textures into the cache |
| Readback | utility | Async GPU to CPU copies for DeckLink and NDI | Filled shared buffers to the sink's scheduler |
| Thumbnails and multiviewer | background | Downscale passes and cue thumbnails | Textures for the UI, rate-limited to 30 Hz |
| Watchdog | utility | Liveness checks on every output and the render thread | Log entries and recovery triggers (section 12) |

**The render thread may never:** take a lock, allocate memory, touch a file or socket, call into Objective-C runtime paths that can allocate (string formatting, dictionary access), block on a decoder, wait for a texture to be uploaded, or wait on a drawable for longer than one tick. These are enforced as tests where possible (allocation counting under a debug allocator during a soak scenario) and as review rules otherwise.

**Hand-offs are lock-free.** State reaches the render thread as an immutable value behind an atomic pointer. Decoded frames travel in single-producer, single-consumer ring queues. Metrics are written into a preallocated ring the measurement thread drains. Where a `DispatchQueue` is convenient (text raster, thumbnails), it is used only off the render path.

**Frame plan lifetime.** The control thread builds the frame plan (section 4) for tick N+1 while the render thread encodes tick N, so the render thread only ever reads a finished plan. If no new plan is ready at a tick (the control thread stalled), the render thread reuses the previous plan with the frame counter advanced, so video keeps playing and the stall is logged rather than displayed.

## 4. The frame plan

A frame plan is a plain value describing everything the render thread must do for one tick, built on the control thread from the ShowState, the library and the machine configuration. Making it a value, rather than having the render thread interpret ShowState directly, keeps the render thread simple, makes a tick reproducible in a test (feed the plan, compare the textures), and means a new content kind or sink is a new pass type, not a change to the render loop.

```swift
struct FramePlan: Sendable {
  let frame: Int64
  let channelPasses: [ChannelPass]   // one per channel with content that a due stack samples
  let textJobs: [TextJob]            // rasterizations to request (not to wait for)
  let stackPasses: [StackPass]       // one per stack an output needs this tick
  let sinkPasses: [SinkPass]         // one per due output: encode, interlace, present or schedule
  let auxPasses: [AuxPass]           // multiviewer, preview, thumbnails; skipped first under pressure
}
```

**ChannelPass** names the channel, its target texture, the incoming source (a decoder queue, a still, a slide renderer, an input), the outgoing source if a transition is running, the transition (type, progress 0–1 for this tick, easing, colour), the grade parameters for this tick (interpolated on the control thread when a grade is animating) and the channel's render size.

**StackPass** names the stack, the output size, the base, and an ordered list of resolved boxes: for each slot, the preset layout chosen by the Spec 1 resolution order, with every box already bound to a concrete source (a channel texture with a fit mode, a text texture from the cache or a placeholder while it rasterizes, a static-text texture), its frame in pixels, its opacity (slot opacity times mute), its transition state, and its per-box grade. Offset slots arrive already resolved by the control thread's lookahead run, pointing at poster frames and cached text.

**SinkPass** names the output, the stack texture to take, the encode (display 10-bit, DeckLink v210 with or without weave, NDI BGRA) and the destination (a drawable, a shared buffer slot). Output transitions (stack switch, blackout) are expressed as a second stack texture and a mix factor.

**The tick, in order**

1. Read the newest frame plan (pointer load).
2. For each channel pass, pick the decoded frame for this tick from the instance's queue (section 6) and record whether a frame was missing.
3. Encode all channel passes into one command buffer; encode all stack passes into a second; encode sink encodes into a third; commit all three with GPU timestamps enabled.
4. For each due output, when its sink pass completes, publish the frame into the output's ring; the sink presents on its own cadence.
5. Encode aux passes only if the previous tick's GPU time left headroom; otherwise skip them and count the skip.
6. Write the tick's metrics into the ring.

The render thread performs no decision-making beyond step 2 and step 5. Everything else was decided when the plan was built.

## 5. Resources

Everything the render thread touches is allocated before it is needed, in private GPU memory, from pools sized for the current show. Allocation happens at three moments only: show load, a stack or output change (between ticks, double-buffered so the old pools serve until the new ones exist), and a decoder session start on the decode thread. Never on the render thread.

| Resource | Format | Size | Count | Notes |
| --- | --- | --- | --- | --- |
| Channel texture | RGBA16Float, premultiplied linear, private | The channel's render size (largest including stack) | 1 per channel, plus mip chain when a due stack samples below half scale | 70.8 MB at 4096×2160 |
| Stack texture | RGBA16Float, private | The output size | 3 per output (present ring) plus 1 for output transitions | A 1080p stack is 16.6 MB |
| Decoded frame | VideoToolbox's IOSurface in its native format (NV12, P010, 4:2:2 10-bit, or 16-bit RGBA for 4444) | Source size | Decoder pool of 8 per session: 4 queued, 1 on screen, headroom for the outgoing instance | Wrapped by CVMetalTextureCache; no copy |
| Still image | RGBA16Float linear with mips, private | Downsampled at load to the channel render size | 1 per still on a channel; 2 during a transition | Decoded with ImageIO off-thread |
| Text texture | BGRA8Unorm sRGB, premultiplied | The box's pixel width, one line high | LRU cache capped by bytes (default 256 MB) | The GPU converts sRGB to linear on sample |
| Poster frame | BGRA8Unorm sRGB | Half the channel render size | 1 per pool item, loaded on demand | For offset slots and thumbnails |
| Readback buffer | MTLBuffer, shared storage | One encoded frame (v210: 23.6 MB at 4096×2160; BGRA: 35.4 MB) | 3 per CPU sink | Section 10 |
| Thumbnail and multiviewer textures | BGRA8Unorm sRGB | Small (480 px wide thumbnails; a quarter-size multiviewer) | A fixed pool | Section 10 |

**Budget for the spike configuration** (two 4K channels, a 4K main stack, a 1080p confidence stack, two decoders): about 140 MB of channel textures, 260 MB of stack textures, 420 MB of decoder pools, plus caches, comfortably under 1 GB on a Mac mini's unified memory. Pre-flight computes this figure from the machine's stacks and channel caps and warns above a configurable ceiling.

**Heaps.** Channel and stack textures come from an `MTLHeap` per size class so a stack change reallocates without fragmenting; decoder pools are VideoToolbox's own; everything else is individually allocated at load. Texture usage flags are the minimum each role needs (`shaderRead` for sources, `renderTarget | shaderRead` for channel and stack textures) so Metal can lay them out optimally.

**Mipmaps** are generated for a channel texture only on ticks where a due stack samples it below half scale (a 4K channel on a 1080p confidence stack). A blit mip generation of a 4K texture costs about a millisecond; the alternative, aliasing on the confidence monitor, costs legibility.

## 6. Content sources

Every content kind is a `ContentSource`: something that, asked for tick N, returns the texture (or textures) to sample, or reports that it has nothing yet. The channel pass does not know whether it is drawing a video, a still, a camera or a designed slide. That seam is what lets later kinds arrive without touching the frame loop.

**Video files.** Demux with AVFoundation's `AVAssetReader` in passthrough mode (compressed samples out), decode with a `VTDecompressionSession` per playing instance. Using Apple's demuxer with a direct decoder session keeps the frame queue, the output pixel format and the seek behaviour under the engine's control while covering every container Apple plays; an FFmpeg demuxer slots in behind the same `Demuxer` protocol later for anything exotic. Request output in the source's native depth: NV12 or P010 for 4:2:0, 4:2:2 10-bit for ProRes 422, 16-bit RGBA for ProRes 4444 and other alpha sources. Conversion to linear light happens in the channel pass, never in the decoder.

**The frame queue.** Each instance decodes ahead into a lock-free queue of 3–4 frames, each tagged with its presentation time and duration. On a tick the channel pass takes the newest frame at or before the instance's media time, releases older ones, and repeats the previous frame if none qualifies, counting the repeat. The queue depth is the whole latency budget for decode jitter: a 4K HEVC frame that occasionally takes 30 ms to decode is invisible behind three frames of queue.

**Trims and the first frame.** A write with an in-point seeks the reader to the preceding keyframe and decodes forward to the in-point before the first frame is published, which can take tens of milliseconds on long-GOP sources. Two rules hide it: the control thread prefetches the media of the next cue (from the same lookahead run that feeds the confidence stack), opening its reader and pre-rolling to the in-point so the eventual write is instant; and a write that was not prefetched shows the item's poster frame on the tick it lands and starts its transition when the first decoded frame arrives, so nothing is ever late, only occasionally still.

**Loops.** Seamless loops need the in-point ready before the out-point arrives. An instance that loops keeps a second reader pre-rolled at the in-point; at the out-point the queue switches readers on the exact frame and the old reader is recycled into the next pre-roll. The decoder session is shared, so a looping instance costs one decoder, not two.

**End of media.** When an instance reaches its out-point without looping, the engine applies the instance's `endBehavior`: `hold` keeps the last frame, `clear` asks the control thread to issue `channel N clear` with source `engine` (a source Spec 2 should add; it passes lock), and `loop` is the case above.

**Stills.** Decoded once with ImageIO off the render thread, downsampled to the channel render size, converted to RGBA16Float linear with mips, and kept for as long as the instance (and any outgoing transition) needs it. A still is simply a source whose texture never changes.

**Reserved sources, same protocol:**

- *Live inputs* (v1.5): DeckLink capture, NDI receive and `AVCaptureDevice` all deliver IOSurface-backed frames into the same queue shape, with `freeze` holding the last frame.
- *Hap* (v1.5): the compressed frames are read through the passthrough reader, Snappy-decompressed on the decode thread, and uploaded as BC1 or BC3 textures from a staging ring; no VideoToolbox involved.
- *Designed slides* (v2): a `SlideRenderer` source that draws the slide's layers into the channel texture with its own pipeline each tick, animating builds, and exposes tagged text layers as fields for text boxes.
- *Audio sets* (v1.5): an audio-only source with a track list and crossfades; it contributes no texture.

**Missing media** produces a source that returns no texture; the channel renders transparent and the strip shows the badge.

**Decoder count.** The channel's decoder cap (2 or 3) bounds concurrent sessions per channel; the machine's total is bounded by pre-flight against what the hardware sustains. Sessions are created on the decode thread when a write is prefetched or lands, never on the render thread.

## 7. The channel pass

One pass per channel with pixel content, producing the channel texture: the content converted to linear light, graded, and mixed with the outgoing content if a transition is running. Text content has no channel pass; it is drawn per stack (sections 8 and 9).

**Stage 1, source to linear.** The fragment shader samples the source's planes and produces premultiplied linear RGBA. For YCbCr sources: matrix (BT.709 by default, BT.601 for SD-sized sources, BT.2020 sources converted to 709 primaries), range expansion when the source is limited range, then the transfer function. For RGBA sources (4444, stills): the transfer function, then premultiplication after linearizing, since files store straight alpha. **Decision on the transfer function:** every Rec.709 or sRGB-tagged source, video or still, is linearized with the sRGB piecewise curve. Video purists would use BT.1886 for video; using one curve keeps a PNG lower-third and the video under it in the same light, which matters more on an LED wall than the small difference between the curves. A per-machine switch to BT.1886 for video can come later without touching the pipeline.

**Stage 2, grade.** Applied in linear RGB: tint (multiply), brightness (multiply), contrast (scale around linear 0.18 mid-grey), saturation (blend toward luma), hue (rotation matrix), opacity (multiply all four components). Parameters arrive per tick, already interpolated by the control thread when a grade write carried a duration, so the shader is stateless. Blur is the exception: when the radius is non-zero, a separable two-pass Gaussian at half resolution runs before this stage and is skipped entirely otherwise, so a non-blurring show pays nothing for it.

**Stage 3, transition mix.** With no transition running, the graded incoming content is the result. With one running, the outgoing content (its own stage 1 and 2 output from the previous instance) is mixed in premultiplied linear space by type:

| Type | Mix at eased progress `t` |
| --- | --- |
| cut | incoming only; the transition effect still exists with zero duration |
| dissolve | `lerp(outgoing, incoming, t)` |
| fadeThroughColor | `t < 0.5`: `lerp(outgoing, colour, 2t)`; else `lerp(colour, incoming, 2t - 1)`, colour opaque and premultiplied |
| custom (later) | A `TransitionShader` conformer supplies a fragment function and a parameter block; the pass binds both |

Because the mix happens here, every stack, preview and thumbnail sees the same transition at the same moment at no extra cost.

**Fit into the channel texture.** The source is drawn into the channel's render size preserving its aspect ratio, letterboxed with transparent pixels. On the main stack this is normally a 1:1 mapping (a 4096×2160 source into a 4096×2160 channel) so the content is resampled once, at the box, and usually at 1:1 again. The cost of a second resample on smaller stacks is accepted for the simplicity of one texture per channel.

**Shader variants.** One channel shader, specialised with Metal function constants for source layout (NV12, P010, 4:2:2 10-bit, RGBA16, still) and transition type, compiled at launch into a small pipeline cache, so the per-tick work is a pipeline lookup and no branching in the shader.

**Designed slides** (v2) draw their layers into the channel texture through their own pipeline, then run stage 2 and stage 3 unchanged, so a slide-to-slide dissolve and a slide grade come free.

## 8. Text rasterization

Text has no look of its own; a box gives it one, per stack, at that stack's size. The rasterizer turns (text fields, text style, box frame in pixels) into textures the stack pass can sample, and it does so off the render thread, cached, and in a form that keeps the door open to per-glyph animation.

**Layout** is Core Text: an attributed string from the field text and the box's Text Style (font by PostScript name, size resolved from points-at-1080 or percent of output height, weight, colour, spacing, all-caps), laid out into a `CTFrame` within the box's pixel width. Core Text supplies shaping, kerning, ligatures, line breaking and non-Latin scripts; nothing else in the engine needs to know how text works.

**Fit policies** run on the layout, not the pixels. `shrinkToFit` binary-searches the point size between `minSize` and the style's size until the frame fits the box in both dimensions. `maxLines` truncates after N lines with an ellipsis and reports the overflow for the pre-flight and the editor. Alignment and vertical anchoring come from the style.

**Raster** is Core Graphics into a premultiplied BGRA8 bitmap, one texture per *line*, with the style's outline and shadow drawn as part of the line (shadow and outline extend the line's bounds, which the raster accounts for). Per-line textures cost nothing extra and make line-by-line reveals, crawls and per-line transitions possible without re-rasterizing. The texture is uploaded as an sRGB-typed Metal texture so the GPU linearizes on sample; 8-bit is sufficient for text edges and keeps the cache small.

**The glyph-run model is kept.** The layout result stored beside each cached texture is the list of glyph runs: for every line, every glyph's ID, font, position and advance. In v1 nothing reads it but the editor's caret and the tests. It is kept so that when per-glyph animation arrives, the renderer can switch to a glyph atlas (every glyph a quad) or signed-distance-field glyphs from Core Text's outline paths, driven by the same layout, with the slide and preset data unchanged.

**Cache.** Keyed by a hash of (field text, text style value, box pixel width, box pixel height, fit policy, output scale). Entries hold the line textures and the layout. The cache is an LRU bounded by bytes (section 5). Lookahead pre-rasterizes the next cue's text for every due stack so a fire never waits on text; a cache miss on a fire draws nothing for that box on the first tick and the texture from the second, which the soak metrics count as a `textLate` event that should read zero.

**Variables.** A box whose text contains variables is re-laid-out only when its resolved text changes, and no more than once a second; the result replaces the cache entry. A timer box therefore costs one small raster per second. Boxes with `transitionOnVariableChange` run their box transition between the old and new textures; the rest swap.

**Thumbnails** use the same rasterizer at thumbnail scale so a cue's thumbnail shows the real line breaks, not an approximation.

**Fonts.** v1 resolves PostScript names against installed fonts and falls back to the machine's fallback font, recording the substitution for pre-flight. Registering fonts from the media root is deferred, as decided.

## 9. The stack pass

One pass per due stack, compositing its slots bottom to top into the stack texture at the output's size. The pass is a sequence of textured quads, each a box, drawn with premultiplied over-blending in linear light. There are no intermediate textures per slot; a channel's boxes are drawn in order as one group and groups never interleave.

**Resolving a slot** happens on the control thread when the frame plan is built: the preset is the slot's, else the stack default, else the channel default, else Preset 1; the layout is the preset's entry for this stack number, else its `"*"` layout. Each box is then bound to a concrete source.

| Box binding | Source for this stack | Drawn as |
| --- | --- | --- |
| pixels | The channel texture (or nothing for text content) | A quad placing the channel texture in the box frame by fit mode: `fit` letterboxes, `fill` crops to cover, `stretch` ignores aspect, `crop` centers at 1:1 |
| field | The cached line textures for (this channel's field text, this box, this stack) | One quad per line, laid out by the cached layout; a missing cache entry draws nothing this tick and counts `textLate` |
| static | The cached textures for the box's own text with variables resolved | As field |

**Fallback boxes** draw only if no earlier box in the same channel's group drew anything, which the control thread decides when resolving (it knows the content kind), not the GPU.

**Per-box grade** is a second instance of the channel pass's stage 2 applied in the box's fragment shader; it exists for output correction (broadcast levels on one stack) and is identity for most boxes, in which case the shader variant without it is used.

**Box transitions.** When a box's content changes, the stack pass draws both the old and new textures mixed by the box's Transition object (cut or dissolve in v1), with the same mixer as the channel pass. Box transitions therefore never need a render target of their own.

**Opacity and mute.** A slot's effective opacity is its opacity times zero when muted; a muted slot still resolves (so unmuting is instant) and draws with alpha zero, which the pass skips. Output-level mute and blackout are not in the stack pass; they are a mix at the sink (section 10) so they can use the output's own transition.

**Offset slots** arrive pre-resolved from the lookahead run: a pixel box points at the pool item's poster frame texture, a field box at text rasterized from the projected state. They cut rather than transition, by definition.

**The gamma-blend switch.** A stack with `gammaBlend` on composites in encoded space: each box shader applies the sRGB OETF to its sampled colour before blending and the final stack pass output is linearized again for the sink. It is a shader variant selected per stack, costs two conversions per box, and exists only for matching an older look.

**Masks** (v1.5) are a layout-level alpha texture multiplied into every box of the layout in the same shader; the slot in the shader signature is reserved now so adding it changes no pipeline layout.

**Base.** The pass begins by clearing to the stack's base: opaque black or transparent. Transparent bases exist for key-and-fill outputs and for stacks layered by an external compositor.

**Cost.** A stack pass is a handful of full-screen quads; at 4096×2160 with two channels and four boxes it is well under 2 ms of GPU time on an M-series Mac. The channel passes dominate, which is why they run once per channel, not once per stack.

## 10. Output sinks

A sink takes a completed stack texture and gets it onto hardware. Every sink shares one **encode pass**: mix the stack texture with a second texture when an output transition is running (the previous stack for a switch, black for blackout, nothing for per-slot mute, which is handled in the stack pass), apply the output's transfer function, and write the output's pixel format. After that the sinks differ.

**Display sink.** One borderless, opaque window per screen at the screen's native mode, above every other window, hosting a `CAMetalLayer`: pixel format `bgr10a2Unorm` (10-bit; `bgra8Unorm_srgb` as a fallback the sink reports), colour space sRGB/Rec.709, extended dynamic range off, `displaySyncEnabled` on, `presentsWithTransaction` off, `maximumDrawableCount` 3. An opaque full-screen layer with nothing above it is what lets macOS scan the layer out directly without compositing it. The sink's `CADisplayLink` callback, not the render thread, takes the newest completed frame from the output's ring, requests a drawable, encodes the trivial encode pass into it and presents; if no drawable is available within the callback it skips and counts a drop. Display configuration changes (a processor rebooting, a cable pulled) pause the sink, keep its last frame, and resume when the screen returns at the configured mode.

**DeckLink sink.** The output is enabled in the configured mode with 10-bit YUV (`v210`) frames, limited range, Rec.709. The encode pass is a compute shader that writes v210 directly into an `MTLBuffer` with shared storage that the card reads by DMA through a custom frame buffer object, so the only CPU involvement is scheduling. Frames are scheduled two to three ahead on the card's stream time; the completion callback reports `completed`, `displayedLate`, `dropped` or `flushed` per frame and those feed the metrics. If the render thread misses a tick, the sink re-schedules the previous frame so the card never starves. Interlaced modes weave on the GPU: the encode pass takes two consecutive stack frames and writes a single frame whose first field is the first tick's even lines and second field the next tick's odd lines, top field first as 1080i SDI expects. Key and fill use two outputs: fill carries the premultiplied RGB (shaped key, the default; a per-output switch produces straight, unshaped fill for switchers that want it), key carries alpha as 10-bit luma. Embedded audio is enabled on the same output at 48 kHz, 24-bit in 32-bit words, scheduled against the same stream time as the video. Reference lock status is read from the card and reported; when a reference is present the card's clock is the engine's master (section 2).

**NDI sink** (v1.5). The encode pass writes BGRA with alpha (or 16-bit `PA16` when the receiver supports it) into a shared buffer ring; the readback thread hands completed buffers to the NDI SDK's asynchronous send at the stack's frame rate, with the SDK's own clock disabled so the engine's tick governs.

**Multiviewer and preview.** Aux passes downscale the stack textures into small BGRA8 sRGB textures at most 30 times a second, backed by IOSurfaces. Because the operator app is a separate process, those IOSurfaces are shared with it over a local Mach connection alongside the API: zero-copy, no encoding, no network. Remote API clients instead receive JPEG snapshots at a low rate over WebSocket when they subscribe to `preview`.

**Thumbnails.** The thumbnail job renders a cue's projected state (Spec 3) on the thumbnail stack at 480 px wide, on the background queue, using the normal stack pass against poster frames and rasterized text. Results are written as PNG into a disk cache keyed by (cue uuid, stack, library version) so thumbnails survive a relaunch; the UI reads them through the same IOSurface path or as files.

**Output transitions.** A stack switch mixes old and new stack textures over the output's switch transition; blackout mixes to black over the blackout transition; both happen in the encode pass so the stack passes stay unaware of them. Audio is unaffected by blackout, as the UX spec requires.

## 11. Audio

Audio never passes through a stack. Each channel's content may carry sound; the engine decodes it, applies the channel's gain and audio transition, and routes it to the numbered audio outputs the channel names. The audio device clock is the master for A/V sync.

**Decode.** The same `AVAssetReader` that demuxes video supplies the audio track as 48 kHz 32-bit float PCM (converted by AVFoundation if the file differs), decoded on the instance's decode thread into a lock-free ring of about 200 ms per instance. Audio-only media and audio sets use the same path without a video track.

**Mix graph per audio output device.** One Core Audio output unit (the HAL output `AudioUnit`) per distinct device, each with its own render callback on Core Audio's real-time thread. The callback pulls from every instance routed to that device, applies per-instance gain (the channel's tracked gain plus any override) with a 50 ms ramp on change, applies the running audio transition (crossfade or fade-through-silence between the outgoing and incoming instance of a channel, with its offset), sums, and writes to the device channels the Audio Output object maps. Dante Virtual Soundcard appears as an ordinary device here, as do aggregate devices; nothing is special-cased.

**The audio clock.** Each device callback publishes the sample position it has delivered and the host time it corresponds to. An instance's media time is derived from the samples of it that have reached the device, so the video pass picks frames against what the listener actually hears. Instances with no audio derive media time from the tick. When a channel is routed to more than one device, the first-numbered device is the clock and the others may drift by their own clock error; pre-flight notes multi-device routing for that reason.

**Sync offset.** A pool item's `syncOffsetMs` (or the write's override) delays audio when positive by holding samples in the ring, and delays video when negative by advancing the instance's media time reference, at the cost of latency, which the strip states as the UX spec requires.

**Output delay.** An Audio Output's `delayMs` (up to 1000 ms, for downstream video latency in LED processors or a broadcast chain) is a fixed delay line at the end of that device's mix, applied after the clock reading so sync is measured at the device, not after the delay.

**SDI embedded audio** is an Audio Output whose device is a DeckLink output. Its mix is produced by the same graph on a timer thread (there is no device callback) and scheduled against the DeckLink stream time as section 10 describes, so embedded audio and the picture share one clock.

**Transport.** `pause` stops consuming the ring and holds the media time; `stop` flushes the ring and resets to the in-point; `play` resumes. Looping audio uses the same two-reader hand-off as video so loops are gapless.

**Mute** of an audio output (`audio N mute`) zeroes that device's mix with a 20 ms ramp; blackout does not touch audio; `audio all mute` is one command over every device.

## 12. Failure modes and recovery

The rule for every failure is the same: the audience sees the last good frame, the operator sees a badge, the log sees the detail, and the engine recovers without anyone touching it. Nothing in this section may ever show black, a dialog or a crash on an output.

| Failure | Detection | Response |
| --- | --- | --- |
| Decoder error on a frame | VideoToolbox callback status | Skip the frame, repeat the previous, count it; after 10 consecutive errors, hold the last frame, mark the instance `missing`, log once |
| Decoder session dies | Session invalidation callback | Recreate on the decode thread from the current media time; frames repeat meanwhile |
| Frame not ready at tick | Queue empty at step 2 | Repeat the previous channel texture; count `videoRepeat` for that channel |
| GPU over budget | Tick's GPU time above budget | Skip aux passes next tick; if three consecutive ticks overrun, drop blur passes and mip generation until clear; log |
| Render thread misses a tick | Watchdog sees no plan consumed | Sinks present or re-schedule their last frame; count `tickMissed` |
| Control thread stalls | No new plan for two ticks | Render thread reuses the last plan with the frame counter advanced (video keeps playing); watchdog logs after 500 ms |
| Metal device lost or command buffer error | Command buffer completion status | Hold last frames on every sink from CPU copies kept for this purpose (one per output, refreshed once a second); rebuild pipelines and heaps; resume; log as a severe event |
| Display disconnected | Screen configuration notification | Pause that sink, keep its ring; resume at the configured mode when it returns |
| DeckLink card unplugged or mode unsupported | SDK notification or scheduling error | Pause that sink; if it was the master clock, fall back per section 2 within one second; resume when available |
| Audio device vanishes | Core Audio device notification | Switch to the Audio Output's configured fallback device if one is set; otherwise drop that output's audio (silence, with a badge) rather than guessing; return when the device reappears |
| Text raster fails (font missing, layout exception) | Raster job error | Draw with the fallback font; record the substitution for pre-flight |
| Media file disappears mid-play | Reader error | Hold the last frame; mark missing; the next write replaces it |

**Watchdog.** A utility thread checks every 250 ms that each active sink presented or scheduled within the last two frame intervals and that the render thread consumed a plan within the last tick; failures are logged with the state of every queue and ring at that moment, which is the information a Monday postmortem needs.

**Last-good-frame copies.** Each output keeps a CPU-side copy of a recent frame, refreshed about once a second by the readback thread when it has spare capacity. Three more conditions are handled the same way, detected elsewhere and never on the render thread: memory pressure (the system notification) shrinks the text and thumbnail caches and never touches decoder pools during playback; a full disk turns logging into an in-memory ring and raises a badge, with output unaffected; thermal throttling is logged from the process thermal state so a rising GPU time has an explanation, and changes nothing. It is the only CPU copy of output pixels in the normal path and it exists purely so a GPU reset has something to show.

**Never on the render thread:** any of the recovery actions above. The render thread detects and counts; the control and watchdog threads recover.

**Process boundary.** The engine is its own process; if it dies, the operator app shows the loss and relaunches it with `state/last.json` (when `restoreLastState` is on) or empty channels. Outputs go black only in this case, and the time from crash to first frame is itself a soak metric.

## 13. Measurement

Every tick writes one record into a preallocated ring; a utility thread drains the ring into the black box (JSON lines, rotated daily) and into a live summary the API exposes under the `metrics` topic. The soak rig reads the same files.

**Per tick:** frame number, master clock time, CPU encode time, GPU time from command-buffer timestamps (channel, stack and sink buffers separately), number of channel and stack passes, aux passes skipped, decoder queue depth per instance, `videoRepeat` per channel, `textLate` count, plan reused flag.

**Per output, per presented frame:** presented or re-presented, present latency (tick to vsync or to scheduled slot), DeckLink completion result, drop count since start.

**Per minute:** memory in use (heaps, decoder pools, caches), decoder sessions alive, cache hit rates, audio underruns per device, watchdog events.

**Soak thresholds** (a build fails on any): zero `dropped` or `displayedLate` on SDI over the run; display re-presents at or below the expected drift rate for unlocked vsync (about one per five minutes per display); p99 GPU time under 50% of the tick; zero `textLate` after the first minute; zero audio underruns; memory flat to within 5% after the first ten minutes; zero watchdog recoveries.

**The soak scenario** is a fixture playlist that exercises the paths that fail in practice: back-to-back 4K video dissolves (two decoders), a long loop, trims with in-points mid-GOP, lyric changes every few seconds, a timer box, a stack switch and a blackout every ten minutes, and a grade animation, running for three hours on the test bench with capture of every output. The first version of this scenario is the spike's acceptance test and it grows with each area that ships.

**Privacy.** Logs rotate daily and are capped by total size, oldest first. Metrics contain numbers and ids, never text content or file names beyond hashes, so logs can be shared for debugging without exposing a service's content.

## 14. Module shape and seams

`OEngine` is the second Swift package target, depending on `OCore` and on Apple frameworks (Metal, VideoToolbox, AVFoundation for demux and audio decode, CoreAudio, CoreText, CoreGraphics, the DeckLink SDK through a C module). It runs as its own process and talks to the operator app only through the Spec 2 API plus shared IOSurfaces for previews.

The seams below are protocols with exactly one v1 implementation each. They are not abstraction for its own sake; each is the line along which something already planned will arrive, and keeping it a protocol now costs a few lines.

| Seam | v1 implementation | What arrives through it later |
| --- | --- | --- |
| `RenderBackend` | Metal | A Direct3D 12 backend (Windows), behind the same pass descriptions |
| `ContentSource` | Video file, still, empty | Live inputs, Hap, designed slides, audio sets |
| `Demuxer` | AVAssetReader passthrough | FFmpeg's libavformat for exotic containers |
| `OutputSink` | Display, DeckLink | NDI, a virtual output for recording or streaming |
| `TransitionShader` | cut, dissolve, fadeThroughColor | Custom shader transitions with parameter blocks (v2) |
| `TextRenderer` | Per-line Core Graphics raster | Glyph atlas or SDF glyphs from the same Core Text layout |
| `MasterClock` | DeckLink hardware clock, CADisplayLink | LTC, MTC and Art-Net timecode as clocks (v2) |
| `Encoder` (sink encode pass) | 10-bit display, v210 with weave | BGRA and PA16 for NDI, 8-bit with dither for previews |

**What is not a seam.** The frame plan, the tick order, the colour pipeline and the resource rules are fixed. A future backend reproduces them; it does not get to reinterpret them.

**Boundaries with OCore.** OEngine imports ShowState, Command and Effect and never defines its own notion of state. The control thread's frame-plan builder is the only code that reads both ShowState and the library, and it lives in OEngine. OCore never imports OEngine.

**Rules for the agent writing it.** Every seam gets a protocol in its own file with a doc comment naming this section. No singleton device or queue; the engine is constructed with its backend, its clock and its sinks injected, so tests can run it headless with a software clock and a texture-capturing sink. Shaders live in one `.metal` file per pass with function constants for variants, never string-assembled at runtime. Objective-C++ is confined to the DeckLink module.

## 15. The engine spike

The spike is the smallest build that exercises every guarantee in section 1 on real hardware, and nothing else. No UI, no library editing, no playlists: a headless `OEngine` process driven over OSC, with the fixture library from Spec 1 on disk.

**It builds:** the master tick with the DeckLink clock and the CADisplayLink fallback; the frame plan builder over OCore's projection; one video `ContentSource` with the frame queue, trims, loops and the two-decoder transition path; the still source; the channel pass with grade and the three transitions; the per-line text rasterizer with its cache; the stack pass with pixel, field and static boxes, fit modes and the +1 offset slot; the display sink at 10-bit; the DeckLink sink with v210, scheduled playback and embedded audio (the interlace weave is the first addition after the spike); the audio mix graph for one device; the metrics ring, black box and watchdog; and the headless test harness with a software clock and a capturing sink.

**Configuration:** the first-run defaults from the UX spec. Channel 1 background, channel 2 foreground. Stack 1 at 4096×2160 on the LED-wall output (DeckLink if the test bench has 12G, otherwise the display). Stack 2, the confidence stack, at 1920×1080 on a display: plain-text stack default preset, channel 2 at offset 0 and +1, a static `[Time]` box. A fixture list of public-domain hymn lyrics over ProRes and HEVC backgrounds with trims and one loop.

**Driven by** the Spec 2 vocabulary over OSC from a script: writes with dissolves, video-to-video dissolves, text changes every few seconds, a grade animated over two seconds, a stack switch and a blackout every ten minutes, `next` through the fixture list with the confidence stack showing the next lyric, for three hours.

**Pass criteria, all of them:**

- Three hours on the test bench with capture of both outputs.
- Zero `dropped` and zero `displayedLate` on the DeckLink output; display re-presents at or below the unlocked-vsync drift rate.
- p99 GPU time under 8 ms at 60 Hz; CPU encode under 2 ms.
- Zero `textLate` after the first minute; zero audio underruns; zero watchdog recoveries.
- Memory flat within 5% after the first ten minutes.
- The confidence stack's +1 slot is correct on every `next`, checked by the capture against the projected state.
- A/V sync within one frame on a clapper fixture, measured on the capture.
- The DeckLink output is frame-accurate against the capture; the 1080i weave, added right after the spike, is verified field-correct on a motion fixture the same way.
- The headless harness reproduces a tick from a saved frame plan and matches the golden images.

Until every line above is green, no UI work starts. If one cannot be made green on this hardware, that is the moment to revisit the architecture, before anything is built on top of it.

## 16. Tests, forward hooks and open questions

**Tests this spec implies**

- **Golden images.** A saved frame plan over fixture content renders in the headless harness to textures that match stored PNGs within a tolerance, for: each transition type at 0, 0.5 and 1; each fit mode; each grade parameter at two values; a text box under both fit policies; the gamma-blend switch; the 1080i weave; key and fill.
- **Colour.** Known pixel values (video range black and white, 50% grey, saturated primaries) through each source layout come out at the expected linear values, and back through each sink encode to the expected code values, 10-bit and 8-bit with dither.
- **Pacing.** With a software clock, a 60 Hz tick driving a 30 fps and an interlaced output renders exactly the expected passes per tick, reuses the plan on a simulated control stall, and skips aux passes under simulated GPU pressure.
- **Frame selection.** A scripted queue with jittered presentation times yields the right frame per tick and counts repeats correctly; a loop with a pre-rolled second reader shows no gap.
- **Decoder budget.** A two-decoder channel stepping on itself produces the Spec 3 `steppedOn` and cuts the right instance.
- **Audio.** The mix graph with a software device produces sample-exact crossfades and ramps; the clock reading drives frame selection within one frame of the expected media time; the output delay line delays exactly `delayMs`.
- **Recovery.** Each row of section 12 is simulated in the harness and produces the documented response and log line.
- **Allocation.** A soak scenario under a counting allocator shows zero allocations on the render thread after warm-up.
- **The spike** (section 15) on hardware.

**Forward hooks already in place:** `ContentSource` for live inputs, Hap, slides and audio sets; `TransitionShader` for custom transitions; `TextRenderer` plus the stored glyph runs for per-glyph animation; the reserved mask slot in the box shader; `RenderBackend` for Windows; `MasterClock` for timecode; `Encoder` for NDI; the metrics `metrics` topic for a dashboard.

**Deliberately not planned:** HDR output, multiple GPUs, rendering channels at more than one resolution at once, and any rendering in the operator app's process.

**Resolved questions**

- **Transfer function:** the sRGB curve for every source, for consistency; a BT.1886 option for video can come later as a per-machine switch.
- **Fill and key:** premultiplied (shaped) fill is the default; the per-output switch to straight (unshaped) fill stays for other users' switchers.
- **Interlaced sides:** 1080i60 is required, since gear further down some chains is limited to it, but the weave is not part of the spike; it is the first thing built after the spike passes, verified on the same capture rig.
- **Preview sharing:** the operator app and the engine always run on the same machine, so previews travel as IOSurfaces over a local Mach connection; anything remote goes through OSC or the API.
