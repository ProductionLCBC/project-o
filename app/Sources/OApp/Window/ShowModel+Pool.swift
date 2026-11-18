// OApp — Spec 10 §6, §7 and §10: drops on a cue, a strip cell and the pool, and a pool tile's menu.

import Foundation
import OCore

extension ShowModel {
    // MARK: - Drops on a cue (Spec 10 §6, "Drops on the grid"; §10)

    /// What a drag let go on a cue's cell would do, as the machine stands now.
    public func plan(_ payload: DragPayload, ontoCue cell: CueCell, in section: GridSection) -> DropPlan {
        Drops.plan(payload, ontoCue: cueContext(cell, in: section).edit, media: store.media, settings: store.catalog?.settings, isFolder: imports.isFolder)
    }

    /// A drag was let go on a cue's cell. Hands back what waits for a
    /// channel, for the popover; a refusal is said on the cell.
    public func land(_ plan: DropPlan, onCue cell: CueCell, in section: GridSection) -> CueDrop? {
        switch plan {
        case .chooseChannel(let drop):
            return drop
        case .refused(let reason):
            if let list = section.listUuid { imports.say(.cannot(reason), onCue: MediaImports.key(list: list, cue: cell.uuid)) }
            return nil
        default:
            return nil
        }
    }

    /// The channel popover's answer: "Return or a click sends one
    /// `edit.cueChannel` writing the item on that channel", or, for a file,
    /// copies and imports it and sends that edit "once its import is done".
    public func write(_ drop: CueDrop, into cell: CueCell, in section: GridSection, channel: Int) {
        var refusal: CannotEdit?
        switch drop.source {
        case .media(let id):
            if let cannot = cueContext(cell, in: section).edit {
                refusal = cannot
            } else if let found = cue(cell, in: section), let item = store.media.first(where: { $0.id == id }) {
                refusal = commit(Edits.write(media: id, defaultGrade: item.entry.defaults.grade, on: channel, cue: found.cue, list: found.list), master: true, at: .grid)
                if refusal == nil { used(media: id) }
            } else {
                refusal = .missing
            }
        case .file(let path):
            refusal = imports.importFile(path, intoCue: cell, in: section, channel: channel)
        }
        if let refusal, let list = section.listUuid { imports.say(.cannot(refusal), onCue: MediaImports.key(list: list, cue: cell.uuid)) }
    }

    // MARK: - Drops on a strip cell (Spec 10 §7, "Drops")

    public func plan(_ payload: DragPayload, ontoChannel channel: Int) -> DropPlan {
        Drops.plan(payload, ontoChannel: channel, media: store.media, cannotSend: store.cannotSend, cannotImport: imports.cannotImport, isFolder: imports.isFolder)
    }

    /// A drag was let go on a strip cell that had held it for its 0.3 seconds.
    public func land(_ plan: DropPlan, onChannel channel: Int) {
        switch plan {
        case .live(let media, let channel):
            goLive(media: media, on: channel)
        case .importLive(let path, let channel):
            if let refusal = imports.importFile(path, liveOn: channel) { imports.say(.cannot(refusal), onChannel: channel) }
        case .refused(let reason):
            imports.say(.cannot(reason), onChannel: channel)
        default:
            break
        }
    }

    // MARK: - The pool (Spec 10 §6)

    public func planOnPool(_ payload: DragPayload) -> DropPlan {
        Drops.planOnPool(payload, cannotImport: imports.cannotImport)
    }

    /// Files let go on the pool, or chosen with Import…: imported, or the pool says why not.
    public func landOnPool(_ plan: DropPlan) {
        switch plan {
        case .importFiles(let paths):
            if let refusal = imports.importFiles(paths) { say(.notSent(refusal), at: .pool) }
        case .refused(let reason):
            say(.notSent(reason), at: .pool)
        default:
            break
        }
    }

    /// Import… (⌘I): why it can't be chosen now, for the button and the menu.
    public var cannotImport: CannotEdit? { imports.cannotImport.map(CannotEdit.unavailable) }

    /// "A tile's menu", as the machine stands now.
    public func tileMenu(for id: String) -> [MenuEntry] {
        guard let item = store.media.first(where: { $0.id == id }), let catalog = store.catalog else { return [] }
        return Menus.tile(item, dropChannel: MediaPool.dropChannel(for: item.entry, settings: catalog.settings), channels: catalog.channels,
                          cannotSend: store.cannotSend, cannotEditMasters: cannotEditMasters, cannotEditMachine: cannotEditMachine)
    }

    /// Why an item's defaults can't be edited, nor it replaced or deleted:
    /// "Machine-index items; library items are refused with
    /// `readOnlyLibrary`" where masters are read-only (Spec 8 §2).
    public func cannotEdit(media id: String) -> CannotEdit? {
        guard let item = store.media.first(where: { $0.id == id }), !item.isDeleted else { return .missing }
        return (item.index == "library" ? cannotEditMasters : cannotEditMachine).map(CannotEdit.unavailable)
    }

    /// "Defaults… (a popover editing its trim in and out, loop, gain, grade,
    /// sync offset and default channel, each an `edit media sha256:…
    /// defaults.FIELD` edit, Spec 8 §5)": one edit per field that changed,
    /// together as one group, so one Undo takes the panel's Save back (Area
    /// 13 reading). Nothing changed sends nothing.
    public func setDefaults(_ new: MediaDefaults, of id: String) -> CannotEdit? {
        if let cannot = cannotEdit(media: id) { return cannot }
        guard let old = store.media.first(where: { $0.id == id })?.entry.defaults else { return .missing }
        func number(_ value: Int?) -> JSONValue { value.map { .number(Double($0)) } ?? .null }
        var commands: [Command] = []
        func set(_ field: String, _ value: JSONValue) { commands += Edits.mediaDefault(id, field: field, value: value).commands }
        if new.trimInMs != old.trimInMs { set("trimInMs", number(new.trimInMs)) }
        if new.trimOutMs != old.trimOutMs { set("trimOutMs", number(new.trimOutMs)) }
        if new.loop != old.loop { set("loop", .bool(new.loop)) }
        if new.gain != old.gain { set("gain", new.gain.map(JSONValue.number) ?? .null) }
        if new.grade != old.grade { set("grade", number(new.grade)) }
        if new.syncOffsetMs != old.syncOffsetMs { set("syncOffsetMs", number(new.syncOffsetMs)) }
        if new.defaultChannel != old.defaultChannel { set("defaultChannel", number(new.defaultChannel)) }
        let isMaster = store.media.first { $0.id == id }?.index == "library"
        return commit(commands.isEmpty ? nil : Sending(commands), master: isMaster, at: .pool)
    }

    /// "Delete… on a pool tile asks `mediaUse` first: "Delete "Ocean loop"?
    /// It's used by 12 cues, 1 macro and 2 keys; they'll show it missing."
    /// Then `media delete HASH` (Spec 8 §6)."
    public func deleteMedia(_ id: String) {
        guard let item = store.media.first(where: { $0.id == id }) else { return }
        if let cannot = cannotEdit(media: id) { return say(.notSent(cannot), at: .pool) }
        ask(.query("mediaUse", ["media": .string(id)])) { [weak self] answer in
            // With no answer the question can't say what uses it, so nothing is asked and nothing deleted.
            guard let self, let answer else { return }
            self.ask(.deleteMedia(name: MediaPool.name(of: item.entry), use: MediaUseCount(answer: answer))) { [weak self] in
                self?.edit(Edits.deleteMedia(id), at: .pool)
                if self?.selectedMedia == id { self?.select(media: nil) }
            }
        }
    }

    /// Where an item's file is (Spec 8 §2, "Where a file is"): "a library
    /// entry's `path` is relative to the media root; a machine-index entry's
    /// `path` is relative to `machine/media/`". Nil for an item with no file.
    public func location(ofMedia id: String, machineRoot: URL?) -> URL? {
        guard let machineRoot, let item = store.media.first(where: { $0.id == id }), !item.entry.path.isEmpty else { return nil }
        let folder = item.index == "library" ? mediaRoot(machineRoot: machineRoot) : machineRoot.appendingPathComponent("media")
        return folder?.appendingPathComponent(item.entry.path)
    }

    /// The media root, which the machine's settings give absolutely or from the machine folder.
    public func mediaRoot(machineRoot: URL?) -> URL? {
        guard let machineRoot, let path = store.catalog?.settings?.mediaRoot, !path.isEmpty else { return nil }
        return path.hasPrefix("/") ? URL(fileURLWithPath: path) : machineRoot.appendingPathComponent(path).standardizedFileURL
    }
}
