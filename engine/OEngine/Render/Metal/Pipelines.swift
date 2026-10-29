// OEngine — Spec 4 §7, "Shader variants. One channel shader, specialised with
// Metal function constants ... compiled at launch into a small pipeline
// cache, so the per-tick work is a pipeline lookup and no branching in the
// shader."

import Foundation
import Metal

/// The variant of the channel shader a pass needs.
struct ChannelVariant: Hashable, Sendable {
    var incoming: Int32
    var outgoing: Int32
    var transition: Int32
    var grade: Bool

    static let layouts = 8
    static let transitions = 3

    /// A dense index, so the render thread's lookup is an array read.
    var index: Int {
        ((Int(incoming) * ChannelVariant.layouts + Int(outgoing)) * ChannelVariant.transitions + Int(transition)) * 2 + (grade ? 1 : 0)
    }

    static let count = layouts * layouts * transitions * 2

    init(incoming: SourceLayout?, outgoing: SourceLayout?, transition: TransitionVariant, grade: Bool) {
        self.incoming = incoming?.shaderCode ?? 0
        self.outgoing = outgoing?.shaderCode ?? 0
        self.transition = transition.rawValue
        self.grade = grade
    }
}

/// The variant of the stack box shader.
struct BoxVariant: Hashable, Sendable {
    var grade: Bool
    var gammaBlend: Bool

    var index: Int { (grade ? 1 : 0) + (gammaBlend ? 2 : 0) }
    static let count = 4
}

enum PipelineError: Error {
    case missingFunction(String)
}

/// The pipeline cache: built on the control side, read on the render thread
/// as fixed arrays indexed by variant.
final class PipelineCache: @unchecked Sendable {
    private let device: MTLDevice
    private let library: MTLLibrary
    private let channel: UnsafeMutablePointer<MTLRenderPipelineState?>
    private let box: UnsafeMutablePointer<MTLRenderPipelineState?>
    private var blur: [MTLRenderPipelineState?] = [nil, nil]
    private var encode: [EncodeKind: MTLRenderPipelineState] = [:]
    private var linearize: MTLRenderPipelineState?
    private var v210: MTLComputePipelineState?
    private let lock = NSLock()
    private(set) var compiled = 0

    init(device: MTLDevice, library: MTLLibrary) {
        self.device = device
        self.library = library
        channel = UnsafeMutablePointer<MTLRenderPipelineState?>.allocate(capacity: ChannelVariant.count)
        channel.initialize(repeating: nil, count: ChannelVariant.count)
        box = UnsafeMutablePointer<MTLRenderPipelineState?>.allocate(capacity: BoxVariant.count)
        box.initialize(repeating: nil, count: BoxVariant.count)
    }

    deinit {
        channel.deinitialize(count: ChannelVariant.count)
        channel.deallocate()
        box.deinitialize(count: BoxVariant.count)
        box.deallocate()
    }

    // MARK: - Render thread reads

    func channelPipeline(_ variant: ChannelVariant) -> MTLRenderPipelineState? {
        channel[variant.index]
    }

    func boxPipeline(_ variant: BoxVariant) -> MTLRenderPipelineState? {
        box[variant.index]
    }

    func blurPipeline(vertical: Bool) -> MTLRenderPipelineState? {
        blur[vertical ? 1 : 0]
    }

    func encodePipeline(_ kind: EncodeKind) -> MTLRenderPipelineState? {
        lock.lock()
        defer { lock.unlock() }
        return encode[kind]
    }

    var linearizePipeline: MTLRenderPipelineState? {
        lock.lock()
        defer { lock.unlock() }
        return linearize
    }

    var v210Pipeline: MTLComputePipelineState? {
        lock.lock()
        defer { lock.unlock() }
        return v210
    }

    // MARK: - Control side compiles

    /// Spec 4 §12 — drop every pipeline so the next `prepare` recompiles them.
    func reset() {
        lock.lock()
        defer { lock.unlock() }
        for i in 0..<ChannelVariant.count { channel[i] = nil }
        for i in 0..<BoxVariant.count { box[i] = nil }
        blur = [nil, nil]
        encode = [:]
        linearize = nil
        v210 = nil
        try? compileBlurLocked()
    }

    private func compileBlurLocked() throws {
        for vertical in [false, true] where blur[vertical ? 1 : 0] == nil {
            let constants = MTLFunctionConstantValues()
            var direction: Int32 = vertical ? 1 : 0
            constants.setConstantValue(&direction, type: .int, index: 0)
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.label = vertical ? "blur vertical" : "blur horizontal"
            descriptor.vertexFunction = try library.makeFunction(name: "blurVertex", constantValues: constants)
            descriptor.fragmentFunction = try library.makeFunction(name: "blurFragment", constantValues: constants)
            descriptor.colorAttachments[0].pixelFormat = .rgba16Float
            blur[vertical ? 1 : 0] = try device.makeRenderPipelineState(descriptor: descriptor)
            compiled += 1
        }
    }

    /// Make sure the channel variant exists; compiles on the caller's thread.
    func ensureChannel(_ variant: ChannelVariant) throws {
        if channel[variant.index] != nil { return }
        lock.lock()
        defer { lock.unlock() }
        if channel[variant.index] != nil { return }
        let constants = MTLFunctionConstantValues()
        var incoming = variant.incoming
        var outgoing = variant.outgoing
        var transition = variant.transition
        var grade = variant.grade
        constants.setConstantValue(&incoming, type: .int, index: 0)
        constants.setConstantValue(&outgoing, type: .int, index: 1)
        constants.setConstantValue(&transition, type: .int, index: 2)
        constants.setConstantValue(&grade, type: .bool, index: 3)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = "channel \(variant.incoming)/\(variant.outgoing)/\(variant.transition)/\(variant.grade)"
        descriptor.vertexFunction = try library.makeFunction(name: "channelVertex", constantValues: constants)
        descriptor.fragmentFunction = try library.makeFunction(name: "channelFragment", constantValues: constants)
        descriptor.colorAttachments[0].pixelFormat = .rgba16Float
        channel[variant.index] = try device.makeRenderPipelineState(descriptor: descriptor)
        compiled += 1
    }

    func ensureBlur() throws {
        lock.lock()
        defer { lock.unlock() }
        try compileBlurLocked()
    }

    /// Spec 4 §9 — the box shader with premultiplied over-blending in linear light.
    func ensureBox(_ variant: BoxVariant) throws {
        if box[variant.index] != nil { return }
        lock.lock()
        defer { lock.unlock() }
        if box[variant.index] != nil { return }
        let constants = MTLFunctionConstantValues()
        var grade = variant.grade
        var gammaBlend = variant.gammaBlend
        constants.setConstantValue(&grade, type: .bool, index: 0)
        constants.setConstantValue(&gammaBlend, type: .bool, index: 1)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = "box grade:\(variant.grade) gamma:\(variant.gammaBlend)"
        descriptor.vertexFunction = try library.makeFunction(name: "boxVertex", constantValues: constants)
        descriptor.fragmentFunction = try library.makeFunction(name: "boxFragment", constantValues: constants)
        let attachment = descriptor.colorAttachments[0]
        attachment?.pixelFormat = .rgba16Float
        attachment?.isBlendingEnabled = true
        attachment?.rgbBlendOperation = .add
        attachment?.alphaBlendOperation = .add
        attachment?.sourceRGBBlendFactor = .one
        attachment?.sourceAlphaBlendFactor = .one
        attachment?.destinationRGBBlendFactor = .oneMinusSourceAlpha
        attachment?.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        box[variant.index] = try device.makeRenderPipelineState(descriptor: descriptor)
        compiled += 1
    }

    /// Spec 4 §9 — "the final stack pass output is linearized again for the sink".
    func ensureLinearize() throws {
        lock.lock()
        defer { lock.unlock() }
        guard linearize == nil else { return }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = "linearize"
        descriptor.vertexFunction = try library.makeFunction(name: "blurVertex", constantValues: MTLFunctionConstantValues())
        descriptor.fragmentFunction = try library.makeFunction(name: "linearizeFragment", constantValues: MTLFunctionConstantValues())
        descriptor.colorAttachments[0].pixelFormat = .rgba16Float
        linearize = try device.makeRenderPipelineState(descriptor: descriptor)
        compiled += 1
    }

    /// Spec 4 §10 — the encode pass for one sink kind.
    func ensureEncode(_ kind: EncodeKind) throws {
        lock.lock()
        defer { lock.unlock() }
        guard encode[kind] == nil else { return }
        let constants = MTLFunctionConstantValues()
        switch kind {
        case .display10Bit, .capture:
            var toDisplay = kind == .display10Bit
            constants.setConstantValue(&toDisplay, type: .bool, index: 0)
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.label = "encode \(kind.rawValue)"
            descriptor.vertexFunction = try library.makeFunction(name: "encodeVertex", constantValues: constants)
            descriptor.fragmentFunction = try library.makeFunction(name: "encodeFragment", constantValues: constants)
            descriptor.colorAttachments[0].pixelFormat = kind == .display10Bit ? .bgr10a2Unorm : .rgba16Float
            encode[kind] = try device.makeRenderPipelineState(descriptor: descriptor)
        case .v210:
            let function = try library.makeFunction(name: "encodeV210", constantValues: constants)
            v210 = try device.makeComputePipelineState(function: function)
        }
        compiled += 1
    }
}
