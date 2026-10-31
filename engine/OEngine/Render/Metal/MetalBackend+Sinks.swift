// OEngine — Spec 4 §10 and §12: the sink encodes the Metal backend provides to
// the sinks, the last-good-frame copies and the rebuild after a GPU error.

import Foundation
import Metal
import simd

extension MetalBackend {
    /// Spec 4 §10 — the display sink's encode pass into its drawable, on the
    /// sink's thread: mix, sRGB transfer, 10-bit.
    public func encodeDisplay(_ frame: CompletedFrame, into drawable: MTLTexture, command: MTLCommandBuffer) {
        guard let stack = texture(frame.stack) else { return }
        let kind: EncodeKind = drawable.pixelFormat == .bgr10a2Unorm ? .display10Bit : .capture
        if pipelines.encodePipeline(kind) == nil { try? pipelines.ensureEncode(kind) }
        guard let pipeline = pipelines.encodePipeline(kind) else { return }
        let pass = SinkPass(output: 0, stack: frame.stack, second: frame.second, mix: frame.mix, encode: kind, destination: frame.destination)
        encodeMix(pass, stack: stack, target: drawable, pipeline: pipeline, into: command)
    }

    /// Spec 4 §10 — a sink registers the v210 ring the render thread writes.
    public func registerV210(output: Int, buffers: V210Buffers) {
        v210Rings.register(output: output, buffers: buffers)
        try? pipelines.ensureEncode(.v210)
    }

    /// Spec 4 §10 — "The encode pass is a compute shader that writes v210
    /// directly into an MTLBuffer with shared storage".
    func encodeV210(_ pass: SinkPass, into buffer: MTLCommandBuffer) {
        guard let stack = texture(pass.stack), let ring = v210Rings.buffers(output: pass.output),
              let pipeline = pipelines.v210Pipeline, let encoder = buffer.makeComputeCommandEncoder() else { return }
        encoder.label = "v210 output \(pass.output)"
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(stack, index: 0)
        var uniforms = EncodeUniforms(mix: SIMD4(pass.mix, 0, 0, 0), size: SIMD4(Float(ring.width), Float(ring.height), 0, 0))
        switch pass.second {
        case .none:
            encoder.setTexture(stack, index: 1)
        case .black:
            uniforms.mix.y = 1
            uniforms.mix.z = 1
            encoder.setTexture(stack, index: 1)
        case .stack(let handle):
            uniforms.mix.y = 1
            encoder.setTexture(texture(handle) ?? stack, index: 1)
        }
        encoder.setBuffer(ring.buffer(forSlot: pass.destination), offset: 0, index: 0)
        encoder.setBytes(&uniforms, length: MemoryLayout<EncodeUniforms>.stride, index: 1)
        let groups = (ring.width + 5) / 6
        let threads = MTLSize(width: groups, height: ring.height, depth: 1)
        let perGroup = MTLSize(width: min(64, pipeline.maxTotalThreadsPerThreadgroup), height: 1, depth: 1)
        encoder.dispatchThreads(threads, threadsPerThreadgroup: perGroup)
        encoder.endEncoding()
    }

    /// Harness: run the v210 encode for a stack texture and hand back the words.
    public func v210Words(stack: TextureHandle, second: SecondTexture = .none, mix: Float = 0, width: Int, height: Int) -> [UInt32]? {
        guard let buffers = V210Buffers(device: device, width: width, height: height) else { return nil }
        v210Rings.register(output: -1, buffers: buffers)
        try? pipelines.ensureEncode(.v210)
        guard let command = queue.makeCommandBuffer() else { return nil }
        encodeV210(SinkPass(output: -1, stack: stack, second: second, mix: mix, encode: .v210, destination: 0), into: command)
        command.commit()
        guard MetalBackend.waitBounded(command) else { return nil }
        let buffer = buffers.buffer(forSlot: 0)
        let count = buffers.rowBytes * height / 4
        let words = buffer.contents().bindMemory(to: UInt32.self, capacity: count)
        return Array(UnsafeBufferPointer(start: words, count: count))
    }

    /// Harness: the display encode of a stack texture as 10-bit codes per pixel (r, g, b, a).
    public func displayCodes(stack: TextureHandle, second: SecondTexture = .none, mix: Float = 0) -> [(Int, Int, Int, Int)]? {
        guard let source = texture(stack) else { return nil }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgr10a2Unorm, width: source.width, height: source.height, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .shared
        guard let target = device.makeTexture(descriptor: d), let command = queue.makeCommandBuffer() else { return nil }
        let frame = CompletedFrame(tick: 0, stack: stack, second: second, mix: mix, destination: 0, receipt: EncodeReceipt(tick: 0, token: 0))
        encodeDisplay(frame, into: target, command: command)
        command.commit()
        guard MetalBackend.waitBounded(command) else { return nil }
        var words = [UInt32](repeating: 0, count: source.width * source.height)
        words.withUnsafeMutableBytes { raw in
            target.getBytes(raw.baseAddress!, bytesPerRow: source.width * 4, from: MTLRegionMake2D(0, 0, source.width, source.height), mipmapLevel: 0)
        }
        return words.map { word in
            (Int((word >> 20) & 0x3FF), Int((word >> 10) & 0x3FF), Int(word & 0x3FF), Int((word >> 30) & 0x3))
        }
    }

    // MARK: - Last-good-frame copies (Spec 4 §12)

    /// Spec 4 §12 — "Each output keeps a CPU-side copy of a recent frame,
    /// refreshed about once a second by the readback thread when it has spare
    /// capacity ... so a GPU reset has something to show."
    public func refreshLastGood(output: Int, stack: TextureHandle) {
        guard let frame = readback(stack) else { return }
        lastGood.store(frame, output: output)
    }

    public func lastGoodFrame(output: Int) -> CapturedFrame? { lastGood.frame(output: output) }

    // MARK: - Rebuild (Spec 4 §12)

    /// Spec 4 §12 — "Metal device lost or command buffer error: ... rebuild
    /// pipelines and heaps; resume; log as a severe event." Pipelines are
    /// dropped and recompiled by the next `prepare`; the textures stay, since
    /// a command buffer error does not invalidate them.
    public func rebuild() {
        pipelines.reset()
        rebuildCount += 1
        log.severe("GPU work failed; pipelines rebuilt (\(rebuildCount))")
    }
}

/// The v210 rings registered by DeckLink sinks, by output.
final class V210Rings: @unchecked Sendable {
    private let lock = NSLock()
    private var rings: [Int: V210Buffers] = [:]

    func register(output: Int, buffers: V210Buffers) {
        lock.lock()
        rings[output] = buffers
        lock.unlock()
    }

    func buffers(output: Int) -> V210Buffers? {
        lock.lock()
        defer { lock.unlock() }
        return rings[output]
    }
}

/// Spec 4 §12 — the CPU copies, by output.
final class LastGoodFrames: @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [Int: CapturedFrame] = [:]

    func store(_ frame: CapturedFrame, output: Int) {
        lock.lock()
        frames[output] = frame
        lock.unlock()
    }

    func frame(output: Int) -> CapturedFrame? {
        lock.lock()
        defer { lock.unlock() }
        return frames[output]
    }
}
