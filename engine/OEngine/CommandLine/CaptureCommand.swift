// OEngine — Spec 4 §15, `oengine capture`: the capture rig's judge of the
// DeckLink output, from the card's own input (Area 7, 2026-11-22).

import Foundation
import OCore

extension OEngineCommandLine {
    /// Spec 4 §15 — "The DeckLink output is frame-accurate against the
    /// capture; the 1080i weave ... is verified field-correct ... A/V sync
    /// within one frame on a clapper fixture, measured on the capture": reads
    /// the card's input in `--format` until `--seconds` or Ctrl-C, judges every
    /// frame an engine run with `--stamp-sdi` sent, and writes `capture.json`
    /// and `capture-events.txt` into `--out`. Exit 1 on a failure, 2 when it
    /// can't capture.
    static func capture(_ args: Arguments) throws -> Int32 {
        guard let formatText = args.options["--format"], let format = CaptureFormat.parse(formatText) else {
            fail("capture needs --format, such as 1920x1080p60 or 1920x1080i59.94")
            return 2
        }
        let device: String
        if let named = args.options["--device"] {
            device = named
        } else if let port = SystemDevices.readPorts().first {
            device = port.device
        } else {
            fail("no DeckLink card")
            return 2
        }
        var tickRate = FrameRate(num: 60, den: 1)
        if let text = args.options["--tick-rate"] {
            guard let rate = CaptureFormat.rate(text) else { throw ProcessError.badArgument("--tick-rate", text) }
            tickRate = rate
        }
        let audioChannels = try args.int("--audio-channels") ?? 2
        let seconds = try args.int("--seconds")
        let out = args.optionalURL("--out")
        let expect = CaptureExpectation.of(rate: format.rate, interlaced: format.interlaced, tickRate: tickRate)
        let capture = DeckLinkCapture(format: format, expect: expect)
        if let problem = capture.start(device: device, audioChannels: audioChannels) {
            fail(problem)
            return 2
        }
        print("oengine: capturing \(device) in \(CaptureFormat.name(format)): a frame every \(expect.tickStep) ticks of \(tickRate.num)/\(tickRate.den), "
              + "fields \(expect.fieldStep) apart, \(audioChannels) channels of audio\(seconds.map { " for \($0) s" } ?? " until Ctrl-C")")

        // Ctrl-C or a terminate signal ends the capture; the main thread waits on it, so the sources run on another queue.
        let done = DispatchSemaphore(value: 0)
        var sources: [DispatchSourceSignal] = []
        for number in [SIGINT, SIGTERM] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global(qos: .userInitiated))
            source.setEventHandler { done.signal() }
            source.resume()
            sources.append(source)
        }
        let started = Date()
        var minute = 0
        while true {
            let left = seconds.map { Double($0) - Date().timeIntervalSince(started) }
            if let left, left <= 0 { break }
            let wait = min(60, left ?? 60)
            if done.wait(timeout: .now() + wait) == .success { break }
            if Date().timeIntervalSince(started) >= Double(minute + 1) * 60 {
                minute += 1
                let check = capture.snapshot().check
                print("oengine: capture minute \(minute): \(check.frames) frames, \(check.stamped) stamped, "
                      + "\(check.failures.isEmpty ? "no problem" : check.failures.joined(separator: "; "))")
            }
        }
        capture.stop()
        withExtendedLifetime(sources) {}
        let (check, notes) = capture.snapshot()
        for line in check.lines { print(line) }
        for note in notes { print("capture: " + note) }
        let summary = CaptureSummary(check: check, format: format, notes: notes)
        if let out {
            do {
                try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try (encoder.encode(summary) + Data("\n".utf8)).write(to: out.appendingPathComponent("capture.json"), options: .atomic)
                try Data((check.events.joined(separator: "\n") + "\n").utf8).write(to: out.appendingPathComponent("capture-events.txt"), options: .atomic)
                print("capture: written to \(out.path)")
            } catch {
                fail("could not write the capture's record: \(error)")
            }
        }
        if check.failures.isEmpty {
            print("capture: PASS")
            return 0
        }
        for failure in check.failures { print("FAIL: capture: " + failure) }
        return 1
    }
}
