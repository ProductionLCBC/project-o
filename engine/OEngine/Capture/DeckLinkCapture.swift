// OEngine — Spec 4 §15, "Three hours on the test bench with capture of both
// outputs": the capture rig's reader. The bench's card has its SDI output
// cabled to its own input (Area 7, 2026-11-22); this reads that input through
// the DeckLink module and hands every frame to the capture check.

import Foundation
import OCore
import ODeckLink

/// Spec 1 §3 — an output `format` named the way a bench names it:
/// `1920x1080p60`, `1920x1080i59.94`, `3840x2160p29.97`. An interlaced
/// format's number is its field rate, as broadcast names it (1080i59.94 is
/// 30000/1001 frames a second); a progressive format's is its frame rate.
public enum CaptureFormat {
    public static func parse(_ text: String) -> VideoFormat? {
        let lower = text.lowercased()
        guard let x = lower.firstIndex(of: "x") else { return nil }
        guard let width = Int(lower[..<x]) else { return nil }
        let rest = lower[lower.index(after: x)...]
        guard let mark = rest.firstIndex(where: { $0 == "p" || $0 == "i" }), let height = Int(rest[..<mark]) else { return nil }
        let interlaced = rest[mark] == "i"
        guard let rate = rate(String(rest[rest.index(after: mark)...])) else { return nil }
        let frameRate = interlaced ? FrameRate(num: rate.num, den: rate.den * 2).reduced : rate
        guard width > 0, height > 0 else { return nil }
        return VideoFormat(width: width, height: height, rate: frameRate, interlaced: interlaced)
    }

    /// `60`, `59.94`, `5994`, `29.97`, `2997`, `23.98`, `25`, or `num/den`.
    static func rate(_ text: String) -> FrameRate? {
        if let slash = text.firstIndex(of: "/") {
            guard let num = Int(text[..<slash]), let den = Int(text[text.index(after: slash)...]), num > 0, den > 0 else { return nil }
            return FrameRate(num: num, den: den).reduced
        }
        switch text {
        case "59.94", "5994": return FrameRate(num: 60000, den: 1001)
        case "29.97", "2997": return FrameRate(num: 30000, den: 1001)
        case "23.98", "23.976", "2398": return FrameRate(num: 24000, den: 1001)
        case "119.88", "11988": return FrameRate(num: 120000, den: 1001)
        default:
            guard let whole = Int(text), whole > 0 else { return nil }
            return FrameRate(num: whole, den: 1)
        }
    }

    /// The name back, as `parse` reads it.
    public static func name(_ format: VideoFormat) -> String {
        let shown = format.interlaced ? FrameRate(num: format.rate.num * 2, den: format.rate.den).reduced : format.rate.reduced
        let number = shown.den == 1 ? "\(shown.num)" : String(format: "%.2f", Double(shown.num) / Double(shown.den))
        return "\(format.width)x\(format.height)\(format.interlaced ? "i" : "p")\(number)"
    }
}

/// Spec 4 §15 — the card's input, every frame read into a `CaptureCheck`.
/// The SDK delivers frames on its own thread; the check is kept under a lock
/// and read with `snapshot`.
public final class DeckLinkCapture: @unchecked Sendable {
    public let format: VideoFormat
    private let lock = NSLock()
    private var check: CaptureCheck
    private var notes: [String] = []
    private var input: OpaquePointer?

    public init(format: VideoFormat, expect: CaptureExpectation) {
        self.format = format
        check = CaptureCheck(expect: expect)
    }

    /// Opens the input of `device` (`decklink:<id>`) and starts reading.
    /// Returns a sentence when it can't.
    public func start(device: String, audioChannels: Int) -> String? {
        let id = device.hasPrefix(DetectedPort.devicePrefix) ? String(device.dropFirst(DetectedPort.devicePrefix.count)) : device
        var opened: OpaquePointer?
        let status = odl_input_open(id, &opened)
        guard status == ODL_OK, let opened else { return "the input of \(device) can't be opened: \(DeckLinkSink.describe(status))" }
        input = opened
        let mode = odl_mode_t(width: Int32(format.width), height: Int32(format.height), rate_num: Int32(format.rate.num),
                              rate_den: Int32(format.rate.den), interlaced: format.interlaced)
        let context = Unmanaged.passUnretained(self).toOpaque()
        let started = odl_input_start(opened, mode, Int32(audioChannels), { context, frame in
            guard let context, let frame else { return }
            Unmanaged<DeckLinkCapture>.fromOpaque(context).takeUnretainedValue().arrived(frame.pointee)
        }, { context, detected in
            guard let context else { return }
            Unmanaged<DeckLinkCapture>.fromOpaque(context).takeUnretainedValue().detected(detected)
        }, context)
        guard started == ODL_OK else {
            odl_input_close(opened)
            input = nil
            return "the input of \(device) didn't start in \(CaptureFormat.name(format)): \(DeckLinkSink.describe(started))"
        }
        return nil
    }

    public func stop() {
        guard let input else { return }
        odl_input_stop(input)
        odl_input_close(input)
        self.input = nil
    }

    /// The check as it stands, and the input's notes (formats it detected).
    public func snapshot() -> (check: CaptureCheck, notes: [String]) {
        lock.lock()
        defer { lock.unlock() }
        return (check, notes)
    }

    private func arrived(_ frame: odl_input_frame_t) {
        let reading: CaptureReading
        if frame.no_signal || frame.bytes == nil || Int(frame.width) != format.width || Int(frame.height) != format.height {
            reading = CaptureReading(signal: false, audio: [])
        } else {
            reading = CaptureReading.read(v210: frame.bytes, rowBytes: Int(frame.row_bytes), width: Int(frame.width), height: Int(frame.height),
                                          audio: frame.audio, audioFrames: Int(frame.audio_frames), audioChannels: Int(frame.audio_channels))
        }
        lock.lock()
        check.observe(reading)
        lock.unlock()
    }

    private func detected(_ mode: odl_mode_t) {
        let format = VideoFormat(width: Int(mode.width), height: Int(mode.height),
                                 rate: FrameRate(num: Int(mode.rate_num), den: Int(mode.rate_den)).reduced, interlaced: mode.interlaced)
        lock.lock()
        if notes.count < 100 { notes.append("the input detected \(CaptureFormat.name(format)) at frame \(check.frames)") }
        lock.unlock()
    }
}

/// Spec 4 §15 — the capture's record of a run, written beside the black box.
public struct CaptureSummary: Codable, Equatable, Sendable {
    public var format: String
    public var tickStep: Int64
    public var fieldStep: Int64
    public var frames: Int64
    public var noSignal: Int64
    public var stamped: Int64
    public var firstTick: UInt32?
    public var lastTick: UInt32?
    public var repeats: Int64
    public var skips: Int64
    public var missingFrames: Int64
    public var offStep: Int64
    public var backwards: Int64
    public var fieldErrors: Int64
    public var unstampedInside: Int64
    public var flashes: Int
    public var clicks: Int
    /// Each clap's click minus its flash, in milliseconds: negative when the sound leads.
    public var clapsMs: [Double]
    public var failures: [String]
    public var events: [String]
    public var notes: [String]

    public init(check: CaptureCheck, format: VideoFormat, notes: [String]) {
        self.format = CaptureFormat.name(format)
        tickStep = check.expect.tickStep
        fieldStep = check.expect.fieldStep
        frames = check.frames
        noSignal = check.noSignal
        stamped = check.stamped
        firstTick = check.firstTick
        lastTick = check.lastTick
        repeats = check.repeats
        skips = check.skips
        missingFrames = check.missingFrames
        offStep = check.offStep
        backwards = check.backwards
        fieldErrors = check.fieldErrors
        unstampedInside = check.unstampedInside
        flashes = check.flashes.count
        clicks = check.clicks.count
        clapsMs = check.claps.map { (Double($0) / 48.0 * 10).rounded() / 10 }
        failures = check.failures
        events = check.events
        self.notes = notes
    }
}
