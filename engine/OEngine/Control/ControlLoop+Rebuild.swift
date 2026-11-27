// OEngine — Spec 4 §5, the show's textures made again between ticks.

import Foundation
import OCore

extension ControlLoop {
    /// Spec 4 §5 — what one build made again, for the Mach channel (Spec 10
    /// §2: the surfaces are sent "whenever a stack's surfaces are made again"
    /// and "when a channel is added or renumbered"; "when a channel is
    /// removed, a message names it") and for the tests. Every list is by
    /// number, in order.
    public struct Rebuild: Equatable, Sendable {
        /// The frame whose plan is the first to name the new textures.
        public var frame: Int64
        public var channelsMade: [Int] = []
        public var channelsGone: [Int] = []
        public var channelsResized: [Int] = []
        public var stacksMade: [Int] = []
        public var stacksGone: [Int] = []
        public var stacksResized: [Int] = []
        /// Spec 4 §12 — what could not be given its textures, as `channel N`
        /// or `stack N`: what it had goes on serving, at the size it had.
        public var failed: [String] = []

        public init(frame: Int64) {
            self.frame = frame
        }

        public var isEmpty: Bool {
            channelsMade.isEmpty && channelsGone.isEmpty && channelsResized.isEmpty && stacksMade.isEmpty && stacksGone.isEmpty
                && stacksResized.isEmpty && failed.isEmpty
        }

        /// Spec 10 §2 — whether a preview or a picture surface was made or
        /// dropped. A stack's previews are a quarter of its size, so they are
        /// made again with it; a channel's pictures are 256 by 144 whatever
        /// its size, so a resized channel keeps them.
        public var surfacesChanged: Bool {
            !(channelsMade.isEmpty && channelsGone.isEmpty && stacksMade.isEmpty && stacksGone.isEmpty && stacksResized.isEmpty)
        }
    }

    /// Spec 4 §5 — "Allocation happens at three moments only: show load, a
    /// stack or output change (between ticks, double-buffered so the old pools
    /// serve until the new ones exist) ... A stack or output change is
    /// anything that changes a size below or adds or removes a channel or a
    /// stack: an edit, an undo, a restore or a reload from disk (Spec 5 §2),
    /// and a stack switch onto an output of another size."
    ///
    /// Once a build, after its commands have run and before its plan is made,
    /// so "A new channel or stack gets its textures before the tick that
    /// first draws it" (Spec 5 §2). The sizes are Spec 4 §5's: a stack's from
    /// the outputs showing it, with "The old stack of a running switch keeps
    /// its size until the switch ends"; a channel's its own, or its largest
    /// stack's. What has no texture gets one, what changed size gets a new
    /// one, and what is gone gives its textures up. The new textures are made
    /// first and the tables swapped after, so this build's plan names only
    /// what exists; the old ones are released for a grace after
    /// (`retireGraceFrames`), and the texture table frees nothing the render
    /// thread's plan can still name (Spec 4 §3). A texture that can't be made
    /// is a severe line: what was there goes on serving.
    ///
    /// A deleted channel's runtime goes with it: its content and its sound
    /// are released, as a clear would. Costs nothing on a tick where neither
    /// the roots nor what the outputs show changed.
    func rebuildResources(frame: Int64, launching: Bool = false) {
        lastRebuild = nil
        endSnapshotHolds(frame: frame)
        // A ring a stack had serves one tick more, as the first field of an interlaced output (`sinkPass`).
        if !retiredRings.isEmpty { retiredRings = retiredRings.filter { $0.value.frame == frame } }

        var switching: [Int: Int] = [:]
        for (output, runtime) in model.outputs {
            if let run = runtime.switchRun, !run.isComplete(at: frame) { switching[output] = run.oldStack }
        }
        let showing = model.state.outputs
        guard launching || lastRootsChanged || showing != builtShowing || switching != builtSwitching else { return }
        builtShowing = showing
        builtSwitching = switching
        let wanted = MachineGeometry(library: library, machine: machine, state: model.state, switching: switching)
        var done = Rebuild(frame: frame)

        // Channels: gone, then made or resized.
        let channelNumbers = Set(library.channels.map(\.number))
        for number in Set(channelTextures.keys).union(model.channels.keys).subtracting(channelNumbers).sorted() {
            if channelTextures[number] != nil { done.channelsGone.append(number) }
            dropChannel(number, frame: frame)
        }
        for number in channelNumbers.sorted() {
            let size = wanted.channelSize(number)
            if let texture = channelTextures[number], let snapshot = channelSnapshots[number], pictureSurfaces[number] != nil {
                guard builtSize(texture) != size else { continue }
                guard let made = makeChannelPair(number, size: size) else {
                    done.failed.append("channel \(number)")
                    continue
                }
                // Spec 4 §7 — a transition leaving a frozen picture goes on leaving it: the snapshot it was
                // taken into, or the channel's old texture when the copy was still to come.
                var held: TextureHandle?
                if var runtime = model.channels[number], case .snapshot? = runtime.outgoing, heldSnapshots[number] == nil {
                    let frozen = runtime.snapshotPending ? texture : snapshot
                    heldSnapshots[number] = (frozen, builtSize(frozen) ?? size)
                    runtime.snapshotPending = false
                    model.channels[number] = runtime
                    held = frozen
                }
                for old in [texture, snapshot] where old != held { retire(old, frame: frame) }
                channelTextures[number] = made.texture
                channelSnapshots[number] = made.snapshot
                lastSampled[number] = nil
                done.channelsResized.append(number)
            } else {
                guard let made = makeChannelPair(number, size: size) else {
                    done.failed.append("channel \(number)")
                    continue
                }
                guard let pictures = makeRing(role: .preview, size: ControlLoop.pictureSize, label: { "channel \(number) picture \($0)" }) else {
                    for handle in [made.texture, made.snapshot] { backend.resources.release(handle) }
                    done.failed.append("channel \(number)")
                    continue
                }
                // Whatever an earlier failure left half made goes.
                for old in [channelTextures[number], channelSnapshots[number]].compactMap({ $0 }) + (pictureSurfaces[number] ?? []) {
                    retire(old, frame: frame)
                }
                channelTextures[number] = made.texture
                channelSnapshots[number] = made.snapshot
                pictureSurfaces[number] = pictures
                pictureSlots[number] = nil
                lastSampled[number] = nil
                done.channelsMade.append(number)
            }
        }

        // Stacks: gone, then made or resized.
        let stackNumbers = Set(machine.stacks.map(\.number))
        for number in Set(stackRings.keys).union(previewSurfaces.keys).subtracting(stackNumbers).sorted() {
            done.stacksGone.append(number)
            dropStack(number, frame: frame)
        }
        for number in stackNumbers.sorted() {
            let size = wanted.stackSize(number)
            let previewSize = PixelSize(width: max(16, size.width / 4), height: max(9, size.height / 4))
            let had = stackRings[number]
            let hadSize = had?.first.flatMap(builtSize)
            if had != nil, previewSurfaces[number] != nil, hadSize == size { continue }
            guard let ring = makeRing(role: .stack, size: size, label: { "stack \(number) slot \($0)" }) else {
                done.failed.append("stack \(number)")
                continue
            }
            guard let previews = makeRing(role: .preview, size: previewSize, label: { "stack \(number) preview \($0)" }) else {
                for handle in ring { backend.resources.release(handle) }
                done.failed.append("stack \(number)")
                continue
            }
            for old in (had ?? []) + (previewSurfaces[number] ?? []) { retire(old, frame: frame) }
            if let had, let hadSize {
                retiredRings[number] = (had, frame)
                rescaleBoxRuns(stack: number, from: hadSize, to: size)
                done.stacksResized.append(number)
            } else {
                done.stacksMade.append(number)
            }
            stackRings[number] = ring
            previewSurfaces[number] = previews
            previewSlots[number] = nil
            previewsPlanned[number] = nil
        }

        // Spec 4 §9 — a box that is no longer in its stack takes its transition's memory with it.
        if lastRootsChanged || launching { pruneBoxRuns(frame: frame) }

        // The sizes the textures have: a channel or a stack whose textures couldn't be made keeps the size it had.
        var stackSizes: [Int: PixelSize] = [:]
        for number in stackNumbers { stackSizes[number] = stackRings[number]?.first.flatMap(builtSize) ?? wanted.stackSize(number) }
        var channelSizes: [Int: PixelSize] = [:]
        for number in channelNumbers { channelSizes[number] = channelTextures[number].flatMap(builtSize) ?? wanted.channelSize(number) }
        geometry = MachineGeometry(stackSizes: stackSizes, channelSizes: channelSizes)

        guard !done.isEmpty else { return }
        lastRebuild = done
        if !done.failed.isEmpty {
            log.severe("frame \(frame): no texture could be made for \(done.failed.joined(separator: ", ")); what was there goes on serving")
        }
        if !launching {
            log.info("frame \(frame): textures made again: channels +\(done.channelsMade) -\(done.channelsGone) ~\(done.channelsResized), "
                     + "stacks +\(done.stacksMade) -\(done.stacksGone) ~\(done.stacksResized)")
        }
    }

    /// The size a texture was made at.
    private func builtSize(_ handle: TextureHandle) -> PixelSize? {
        backend.resources.descriptor(handle)?.size
    }

    /// Spec 4 §5 — "Channel render texture ... 1 per channel, plus 1 for
    /// transitions": the channel's texture and its snapshot, or nil when
    /// either can't be made (and then neither is kept).
    private func makeChannelPair(_ number: Int, size: PixelSize) -> (texture: TextureHandle, snapshot: TextureHandle)? {
        let texture = backend.makeTexture(TextureDescriptor(role: .channel, size: size, mipmapped: true, label: "channel \(number)"))
        guard !texture.isNone else { return nil }
        let snapshot = backend.makeTexture(TextureDescriptor(role: .channel, size: size, label: "channel \(number) snapshot"))
        guard !snapshot.isNone else {
            backend.resources.release(texture)
            return nil
        }
        return (texture, snapshot)
    }

    /// Three textures written in turn (Spec 4 §2, Spec 10 §2), or nil when one can't be made.
    private func makeRing(role: TextureRole, size: PixelSize, label: (Int) -> String) -> [TextureHandle]? {
        var ring: [TextureHandle] = []
        for index in 0..<FrameRing.depth {
            let handle = backend.makeTexture(TextureDescriptor(role: role, size: size, label: label(index)))
            guard !handle.isNone else {
                for made in ring { backend.resources.release(made) }
                return nil
            }
            ring.append(handle)
        }
        return ring
    }

    /// Spec 4 §5 — "the old pools serve until the new ones exist", and a
    /// while longer: the sinks present a frame behind the tick, and the
    /// readback thread and the preview topic read on their own time.
    private func retire(_ handle: TextureHandle, frame: Int64) {
        backend.resources.release(handle, afterTick: frame + retireGraceFrames)
    }

    /// A channel that is gone: its runtime, its content and its sound, as a
    /// clear would release them, and its textures.
    private func dropChannel(_ number: Int, frame: Int64) {
        if let runtime = model.channels.removeValue(forKey: number) {
            if case .content(let content)? = runtime.outgoing { release(content, frame: frame) }
            for tail in runtime.soundTails { release(.media(tail.media), frame: frame) }
            release(runtime.live, frame: frame)
        }
        lastSampled[number] = nil
        pictureSlots[number] = nil
        let textures = [channelTextures.removeValue(forKey: number), channelSnapshots.removeValue(forKey: number)].compactMap { $0 }
        for handle in textures + (pictureSurfaces.removeValue(forKey: number) ?? []) { retire(handle, frame: frame) }
        if let held = heldSnapshots.removeValue(forKey: number) { retire(held.texture, frame: frame) }
    }

    private func dropStack(_ number: Int, frame: Int64) {
        for handle in (stackRings.removeValue(forKey: number) ?? []) + (previewSurfaces.removeValue(forKey: number) ?? []) {
            retire(handle, frame: frame)
        }
        previewSlots[number] = nil
        previewsPlanned[number] = nil
    }

    /// Spec 4 §7 — the frozen picture a resized channel's transition was
    /// leaving is held in the texture it was taken in until that transition
    /// ends, or a new one freezes another picture.
    private func endSnapshotHolds(frame: Int64) {
        guard !heldSnapshots.isEmpty else { return }
        for (channel, held) in heldSnapshots {
            if let runtime = model.channels[channel], case .snapshot? = runtime.outgoing, !runtime.snapshotPending { continue }
            retire(held.texture, frame: frame)
            heldSnapshots[channel] = nil
        }
    }

    /// Spec 4 §5 — "The stack's text draws from its previous rasters, scaled,
    /// until the new ones are ready": what each box of a resized stack drew
    /// last, and what it is dissolving from, moved to the new size.
    private func rescaleBoxRuns(stack: Int, from old: PixelSize, to new: PixelSize) {
        guard old.width > 0, old.height > 0, old != new else { return }
        let x = Float(new.width) / Float(old.width)
        let y = Float(new.height) / Float(old.height)
        for (key, var run) in model.boxRuns where key.stack == stack {
            run.previousContent = run.previousContent?.scaled(x: x, y: y)
            run.outgoing = run.outgoing?.scaled(x: x, y: y)
            model.boxRuns[key] = run
        }
    }

    /// The boxes the stacks hold now, by their keys: a run under any other key is of a box that is gone.
    private func pruneBoxRuns(frame: Int64) {
        guard !model.boxRuns.isEmpty else { return }
        var valid: Set<BoxKey> = []
        for stack in machine.stacks {
            for slot in stack.effectiveSlots(library: library) {
                let count = SlotResolver.layout(for: slot, stack: stack, library: library)?.boxes.count ?? 0
                for box in 0..<count { valid.insert(BoxKey(stack: stack.number, slot: slot.channel, box: box)) }
            }
        }
        for (key, run) in model.boxRuns where !valid.contains(key) {
            releaseReplaced(run, afterTick: frame + Int64(PlanRing.depth))
            model.boxRuns[key] = nil
        }
    }

    /// Spec 4 §8 — "the result replaces the cache entry": the rasters a
    /// box's value changes replaced, which it kept while the new value's
    /// raster was missing, go once nothing draws them.
    func releaseReplaced(_ run: BoxRun, afterTick: Int64) {
        for key in run.replaced { text.release(key, afterTick: afterTick) }
    }
}

extension BoxContent {
    /// The same content with its frames scaled, for a stack that changed size.
    func scaled(x: Float, y: Float) -> BoxContent {
        func scale(_ frame: PixelRect) -> PixelRect {
            PixelRect(x: frame.x * x, y: frame.y * y, width: frame.width * x, height: frame.height * y)
        }
        switch self {
        case .pixels(var quad):
            quad.frame = scale(quad.frame)
            return .pixels(quad)
        case .lines(let lines):
            return .lines(lines.map { TextLine(texture: $0.texture, frame: scale($0.frame)) })
        }
    }
}
