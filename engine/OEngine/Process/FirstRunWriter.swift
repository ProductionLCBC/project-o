// OEngine — Spec 10 §13, first run: writing the defaults.

import Foundation
import OCore
import OFormats

/// Spec 10 §13 — "The engine writes the defaults (C1: the app never writes in
/// the roots). At launch, when the library root has no `library.json`, it
/// writes the first-run library ... When the machine root has no
/// `machine.json`, it writes [the machine's documents] ... A machine root
/// with `machine.json` but a library root without `library.json`, or the
/// other way round, gets only the missing side." Spec 10 §2 — "It writes any
/// first-run documents before Spec 9 §4's first step". Spec 10 §18, Area 19 —
/// "The engine writes §13's defaults once and never over existing files".
///
/// What is written is `FirstRun`'s, in OCore; this is the part that touches
/// the disk. Each document is a new file, written whole and synced before it
/// takes its name, and one that is already there is left as it is. A side's
/// own `library.json` or `machine.json` goes last, so a launch that was cut
/// short finds the side still missing and finishes it.
///
/// Adam's answers of 2026-11-15: the machine side needs `--campus` and
/// `--operator-screen`, which the app always gives, and a launch without them
/// on a root with no `machine.json` is refused with nothing written; the
/// library side alone needs neither, and takes its name from the machine's
/// own campus.
public enum FirstRunWriter {
    public struct Request: Sendable {
        public var libraryRoot: URL
        public var machineRoot: URL
        /// `--campus`.
        public var campus: String?
        /// `--operator-screen`: the screen holding the app's window, as `display:<uuid>`.
        public var operatorScreen: String?
        /// "the Mac's time zone", as its identifier.
        public var timeZone: String

        public init(libraryRoot: URL, machineRoot: URL, campus: String? = nil, operatorScreen: String? = nil,
                    timeZone: String = TimeZone.current.identifier) {
            self.libraryRoot = libraryRoot
            self.machineRoot = machineRoot
            self.campus = campus
            self.operatorScreen = operatorScreen
            self.timeZone = timeZone
        }
    }

    /// What one launch's first run came to.
    public struct Written: Equatable, Sendable {
        /// The documents written, by their paths in each root.
        public var library: [String] = []
        public var machine: [String] = []
        /// Documents that were already there, and were left as they were.
        public var kept: [String] = []
        /// The machine as it was made, for the lines the launch prints.
        public var outputs: [Output] = []

        public init() {}
    }

    public enum Outcome: Equatable, Sendable {
        /// Both roots have their documents: nothing was written.
        case nothing
        case wrote(Written)
        /// A launch that can't do first run as it was asked: nothing was written.
        case refused(String)
        /// A write failed; what was written before it stays, and the next launch goes on from there.
        case failed(String)
    }

    /// Which sides have no documents yet.
    public static func missing(libraryRoot: URL, machineRoot: URL) -> (library: Bool, machine: Bool) {
        let files = FileManager.default
        return (!files.fileExists(atPath: libraryRoot.appendingPathComponent("library.json").path),
                !files.fileExists(atPath: machineRoot.appendingPathComponent("machine.json").path))
    }

    /// Why this launch can't do the first run it would have to do, or nil.
    /// Reads two file names and writes nothing, so it is asked before the
    /// machine root is locked or made.
    public static func refusal(_ request: Request) -> String? {
        guard missing(libraryRoot: request.libraryRoot, machineRoot: request.machineRoot).machine else { return nil }
        let root = request.machineRoot.path
        guard let campus = request.campus, !campus.isEmpty, let screen = request.operatorScreen else {
            return "\(root) has no machine.json, and first run needs --campus <name> and --operator-screen display:<uuid>, which the app gives; nothing was written"
        }
        guard DetectedScreen.uuid(ofDevice: screen).map({ !$0.isEmpty }) == true else {
            return "--operator-screen names the screen holding the app's window as display:<uuid> (oengine devices lists them); nothing was written"
        }
        return nil
    }

    /// Writes whichever side is missing. `devices` is asked only when the
    /// machine side is written.
    public static func run(_ request: Request, devices: () -> DetectedDevices, uuid: () -> UUID = { UUID() }) -> Outcome {
        let needs = missing(libraryRoot: request.libraryRoot, machineRoot: request.machineRoot)
        guard needs.library || needs.machine else { return .nothing }
        if let refusal = refusal(request) { return .refused(refusal) }
        // The campus: the one the launch names, else the machine's own.
        let campus = request.campus ?? campusName(machineRoot: request.machineRoot) ?? ""
        var written = Written()
        do {
            if needs.library {
                let library = FirstRun.library(name: FirstRun.libraryName(campus: campus), uuid: uuid)
                // "`media/` with `imports/` as the default import folder and `fonts/`" (Spec 1 §5: both under `media/`).
                for folder in ["media/imports", "media/fonts"] {
                    try FileManager.default.createDirectory(at: request.libraryRoot.appendingPathComponent(folder), withIntermediateDirectories: true)
                }
                try write(Writer.snapshot(of: library).files, last: "library.json", in: request.libraryRoot, written: &written.library, kept: &written.kept)
            }
            if needs.machine {
                let mediaRoot = relativePath(from: request.machineRoot, to: request.libraryRoot.appendingPathComponent("media"))
                let machine = FirstRun.machine(FirstRun.MachineRequest(campus: campus, timeZone: request.timeZone, mediaRoot: mediaRoot, devices: devices(),
                                                                       operatorScreen: request.operatorScreen), uuid: uuid)
                try write(Writer.snapshot(of: machine).files, last: "machine.json", in: request.machineRoot, written: &written.machine, kept: &written.kept)
                written.outputs = machine.outputs
            }
        } catch {
            return .failed("first run could not write its documents: \(error)")
        }
        return .wrote(written)
    }

    /// Each document as a new file, the side's own document last; one that is there already is kept.
    private static func write(_ files: [String: Data], last: String, in root: URL, written: inout [String], kept: inout [String]) throws {
        for path in files.keys.sorted().filter({ $0 != last }) + [last] {
            guard let data = files[path] else { continue }
            if FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path) {
                kept.append(path)
                continue
            }
            do {
                try LocalFiles.execute(WritePlan(operations: [.create(path: path, data: data)]), in: root)
                written.append(path)
            } catch let error as FileError where error.code == EEXIST {
                // Something made it between the look and the write: it is kept, like any that was there.
                kept.append(path)
            }
        }
    }

    /// The campus name a machine root's own `machine.json` holds.
    static func campusName(machineRoot: URL) -> String? {
        guard let data = try? Data(contentsOf: machineRoot.appendingPathComponent("machine.json")),
              let name = (try? JSONValue.parse(data))?.objectValue?["campusName"]?.stringValue, !name.isEmpty else { return nil }
        return name
    }

    /// Spec 10 §13 — "`mediaRoot` the path from the machine root to the
    /// library root's `media/`: `../library/media` in the default layout".
    static func relativePath(from folder: URL, to target: URL) -> String {
        let from = folder.standardizedFileURL.pathComponents, to = target.standardizedFileURL.pathComponents
        var shared = 0
        while shared < from.count, shared < to.count, from[shared] == to[shared] { shared += 1 }
        let parts = Array(repeating: "..", count: from.count - shared) + to[shared...]
        return parts.isEmpty ? "." : parts.joined(separator: "/")
    }

    /// The lines a launch prints of what first run wrote: the roots, and
    /// Spec 10 §13's "names each new output (\"Output 1 is DELL U2720Q\")".
    public static func lines(_ written: Written, request: Request) -> [String] {
        var lines: [String] = []
        if !written.library.isEmpty { lines.append("first run: wrote the library's \(written.library.count) documents in \(request.libraryRoot.path)") }
        if !written.machine.isEmpty {
            lines.append("first run: wrote the machine's \(written.machine.count) documents in \(request.machineRoot.path)")
            if written.outputs.isEmpty {
                lines.append("first run: no outputs, since this Mac has no screen beside the app's and no card; stack 1 shows in the preview")
            }
            for output in written.outputs { lines.append("first run: output \(output.number) is \(output.label)") }
        }
        for path in written.kept { lines.append("first run: \(path) was already there and was left as it was") }
        return lines
    }
}
