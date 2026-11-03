// OEngine — Spec 4 §9, resolving a slot: the one implementation the live plan
// builder (ControlLoop) and the thumbnail job (ThumbnailService, Spec 4 §10)
// share, so a thumbnail is "the normal stack pass against poster frames and
// rasterized text".

import Foundation
import OCore

/// Spec 4 §9 — "Resolving a slot happens on the control thread when the frame
/// plan is built: the preset is the slot's, else the stack default, else the
/// channel default, else Preset 1; the layout is the preset's entry for this
/// stack number, else its `"*"` layout. Each box is then bound to a concrete
/// source." The binding table of §9: pixels to the channel texture or a
/// poster, field to the cached line textures, static to the cached textures
/// of the box's own text with variables resolved; "Fallback boxes draw only
/// if no earlier box in the same channel's group drew anything"; "A slot's
/// effective opacity is its opacity times zero when muted".
public enum SlotResolver {
    /// Spec 4 §9 — what a pixel box draws: a texture and the part of it the
    /// content occupies (Spec 4 §7, letterboxed), with the content's pixel
    /// size for the fit modes and whether a mip chain exists this tick.
    public struct PixelSource: Equatable, Sendable {
        public var texture: TextureHandle
        public var content: UVRect
        public var contentPixels: PixelSize
        public var mips: Bool

        public init(texture: TextureHandle, content: UVRect, contentPixels: PixelSize, mips: Bool = false) {
            self.texture = texture
            self.content = content
            self.contentPixels = contentPixels
            self.mips = mips
        }
    }

    /// One box of a slot's layout, resolved or not, with what the caller
    /// needs to carry its transition: the key it is tracked by, the box, and
    /// whether a change may transition (Spec 4 §8, `transitionOnVariableChange`).
    public struct SlotBox: Sendable {
        public var key: BoxKey
        public var box: Box
        public var resolved: ResolvedBox?
        public var transitionAllowed: Bool
    }

    /// What every slot of one stack pass shares.
    public struct Inputs {
        public var library: Library
        public var stack: Stack
        public var size: PixelSize
        /// Spec 4 §9 — the channels muted on this stack.
        public var muted: Set<Int>
        public var text: any TextProvider

        public init(library: Library, stack: Stack, size: PixelSize, muted: Set<Int>, text: any TextProvider) {
            self.library = library
            self.stack = stack
            self.size = size
            self.muted = muted
            self.text = text
        }

        /// Spec 4 §9 — "the preset is the slot's, else the stack default, else
        /// the channel default, else Preset 1".
        public func preset(for slot: StackSlot) -> Preset {
            library.resolvedPreset(slot.preset ?? stack.defaultPreset ?? library.channel(slot.channel)?.defaultPreset)
        }
    }

    /// Resolve one slot's boxes in layout order. `content` is what the slot
    /// shows (the live state at offset 0, the lookahead for offsets, a
    /// projected state for a thumbnail); `pixels` is what a pixel box draws
    /// for that content; `staticText` resolves a static box's variables (the
    /// control loop gates it, Spec 4 §8); `onTextMiss` hears of every text
    /// job the cache could not answer ("counts `textLate`").
    public static func resolve(_ inputs: Inputs, slotIndex: Int, slot: StackSlot, content: ContentInstance?,
                               pixels: (StackSlot, ContentInstance?) -> PixelSource?,
                               staticText: (BoxKey, Box, String) -> String,
                               onTextMiss: (TextJob) -> Void) -> [SlotBox] {
        guard let layout = inputs.preset(for: slot).layout(for: inputs.stack.number) else { return [] }
        let opacity = Float(slot.opacity) * (inputs.muted.contains(slot.channel) ? 0 : 1)
        var out: [SlotBox] = []
        var drew = false
        for (boxIndex, box) in layout.boxes.enumerated() {
            let key = BoxKey(stack: inputs.stack.number, slot: slotIndex, box: boxIndex)
            let allowed = transitionAllowed(for: box)
            if box.fallback && drew {
                out.append(SlotBox(key: key, box: box, resolved: nil, transitionAllowed: allowed))
                continue
            }
            let frameRect = PixelRect(box.frame, in: inputs.size)
            var resolved: ResolvedBox?
            switch box.binding.kind {
            case .pixels:
                if let source = pixels(slot, content) {
                    let fit = box.fit.pixelFit ?? .fit
                    let quad = ControlLoop.fitQuad(texture: source.texture, content: source.content, contentPixels: source.contentPixels,
                                                   into: frameRect, fit: fit, mips: source.mips)
                    resolved = ResolvedBox(channel: slot.channel, frame: frameRect, content: .pixels(quad), opacity: opacity,
                                           grade: boxGrade(box, library: inputs.library), offset: slot.offset, binding: box.binding)
                }
            case .field(let name):
                if case .text(let t)? = content, let value = t.fields[name], !value.isEmpty {
                    resolved = textBox(value, box: box, frame: frameRect, inputs: inputs, slot: slot, opacity: opacity, onTextMiss: onTextMiss)
                }
            case .static(let raw):
                let value = staticText(key, box, raw)
                if !value.isEmpty {
                    resolved = textBox(value, box: box, frame: frameRect, inputs: inputs, slot: slot, opacity: opacity, onTextMiss: onTextMiss)
                }
            }
            if resolved != nil { drew = true }
            out.append(SlotBox(key: key, box: box, resolved: resolved, transitionAllowed: allowed))
        }
        return out
    }

    /// Spec 4 §8 — "Boxes with `transitionOnVariableChange` run their box
    /// transition between the old and new textures; the rest swap." A box
    /// without variables always transitions.
    public static func transitionAllowed(for box: Box) -> Bool {
        guard case .static(let raw) = box.binding.kind, VariableProvider.containsVariables(raw) else { return true }
        return box.transitionOnVariableChange
    }

    /// Spec 4 §9 — "Per-box grade ... is identity for most boxes, in which
    /// case the shader variant without it is used."
    static func boxGrade(_ box: Box, library: Library) -> GradeParameters? {
        guard let ref = box.grade, ref != 0, let grade = library.grade(ref) else { return nil }
        let parameters = GradeParameters(grade)
        return parameters.isIdentity ? nil : parameters
    }

    /// Spec 4 §8 — the job for one box's text: its key, the style, the box's
    /// pixel size, the fit policy and the output height the sizes scale with.
    public static func textJob(_ value: String, box: Box, frame: PixelRect, outputHeight: Int) -> TextJob {
        let style = box.textStyle ?? BoxTextStyle()
        let fit = box.fit.textFit ?? TextFit()
        let boxSize = PixelSize(width: Int(frame.width.rounded()), height: Int(frame.height.rounded()))
        return TextJob(key: TextKey.make(text: value, style: style, box: boxSize, fit: fit, outputHeight: outputHeight),
                       text: value, style: style, box: boxSize, fit: fit, outputHeight: outputHeight)
    }

    /// Spec 4 §9 — "field: The cached line textures ... a missing cache entry
    /// draws nothing this tick and counts `textLate`".
    static func textBox(_ value: String, box: Box, frame: PixelRect, inputs: Inputs, slot: StackSlot, opacity: Float,
                        onTextMiss: (TextJob) -> Void) -> ResolvedBox {
        let job = textJob(value, box: box, frame: frame, outputHeight: inputs.size.height)
        var lines: [TextLine] = []
        if let entry = inputs.text.entry(for: job) {
            lines = entry.lines.map { line in
                TextLine(texture: line.texture, frame: PixelRect(x: frame.x + line.frame.x, y: frame.y + line.frame.y,
                                                                 width: line.frame.width, height: line.frame.height))
            }
        } else {
            inputs.text.request(job)
            onTextMiss(job)
        }
        return ResolvedBox(channel: slot.channel, frame: frame, content: .lines(lines), opacity: opacity, grade: boxGrade(box, library: inputs.library),
                           offset: slot.offset, binding: box.binding, text: value)
    }
}
