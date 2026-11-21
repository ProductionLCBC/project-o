// OEngine — Spec 11 §3, the `render` query's pictures, drawn by the
// thumbnail job with the thumbnail job's code.

import Foundation
import OCore

extension ThumbnailService {
    /// The channel number of the grade picture's one channel pass: no live
    /// channel has it, so a blur's scratch pair is the picture's own.
    static let offlineChannel = -1
    /// How many sizes' textures are kept for the next picture of that size.
    static let canvasSizesKept = 4

    /// Spec 11 §3 — "`render` draws a picture for an editor's canvas", "so
    /// that what an editor shows is what the engine draws". One request, on
    /// the job's queue: the stack pass the thumbnail job makes, for the
    /// subject and at the width asked for, read back and made a PNG.
    ///
    /// "Size. `width` is 160 to 1920 pixels. The height follows the stack's
    /// size, or the item's for a grade. A stack's size is ... the size its
    /// stack pass and preview use at that moment ..., so a picture's shape is
    /// the screen's": the sizes are the ones the request was read against.
    func draw(_ job: RenderQueue.Job) -> Swift.Result<RenderDrawn, Rejection> {
        let roots = (library: job.library, machine: job.machine)
        let width = job.request.width
        switch job.request.subject {
        case .cue(let list, let index, let stack):
            // "The cue's projected state on that stack, Spec 3 §7's cue view, as the thumbnail job draws it (Spec 4 §10)".
            let size = ThumbnailService.pictureSize(width: width, of: job.geometry.stackSize(stack.number))
            return picture(size) { textures in
                let states = projectedStates(of: list, through: index + furthestOffset(of: stack, library: roots.library), roots: roots)
                guard index < states.count else { return nil }
                let pass = stackPass(states: states, index: index, roots: roots, list: list, stack: stack, size: size, target: textures.stack)
                var drawn = RenderDrawn(png: Data(), size: size)
                drawn.missing = ThumbnailService.namesMissingMedia(states[index...], channels: stack.effectiveSlots(library: roots.library).map(\.channel))
                return (pass, drawn)
            }
        case .layout(let preset, let key, let stack, let sample):
            let size = ThumbnailService.pictureSize(width: width, of: job.geometry.stackSize(stack.number))
            return picture(size) { textures in
                layoutPass(preset: preset, layout: key, stack: stack, sample: sample, roots: roots, size: size, target: textures.stack)
            }
        case .grade(let grade, let id):
            guard let resolved = MediaResolver.resolve(id, library: roots.library, machine: roots.machine) else {
                return .failure(Rejection(reason: .unknownObject, message: "\(id) isn't in either media index"))
            }
            // "The height follows ... the item's for a grade."
            let item = PixelSize(width: max(1, resolved.entry.width ?? 16), height: max(1, resolved.entry.height ?? 9))
            let size = ThumbnailService.pictureSize(width: width, of: item)
            return picture(size) { textures in
                gradePass(grade, of: resolved, geometry: job.geometry, size: size, target: textures.stack)
            }
        }
    }

    /// Whether any of these states holds media whose file is missing on one of `channels`.
    static func namesMissingMedia(_ states: ArraySlice<ShowState>, channels: [Int]) -> Bool {
        states.contains { state in channels.contains { state.channels[$0]?.content.media?.missing == true } }
    }

    // MARK: - One picture

    /// A stack texture and a picture texture of `size`, kept for the next
    /// picture of that size; a drag on a canvas asks for one size again and
    /// again. The least recently used size goes past four.
    private func canvas(_ size: PixelSize) -> (stack: TextureHandle, picture: TextureHandle)? {
        canvasClock += 1
        if let found = canvasTextures[size] {
            canvasTextures[size]?.used = canvasClock
            return (found.stack, found.picture)
        }
        let stack = backend.makeTexture(TextureDescriptor(role: .stack, size: size, label: "render stack"))
        let picture = backend.makeTexture(TextureDescriptor(role: .thumbnail, size: size, label: "render picture"))
        guard !stack.isNone, !picture.isNone else {
            for handle in [stack, picture] { backend.resources.release(handle) }
            return nil
        }
        canvasTextures[size] = (stack, picture, canvasClock)
        while canvasTextures.count > ThumbnailService.canvasSizesKept, let oldest = canvasTextures.min(by: { $0.value.used < $1.value.used }) {
            canvasTextures[oldest.key] = nil
            backend.resources.release(oldest.value.stack)
            backend.resources.release(oldest.value.picture)
        }
        return (stack, picture)
    }

    /// Draws the pass `build` makes into a picture of `size` and reads it
    /// back as a PNG. Nothing is evicted from the text cache meanwhile, so a
    /// raster made for a later box can't push out an earlier box's lines.
    private func picture(_ size: PixelSize,
                         _ build: ((stack: TextureHandle, picture: TextureHandle)) -> (StackPass, RenderDrawn)?) -> Swift.Result<RenderDrawn, Rejection> {
        guard let textures = canvas(size) else {
            return .failure(Rejection(reason: .conflict, message: "no texture could be made for a picture of \(size.width) by \(size.height)"))
        }
        return textCache.withoutEviction {
            guard let (pass, report) = build(textures) else {
                return .failure(Rejection(reason: .conflict, message: "the picture could not be drawn"))
            }
            guard backend.renderOffline(pass, into: textures.picture) else {
                return .failure(Rejection(reason: .conflict, message: "the GPU did not finish the picture in time"))
            }
            guard let read = backend.readbackBGRA8(textures.picture),
                  let png = try? ThumbnailCache.png(bgra8: read.bytes, width: read.width, height: read.height) else {
                return .failure(Rejection(reason: .conflict, message: "the picture could not be read back"))
            }
            var drawn = report
            drawn.png = png
            drawn.size = PixelSize(width: read.width, height: read.height)
            return .success(drawn)
        }
    }

    // MARK: - A layout with a sample

    /// Spec 11 §3 — "The layout with the sample standing in for the slot's
    /// channel (below): a stack's own layout at that stack's size and number,
    /// the `*` layout at the size and number of the stack `stack` names".
    ///
    /// One slot of that stack, on the library's first channel, drawing the
    /// preset with only the layout asked for. The sample is written to that
    /// channel by the projection itself, so its content is what a write of it
    /// would hold: "Field boxes draw the text's fields, falling back to that
    /// list's metadata (Spec 6 §3); pixel boxes draw the media as its poster
    /// or still; static boxes draw their text, their context values reading
    /// that cue (Spec 6 §5); fallback boxes follow the content's kind as on
    /// air (Spec 4 §9). Without `listUuid` and `cue`, metadata and context
    /// values draw nothing." `next` is what the boxes at +1 to +3 draw; a box
    /// further ahead than `next` reaches draws nothing, as past a list's end.
    private func layoutPass(preset: Preset, layout key: LayoutKey, stack: Stack, sample: RenderSample, roots: (library: Library, machine: Machine),
                            size: PixelSize, target: TextureHandle) -> (StackPass, RenderDrawn)? {
        guard let layout = preset.layouts[key] else { return nil }
        // The preset as this picture draws it: the one layout, found whichever stack it is drawn for.
        var drawnPreset = preset
        drawnPreset.layouts = [key: layout]
        var library = roots.library
        library.presets = library.presets.map { $0.number == preset.number ? drawnPreset : $0 }
        let channel = library.channels.map(\.number).min() ?? 1
        let slot = StackSlot(channel: channel, preset: preset.number)
        var drawnStack = stack
        drawnStack.slots = [slot]

        // The sample's contents, written one after another as cues would write them.
        let variables = self.variables
        let missing = missingNow
        let source = sample.list.flatMap { list in sample.cue.map { CommandSource(kind: .cue, list: list.uuid, cue: $0) } } ?? CommandSource(kind: .ui)
        let kept = sample.list.map { KeptCopies(list: $0) } ?? KeptCopies()
        var states: [ShowState] = []
        var state = ShowState.fresh(library: library, machine: roots.machine)
        for content in [sample.content] + sample.next {
            let before = state
            let context = ProjectionContext(frame: 0, library: library, machine: roots.machine, missing: missing, source: source,
                                            variables: { name in variables.value(name, state: before) }, kept: kept)
            let command: Command = content == .empty ? .channelClear(channel: .number(channel))
                : .channelWrite(ChannelWrite(channel: .number(channel), content: content))
            state = project(before, [command], context: context).0
            var drawn = state
            // Where the sample came from: the list its metadata falls back to, and the cue its context values read.
            drawn.pointer = sample.list.map { LivePointer(listUuid: $0.uuid, cueUuid: sample.cue) }
            states.append(drawn)
        }

        let inputs = SlotResolver.Inputs(library: library, machine: roots.machine, kept: kept, stack: drawnStack, size: size, muted: [],
                                         text: EagerTextProvider(cache: textCache))
        let variableRoots = VariableRoots(library: library, machine: roots.machine, kept: kept)
        let clock = variables.publishedClock()
        var tabular: [Int: Bool] = [:]
        let results = SlotResolver.resolve(inputs, slot: slot,
                                           state: { offset in offset >= 0 && offset < states.count ? states[offset] : nil },
                                           pixels: { _, _, content in self.posterSource(for: content, roots: (library, roots.machine)) },
                                           text: { key, _, template, shown in
                                               let resolved = variables.resolve(template.raw, state: shown, scope: template.scope, roots: variableRoots, clock: clock)
                                               tabular[key.box] = resolved.tabular
                                               return SlotResolver.BoxText(text: resolved.text, tabular: resolved.tabular)
                                           },
                                           onTextMiss: { _ in })

        // "What it reports. For a layout, `overflow` lists each text box whose sample text overflows (Spec 6 §4) ...
        // and `fallbackFonts` each box whose font fell back to `fallbackFont`, with the font's name. Boxes are
        // numbered by their place in the layout, from 0."
        var drawn = RenderDrawn(png: Data(), size: size)
        for result in results {
            guard let box = result.resolved, box.binding.isText, let text = box.text else { continue }
            let job = SlotResolver.textJob(text, box: result.box, frame: PixelRect(result.box.frame, in: size), outputHeight: size.height,
                                           tabular: tabular[result.key.box] ?? false)
            if let laid = textCache.layout(for: job.key), laid.overflowed {
                drawn.overflow.append(.object(["box": .number(Double(result.key.box)), "offset": .number(Double(result.box.offset)),
                                               "linesCut": .number(Double(laid.linesCut))]))
            }
            if textCache.substitutedFont(for: job.key) != nil {
                drawn.fallbackFonts.append(.object(["box": .number(Double(result.key.box)), "font": .string(job.style.values.font)]))
            }
        }
        drawn.missing = ThumbnailService.namesMissingMedia(states[...], channels: [channel])
        let pass = StackPass(stack: stack.number, target: target, size: size, base: stack.base, gammaBlend: stack.gammaBlend,
                             boxes: results.compactMap(\.resolved))
        return (pass, drawn)
    }

    // MARK: - A media item through a grade

    /// Spec 11 §3 — "The item's poster or still through the grade, or as it
    /// is when `grade` is null, over black": one channel pass, the poster as
    /// its source and the grade as the channel's, into a texture of the
    /// picture's size, then that texture over black. A blur is in pixels of
    /// the channel that would play the item, so it is scaled to the picture:
    /// by the item's default channel's width, or 1920 when it has none.
    /// "a media item whose file is missing draws nothing ..., and the answer
    /// says `missing: true`."
    private func gradePass(_ grade: Grade?, of resolved: MediaResolution, geometry: MachineGeometry, size: PixelSize,
                           target: TextureHandle) -> (StackPass, RenderDrawn)? {
        var drawn = RenderDrawn(png: Data(), size: size)
        let black = StackPass(stack: 0, target: target, size: size, base: .black, gammaBlend: false, boxes: [])
        guard !missingNow.contains(resolved.entry.id) else {
            drawn.missing = true
            return (black, drawn)
        }
        guard let key = PosterKey.of(resolved) else { return (black, drawn) }
        let poster = posters.load(key)
        guard !poster.isNone else { return (black, drawn) }

        if gradeTexture?.size != size {
            if let old = gradeTexture { backend.resources.release(old.texture) }
            gradeTexture = nil
            let made = backend.makeTexture(TextureDescriptor(role: .channel, size: size, label: "render grade"))
            guard !made.isNone else { return nil }
            gradeTexture = (size, made)
        }
        guard let channel = gradeTexture?.texture else { return nil }

        var parameters = grade.map(GradeParameters.init) ?? .identity
        let reference = resolved.entry.defaults.defaultChannel.map { geometry.channelSize($0).width } ?? 1920
        parameters.blur *= Float(size.width) / Float(max(1, reference))
        let posterSize = backend.resources.descriptor(poster)?.size ?? size
        let pass = ChannelPass(channel: ThumbnailService.offlineChannel, target: channel, size: size,
                               incoming: SourceBinding(source: .texture(poster), layout: .bgra8sRGB, matrix: .bt709, range: .full, size: posterSize),
                               grade: parameters)
        guard backend.renderOfflineChannel(pass) else { return nil }
        let full = PixelRect(x: 0, y: 0, width: Float(size.width), height: Float(size.height))
        let box = ResolvedBox(channel: 0, frame: full, content: .pixels(PixelQuad(texture: channel, frame: full, uv: .full)), opacity: 1)
        return (StackPass(stack: 0, target: target, size: size, base: .black, gammaBlend: false, boxes: [box]), drawn)
    }
}
