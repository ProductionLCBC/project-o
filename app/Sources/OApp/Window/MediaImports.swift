// OApp — Spec 10 §6, §7 and Spec 8 §3, importing: the staging copy, `media import`, the jobs the pool's header shows, and what waits on an import.

import Foundation
import OCore

/// Spec 10 §6 — "the drop channel for the kind the file's type suggests".
/// The engine finds a file's kind by opening it (Spec 8 §3); before it has,
/// the app goes by the name (Area 13 reading), and a name that suggests
/// nothing asks for a channel.
public enum FileKind {
    private static let kinds: [String: MediaKind] = [
        "mov": .video, "mp4": .video, "m4v": .video,
        "png": .image, "jpg": .image, "jpeg": .image, "heic": .image, "tif": .image, "tiff": .image, "gif": .image,
        "wav": .audio, "aif": .audio, "aiff": .audio, "m4a": .audio, "mp3": .audio,
    ]

    public static func suggested(forPath path: String) -> MediaKind? {
        kinds[(path as NSString).pathExtension.lowercased()]
    }

    /// The machine's drop channel for that kind (Spec 8 §8), or nil for "Ask".
    public static func dropChannel(forPath path: String, settings: MachineSettings?) -> Int? {
        switch suggested(forPath: path) {
        case .video?: return settings?.dropChannels?.video
        case .image?: return settings?.dropChannels?.image
        case .audio?: return settings?.dropChannels?.audio
        default: return nil
        }
    }
}

/// What a channel holds, as far as telling whether "a write or a clear has
/// reached the channel since the drop" (Spec 10 §7): its content and what
/// put it there. A refire that writes the same content from the same cue
/// leaves the channel as it was, and isn't told apart (Area 13 reading).
public struct ChannelStamp: Equatable, Sendable {
    var content: ChannelContent.Kind?
    var provenance: Provenance?

    public init(_ status: ChannelStatus?) {
        content = status?.content?.kind
        provenance = status?.provenance
    }
}

/// What waits on an import: "When the job's `done` names the item,
/// `imported` or `known`, the app sends ..." (Spec 10 §6, §7; choice U-8).
public enum PendingImport: Equatable, Sendable {
    /// "the edit a pool tile's drop sends (§10). The pending edit follows
    /// the cue by its uuid, and nothing is sent if by then the cue is gone
    /// or what it writes on that channel has changed."
    case cue(listUuid: String, cue: String, channel: Int, was: CueSays)
    /// "sends the live write when the job's `done` names the item ...
    /// Nothing is sent if a write or a clear has reached the channel since the drop".
    case live(channel: Int, was: ChannelStamp)
    /// "sends `media replace OLD NEW` when the import's `done` names the new id" (Spec 8 §6).
    case replace(old: String)
}

/// Why what waited on an import wasn't sent.
public enum NotSent: Equatable, Sendable {
    case cueGone
    /// "what it writes on that channel has changed".
    case cueChanged(channel: Int)
    /// "Not sent: channel 2 changed while importing".
    case channelChanged(channel: Int)
    /// "the engine ending drops it too and may lose the import, so the cell says to drop the file again".
    case engineEnded
}

/// One row of the pool header's jobs: a file on its way in.
public struct ImportRow: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        /// The app is copying it to the staging folder (Spec 8 §3, "Staged").
        case copying
        /// The engine has it; its progress, when it has said.
        case importing(progress: Double?)
        /// "`imported` or `known`".
        case done(known: Bool)
        /// The engine refused it, with its reason's code.
        case refused(String)
        /// The copy failed, with the system's words.
        case copyFailed(String)
        /// There was no engine to import it, or it ended meanwhile.
        case engineAway
        /// It came in, and what waited on it wasn't sent.
        case notSent(NotSent)
    }

    public let id: Int
    public var name: String
    public var state: State
    /// The engine's name for the job, once its result gives it.
    var job: String?
    /// Whether an event has named this row's file yet.
    var isNamed = false
    var pending: PendingImport?
    /// Whether Cancel is offered: something waits on it.
    public var canCancel: Bool { pending != nil && !isOver }

    /// Whether it is finished, one way or another.
    public var isOver: Bool {
        switch state {
        case .copying, .importing: return false
        default: return true
        }
    }

    /// "keeps refusals, with their reasons, until dismissed": a row that ended well leaves by itself.
    public var staysUntilDismissed: Bool {
        if case .done = state { return false }
        return isOver
    }
}

/// What a cue's cell or a strip's cell says about a drop (Spec 10 §6, §7).
public enum DropNote: Equatable, Sendable {
    /// "showing the copy's progress".
    case copying(row: Int)
    /// "the cell shows the import's progress from the `media` topic, by the `job` its result names, with Cancel".
    case importing(row: Int, progress: Double?)
    case refused(String)
    case copyFailed(String)
    case notSent(NotSent)
    /// The drop itself was refused: the lock, a cue that takes no edit, or
    /// "several files, or a folder, are refused there, and the cell says to drop them on the pool."
    case cannot(CannotEdit)

    /// The row whose Cancel the cell offers.
    public var row: Int? {
        switch self {
        case .copying(let row), .importing(let row, _): return row
        default: return nil
        }
    }
}

/// Spec 8 §3, "Staged" — "A file dropped from outside both folders is first
/// copied by the app into its staging folder ..., outside both roots, and
/// imported from there". How a file gets there: a seam, so a test copies nothing.
public protocol MediaStager: AnyObject {
    /// Hands back the path to import: the copy's, or the file's own when it needn't be copied.
    @MainActor func stage(_ path: String, done: @escaping @MainActor (Result<String, StagingError>) -> Void)
}

public struct StagingError: Error, Equatable, Sendable {
    public var message: String

    public init(_ message: String) {
        self.message = message
    }
}

/// Spec 10 §6, "Importing" — "Files dropped on the pool from outside, or
/// chosen with Import…, are copied into the staging folder and imported with
/// `media import "PATH"` (Spec 8 §3). The header shows the jobs as the
/// `media` topic reports them, each file's progress and outcome, and keeps
/// refusals, with their reasons, until dismissed."
@MainActor
public final class MediaImports {
    private unowned let model: ShowModel
    public var stager: (any MediaStager)?
    /// Whether a dropped path is a folder; a test says so itself.
    public var isFolder: (String) -> Bool = { path in
        var folder: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &folder) && folder.boolValue
    }
    public private(set) var rows: [ImportRow] = []
    /// What each cue's cell says, by its list's and its own uuid; and each strip cell, by its channel.
    public private(set) var cueNotes: [String: DropNote] = [:]
    public private(set) var stripNotes: [Int: DropNote] = [:]
    private var nextID = 0
    private var early: [String: [MediaEvent]] = [:]
    private var noteTasks: [String: any ClockTask] = [:]

    /// How long a cell's last word stays, and a row that ended well.
    public static let seconds: TimeInterval = 5

    init(model: ShowModel) {
        self.model = model
    }

    public static func key(list: String, cue: String) -> String { list + "/" + cue }

    // MARK: - Starting an import

    /// Why no file can be imported now: the engine is away or silent, or the lock is on (Spec 8 §2).
    public var cannotImport: Unavailable? { model.store.cannotEdit(master: false) }

    /// Files dropped on the pool, or chosen with Import…: each is a row of its own. A folder is one row until its files are named.
    @discardableResult
    public func importFiles(_ paths: [String]) -> CannotEdit? {
        if let cannot = cannotImport { return .unavailable(cannot) }
        for path in paths { start(path, pending: nil) }
        return nil
    }

    /// A file dropped on a cue, once its channel is chosen (Spec 10 §6, "Drops on the grid").
    @discardableResult
    public func importFile(_ path: String, intoCue cell: CueCell, in section: GridSection, channel: Int) -> CannotEdit? {
        if let cannot = model.cueContext(cell, in: section).edit { return cannot }
        guard let listUuid = section.listUuid, let found = model.cue(cell, in: section) else { return .missing }
        start(path, pending: .cue(listUuid: listUuid, cue: cell.uuid, channel: channel, was: CueSays.about(channel, in: found.cue)))
        return nil
    }

    /// A file dropped on a strip cell (Spec 10 §7, "Drops").
    @discardableResult
    public func importFile(_ path: String, liveOn channel: Int) -> CannotEdit? {
        if let cannot = cannotImport { return .unavailable(cannot) }
        start(path, pending: .live(channel: channel, was: ChannelStamp(model.store.channels[channel])))
        return nil
    }

    /// Replace with… (Spec 10 §6, "A tile's menu").
    @discardableResult
    public func importFile(_ path: String, replacing old: String) -> CannotEdit? {
        if let cannot = cannotImport { return .unavailable(cannot) }
        start(path, pending: .replace(old: old))
        return nil
    }

    private func start(_ path: String, pending: PendingImport?) {
        nextID += 1
        let id = nextID
        rows.append(ImportRow(id: id, name: (path as NSString).lastPathComponent, state: .copying, pending: pending))
        tell(id)
        guard let stager else { return finish(id, .copyFailed("")) }
        stager.stage(path) { [weak self] result in
            guard let self, let index = self.index(id), !self.rows[index].isOver else { return }
            switch result {
            case .failure(let error): self.finish(id, .copyFailed(error.message))
            case .success(let staged): self.send(id, staged)
            }
        }
    }

    private func index(_ id: Int) -> Int? {
        rows.firstIndex { $0.id == id }
    }

    private func send(_ id: Int, _ path: String) {
        guard let index = index(id) else { return }
        guard model.store.cannotSend == nil, let transmit = model.transmit else { return finish(id, .engineAway) }
        rows[index].state = .importing(progress: nil)
        tell(id)
        transmit(.command(.media(.importFile(path: path)), source: .ui)) { [weak self] reply in
            guard let self, let index = self.index(id), !self.rows[index].isOver else { return }
            guard let outcome = reply?.outcome else { return self.finish(id, .engineAway) }
            if outcome.kind == .rejected { return self.finish(id, .refused(outcome.rejection?.code ?? "")) }
            guard let job = outcome.job else { return }
            self.rows[index].job = job
            // What the job said before its result named it.
            for event in self.early.removeValue(forKey: job) ?? [] { self.event(event) }
        }
    }

    // MARK: - What the engine says (Spec 8 §7, the `media` topic)

    func event(_ event: MediaEvent) {
        guard event.op == "import", let job = event.job else { return }
        guard rows.contains(where: { $0.job == job }) else {
            if early.count < 32 { early[job, default: []].append(event) }
            return
        }
        let file = event.file ?? ""
        let index: Int
        if let named = rows.firstIndex(where: { $0.job == job && $0.isNamed && $0.name == file }) {
            index = named
        } else if let first = rows.firstIndex(where: { $0.job == job && !$0.isNamed }) {
            // The row made when the file was dropped is the first file the engine names.
            index = first
            if !file.isEmpty { rows[index].name = file }
            rows[index].isNamed = true
        } else {
            // A folder's next file: a row of its own, with nothing waiting on it.
            nextID += 1
            rows.append(ImportRow(id: nextID, name: file, state: .importing(progress: nil), job: job, isNamed: true))
            index = rows.count - 1
        }
        let id = rows[index].id
        guard !rows[index].isOver else { return }
        guard event.isDone else {
            rows[index].state = .importing(progress: event.progress)
            return tell(id)
        }
        switch event.outcome {
        case "imported", "known":
            imported(id, media: event.id ?? "", known: event.outcome == "known")
        case "refused":
            finish(id, .refused(event.reason ?? ""))
        default:
            finish(id, .refused(event.outcome ?? ""))
        }
    }

    /// The file is in the pool: what waited on it is sent, or said not to have been.
    private func imported(_ id: Int, media: String, known: Bool) {
        guard let index = index(id) else { return }
        let pending = rows[index].pending
        var failure: NotSent?
        let grade = model.store.media.first { $0.id == media }?.entry.defaults.grade
        switch pending {
        case nil:
            break
        case .cue(let listUuid, let cueUuid, let channel, let was)?:
            if let list = model.store.lists[listUuid]?.list, let cue = list.cues.first(where: { $0.uuid.uuidString.lowercased() == cueUuid }) {
                if CueSays.about(channel, in: cue) == was {
                    model.edit(Edits.write(media: media, defaultGrade: grade, on: channel, cue: cue, list: list.number), at: .grid)
                } else {
                    failure = .cueChanged(channel: channel)
                }
            } else {
                failure = .cueGone
            }
        case .live(let channel, let was)?:
            if ChannelStamp(model.store.channels[channel]) == was {
                model.goLive(imported: media, on: channel, defaultGrade: grade)
            } else {
                failure = .channelChanged(channel: channel)
            }
        case .replace(let old)?:
            model.edit(Edits.replaceMedia(old: old, new: media), at: .pool)
        }
        finish(id, failure.map(ImportRow.State.notSent) ?? .done(known: known))
    }

    // MARK: - Ending

    private func finish(_ id: Int, _ state: ImportRow.State) {
        guard let index = index(id) else { return }
        rows[index].state = state
        tell(id)
        rows[index].pending = nil
        if !rows[index].staysUntilDismissed {
            // A row that ended well leaves by itself.
            model.later(Self.seconds) { [weak self] in
                self?.rows.removeAll { $0.id == id }
                self?.model.changed([.pool])
            }
        }
    }

    /// "Cancel drops the pending edit, and the import still finishes into the pool".
    public func cancel(row id: Int) {
        guard let index = index(id), rows[index].pending != nil else { return }
        clearNote(for: rows[index].pending)
        rows[index].pending = nil
        model.changed([.pool, .dropNotes])
    }

    /// A refusal is dismissed.
    public func dismiss(row id: Int) {
        rows.removeAll { $0.id == id && $0.isOver }
        model.changed([.pool])
    }

    public func dismissAll() {
        rows.removeAll(where: \.isOver)
        model.changed([.pool])
    }

    /// "the engine ending drops it too and may lose the import, so the cell says to drop the file again."
    func engineEnded() {
        early = [:]
        for row in rows where !row.isOver {
            if row.pending != nil {
                finish(row.id, .notSent(.engineEnded))
            } else {
                finish(row.id, .engineAway)
            }
        }
    }

    // MARK: - What the cells say

    /// Says something on a cue's cell that isn't about an import: a refusal of the drop itself.
    public func say(_ note: DropNote, onCue key: String) {
        cueNotes[key] = note
        expire("cue:" + key) { [weak self] in self?.cueNotes[key] = nil }
        model.changed([.dropNotes])
    }

    public func say(_ note: DropNote, onChannel channel: Int) {
        stripNotes[channel] = note
        expire("strip:\(channel)") { [weak self] in self?.stripNotes[channel] = nil }
        model.changed([.dropNotes])
    }

    private func expire(_ name: String, _ clear: @escaping @MainActor () -> Void) {
        noteTasks[name]?.cancel()
        noteTasks[name] = model.later(Self.seconds) { [weak self] in
            clear()
            self?.noteTasks[name] = nil
            self?.model.changed([.dropNotes])
        }
    }

    private func clearNote(for pending: PendingImport?) {
        switch pending {
        case .cue(let list, let cue, _, _)?:
            let key = Self.key(list: list, cue: cue)
            cueNotes[key] = nil
            noteTasks["cue:" + key]?.cancel()
        case .live(let channel, _)?:
            stripNotes[channel] = nil
            noteTasks["strip:\(channel)"]?.cancel()
        default:
            break
        }
    }

    /// Brings the pool's header, and the cell the row's drop landed on, up to date with the row.
    private func tell(_ id: Int) {
        guard let index = index(id) else { return }
        let row = rows[index]
        var note: DropNote?
        var lasts = false
        switch row.state {
        case .copying: note = .copying(row: id)
        case .importing(let progress): note = .importing(row: id, progress: progress)
        case .done: note = nil
        case .refused(let reason):
            note = .refused(reason)
            lasts = true
        case .copyFailed(let message):
            note = .copyFailed(message)
            lasts = true
        case .engineAway:
            note = .notSent(.engineEnded)
            lasts = true
        case .notSent(let why):
            note = .notSent(why)
            lasts = true
        }
        switch row.pending {
        case .cue(let list, let cue, _, _)?:
            let key = Self.key(list: list, cue: cue)
            cueNotes[key] = note
            noteTasks["cue:" + key]?.cancel()
            if lasts { expire("cue:" + key) { [weak self] in self?.cueNotes[key] = nil } }
        case .live(let channel, _)?:
            stripNotes[channel] = note
            noteTasks["strip:\(channel)"]?.cancel()
            if lasts { expire("strip:\(channel)") { [weak self] in self?.stripNotes[channel] = nil } }
        default:
            break
        }
        model.changed([.pool, .dropNotes])
    }
}
