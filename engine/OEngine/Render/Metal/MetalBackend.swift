// OEngine — Spec 4 §14, the `RenderBackend` seam's v1 implementation: Metal.

import Foundation
import Metal
import simd

public enum MetalBackendError: Error, Equatable {
    case noDevice
    case noCommandQueue
    case noShaderLibrary(String)
}

/// Spec 4 §4 step 3 — "Encode all channel passes into one command buffer;
/// encode all stack passes into a second; encode sink encodes into a third;
/// commit all three with GPU timestamps enabled." Spec 4 §5 — resources are
/// allocated on the control side, before use. Spec 4 §3 — on the render
/// thread the backend allocates nothing of its own, takes no lock and waits
/// for nothing: pipelines and textures are array reads, uniforms travel by
/// `setBytes`, and completion is polled from the command buffers' status.
public final class MetalBackend: RenderBackend, @unchecked Sendable {
    public let name = "metal"
    public let device: MTLDevice
    let queue: MTLCommandQueue
    let library: MTLLibrary
    public let resources = ResourceTable(capacity: 4096)
    let pipelines: PipelineCache
    let log: EngineLog
    private let receipts: ReceiptRing
    private var nextToken: Int64 = 1
    private let blurScratch = BlurScratch()
    private let whiteMask: MTLTexture?
    /// Spec 4 §5 — a box samples a mip chain only on ticks it was generated.
    private let samplerWithMips: MTLSamplerState?
    private let samplerLevelZero: MTLSamplerState?
    let v210Rings = V210Rings()
    let lastGood = LastGoodFrames()
    public private(set) var missingPipelineCount = 0
    public private(set) var snapshotCount = 0
    public internal(set) var rebuildCount = 0

    /// Whether a Metal device exists on this machine.
    public static var isAvailable: Bool { MTLCreateSystemDefaultDevice() != nil }

    public init(device: MTLDevice? = MTLCreateSystemDefaultDevice(), log: EngineLog = EngineLog(category: "metal")) throws {
        guard let device else { throw MetalBackendError.noDevice }
        guard let queue = device.makeCommandQueue() else { throw MetalBackendError.noCommandQueue }
        self.device = device
        self.queue = queue
        self.log = log
        // Spec 4 §14 — the shaders compiled by the MetalCompiler plugin into the module's bundle.
        guard let url = Bundle.module.url(forResource: "default", withExtension: "metallib") else {
            throw MetalBackendError.noShaderLibrary("default.metallib is not in the resource bundle")
        }
        do {
            library = try device.makeLibrary(URL: url)
        } catch {
            throw MetalBackendError.noShaderLibrary("\(error)")
        }
        pipelines = PipelineCache(device: device, library: library)
        receipts = ReceiptRing()
        let maskDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: 1, height: 1, mipmapped: false)
        maskDescriptor.usage = .shaderRead
        whiteMask = device.makeTexture(descriptor: maskDescriptor)
        var white: UInt8 = 255
        whiteMask?.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &white, bytesPerRow: 1)
        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.minFilter = .linear
        samplerDescriptor.magFilter = .linear
        samplerDescriptor.sAddressMode = .clampToEdge
        samplerDescriptor.tAddressMode = .clampToEdge
        samplerDescriptor.normalizedCoordinates = true
        samplerDescriptor.mipFilter = .linear
        samplerWithMips = device.makeSamplerState(descriptor: samplerDescriptor)
        samplerDescriptor.mipFilter = .notMipmapped
        samplerLevelZero = device.makeSamplerState(descriptor: samplerDescriptor)
        try pipelines.ensureBlur()
        queue.label = "o.engine.render"
    }

    // MARK: - Resources (Spec 4 §5)

    public func makeTexture(_ descriptor: TextureDescriptor) -> TextureHandle {
        guard let texture = device.makeTexture(descriptor: MetalBackend.metalDescriptor(for: descriptor)) else {
            log.error("could not allocate \(descriptor.role.rawValue) texture \(descriptor.size.width)x\(descriptor.size.height)")
            return .none
        }
        texture.label = descriptor.label
        return resources.allocate(texture, descriptor: descriptor)
    }

    static func metalDescriptor(for descriptor: TextureDescriptor) -> MTLTextureDescriptor {
        let d = MTLTextureDescriptor()
        d.textureType = .type2D
        d.width = max(1, descriptor.size.width)
        d.height = max(1, descriptor.size.height)
        switch descriptor.role {
        case .channel, .stack, .still, .blurScratch:
            d.pixelFormat = .rgba16Float
            d.storageMode = .private
            d.usage = [.renderTarget, .shaderRead]
        case .textLine, .poster:
            d.pixelFormat = .bgra8Unorm_srgb
            d.storageMode = .shared
            d.usage = [.shaderRead]
        case .preview:
            d.pixelFormat = .bgra8Unorm_srgb
            d.storageMode = .private
            d.usage = [.renderTarget, .shaderRead]
        }
        if descriptor.mipmapped {
            d.mipmapLevelCount = max(1, Int(floor(log2(Double(max(d.width, d.height))))) + 1)
        }
        return d
    }

    func texture(_ handle: TextureHandle) -> MTLTexture? {
        resources.object(handle) as? MTLTexture
    }

    // MARK: - Prepare (control side)

    /// Spec 4 §7 — every variant the plan needs exists before the render
    /// thread sees the plan; blur scratch textures exist for channels that blur.
    public func prepare(_ plan: FramePlan) {
        for pass in plan.channelPasses {
            do {
                try pipelines.ensureChannel(MetalBackend.variant(for: pass))
                if pass.grade.blur > 0 {
                    try pipelines.ensureChannel(ChannelVariant(incoming: pass.incoming.layout, outgoing: nil, transition: .cut, grade: false))
                    blurScratch.ensure(channel: pass.channel, size: pass.size, device: device)
                }
            } catch {
                log.error("pipeline for channel \(pass.channel): \(error)")
            }
        }
        for pass in plan.stackPasses {
            for box in pass.boxes {
                do { try pipelines.ensureBox(BoxVariant(grade: box.grade != nil, gammaBlend: pass.gammaBlend)) } catch { log.error("box pipeline: \(error)") }
            }
            if pass.gammaBlend {
                do { try pipelines.ensureLinearize() } catch { log.error("linearize pipeline: \(error)") }
            }
        }
        for pass in plan.sinkPasses {
            do { try pipelines.ensureEncode(pass.encode) } catch { log.error("encode pipeline \(pass.encode.rawValue): \(error)") }
        }
    }

    /// Spec 4 §7 — "compiled at launch into a small pipeline cache, so the
    /// per-tick work is a pipeline lookup": every channel variant the layouts
    /// can need (each as incoming, each pair as a dissolve or a fade, with and
    /// without a grade), the box variants, the linearize pass and the encodes.
    /// Returns how many pipelines exist afterwards.
    @discardableResult
    public func warmUp(layouts: [SourceLayout] = [.nv12, .p010, .yuv422p10, .rgba16, .linearRGBA16]) -> Int {
        var count = 0
        func ensure(_ variant: ChannelVariant) {
            do {
                try pipelines.ensureChannel(variant)
                count += 1
            } catch {
                log.error("warm-up: channel pipeline \(variant): \(error)")
            }
        }
        for grade in [false, true] {
            for incoming in layouts {
                ensure(ChannelVariant(incoming: incoming, outgoing: nil, transition: .cut, grade: grade))
                for outgoing in layouts {
                    for transition in [TransitionVariant.dissolve, .fadeThroughColor] {
                        ensure(ChannelVariant(incoming: incoming, outgoing: outgoing, transition: transition, grade: grade))
                    }
                }
            }
            for outgoing in layouts {
                for transition in [TransitionVariant.dissolve, .fadeThroughColor] {
                    ensure(ChannelVariant(incoming: nil, outgoing: outgoing, transition: transition, grade: grade))
                }
            }
            ensure(ChannelVariant(incoming: nil, outgoing: nil, transition: .cut, grade: grade))
        }
        for grade in [false, true] {
            for gammaBlend in [false, true] {
                do { try pipelines.ensureBox(BoxVariant(grade: grade, gammaBlend: gammaBlend)) } catch { log.error("warm-up: box pipeline: \(error)") }
            }
        }
        do { try pipelines.ensureLinearize() } catch { log.error("warm-up: linearize: \(error)") }
        for kind in [EncodeKind.display10Bit, .v210, .capture] {
            do { try pipelines.ensureEncode(kind) } catch { log.error("warm-up: encode \(kind.rawValue): \(error)") }
        }
        return count
    }

    static func variant(for pass: ChannelPass) -> ChannelVariant {
        let transition: TransitionVariant = pass.transition.map { BuiltInTransition($0.type).variant } ?? .cut
        let incoming: SourceLayout? = pass.grade.blur > 0 ? .linearRGBA16 : (pass.incoming.source == .none ? nil : pass.incoming.layout)
        let outgoing: SourceLayout? = transition == .cut ? nil : pass.outgoing.map { $0.source == .none ? nil : $0.layout } ?? nil
        var graded = pass.grade
        graded.blur = 0
        return ChannelVariant(incoming: incoming, outgoing: outgoing, transition: transition, grade: !graded.isIdentity)
    }

    // MARK: - Encode (render thread)

    public func encode(_ tick: TickTime, plan: FramePlan, picks: PickedFrames, options: EncodeOptions) -> EncodeReceipt {
        let token = nextToken
        nextToken += 1
        var slot = ReceiptSlot(token: token)

        if !plan.channelPasses.isEmpty, let buffer = queue.makeCommandBuffer() {
            buffer.label = "channels \(tick.tick)"
            for (index, pass) in plan.channelPasses.enumerated() where index * 2 + 1 < picks.capacity {
                encodeChannel(pass, picks: picks, index: index, into: buffer, options: options)
            }
            buffer.commit()
            slot.channel = buffer
        }
        if !plan.stackPasses.isEmpty, let buffer = queue.makeCommandBuffer() {
            buffer.label = "stacks \(tick.tick)"
            for pass in plan.stackPasses { encodeStack(pass, into: buffer) }
            buffer.commit()
            slot.stack = buffer
        }
        if !plan.sinkPasses.isEmpty || (!options.skipAux && !plan.auxPasses.isEmpty), let buffer = queue.makeCommandBuffer() {
            buffer.label = "sinks \(tick.tick)"
            for pass in plan.sinkPasses { encodeSink(pass, into: buffer) }
            if !options.skipAux {
                for pass in plan.auxPasses { encodeAux(pass, into: buffer) }
            }
            buffer.commit()
            slot.sink = buffer
        }
        receipts.store(slot)
        return EncodeReceipt(tick: tick.tick, token: token)
    }

    public func completion(of receipt: EncodeReceipt) -> GPUCompletion? {
        guard let slot = receipts.slot(for: receipt.token) else { return nil }
        var failed = false
        func timing(_ buffer: MTLCommandBuffer?) -> Int64? {
            guard let buffer else { return 0 }
            switch buffer.status {
            case .completed:
                return Int64(max(0, buffer.gpuEndTime - buffer.gpuStartTime) * 1_000_000_000)
            case .error:
                failed = true
                return 0
            default:
                return nil
            }
        }
        guard let channel = timing(slot.channel), let stack = timing(slot.stack), let sink = timing(slot.sink) else { return nil }
        return GPUCompletion(channelNs: channel, stackNs: stack, sinkNs: sink, failed: failed)
    }

    /// Harness: block until the tick's work is done. Never on the render thread.
    public func waitForCompletion(of receipt: EncodeReceipt) {
        guard let slot = receipts.slot(for: receipt.token) else { return }
        for command in [slot.channel, slot.stack, slot.sink].compactMap({ $0 }) {
            if !MetalBackend.waitBounded(command) { log.error("GPU work of tick \(receipt.tick) did not complete within the bound") }
        }
    }

    /// Harness and readback threads only, never the render thread: wait for a
    /// command buffer, bounded, so a GPU that never answers fails a test
    /// instead of hanging it. Polls the buffer's status.
    @discardableResult
    static func waitBounded(_ command: MTLCommandBuffer, seconds: Double = 30) -> Bool {
        let deadline = MonotonicClock.now().nanoseconds + Int64(seconds * 1_000_000_000)
        while command.status != .completed && command.status != .error {
            if MonotonicClock.now().nanoseconds > deadline { return false }
            usleep(200)
        }
        return command.status == .completed
    }

    // MARK: - The channel pass (Spec 4 §7)

    private struct BoundSource {
        var plane0: MTLTexture?
        var plane1: MTLTexture?
        var layout: SourceLayout
        var size: PixelSize
    }

    private func bind(_ binding: SourceBinding, pick: PickedFrame) -> BoundSource? {
        switch binding.source {
        case .none:
            return nil
        case .texture(let handle):
            guard let t = texture(handle) else { return nil }
            return BoundSource(plane0: t, plane1: nil, layout: binding.layout, size: PixelSize(width: t.width, height: t.height))
        case .instance:
            guard let plane0 = pick.plane0 as? MTLTexture else { return nil }
            return BoundSource(plane0: plane0, plane1: pick.plane1 as? MTLTexture, layout: pick.layout,
                               size: PixelSize(width: plane0.width, height: plane0.height))
        }
    }

    private func encodeChannel(_ pass: ChannelPass, picks: PickedFrames, index: Int, into buffer: MTLCommandBuffer, options: EncodeOptions) {
        guard let target = texture(pass.target) else { return }
        // Spec 4 §7 — an interrupted or restarted transition keeps the picture as it was: copy it first.
        if pass.snapshotOutgoing, let outgoing = pass.outgoing, case .texture(let handle) = outgoing.source, let snapshot = texture(handle),
           let blit = buffer.makeBlitCommandEncoder() {
            blit.copy(from: target, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                      sourceSize: MTLSize(width: target.width, height: target.height, depth: 1),
                      to: snapshot, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
            blit.endEncoding()
            snapshotCount += 1
        }
        var incoming = bind(pass.incoming, pick: picks[index * 2])
        let outgoing = pass.outgoing.flatMap { bind($0, pick: picks[index * 2 + 1]) }
        var incomingLayout = pass.incoming.layout
        var incomingRange = pass.incoming.range
        // Spec 4 §7 — blur: a separable two-pass Gaussian at half resolution before stage 2.
        if pass.grade.blur > 0, !options.dropExtras, let source = incoming, let scratch = blurScratch.textures(channel: pass.channel) {
            encodeBlur(source: source, binding: pass.incoming, radius: pass.grade.blur, scratch: scratch, into: buffer)
            incoming = BoundSource(plane0: scratch.a, plane1: nil, layout: .linearRGBA16, size: source.size)
            incomingLayout = .linearRGBA16
            incomingRange = .full
        }
        let transition: TransitionVariant = pass.transition.map { BuiltInTransition($0.type).variant } ?? .cut
        var graded = pass.grade
        graded.blur = 0
        let variant = ChannelVariant(incoming: incoming == nil ? nil : incomingLayout,
                                     outgoing: transition == .cut ? nil : outgoing.map(\.layout), transition: transition, grade: !graded.isIdentity)
        guard let pipeline = pipelines.channelPipeline(variant) else {
            missingPipelineCount += 1
            return
        }
        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = target
        descriptor.colorAttachments[0].loadAction = .clear
        descriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        descriptor.colorAttachments[0].storeAction = .store
        guard let encoder = buffer.makeRenderCommandEncoder(descriptor: descriptor) else { return }
        encoder.label = "channel \(pass.channel)"
        encoder.setRenderPipelineState(pipeline)
        var uniforms = ChannelUniforms()
        if let incoming {
            uniforms.incomingRect = MetalBackend.rect(ControlLoop.contentRect(source: incoming.size, channel: pass.size))
            uniforms.incomingRange = ColorMath.rangeExpansion(range: incomingRange, bits: ColorMath.bits(for: incomingLayout))
            uniforms.codeScales.x = ColorMath.codeScale(for: incomingLayout)
            uniforms.incomingMatrix = ColorMath.ycbcrToRGB(pass.incoming.matrix)
            uniforms.incomingPrimaries = ColorMath.primariesToRec709(pass.incoming.matrix)
            encoder.setFragmentTexture(incoming.plane0, index: 0)
            encoder.setFragmentTexture(incoming.plane1 ?? incoming.plane0, index: 1)
        }
        if let outgoing, let binding = pass.outgoing {
            uniforms.outgoingRect = MetalBackend.rect(ControlLoop.contentRect(source: outgoing.size, channel: pass.size))
            uniforms.outgoingRange = ColorMath.rangeExpansion(range: binding.range, bits: ColorMath.bits(for: outgoing.layout))
            uniforms.codeScales.y = ColorMath.codeScale(for: outgoing.layout)
            uniforms.outgoingMatrix = ColorMath.ycbcrToRGB(binding.matrix)
            uniforms.outgoingPrimaries = ColorMath.primariesToRec709(binding.matrix)
            encoder.setFragmentTexture(outgoing.plane0, index: 2)
            encoder.setFragmentTexture(outgoing.plane1 ?? outgoing.plane0, index: 3)
        }
        if let t = pass.transition {
            let parameters = BuiltInTransition(t.type).parameters(progress: t.progress, color: t.color)
            uniforms.transition.x = parameters.progress
            let c = parameters.color
            // Spec 1 §5 colours are sRGB; the fade colour is "opaque and premultiplied" in linear light.
            uniforms.color = SIMD4(ColorMath.srgbDecode(c.r), ColorMath.srgbDecode(c.g), ColorMath.srgbDecode(c.b), 1)
        }
        uniforms.setGrade(graded)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<ChannelUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        // Spec 4 §5 — mips only when a due stack samples below half scale, and not under pressure.
        if pass.generateMips, !options.dropExtras, target.mipmapLevelCount > 1, let blit = buffer.makeBlitCommandEncoder() {
            blit.generateMipmaps(for: target)
            blit.endEncoding()
        }
    }

    static func rect(_ uv: UVRect) -> SIMD4<Float> { SIMD4(uv.u, uv.v, uv.width, uv.height) }

    /// Spec 4 §7 — stage 1 into the half-resolution scratch, then the two blur passes.
    private func encodeBlur(source: BoundSource, binding: SourceBinding, radius: Float, scratch: BlurScratch.Pair, into buffer: MTLCommandBuffer) {
        let convert = ChannelVariant(incoming: source.layout, outgoing: nil, transition: .cut, grade: false)
        guard let convertPipeline = pipelines.channelPipeline(convert),
              let horizontal = pipelines.blurPipeline(vertical: false), let vertical = pipelines.blurPipeline(vertical: true) else {
            missingPipelineCount += 1
            return
        }
        func pass(_ target: MTLTexture, _ pipeline: MTLRenderPipelineState, _ body: (MTLRenderCommandEncoder) -> Void) {
            let descriptor = MTLRenderPassDescriptor()
            descriptor.colorAttachments[0].texture = target
            descriptor.colorAttachments[0].loadAction = .clear
            descriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
            descriptor.colorAttachments[0].storeAction = .store
            guard let encoder = buffer.makeRenderCommandEncoder(descriptor: descriptor) else { return }
            encoder.setRenderPipelineState(pipeline)
            body(encoder)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
        }
        pass(scratch.a, convertPipeline) { encoder in
            var uniforms = ChannelUniforms()
            uniforms.incomingRange = ColorMath.rangeExpansion(range: binding.range, bits: ColorMath.bits(for: source.layout))
            uniforms.codeScales.x = ColorMath.codeScale(for: source.layout)
            uniforms.incomingMatrix = ColorMath.ycbcrToRGB(binding.matrix)
            uniforms.incomingPrimaries = ColorMath.primariesToRec709(binding.matrix)
            encoder.setFragmentTexture(source.plane0, index: 0)
            encoder.setFragmentTexture(source.plane1 ?? source.plane0, index: 1)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<ChannelUniforms>.stride, index: 0)
        }
        let halfRadius = radius / 2
        var uniforms = BlurUniforms(params: SIMD4(halfRadius, 1 / Float(scratch.a.width), 1 / Float(scratch.a.height), 0))
        pass(scratch.b, horizontal) { encoder in
            encoder.setFragmentTexture(scratch.a, index: 0)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<BlurUniforms>.stride, index: 0)
        }
        pass(scratch.a, vertical) { encoder in
            encoder.setFragmentTexture(scratch.b, index: 0)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<BlurUniforms>.stride, index: 0)
        }
    }

    // MARK: - The stack pass (Spec 4 §9), the sink encode (Spec 4 §10), aux passes

    private func encodeStack(_ pass: StackPass, into buffer: MTLCommandBuffer) {
        guard let target = texture(pass.target) else { return }
        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = target
        descriptor.colorAttachments[0].loadAction = .clear
        // Spec 4 §9 — "The pass begins by clearing to the stack's base: opaque black or transparent."
        descriptor.colorAttachments[0].clearColor = pass.base == .black ? MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1) : MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        descriptor.colorAttachments[0].storeAction = .store
        guard let encoder = buffer.makeRenderCommandEncoder(descriptor: descriptor) else { return }
        encoder.label = "stack \(pass.stack)"
        let size = SIMD2<Float>(Float(target.width), Float(target.height))
        for box in pass.boxes where box.isDrawn {
            let variant = BoxVariant(grade: box.grade != nil, gammaBlend: pass.gammaBlend)
            guard let pipeline = pipelines.boxPipeline(variant) else {
                missingPipelineCount += 1
                continue
            }
            encoder.setRenderPipelineState(pipeline)
            encoder.setFragmentTexture(whiteMask, index: 1)
            if let transition = box.transition, transition.type == .dissolve {
                drawContent(transition.outgoing, box: box, opacity: box.opacity * (1 - transition.progress), size: size, encoder: encoder)
                drawContent(box.content, box: box, opacity: box.opacity * transition.progress, size: size, encoder: encoder)
            } else {
                drawContent(box.content, box: box, opacity: box.opacity, size: size, encoder: encoder)
            }
        }
        encoder.endEncoding()
        // Spec 4 §9 — gamma blend: "the final stack pass output is linearized again for the sink".
        if pass.gammaBlend, let linearize = pipelines.linearizePipeline, let scratch = blurScratch.stackScratch(stack: pass.stack, size: PixelSize(width: target.width, height: target.height), device: device) {
            if let blit = buffer.makeBlitCommandEncoder() {
                blit.copy(from: target, to: scratch)
                blit.endEncoding()
            }
            let d = MTLRenderPassDescriptor()
            d.colorAttachments[0].texture = target
            d.colorAttachments[0].loadAction = .dontCare
            d.colorAttachments[0].storeAction = .store
            if let e = buffer.makeRenderCommandEncoder(descriptor: d) {
                e.setRenderPipelineState(linearize)
                e.setFragmentTexture(scratch, index: 0)
                e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                e.endEncoding()
            }
        }
    }

    private func drawContent(_ content: BoxContent, box: ResolvedBox, opacity: Float, size: SIMD2<Float>, encoder: MTLRenderCommandEncoder) {
        guard opacity > 0 else { return }
        switch content {
        case .pixels(let quad):
            guard let t = texture(quad.texture) else { return }
            drawQuad(texture: t, frame: quad.frame, uv: quad.uv, opacity: opacity, grade: box.grade, size: size, mips: quad.mips, encoder: encoder)
        case .lines(let lines):
            for line in lines {
                guard let t = texture(line.texture) else { continue }
                drawQuad(texture: t, frame: line.frame, uv: .full, opacity: opacity, grade: box.grade, size: size, mips: false, encoder: encoder)
            }
        }
    }

    private func drawQuad(texture: MTLTexture, frame: PixelRect, uv: UVRect, opacity: Float, grade: GradeParameters?, size: SIMD2<Float>,
                          mips: Bool, encoder: MTLRenderCommandEncoder) {
        var uniforms = StackUniforms(
            frame: SIMD4(frame.x / size.x * 2 - 1, 1 - (frame.y + frame.height) / size.y * 2, frame.width / size.x * 2, frame.height / size.y * 2),
            uv: SIMD4(uv.u, uv.v, uv.width, uv.height), opacity: SIMD4(opacity, 0, 0, 0),
            gradeA: SIMD4(1, 0, 1, 1), tint: SIMD4(0, 0, 0, 0), hue: matrix_identity_float3x3)
        if let grade { uniforms.setGrade(grade) }
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<StackUniforms>.stride, index: 0)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<StackUniforms>.stride, index: 0)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.setFragmentSamplerState(mips && texture.mipmapLevelCount > 1 ? samplerWithMips : samplerLevelZero, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    }

    private func encodeSink(_ pass: SinkPass, into buffer: MTLCommandBuffer) {
        switch pass.encode {
        case .display10Bit:
            // Spec 4 §10 — the display sink encodes into its drawable on its own thread.
            break
        case .v210:
            // Spec 4 §10 — v210 into the DeckLink ring's shared buffer, scheduled by the sink's thread.
            encodeV210(pass, into: buffer)
        case .capture:
            guard let stack = texture(pass.stack),
                  let target = captureTargets.target(output: pass.output, size: PixelSize(width: stack.width, height: stack.height), device: device),
                  let pipeline = pipelines.encodePipeline(.capture) else { return }
            encodeMix(pass, stack: stack, target: target, pipeline: pipeline, into: buffer)
        }
    }

    let captureTargets = CaptureTargets()

    /// Spec 4 §10 — the shared encode pass: mix with the second texture, transfer function, pixel format.
    func encodeMix(_ pass: SinkPass, stack: MTLTexture, target: MTLTexture, pipeline: MTLRenderPipelineState, into buffer: MTLCommandBuffer) {
        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = target
        descriptor.colorAttachments[0].loadAction = .dontCare
        descriptor.colorAttachments[0].storeAction = .store
        guard let encoder = buffer.makeRenderCommandEncoder(descriptor: descriptor) else { return }
        encoder.label = "encode output \(pass.output)"
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(stack, index: 0)
        var uniforms = EncodeUniforms(mix: SIMD4(pass.mix, 0, 0, 0), size: SIMD4(Float(target.width), Float(target.height), 0, 0))
        switch pass.second {
        case .none:
            encoder.setFragmentTexture(stack, index: 1)
        case .black:
            uniforms.mix.y = 1
            uniforms.mix.z = 1
            encoder.setFragmentTexture(stack, index: 1)
        case .stack(let handle):
            uniforms.mix.y = 1
            encoder.setFragmentTexture(texture(handle) ?? stack, index: 1)
        }
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<EncodeUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
    }

    private func encodeAux(_ pass: AuxPass, into buffer: MTLCommandBuffer) {
        // Spec 4 §10 — previews and the multiviewer are Area 5; the pass is counted, not drawn.
    }

    // MARK: - Harness and control side (Spec 4 §14, §16)

    public func readback(_ handle: TextureHandle) -> CapturedFrame? {
        guard let texture = texture(handle) else { return nil }
        return readback(texture: texture)
    }

    /// Spec 4 §14 — the harness's capturing sink reads the encode pass's
    /// output for an output number.
    public func readbackCapture(output: Int) -> CapturedFrame? {
        guard let texture = captureTargets.existing(output: output) else { return nil }
        return readback(texture: texture)
    }

    func readback(texture: MTLTexture) -> CapturedFrame? {
        guard texture.pixelFormat == .rgba16Float else { return nil }
        let width = texture.width
        let height = texture.height
        let bytesPerRow = width * 8
        guard let buffer = device.makeBuffer(length: bytesPerRow * height, options: .storageModeShared),
              let command = queue.makeCommandBuffer(), let blit = command.makeBlitCommandEncoder() else { return nil }
        blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: width, height: height, depth: 1), to: buffer, destinationOffset: 0,
                  destinationBytesPerRow: bytesPerRow, destinationBytesPerImage: bytesPerRow * height)
        blit.endEncoding()
        command.commit()
        guard MetalBackend.waitBounded(command) else {
            log.error("readback of \(texture.label ?? "a texture") did not complete within the bound")
            return nil
        }
        var frame = CapturedFrame(width: width, height: height)
        let halves = buffer.contents().bindMemory(to: Float16.self, capacity: width * height * 4)
        for i in 0..<(width * height) {
            frame.pixels[i] = LinearPixel(r: Float(halves[i * 4]), g: Float(halves[i * 4 + 1]), b: Float(halves[i * 4 + 2]), a: Float(halves[i * 4 + 3]))
        }
        return frame
    }

    public func makeStill(_ frame: CapturedFrame, label: String) -> TextureHandle {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: max(1, frame.width), height: max(1, frame.height), mipmapped: true)
        d.usage = [.shaderRead]
        d.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: d) else { return .none }
        texture.label = label
        MetalBackend.upload(frame, into: texture)
        generateMipmaps(texture)
        return resources.allocate(texture, descriptor: TextureDescriptor(role: .still, size: PixelSize(width: frame.width, height: frame.height), mipmapped: true, label: label))
    }

    static func upload(_ frame: CapturedFrame, into texture: MTLTexture) {
        var halves = [Float16](repeating: 0, count: frame.width * frame.height * 4)
        for i in 0..<frame.pixels.count {
            let p = frame.pixels[i]
            halves[i * 4] = Float16(p.r)
            halves[i * 4 + 1] = Float16(p.g)
            halves[i * 4 + 2] = Float16(p.b)
            halves[i * 4 + 3] = Float16(p.a)
        }
        halves.withUnsafeBytes { raw in
            texture.replace(region: MTLRegionMake2D(0, 0, frame.width, frame.height), mipmapLevel: 0, withBytes: raw.baseAddress!, bytesPerRow: frame.width * 8)
        }
    }

    /// Control side: build the mip chain of a texture and wait.
    public func generateMipmaps(_ texture: MTLTexture) {
        guard texture.mipmapLevelCount > 1, let command = queue.makeCommandBuffer(), let blit = command.makeBlitCommandEncoder() else { return }
        blit.generateMipmaps(for: texture)
        blit.endEncoding()
        command.commit()
        MetalBackend.waitBounded(command)
    }

    /// A texture the decoder would hand over, from raw plane bytes.
    public func makePlanes(layout: SourceLayout, size: PixelSize, planes: [Data]) -> PickedFrame? {
        func make(_ format: MTLPixelFormat, _ width: Int, _ height: Int, _ bytes: Data, _ bytesPerPixel: Int) -> MTLTexture? {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: max(1, width), height: max(1, height), mipmapped: false)
            d.usage = [.shaderRead]
            d.storageMode = .shared
            guard let t = device.makeTexture(descriptor: d), bytes.count >= width * height * bytesPerPixel else { return nil }
            bytes.withUnsafeBytes { raw in
                t.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: raw.baseAddress!, bytesPerRow: width * bytesPerPixel)
            }
            return t
        }
        var frame = PickedFrame()
        frame.layout = layout
        switch layout {
        case .nv12:
            guard planes.count == 2 else { return nil }
            frame.plane0 = make(.r8Unorm, size.width, size.height, planes[0], 1)
            frame.plane1 = make(.rg8Unorm, size.width / 2, size.height / 2, planes[1], 2)
        case .p010:
            guard planes.count == 2 else { return nil }
            frame.plane0 = make(.r16Unorm, size.width, size.height, planes[0], 2)
            frame.plane1 = make(.rg16Unorm, size.width / 2, size.height / 2, planes[1], 4)
        case .yuv422p10:
            guard planes.count == 2 else { return nil }
            frame.plane0 = make(.r16Unorm, size.width, size.height, planes[0], 2)
            frame.plane1 = make(.rg16Unorm, size.width / 2, size.height, planes[1], 4)
        case .rgba16, .linearRGBA16, .finished:
            guard planes.count == 1 else { return nil }
            frame.plane0 = make(.rgba16Float, size.width, size.height, planes[0], 8)
        case .bgra8sRGB:
            guard planes.count == 1 else { return nil }
            frame.plane0 = make(.bgra8Unorm_srgb, size.width, size.height, planes[0], 4)
        }
        return frame.plane0 == nil ? nil : frame
    }

    /// Control side: upload a BGRA8 sRGB premultiplied bitmap into a texture handle's texture.
    public func upload(bgra8 bytes: Data, bytesPerRow: Int, into handle: TextureHandle) {
        guard let texture = texture(handle), bytes.count >= bytesPerRow * texture.height else { return }
        bytes.withUnsafeBytes { raw in
            texture.replace(region: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0, withBytes: raw.baseAddress!, bytesPerRow: bytesPerRow)
        }
    }
}

/// The three command buffers of a tick, kept until their completion is read.
struct ReceiptSlot {
    var token: Int64
    var channel: MTLCommandBuffer?
    var stack: MTLCommandBuffer?
    var sink: MTLCommandBuffer?

    init(token: Int64) {
        self.token = token
    }
}

/// A fixed ring of recent receipts: written by the render thread, read by it
/// and by the harness.
final class ReceiptRing: @unchecked Sendable {
    static let depth = 8
    private let slots: UnsafeMutablePointer<ReceiptSlot>

    init() {
        slots = UnsafeMutablePointer<ReceiptSlot>.allocate(capacity: ReceiptRing.depth)
        slots.initialize(repeating: ReceiptSlot(token: 0), count: ReceiptRing.depth)
    }

    deinit {
        slots.deinitialize(count: ReceiptRing.depth)
        slots.deallocate()
    }

    func store(_ slot: ReceiptSlot) {
        slots[Int(slot.token % Int64(ReceiptRing.depth))] = slot
    }

    func slot(for token: Int64) -> ReceiptSlot? {
        let slot = slots[Int(token % Int64(ReceiptRing.depth))]
        return slot.token == token ? slot : nil
    }
}

/// Spec 4 §7 — the half-resolution scratch pair of a blurring channel, and a
/// full-size scratch for gamma-blend stacks. Allocated on the control side in
/// `prepare`, read on the render thread.
final class BlurScratch: @unchecked Sendable {
    struct Pair {
        var a: MTLTexture
        var b: MTLTexture
    }

    private let lock = NSLock()
    private var pairs: [Int: Pair] = [:]
    private var stacks: [Int: MTLTexture] = [:]

    func ensure(channel: Int, size: PixelSize, device: MTLDevice) {
        lock.lock()
        defer { lock.unlock() }
        guard pairs[channel] == nil else { return }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: max(1, size.width / 2), height: max(1, size.height / 2), mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .private
        guard let a = device.makeTexture(descriptor: d), let b = device.makeTexture(descriptor: d) else { return }
        a.label = "blur scratch a \(channel)"
        b.label = "blur scratch b \(channel)"
        pairs[channel] = Pair(a: a, b: b)
    }

    func textures(channel: Int) -> Pair? {
        lock.lock()
        defer { lock.unlock() }
        return pairs[channel]
    }

    func stackScratch(stack: Int, size: PixelSize, device: MTLDevice) -> MTLTexture? {
        lock.lock()
        defer { lock.unlock() }
        if let existing = stacks[stack], existing.width == size.width, existing.height == size.height { return existing }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: max(1, size.width), height: max(1, size.height), mipmapped: false)
        d.usage = [.shaderRead]
        d.storageMode = .private
        guard let t = device.makeTexture(descriptor: d) else { return nil }
        stacks[stack] = t
        return t
    }
}

/// Spec 4 §14 — the capturing sink's encode targets, one per output.
final class CaptureTargets: @unchecked Sendable {
    private let lock = NSLock()
    private var targets: [Int: MTLTexture] = [:]

    func target(output: Int, size: PixelSize, device: MTLDevice) -> MTLTexture? {
        lock.lock()
        defer { lock.unlock() }
        if let existing = targets[output], existing.width == size.width, existing.height == size.height { return existing }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: max(1, size.width), height: max(1, size.height), mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .private
        guard let t = device.makeTexture(descriptor: d) else { return nil }
        t.label = "capture output \(output)"
        targets[output] = t
        return t
    }

    func existing(output: Int) -> MTLTexture? {
        lock.lock()
        defer { lock.unlock() }
        return targets[output]
    }
}
