// OCore — Spec 8 §6, `media replace` and `media unreplace` as edits.

import Foundation

/// Spec 8 §6 — where `media replace` rewrites a reference, as Adam answered
/// on 2026-11-11 (5): "write refs: in cues, macros, key bindings and
/// scheduler entries, and in cues' held `cueChannel` edits. Held media
/// commands and `edit media` keep naming their entry. Local copies follow the
/// mapping." Only documents this machine writes: the library's lists and
/// macros on a writable machine (§2), the machine's macros, key bindings and
/// scheduler entries always. Presets hold no media in v1.
///
/// A reference is named as Spec 5 §3 addresses its holder (`MediaReference`):
/// a cue by its list's number and uuid and its own uuid, a macro by number, a
/// key binding by device and key, a scheduler entry by its position in the
/// keys document; and the path to the ref inside it, `commands.2.content.ref`
/// (a held `edit.cueChannel` carries its content at the same place) or
/// `command.content.ref`.
public enum MediaRefSites {
    public struct Site: Equatable, Sendable {
        public var reference: MediaReference
        public var id: String
    }

    /// Every rewritable reference on this machine, with the id it names now.
    public static func sites(library: Library, machine: Machine, libraryWritable: Bool) -> [Site] {
        var out: [Site] = []
        func visit(_ commands: [GuardedCommand], object: String, address: [String: JSONValue], inCue: Bool) {
            for (i, entry) in commands.enumerated() {
                if let id = ref(of: entry.command, inCue: inCue) {
                    out.append(Site(reference: MediaReference(object: object, address: address, path: "commands.\(i).content.ref"), id: id))
                }
            }
        }
        if libraryWritable {
            for list in library.lists {
                for cue in list.cues { visit(cue.commands, object: "cue", address: cueAddress(list, cue.uuid), inCue: true) }
            }
            for macro in library.macros { visit(macro.commands, object: "macro", address: ["macro": .number(Double(macro.number))], inCue: false) }
        }
        // Spec 2 §5 — a library macro of the same number is the one that runs.
        for macro in machine.macros where library.macro(macro.number) == nil {
            visit(macro.commands, object: "macro", address: ["macro": .number(Double(macro.number))], inCue: false)
        }
        for (i, binding) in machine.keys.enumerated() {
            guard let id = ref(of: binding.command, inCue: false) else { continue }
            out.append(Site(reference: MediaReference(object: "keys", address: keyAddress(binding, at: i), path: "command.content.ref"), id: id))
        }
        return out
    }

    static func cueAddress(_ list: List, _ cue: UUID) -> [String: JSONValue] {
        ["list": .number(Double(list.number)), "listUuid": .string(list.uuid.uuidString.lowercased()), "cue": .string(cue.uuidString.lowercased())]
    }

    /// Spec 5 §3 — "a key binding, named by its device and key"; "scheduler
    /// entries have no identity of their own and are named by position".
    static func keyAddress(_ binding: KeyBinding, at index: Int) -> [String: JSONValue] {
        if binding.when != nil { return ["at": .number(Double(index))] }
        return ["device": .string(binding.device), "key": binding.key.map(JSONValue.string) ?? .null]
    }

    /// The media or slide id a stored command's write names: a write, or in a
    /// cue a held `edit.cueChannel` that writes.
    static func ref(of command: Command, inCue: Bool) -> String? {
        switch command {
        case .channelWrite(let w):
            return w.content.mediaRef
        case .edit(let e) where inCue:
            if case .cueChannel(let c) = e.action, case .write(let content, _) = c.state { return content.mediaRef }
            return nil
        default:
            return nil
        }
    }

    /// The command with the ref its write names set to `id`.
    static func setting(_ command: Command, to id: String, inCue: Bool) -> Command? {
        switch command {
        case .channelWrite:
            return command.mediaRef == nil ? nil : command.mapMediaRefs { _ in id }
        case .edit(var e) where inCue:
            guard case .cueChannel(var c) = e.action, case .write(let content, let riders) = c.state, content.mediaRef != nil,
                  case .channelWrite(let w) = Command.channelWrite(ChannelWrite(channel: .number(c.channel), content: content, riders: riders))
                    .mapMediaRefs({ _ in id }) else { return nil }
            c.state = .write(w.content, w.riders)
            e.action = .cueChannel(c)
            return .edit(e)
        default:
            return nil
        }
    }

    /// The position a path names in a holder's commands.
    static func commandIndex(_ path: String) -> Int? {
        let parts = path.split(separator: ".")
        guard parts.count == 4, parts[0] == "commands", parts[2] == "content", parts[3] == "ref" else { return nil }
        return Int(parts[1])
    }

    /// The id at a reference, if its holder and path still hold a write.
    public static func id(at reference: MediaReference, library: Library, machine: Machine) -> String? {
        var library = library
        var machine = machine
        var found: String?
        _ = visit(reference, library: &library, machine: &machine) { command, inCue in
            found = ref(of: command, inCue: inCue)
            return nil
        }
        return found
    }

    /// Sets the id at a reference; false when its holder or path is gone.
    public static func set(_ reference: MediaReference, to id: String, library: inout Library, machine: inout Machine) -> Bool {
        visit(reference, library: &library, machine: &machine) { command, inCue in setting(command, to: id, inCue: inCue) }
    }

    /// Finds the command a reference names and lets `change` replace it.
    private static func visit(_ reference: MediaReference, library: inout Library, machine: inout Machine,
                              _ change: (Command, Bool) -> Command?) -> Bool {
        func number(_ key: String) -> Int? { reference.address[key]?.intValue }
        func uuid(_ key: String) -> UUID? { reference.address[key]?.stringValue.flatMap(UUID.init(uuidString:)) }
        func apply(_ commands: inout [GuardedCommand], inCue: Bool) -> Bool {
            guard let i = commandIndex(reference.path), commands.indices.contains(i),
                  let changed = change(commands[i].command, inCue) else { return false }
            commands[i].command = changed
            return true
        }
        switch reference.object {
        case "cue":
            // By the list's uuid, which a renumber doesn't change; by its number when no uuid is recorded.
            let listUuid = uuid("listUuid")
            let listNumber = number("list")
            guard let cue = uuid("cue"),
                  let l = library.lists.firstIndex(where: { list in listUuid.map { list.uuid == $0 } ?? (list.number == listNumber) }),
                  let c = library.lists[l].cues.firstIndex(where: { $0.uuid == cue }) else { return false }
            return apply(&library.lists[l].cues[c].commands, inCue: true)
        case "macro":
            guard let n = number("macro") else { return false }
            if let m = library.macros.firstIndex(where: { $0.number == n }) { return apply(&library.macros[m].commands, inCue: false) }
            if let m = machine.macros.firstIndex(where: { $0.number == n }) { return apply(&machine.macros[m].commands, inCue: false) }
            return false
        case "keys":
            guard reference.path == "command.content.ref" else { return false }
            let index: Int?
            if let at = number("at") {
                index = machine.keys.indices.contains(at) && machine.keys[at].when != nil ? at : nil
            } else {
                let device = reference.address["device"]?.stringValue
                let key = reference.address["key"]?.stringValue
                index = machine.keys.firstIndex { $0.when == nil && $0.device == device && $0.key == key }
            }
            guard let index, let changed = change(machine.keys[index].command, false) else { return false }
            machine.keys[index].command = changed
            return true
        default:
            return false
        }
    }

    /// Spec 5 §2 — the `library` event's entry for a reference's holder.
    static func change(for reference: MediaReference, library: Library) -> LibraryChange {
        switch reference.object {
        case "cue":
            var address = reference.address
            address["listUuid"] = nil
            if let uuid = reference.address["listUuid"]?.stringValue.flatMap(UUID.init(uuidString:)),
               let list = library.lists.first(where: { $0.uuid == uuid }) {
                return LibraryChange.cue(list, UUID(uuidString: reference.address["cue"]?.stringValue ?? "") ?? UUID(), paths: ["commands"])
            }
            return LibraryChange(object: "cue", address: address, paths: ["commands"])
        case "macro":
            return LibraryChange(object: "macro", address: reference.address, paths: ["commands"])
        default:
            return LibraryChange(object: "keys", address: [:])
        }
    }
}

/// Spec 8 §6 — "Replace (M10) is the re-exported video on a Sunday morning."
/// `media replace` and its inverse are ordinary edits (§2): pure, checked
/// and applied against the roots the group's earlier commands left, logged
/// with what they did, undone through Spec 5 §8.
public enum MediaEdits {
    /// One applied media edit: the roots after it, the command as logged
    /// (with what it did), its inverse (none for a `noop`) and what changed
    /// for the `library` event.
    public struct Outcome: Equatable, Sendable {
        public var library: Library
        public var machine: Machine
        public var logged: MediaCommand
        public var inverse: MediaCommand?
        public var changes: [LibraryChange]

        /// Spec 5 §4 — "a value equal to the current one is a `noop`".
        public var isNoop: Bool { inverse == nil }
    }

    static func reject(_ reason: RejectionReason, _ message: String) -> Result<Outcome, Rejection> {
        .failure(Rejection(reason: reason, message: message))
    }

    static func media(_ id: String, _ paths: [String]) -> LibraryChange {
        LibraryChange(object: "media", address: ["media": .string(id)], paths: paths)
    }

    /// Spec 8 §6 — `media replace OLD NEW`: "It rewrites every reference to
    /// OLD in the lists, presets, macros, key bindings and scheduler entries
    /// this machine writes, and records `OLD → NEW` in the `replaced` map of
    /// the index that holds OLD."
    ///
    /// - "NEW takes OLD's defaults when it has none of its own, every default
    ///   empty as an import leaves them; an item someone has set up keeps its
    ///   own (choice M-3)", and with them the poster name their in-point gives
    ///   (§5), which the worker then makes. Not on a library item a
    ///   `readOnlyMasters` machine can't write: its defaults stay empty.
    /// - "OLD's entry and file stay."
    /// - "NEW can't be OLD or a deleted item" (`badValue`). "If NEW's chain
    ///   already leads back to OLD, as when a replacement is reversed, the
    ///   mapping that leaves NEW is removed first, so no loop forms." A
    ///   mapping that leaves OLD in the machine index, which would shadow the
    ///   library's new one, goes too.
    /// - "On a `readOnlyMasters` machine, replacing library media is refused
    ///   with `readOnlyLibrary`, and replacing local-only media rewrites
    ///   machine documents only (§2)."
    public static func replace(old: String, new: String, library: Library, machine: Machine) -> Result<Outcome, Rejection> {
        let writable = machine.settings.libraryMode == .writable
        guard let (oldEntry, oldTier) = MediaResolver.entry(for: old, library: library.mediaIndex, machine: machine.mediaLocal) else {
            return reject(.unknownObject, "\(old) isn't in either media index")
        }
        guard let (newEntry, newTier) = MediaResolver.entry(for: new, library: library.mediaIndex, machine: machine.mediaLocal) else {
            return reject(.unknownObject, "\(new) isn't in either media index")
        }
        guard old != new else { return reject(.badValue, "an item can't replace itself") }
        guard !newEntry.isDeleted else { return reject(.badValue, "\(new) is deleted, so it can't replace \(old)") }
        if oldTier == .library, !writable {
            return reject(.readOnlyLibrary, "\(old) is library media, which a readOnlyMasters machine doesn't change")
        }
        _ = oldEntry
        var library = library
        var machine = machine
        var mapping = MediaMappingChanges()
        var changes: [LibraryChange] = []

        // "If NEW's chain already leads back to OLD ... the mapping that leaves NEW is removed first".
        while MediaResolver.chain(from: new, library: library.mediaIndex, machine: machine.mediaLocal).ids.dropFirst().contains(old) {
            if let to = machine.mediaLocal.replaced[new] {
                machine.mediaLocal.replaced[new] = nil
                mapping.removed.append(MediaMapping(index: .machine, from: new, to: to))
            } else if let to = library.mediaIndex.replaced[new] {
                guard writable else { return reject(.readOnlyLibrary, "\(new) leads back to \(old) through the library's map, which a readOnlyMasters machine doesn't change") }
                library.mediaIndex.replaced[new] = nil
                mapping.removed.append(MediaMapping(index: .library, from: new, to: to))
            } else {
                break
            }
            changes.append(media(new, ["replaced"]))
        }
        // OLD → NEW in the index that holds OLD; the machine's own mapping of OLD would win over the library's.
        if oldTier == .library, let to = machine.mediaLocal.replaced[old] {
            machine.mediaLocal.replaced[old] = nil
            mapping.removed.append(MediaMapping(index: .machine, from: old, to: to))
        }
        let before = oldTier == .library ? library.mediaIndex.replaced[old] : machine.mediaLocal.replaced[old]
        if before != new {
            if let before { mapping.removed.append(MediaMapping(index: oldTier, from: old, to: before)) }
            if oldTier == .library { library.mediaIndex.replaced[old] = new } else { machine.mediaLocal.replaced[old] = new }
            mapping.added.append(MediaMapping(index: oldTier, from: old, to: new))
        }
        if !mapping.removed.isEmpty || !mapping.added.isEmpty { changes.append(media(old, ["replaced"])) }

        // Every write that names OLD now names NEW.
        var refs: [MediaReference] = []
        for site in MediaRefSites.sites(library: library, machine: machine, libraryWritable: writable) where site.id == old {
            if MediaRefSites.set(site.reference, to: new, library: &library, machine: &machine) {
                refs.append(site.reference)
                let change = MediaRefSites.change(for: site.reference, library: library)
                if !changes.contains(change) { changes.append(change) }
            }
        }

        // Choice M-3 — NEW takes OLD's defaults when its own are all empty.
        var defaults: MediaDefaults?
        let newWritable = newTier == .machine || writable
        if newWritable, newEntry.defaults == MediaDefaults(), oldEntry.defaults != MediaDefaults() {
            defaults = newEntry.defaults
            setDefaults(of: new, tier: newTier, to: oldEntry.defaults, library: &library, machine: &machine)
            changes.append(media(new, ["defaults"]))
        }

        let record = MediaReplaceRecord(refs: refs, mapping: mapping, defaults: defaults)
        let acted = !refs.isEmpty || !mapping.removed.isEmpty || !mapping.added.isEmpty || defaults != nil
        return .success(Outcome(library: library, machine: machine, logged: .replace(old: old, new: new, record: record),
                                inverse: acted ? .unreplace(old: old, new: new, record: record) : nil, changes: acted ? changes : []))
    }

    /// Spec 8 §6 — `media unreplace OLD NEW {…}`, replace's inverse: "puts all
    /// three back, so references that already named NEW keep it": each
    /// reference it rewrote names OLD again, the mappings it added go and the
    /// ones it removed come back, and NEW's defaults are what they were, with
    /// the poster name they give. Spec 5 §8 — "If an inverse would now break
    /// another rule ..., the undo is rejected with `conflict`": a reference
    /// that no longer names NEW, or a mapping since changed.
    public static func unreplace(old: String, new: String, record: MediaReplaceRecord, library: Library, machine: Machine) -> Result<Outcome, Rejection> {
        let writable = machine.settings.libraryMode == .writable
        let original = library
        var library = library
        var machine = machine
        var changes: [LibraryChange] = []
        for reference in record.refs {
            guard MediaRefSites.id(at: reference, library: library, machine: machine) == new,
                  MediaRefSites.set(reference, to: old, library: &library, machine: &machine) else {
                return reject(.conflict, "\(reference.object) \(reference.path) no longer names \(new)")
            }
            let change = MediaRefSites.change(for: reference, library: library)
            if !changes.contains(change) { changes.append(change) }
        }
        for added in record.mapping.added.reversed() {
            let current = added.index == .library ? library.mediaIndex.replaced[added.from] : machine.mediaLocal.replaced[added.from]
            guard current == added.to else { return reject(.conflict, "\(added.from) no longer maps to \(added.to)") }
            if added.index == .library { library.mediaIndex.replaced[added.from] = nil } else { machine.mediaLocal.replaced[added.from] = nil }
        }
        for removed in record.mapping.removed {
            if removed.index == .library { library.mediaIndex.replaced[removed.from] = removed.to } else { machine.mediaLocal.replaced[removed.from] = removed.to }
        }
        for id in Set(record.mapping.added.map(\.from) + record.mapping.removed.map(\.from)).sorted() { changes.append(media(id, ["replaced"])) }
        if let defaults = record.defaults {
            guard let (_, tier) = MediaResolver.entry(for: new, library: library.mediaIndex, machine: machine.mediaLocal) else {
                return reject(.conflict, "\(new) is no longer in either media index")
            }
            setDefaults(of: new, tier: tier, to: defaults, library: &library, machine: &machine)
            changes.append(media(new, ["defaults"]))
        }
        // Spec 8 §2 — a readOnlyMasters machine never writes the library.
        if !writable, library != original {
            return reject(.readOnlyLibrary, "undoing the replace of \(old) changes library documents, which a readOnlyMasters machine doesn't write")
        }
        return .success(Outcome(library: library, machine: machine, logged: .unreplace(old: old, new: new, record: record),
                                inverse: .replace(old: old, new: new, record: record), changes: changes))
    }

    // MARK: - Delete and undelete (Spec 8 §6)

    /// Spec 8 §6 — the checks a `media delete` or `media undelete` makes that
    /// need no engine, before any file moves and again after: the item is in
    /// an index; a delete's isn't deleted yet (deleting it again changes
    /// nothing, `noop`), an undelete's is (`conflict` otherwise, Spec 5 §8);
    /// and "Library mode ... apply (§2)": library media on a `readOnlyMasters`
    /// machine is `readOnlyLibrary`. Operator lock is the runner's. `onAir`
    /// and `noTrash` are the engine's.
    public static func check(_ command: MediaCommand, library: Library, machine: Machine) -> Result<Bool, Rejection> {
        let writable = machine.settings.libraryMode == .writable
        switch command {
        case .delete(let id, _):
            guard let (entry, tier) = MediaResolver.entry(for: id, library: library.mediaIndex, machine: machine.mediaLocal) else {
                return .failure(Rejection(reason: .unknownObject, message: "\(id) isn't in either media index"))
            }
            if tier == .library, !writable {
                return .failure(Rejection(reason: .readOnlyLibrary, message: "\(id) is library media, which a readOnlyMasters machine doesn't delete"))
            }
            return .success(!entry.isDeleted)
        case .undelete(let id, _):
            guard let (entry, tier) = MediaResolver.entry(for: id, library: library.mediaIndex, machine: machine.mediaLocal) else {
                return .failure(Rejection(reason: .unknownObject, message: "\(id) isn't in either media index"))
            }
            if tier == .library, !writable {
                return .failure(Rejection(reason: .readOnlyLibrary, message: "\(id) is library media, which a readOnlyMasters machine doesn't change"))
            }
            guard entry.isDeleted else { return .failure(Rejection(reason: .conflict, message: "\(id) isn't deleted")) }
            return .success(true)
        default:
            return .success(true)
        }
    }

    /// Spec 8 §6, step 3 — "Applies ... the entry stays, with `deletedAt`
    /// set and its `path` empty, and the command is logged with where each
    /// file came from and where the Trash put it." Every reference to the item
    /// then shows the missing badge, its id still known. Its inverse is
    /// `media undelete` with the same files.
    public static func delete(id: String, files: [MediaTrashedFile], at timestamp: String, library: Library, machine: Machine) -> Result<Outcome, Rejection> {
        switch check(.delete(id: id, files: nil), library: library, machine: machine) {
        case .failure(let rejection):
            return .failure(rejection)
        case .success(false):
            return .success(Outcome(library: library, machine: machine, logged: .delete(id: id, files: files), inverse: nil, changes: []))
        case .success(true):
            break
        }
        var library = library
        var machine = machine
        func update(_ entry: inout MediaEntry) {
            entry.deletedAt = timestamp
            entry.path = ""
        }
        if let i = machine.mediaLocal.position(of: id) {
            update(&machine.mediaLocal.entries[i])
        } else if let i = library.mediaIndex.position(of: id) {
            update(&library.mediaIndex.entries[i])
        }
        return .success(Outcome(library: library, machine: machine, logged: .delete(id: id, files: files),
                                inverse: .undelete(id: id, files: files), changes: [media(id, ["path", "deletedAt"])]))
    }

    /// Spec 8 §6 — `media undelete`, delete's inverse: "moves the files back
    /// to where they came from and clears `deletedAt`". `restored` is where
    /// the engine put each file back, a numbered name where another file had
    /// taken its path ("It never overwrites a file now at one of those
    /// paths"); the entry takes the restored path of its first file in its
    /// own folder (none when its location is an override's, which still
    /// names its file). Its inverse is `media delete`.
    public static func undelete(id: String, files: [MediaTrashedFile], restored: [MediaTrashedFile], library: Library, machine: Machine) -> Result<Outcome, Rejection> {
        if case .failure(let rejection) = check(.undelete(id: id, files: files), library: library, machine: machine) { return .failure(rejection) }
        var library = library
        var machine = machine
        func update(_ entry: inout MediaEntry, folder: MediaFolder) {
            entry.deletedAt = nil
            entry.path = restored.first { $0.location.folder == folder }?.location.path ?? ""
            if !entry.path.isEmpty { entry.folder = MediaLocation(folder, entry.path)?.parent ?? entry.folder }
        }
        if let i = machine.mediaLocal.position(of: id) {
            update(&machine.mediaLocal.entries[i], folder: .machineMedia)
        } else if let i = library.mediaIndex.position(of: id) {
            update(&library.mediaIndex.entries[i], folder: .mediaRoot)
        }
        return .success(Outcome(library: library, machine: machine, logged: .undelete(id: id, files: files),
                                inverse: .delete(id: id, files: nil), changes: [media(id, ["path", "deletedAt"])]))
    }

    /// An entry's defaults, and with them the poster name their in-point
    /// gives a video (Spec 8 §5, "The new in-point gives the poster a new name").
    static func setDefaults(of id: String, tier: MediaTier, to defaults: MediaDefaults, library: inout Library, machine: inout Machine) {
        func update(_ entry: inout MediaEntry) {
            entry.defaults = defaults
            if entry.kind == .video, entry.poster != nil { entry.poster = MediaPosters.posterPath(of: entry) }
        }
        switch tier {
        case .library:
            if let i = library.mediaIndex.position(of: id) { update(&library.mediaIndex.entries[i]) }
        case .machine:
            if let i = machine.mediaLocal.position(of: id) { update(&machine.mediaLocal.entries[i]) }
        }
    }
}
