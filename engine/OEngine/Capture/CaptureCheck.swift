// OEngine — Spec 4 §15, the pass criteria the capture rig judges: "Zero
// dropped and zero displayedLate on the DeckLink output", "The DeckLink output
// is frame-accurate against the capture; the 1080i weave ... is verified
// field-correct", and "A/V sync within one frame on a clapper fixture,
// measured on the capture" (Area 7, from the loopback of 2026-11-22).

import Foundation
import OCore

/// One frame as the card's input delivered it, read for the check: the
/// stamps of the first line of each field (FrameStamp), the picture's mean
/// luma, and channel 0 of the audio that came with it.
public struct CaptureReading: Equatable, Sendable {
    /// False when the card reported no input source for this frame.
    public var signal: Bool
    /// Row 0's stamp, the first field's tick; nil when the line isn't a stamp.
    public var firstField: UInt32?
    /// Row 1's stamp, the second field's tick.
    public var secondField: UInt32?
    /// The mean luma code (64 black to 940 white) over a sparse grid below the stamps.
    public var meanLuma: Int
    /// Channel 0 of the frame's embedded audio, 24 bits in 32 (Spec 4 §10).
    public var audio: [Int32]

    public init(signal: Bool = true, firstField: UInt32? = nil, secondField: UInt32? = nil, meanLuma: Int = 64, audio: [Int32] = []) {
        self.signal = signal
        self.firstField = firstField
        self.secondField = secondField
        self.meanLuma = meanLuma
        self.audio = audio
    }

    /// Reads a v210 frame (Spec 4 §10: four words for six pixels, rows padded
    /// to 128 bytes) and its interleaved audio.
    public static func read(v210 bytes: UnsafeRawPointer, rowBytes: Int, width: Int, height: Int,
                            audio: UnsafePointer<Int32>?, audioFrames: Int, audioChannels: Int) -> CaptureReading {
        let words = bytes.assumingMemoryBound(to: UInt32.self)
        let rowWords = rowBytes / 4
        let stampable = width >= 18 && height >= 2
        let first = stampable ? FrameStamp.read(words) : nil
        let second = stampable ? FrameStamp.read(words + rowWords) : nil
        // Every eighth row from row 8 and every fourth group: the first pixel's Y, the middle ten bits of a group's first word.
        var sum = 0
        var count = 0
        let groups = width / 6
        var y = min(8, max(0, height - 1))
        while y < height {
            var group = 0
            while group < groups {
                sum += Int((words[y * rowWords + group * 4] >> 10) & 0x3FF)
                count += 1
                group += 4
            }
            y += 8
        }
        var channel0: [Int32] = []
        if let audio, audioChannels > 0, audioFrames > 0 {
            channel0.reserveCapacity(audioFrames)
            for frame in 0..<audioFrames { channel0.append(audio[frame * audioChannels]) }
        }
        return CaptureReading(signal: true, firstField: first, secondField: second, meanLuma: count > 0 ? sum / count : 64, audio: channel0)
    }
}

/// What the check expects of the run it watches.
public struct CaptureExpectation: Equatable, Sendable {
    /// Master ticks from one output frame to the next: 1 for 1080p60 on a 60 Hz
    /// tick, 2 for 2160p30 or 1080i60 (Spec 4 §2).
    public var tickStep: Int64
    /// Ticks from a frame's first field to its second: 0 progressive, 1 for
    /// 1080i60 on a 60 Hz tick (Spec 4 §10, the weave).
    public var fieldStep: Int64
    /// One output frame, in nanoseconds: the A/V limit (Spec 4 §15, "within one frame").
    public var frameNs: Int64
    /// A frame whose mean luma reaches this is a flash.
    public var flashLuma: Int = 800
    /// A channel-0 sample this loud (24 bits in 32) is a click: half of full scale.
    public var clickLevel: Int32 = 1 << 30
    /// The quiet a click needs before it, in samples, to count as a new one.
    public var quietSamples: Int = 9_600
    /// How far apart a flash and a click may be and still be one clap, in samples.
    public var pairSamples: Int = 24_000

    public init(tickStep: Int64, fieldStep: Int64, frameNs: Int64) {
        self.tickStep = tickStep
        self.fieldStep = fieldStep
        self.frameNs = frameNs
    }

    /// The expectation for an output of `rate` (its frame rate, Spec 1 §3) on a
    /// master tick of `tickRate` (Spec 4 §2: the highest output rate, fields counted).
    public static func of(rate: FrameRate, interlaced: Bool, tickRate: FrameRate) -> CaptureExpectation {
        // ticks per frame = tickRate / rate
        let step = max(1, Int64(tickRate.num) * Int64(rate.den) / max(1, Int64(tickRate.den) * Int64(rate.num)))
        return CaptureExpectation(tickStep: step, fieldStep: interlaced ? step / 2 : 0,
                                  frameNs: DeckLinkSink.frameDuration(frame: 0, rate: rate))
    }
}

/// Spec 4 §15 — the capture's judgement of a run, frame by frame: every
/// stamped frame once and in order, both fields from the same pair, nothing
/// unstamped between the first stamp and the last, and each clap's click
/// within one frame of its flash. Frames before the first stamp (the engine
/// not yet running) and after the last (the engine stopped, the card holding
/// its last frame) are not judged.
public struct CaptureCheck: Sendable {
    public let expect: CaptureExpectation

    public private(set) var frames: Int64 = 0
    public private(set) var noSignal: Int64 = 0
    public private(set) var stamped: Int64 = 0
    public private(set) var firstTick: UInt32?
    public private(set) var lastTick: UInt32?
    public private(set) var repeats: Int64 = 0
    public private(set) var skips: Int64 = 0
    public private(set) var missingFrames: Int64 = 0
    public private(set) var offStep: Int64 = 0
    public private(set) var backwards: Int64 = 0
    public private(set) var fieldErrors: Int64 = 0
    public private(set) var unstampedInside: Int64 = 0
    /// Each problem as a line, the first few hundred: when (the capture frame and the tick) and what.
    public private(set) var events: [String] = []

    // Held until the next stamped frame says whether they were inside the run.
    private var pendingRepeats: Int64 = 0
    private var pendingUnstamped: Int64 = 0

    // A/V, on the capture's own sample count.
    public private(set) var samples: Int64 = 0
    public private(set) var flashes: [Int64] = []
    public private(set) var clicks: [Int64] = []
    private var lastLoud: Int64 = Int64.min / 2
    private var previousLuma = 0

    public init(expect: CaptureExpectation) {
        self.expect = expect
    }

    private mutating func note(_ line: String) {
        if events.count < 500 { events.append(line) }
    }

    public mutating func observe(_ reading: CaptureReading) {
        let index = frames
        frames += 1
        let frameStart = samples
        defer { samples += Int64(reading.audio.count) }
        // Claps: a flash is the first frame at the flash luma; a click the first loud sample after a quiet.
        if reading.signal {
            if reading.meanLuma >= expect.flashLuma, previousLuma < expect.flashLuma { flashes.append(frameStart) }
            previousLuma = reading.meanLuma
        }
        for (offset, sample) in reading.audio.enumerated() where sample.magnitude >= UInt32(expect.clickLevel) {
            let at = frameStart + Int64(offset)
            if at - lastLoud >= Int64(expect.quietSamples) { clicks.append(at) }
            lastLoud = at
        }
        guard reading.signal else {
            noSignal += 1
            if firstTick != nil { pendingUnstamped += 1 }
            return
        }
        guard let first = reading.firstField, let second = reading.secondField else {
            if firstTick != nil { pendingUnstamped += 1 }
            return
        }
        stamped += 1
        if Int64(Int32(bitPattern: second &- first)) != expect.fieldStep {
            fieldErrors += 1
            note("frame \(index): fields from ticks \(first) and \(second), want \(expect.fieldStep) apart")
        }
        guard let last = lastTick else {
            firstTick = second
            lastTick = second
            return
        }
        let delta = Int64(Int32(bitPattern: second &- last))
        if delta == 0 {
            pendingRepeats += 1
            return
        }
        // A new tick: whatever was held was inside the run.
        if pendingRepeats > 0 {
            repeats += pendingRepeats
            note("frame \(index): tick \(last) shown \(pendingRepeats + 1) times")
        }
        if pendingUnstamped > 0 {
            unstampedInside += pendingUnstamped
            note("frame \(index): \(pendingUnstamped) frames without a stamp before tick \(second)")
        }
        pendingRepeats = 0
        pendingUnstamped = 0
        if delta < 0 {
            backwards += 1
            note("frame \(index): tick \(second) after \(last)")
        } else if delta != expect.tickStep {
            if delta % expect.tickStep == 0 {
                skips += 1
                missingFrames += delta / expect.tickStep - 1
                note("frame \(index): tick \(second) after \(last), \(delta / expect.tickStep - 1) frames missing")
            } else {
                offStep += 1
                note("frame \(index): tick \(second) after \(last), not a multiple of \(expect.tickStep)")
            }
        }
        lastTick = second
    }

    /// One clap: the click's offset from the start of its flash frame, in
    /// samples at 48 kHz; negative when the sound leads the picture.
    public var claps: [Int64] {
        var offsets: [Int64] = []
        var used = Set<Int>()
        for flash in flashes {
            var best: (index: Int, distance: Int64)?
            for (index, click) in clicks.enumerated() where !used.contains(index) {
                let distance = abs(click - flash)
                if distance <= Int64(expect.pairSamples), distance < (best?.distance ?? .max) { best = (index, distance) }
            }
            if let best {
                used.insert(best.index)
                offsets.append(clicks[best.index] - flash)
            }
        }
        return offsets
    }

    /// One frame at 48 kHz: the A/V limit in samples.
    public var frameSamples: Int64 { expect.frameNs * 48_000 / 1_000_000_000 }

    /// The failures, each a line; empty when the run passed.
    public var failures: [String] {
        var out: [String] = []
        if stamped == 0 { out.append("no stamped frame was captured") }
        if repeats > 0 { out.append("\(repeats) frames shown again") }
        if skips > 0 { out.append("\(skips) skips, \(missingFrames) frames missing") }
        if offStep > 0 { out.append("\(offStep) frames off the output's step") }
        if backwards > 0 { out.append("\(backwards) frames out of order") }
        if fieldErrors > 0 { out.append("\(fieldErrors) frames with fields from the wrong pair") }
        if unstampedInside > 0 { out.append("\(unstampedInside) frames without a stamp inside the run") }
        let late = claps.filter { abs($0) >= frameSamples }
        if !late.isEmpty { out.append("\(late.count) of \(claps.count) claps a frame or more apart: \(late.prefix(5).map(CaptureCheck.ms).joined(separator: ", "))") }
        return out
    }

    static func ms(_ samples: Int64) -> String { String(format: "%+.1f ms", Double(samples) / 48.0) }

    /// The report, a line each.
    public var lines: [String] {
        var out = ["capture: \(frames) frames, \(noSignal) without a signal, \(stamped) stamped from tick \(firstTick.map(String.init) ?? "-") to \(lastTick.map(String.init) ?? "-")",
                   "capture: \(repeats) shown again, \(skips) skips (\(missingFrames) missing), \(offStep) off step, \(backwards) out of order, \(fieldErrors) field errors, \(unstampedInside) unstamped inside"]
        let offsets = claps.sorted()
        if offsets.isEmpty {
            out.append("capture: no clap (\(flashes.count) flashes, \(clicks.count) clicks)")
        } else {
            let median = offsets[offsets.count / 2]
            out.append("capture: \(offsets.count) claps, click minus flash \(CaptureCheck.ms(offsets.first ?? 0)) to \(CaptureCheck.ms(offsets.last ?? 0)), median \(CaptureCheck.ms(median)); limit one frame, \(CaptureCheck.ms(frameSamples)) (\(flashes.count) flashes, \(clicks.count) clicks)")
        }
        return out
    }
}
