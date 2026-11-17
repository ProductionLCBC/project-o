// OApp — Spec 10 §2, the Mach channel: the preview surfaces, the channel pictures and the meters.

import Foundation
import IOSurface
import OMach

/// The engine's Mach channel as the app reads it: a seam over `MachClient`,
/// so a test can stand in for the engine.
public protocol MachSource: AnyObject, Sendable {
    func connect(name: String) throws
    func disconnect()
    var state: MachClient.State { get }
}

extension MachClient: MachSource {}

/// Spec 10 §2 — "The preview surfaces, the channel pictures and the meters
/// come over a Mach channel", whose service `hello` names. The app holds one
/// client for the engine it is connected to, and reads the newest surface of
/// each stack and each channel, and the last meters, when it draws.
///
/// Area 13 reading — the channel has failed when the lookup or the connect
/// fails, and is tried again every five seconds; there is no staleness
/// timer, since under pressure the engine stops sending frames by design.
@MainActor
public final class MachLink {
    /// "tried again every five seconds".
    public static let retry: TimeInterval = 5

    private let source: any MachSource
    private let clock: any AppClock
    /// Runs the connect away from the main thread, which never waits on the engine (Spec 10 §1), and comes back.
    private let offMain: (@escaping @Sendable () -> Bool, @escaping @MainActor (Bool) -> Void) -> Void
    private var name: String?
    private var retryTask: (any ClockTask)?
    public private(set) var isConnected = false
    /// What the channel last held, read once a draw (`poll`).
    public private(set) var state: MachClient.State?
    public var onChange: (() -> Void)?

    public init(source: any MachSource = MachClient(), clock: any AppClock,
                offMain: @escaping (@escaping @Sendable () -> Bool, @escaping @MainActor (Bool) -> Void) -> Void = MachLink.background) {
        self.source = source
        self.clock = clock
        self.offMain = offMain
    }

    /// The default: a background queue, and the main queue for the answer.
    public static let background: (@escaping @Sendable () -> Bool, @escaping @MainActor (Bool) -> Void) -> Void = { work, done in
        DispatchQueue.global(qos: .userInitiated).async {
            let result = work()
            DispatchQueue.main.async { MainActor.assumeIsolated { done(result) } }
        }
    }

    /// Connects to the service an engine's `hello` named, and keeps trying while that engine is the one connected.
    public func connect(name: String) {
        guard name != self.name || !isConnected else { return }
        if self.name != nil { disconnect() }
        self.name = name
        attempt()
    }

    private func attempt() {
        guard let name else { return }
        let source = self.source
        offMain({ (try? source.connect(name: name)) != nil }) { [weak self] connected in
            guard let self, self.name == name else {
                if connected { source.disconnect() }
                return
            }
            self.isConnected = connected
            if connected {
                self.onChange?()
            } else {
                self.retryTask?.cancel()
                self.retryTask = self.clock.after(Self.retry) { [weak self] in self?.attempt() }
            }
        }
    }

    /// The engine has gone, or another one is connected.
    public func disconnect() {
        retryTask?.cancel()
        retryTask = nil
        name = nil
        if isConnected { source.disconnect() }
        isConnected = false
        state = nil
        onChange?()
    }

    /// Reads the channel as it stands; the views draw from what this found.
    public func poll() {
        guard isConnected else { return }
        state = source.state
    }

    /// The surface that holds a stack's newest preview frame.
    public func preview(stack: Int) -> IOSurfaceRef? {
        guard let state, let set = state.previews[stack], let slot = state.newestPreview[stack], set.surfaces.indices.contains(slot) else { return nil }
        return set.surfaces[slot]
    }

    /// The surface that holds a channel's newest picture.
    public func picture(channel: Int) -> IOSurfaceRef? {
        guard let state, let set = state.pictures[channel], let slot = state.newestPicture[channel], set.surfaces.indices.contains(slot) else { return nil }
        return set.surfaces[slot]
    }

    /// A channel's peak level in dBFS from the last meters frame, or nil when it has none.
    public func level(channel: Int) -> Double? {
        state?.meters.first { $0.channel == channel }.map { Double(MeterReading.decibels($0.peak)) }
    }
}
