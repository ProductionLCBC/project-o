// OEngine — Spec 4 §14, the headless harness: a backend that records what it
// was asked to encode instead of touching a GPU.

import Foundation

/// What one tick asked the backend to do, as the pacing tests read it
/// (Spec 4 §16: "renders exactly the expected passes per tick").
public struct EncodedTick: Equatable, Sendable {
    public var tick: Int64
    public var channelPasses: Int
    public var stackPasses: [Int]
    public var sinkOutputs: [Int]
    public var auxPasses: Int
    public var auxSkipped: Int
    public var dropExtras: Bool
    public var snapshots: [Int]
}

/// A GPU object stand-in, so handles resolve to something in the harness.
public final class PlaceholderTexture: @unchecked Sendable {
    public let descriptor: TextureDescriptor

    public init(_ descriptor: TextureDescriptor) {
        self.descriptor = descriptor
    }
}

/// Spec 4 §14 — "tests can run it headless with a software clock and a
/// texture-capturing sink": the backend of the headless harness before any
/// Metal code. It hands out handles, records every encode, and reports a
/// simulated GPU time so the pressure rules can be tested.
public final class RecordingBackend: RenderBackend, @unchecked Sendable {
    public let name = "recording"
    public let resources = ResourceTable(capacity: 4096)
    public var simulatedGPUMilliseconds: Double = 3
    public var failNextCompletion = false
    /// Off, the backend keeps nothing per tick (no lock, no append): the mode of
    /// the allocation test, which counts what a render tick does on its own.
    public var recordsEncodes = true
    public private(set) var encoded: [EncodedTick] = []
    public private(set) var rebuilds = 0
    private var completions: [Int64: GPUCompletion] = [:]
    private var nextToken: Int64 = 1
    private var fixedCompletion = GPUCompletion(channelNs: 0, stackNs: 0, sinkNs: 0)
    private let lock = NSLock()

    public init() {}

    public func makeTexture(_ descriptor: TextureDescriptor) -> TextureHandle {
        resources.allocate(PlaceholderTexture(descriptor), descriptor: descriptor)
    }

    public func encode(_ tick: TickTime, plan: FramePlan, picks: PickedFrames, options: EncodeOptions) -> EncodeReceipt {
        guard recordsEncodes else {
            fixedCompletion = GPUCompletion(channelNs: Int64(simulatedGPUMilliseconds * 1_000_000), stackNs: 0, sinkNs: 0)
            return EncodeReceipt(tick: tick.tick, token: -1)
        }
        lock.lock()
        defer { lock.unlock() }
        let token = nextToken
        nextToken += 1
        encoded.append(EncodedTick(
            tick: tick.tick, channelPasses: plan.channelPasses.count, stackPasses: plan.stackPasses.map(\.stack),
            sinkOutputs: plan.sinkPasses.map(\.output), auxPasses: options.skipAux ? 0 : plan.auxPasses.count,
            auxSkipped: options.skipAux ? plan.auxPasses.count : 0, dropExtras: options.dropExtras,
            snapshots: plan.channelPasses.filter(\.snapshotOutgoing).map(\.channel)))
        let ns = Int64(simulatedGPUMilliseconds * 1_000_000)
        completions[token] = GPUCompletion(channelNs: ns, stackNs: 0, sinkNs: 0, failed: failNextCompletion)
        failNextCompletion = false
        return EncodeReceipt(tick: tick.tick, token: token)
    }

    public func completion(of receipt: EncodeReceipt) -> GPUCompletion? {
        if receipt.token == -1 { return fixedCompletion }
        lock.lock()
        defer { lock.unlock() }
        return completions[receipt.token]
    }

    public func reset() {
        lock.lock()
        encoded.removeAll()
        lock.unlock()
    }

    public func rebuild() {
        lock.lock()
        rebuilds += 1
        lock.unlock()
    }
}
