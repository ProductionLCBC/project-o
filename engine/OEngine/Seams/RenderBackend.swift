// OEngine — Spec 4 §14, the `RenderBackend` seam.

import Foundation

/// Spec 4 §14 — `RenderBackend`: "Metal" in v1, "A Direct3D 12 backend
/// (Windows), behind the same pass descriptions" later. "What is not a seam.
/// The frame plan, the tick order, the colour pipeline and the resource rules
/// are fixed. A future backend reproduces them; it does not get to reinterpret
/// them."
///
/// The backend owns GPU objects behind handles (Spec 4 §5, allocated before
/// use and never on the render thread) and encodes one tick's plan (Spec 4
/// §4, step 3) without blocking. The render loop never sees a GPU object.
public protocol RenderBackend: AnyObject, Sendable {
    var name: String { get }

    /// Spec 4 §5 — the handle table every pass resolves through.
    var resources: ResourceTable { get }

    /// Spec 4 §5 — allocate a texture on the control side, "at show load, a
    /// stack or output change ... Never on the render thread."
    func makeTexture(_ descriptor: TextureDescriptor) -> TextureHandle

    /// Spec 4 §4 step 3 — "Encode all channel passes into one command buffer;
    /// encode all stack passes into a second; encode sink encodes into a
    /// third; commit all three with GPU timestamps enabled." Render thread
    /// only; must not allocate from engine code, lock, or wait.
    func encode(_ tick: TickTime, plan: FramePlan, picks: PickedFrames, options: EncodeOptions) -> EncodeReceipt

    /// Spec 4 §13 — the GPU timings of an earlier tick, once its command
    /// buffers completed; nil while they are in flight. Polled, never waited
    /// for (Spec 4 §3: the render thread never waits on anyone).
    func completion(of receipt: EncodeReceipt) -> GPUCompletion?

    /// Spec 4 §7 — "compiled at launch into a small pipeline cache": the
    /// control thread makes sure every variant a plan needs exists before the
    /// plan is published, so the render thread never compiles.
    func prepare(_ plan: FramePlan)

    /// Harness and control side only: the pixels of a texture, after waiting
    /// for the GPU. Nil when the backend has no pixels to give.
    func readback(_ handle: TextureHandle) -> CapturedFrame?

    /// Harness and control side: a texture holding premultiplied linear
    /// pixels, as a still source or a golden input.
    func makeStill(_ frame: CapturedFrame, label: String) -> TextureHandle

    /// Harness: planes of one source layout from raw bytes, as a decoder would
    /// hand them over, so the colour tests can feed known code values.
    func makePlanes(layout: SourceLayout, size: PixelSize, planes: [Data]) -> PickedFrame?
}

extension RenderBackend {
    public func prepare(_ plan: FramePlan) {}
    public func readback(_ handle: TextureHandle) -> CapturedFrame? { nil }
    public func makeStill(_ frame: CapturedFrame, label: String) -> TextureHandle {
        makeTexture(TextureDescriptor(role: .still, size: PixelSize(width: frame.width, height: frame.height), label: label))
    }
    public func makePlanes(layout: SourceLayout, size: PixelSize, planes: [Data]) -> PickedFrame? { nil }
}

/// Spec 4 §5 — the roles a texture can have, each with the minimum usage
/// flags "so Metal can lay them out optimally".
public enum TextureRole: String, Codable, Sendable {
    /// RGBA16Float, premultiplied linear, render target and source.
    case channel
    /// RGBA16Float, the output size, render target and source.
    case stack
    /// RGBA16Float linear with mips, a decoded still.
    case still
    /// BGRA8Unorm sRGB, "one line high".
    case textLine
    /// BGRA8Unorm sRGB, "half the channel render size".
    case poster
    /// BGRA8Unorm sRGB, small.
    case preview
    /// A half-resolution RGBA16Float scratch for the blur pass.
    case blurScratch
}

public struct TextureDescriptor: Equatable, Sendable {
    public var role: TextureRole
    public var size: PixelSize
    public var mipmapped: Bool
    public var label: String

    public init(role: TextureRole, size: PixelSize, mipmapped: Bool = false, label: String = "") {
        self.role = role
        self.size = size
        self.mipmapped = mipmapped
        self.label = label
    }
}

/// Spec 4 §4 step 5 and §12 — what the render loop decided for this tick:
/// skip the aux passes when the previous tick left no headroom, and drop the
/// blur passes and mip generation after three consecutive overruns.
public struct EncodeOptions: Equatable, Sendable {
    public var skipAux: Bool
    public var dropExtras: Bool

    public init(skipAux: Bool = false, dropExtras: Bool = false) {
        self.skipAux = skipAux
        self.dropExtras = dropExtras
    }
}

/// A token for one tick's GPU work.
public struct EncodeReceipt: Equatable, Sendable {
    public var tick: Int64
    public var token: Int64

    public init(tick: Int64, token: Int64) {
        self.tick = tick
        self.token = token
    }
}

/// Spec 4 §13 — "GPU time from command-buffer timestamps (channel, stack and
/// sink buffers separately)"; Spec 4 §12 — "Metal device lost or command
/// buffer error" is reported here and recovered elsewhere.
public struct GPUCompletion: Equatable, Sendable {
    public var channelNs: Int64
    public var stackNs: Int64
    public var sinkNs: Int64
    public var failed: Bool

    public init(channelNs: Int64, stackNs: Int64, sinkNs: Int64, failed: Bool = false) {
        self.channelNs = channelNs
        self.stackNs = stackNs
        self.sinkNs = sinkNs
        self.failed = failed
    }

    public var totalNs: Int64 { channelNs + stackNs + sinkNs }
}
