// OApp — Spec 10 §4, "View settings" (S8): `machine/view.json`, read at launch and written a second after the last change.

import Foundation

/// Spec 10 §4 — "View settings (S8) are in `machine/view.json` ... The app
/// writes the file a second after the last change, atomically (Spec 1 §5).
/// The machine root is never synced, so it stays with the machine. It isn't
/// a document of Spec 1 §5: it carries no header and no schema promises,
/// unknown keys are ignored, a file that doesn't read means defaults".
public enum ViewSettingsFile {
    public static let name = "view.json"

    public static func url(machineRoot: URL) -> URL {
        machineRoot.appendingPathComponent(name)
    }

    /// The settings the file holds; the defaults when there is no file, or it doesn't read.
    public static func read(machineRoot: URL) -> ViewSettings {
        guard let data = try? Data(contentsOf: url(machineRoot: machineRoot)) else { return ViewSettings() }
        return settings(from: data)
    }

    public static func settings(from data: Data) -> ViewSettings {
        (try? JSONDecoder().decode(ViewSettings.self, from: data)) ?? ViewSettings()
    }

    /// The file's bytes, as the repository writes JSON: sorted keys, two-space indent, LF.
    public static func data(_ settings: ViewSettings) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(settings)
        data.append(0x0A)
        return data
    }

    /// Writes the file atomically: a reader sees the old file or the new
    /// one, never a part of either. It is the one file the app writes in the
    /// roots (Spec 10 §1), and it never makes the machine folder: an engine's
    /// first run makes that (§13). Says whether it wrote.
    @discardableResult
    public static func write(_ settings: ViewSettings, machineRoot: URL) -> Bool {
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: machineRoot.path, isDirectory: &isFolder), isFolder.boolValue,
              let data = try? data(settings) else { return false }
        return (try? data.write(to: url(machineRoot: machineRoot), options: .atomic)) != nil
    }
}

/// Spec 10 §4 — "The app writes the file a second after the last change":
/// each change puts the write off, so a divider being dragged writes once,
/// when it rests.
@MainActor
public final class ViewSettingsSaver {
    /// "a second after the last change".
    public static let delay: TimeInterval = 1

    private let clock: any AppClock
    /// Writes the settings; false when it couldn't, and the next change or a flush tries again.
    private let write: (ViewSettings) -> Bool
    private var waiting: ViewSettings?
    private var task: (any ClockTask)?

    public init(clock: any AppClock, write: @escaping (ViewSettings) -> Bool) {
        self.clock = clock
        self.write = write
    }

    /// The settings changed.
    public func changed(_ settings: ViewSettings) {
        waiting = settings
        task?.cancel()
        task = clock.after(Self.delay) { [weak self] in self?.flush() }
    }

    /// Writes now what is waiting, as the app does before it quits.
    public func flush() {
        task?.cancel()
        task = nil
        guard let settings = waiting else { return }
        if write(settings) { waiting = nil }
    }

    /// Whether a change hasn't been written yet.
    public var isWaiting: Bool { waiting != nil }
}
