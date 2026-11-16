// OEngine — Spec 10 §3, the engine's values as one build left them.

import Foundation
import OCore

/// Spec 10 §3 — where timed media stands: "Timed media's duration and
/// position count within its in and out points, so its remaining time is the
/// duration less the position".
public struct MediaTiming: Equatable, Sendable {
    public var durationMs: Int
    public var positionMs: Int
    public var playing: Bool

    public init(durationMs: Int, positionMs: Int, playing: Bool) {
        self.durationMs = durationMs
        self.positionMs = positionMs
        self.playing = playing
    }
}

/// Spec 10 §3 — "an answer reflects every event sent before it": everything
/// a topic's event or a query's answer is made from, copied on the control
/// side when a build has finished. The copies are values (Swift copies them
/// without copying their storage until someone writes), so taking one costs
/// the control thread almost nothing, and a worker can then spend as long as
/// a catalog takes on a moment that no longer moves.
struct ApiSnapshot: Sendable {
    var library: Library
    var machine: Machine
    var state: ShowState
    var kept: KeptCopies
    var frame: Int64
    var rate: FrameRate
    /// Spec 2 §9 — the last line logged when the build finished.
    var seq: Int
    var revision: Int
    var timings: [Int: MediaTiming]
    /// Spec 6 §7 — the popup slots with a clear-after still counting, and the frame each clears at.
    var pendingClears: [Int: Int64]
    var timers: [Int: TimerReading]
    var timerSlots: Int
    var popupSlots: Int
    /// Spec 7 §6 — the live reading, for the `live` event as its topic would send it now.
    var live: LiveSnapshot
    var standings: [Int: OutputStanding]
    /// Spec 10 §3 — for SDI outputs, "its reference (`locked`, `freeRun` or `none`)".
    var references: [Int: String]
    /// Spec 10 §3 — per audio output, "`ok`, `fallback` or `silent`".
    var audioStandings: [Int: String]
    var mutedAudio: Set<Int>
    var mediaFiles: [MediaLocation: MediaFileState]
    var mediaTiles: Set<String>
    var tilesFolder: URL?

    /// Control side, after a build.
    init(engine: Engine) {
        let control = engine.control
        library = control.library
        machine = control.machine
        state = control.model.state
        kept = control.kept
        frame = control.model.frame
        rate = engine.pacing.masterRate
        seq = control.commandLog.lastSeq
        revision = control.revision
        timings = control.mediaTimings(at: frame)
        pendingClears = control.pendingClears
        timers = control.timerReadings(at: frame)
        timerSlots = control.variables.timerSlots
        popupSlots = control.variables.popupSlots
        live = control.lastLive
        standings = engine.outputStandings()
        var references: [Int: String] = [:]
        for output in machine.outputs where output.kind == .sdi {
            if output.genlock == .freeRun {
                references[output.number] = "freeRun"
            } else {
                references[output.number] = (engine.sinks[output.number] as? DeckLinkSink)?.clock?.referenceLocked == true ? "locked" : "none"
            }
        }
        self.references = references
        var audioStandings: [Int: String] = [:]
        for device in engine.audio?.deviceStates ?? [] {
            let name: String
            switch device.standing {
            case .primary: name = "ok"
            case .fallback: name = "fallback"
            case .silent: name = "silent"
            }
            for output in device.outputs { audioStandings[output] = name }
        }
        // An audio output no device plays (an engine run silent, or a device that never opened) is silent.
        for output in machine.audioOutputs where audioStandings[output.number] == nil { audioStandings[output.number] = "silent" }
        self.audioStandings = audioStandings
        mutedAudio = control.mutedAudioOutputs
        mediaFiles = control.mediaFiles
        mediaTiles = control.mediaTiles
        tilesFolder = control.mediaWorker?.tilesFolder
    }

    /// Spec 7 §6 — "The `live` event", as its topic would send it now.
    var liveEvent: JSONValue {
        live.event(frame: Int(frame), rate: rate, seq: seq)
    }

    /// Milliseconds from this snapshot's frame to `frame`, never negative.
    func milliseconds(until frame: Int64) -> Int {
        guard rate.num > 0 else { return 0 }
        let frames = max(0, frame - self.frame)
        return Int((Double(frames) * 1000 * Double(rate.den) / Double(rate.num)).rounded())
    }
}
