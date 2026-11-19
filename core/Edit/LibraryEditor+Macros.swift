// OCore — Spec 5 §4 and §6 for macros (Spec 11 §9). A macro lives in the
// library or, when it names a stack or an output, in the machine root (Spec
// 1 §2), so its edits also say where its file is.

import Foundation

extension Editor {
    /// Spec 1 §2 — "one number names one macro": the macro and the root that holds it.
    func macro(_ number: Int) -> (macro: Macro, machineLevel: Bool)? {
        if let found = library.macro(number) { return (found, false) }
        if let found = machine.macro(number) { return (found, true) }
        return nil
    }

    /// Spec 11 §9 — a macro's commands, "the tile's colour and label", New,
    /// Duplicate, Delete, renumber and swap. "A cycle, or a macro nested past
    /// the depth cap, is refused (`cycle`, Spec 5 §6)."
    mutating func editMacro(_ number: Int?, _ action: EditAction, makeUUID: () -> UUID) throws -> (EditCommand, EditCommand?) {
        if case .create(let body, let folder, let title) = action {
            if folder != nil || title != nil { throw reject(.badValue, "a macro has no folder or title") }
            let n = try freeNumber(.macro, number)
            let (tree, logged) = try newObject(.macro, n, body: body, fresh: { encode(Macro(number: n, commands: [], label: "", uuid: $0)) },
                                               makeUUID: makeUUID)
            if let problem = EditFields.macro.problem(with: tree) { throw reject(.badValue, "the macro \(problem)") }
            let made: Macro = try read(tree, "the macro")
            if (library.macros + machine.macros).contains(where: { $0.uuid == made.uuid }) {
                throw reject(.duplicate, "a macro with uuid \(made.uuid.uuidString.lowercased()) exists")
            }
            try checkMacroCommands(made.commands, old: [])
            try place(made, replacing: nil)
            changes.append(Editor.changed(.macro, n))
            return (EditCommand(.numbered(.macro, n), .create(body: logged, folder: nil, title: nil)), EditCommand(.numbered(.macro, n), .delete))
        }
        guard let number else { throw reject(.badValue, "name the macro by its number") }
        guard let (macro, machineLevel) = self.macro(number) else { throw reject(.unknownObject, "macro \(number) does not exist") }
        let address = EditAddress.numbered(.macro, number)
        let logged = EditCommand(address, action)
        var updated = macro

        func stored(_ inverse: EditAction, _ path: String) throws -> (EditCommand, EditCommand?) {
            guard updated != macro else { return (logged, nil) }
            try checkMacroCommands(updated.commands, old: macro.commands)
            try place(updated, replacing: macro)
            changes.append(Editor.changed(.macro, number, [path]))
            return (logged, EditCommand(address, inverse))
        }

        switch action {
        // Spec 5 §4 — the commands are set whole, one at `commands.N`, or inserted, removed and moved by position, as a cue's are.
        case .set("commands", let value):
            guard let items = value.arrayValue else { throw reject(.badValue, "commands is an array of command objects") }
            updated.commands = try items.map(decodeCommand)
            return try stored(.set(path: "commands", value: .array(macro.commands.map { encode($0) })), "commands")
        case .set(let path, let value) where path.hasPrefix("commands."):
            guard let n = Int(path.dropFirst("commands.".count)) else {
                throw reject(.unknownPath, "set a whole command at commands.N, not a part of one")
            }
            guard n >= 0, n < macro.commands.count else { throw reject(.unknownPath, "macro \(number) has no command at \(path)") }
            updated.commands[n] = try decodeCommand(value)
            return try stored(.set(path: path, value: encode(macro.commands[n])), "commands")
        case .insert("commands", let at, let value):
            try position(at, upTo: macro.commands.count, "the command's")
            updated.commands.insert(try decodeCommand(value), at: at)
            return try stored(.remove(path: "commands", at: at), "commands")
        case .remove("commands"?, let at?):
            try position(at, upTo: macro.commands.count - 1, "the command's")
            let removed = updated.commands.remove(at: at)
            return try stored(.insert(path: "commands", at: at, value: encode(removed)), "commands")
        case .move("commands"?, let from?, let at):
            try position(from, upTo: macro.commands.count - 1, "the command's")
            try position(at, upTo: macro.commands.count - 1, "the command's")
            if from == at { return (logged, nil) }
            updated.commands.insert(updated.commands.remove(at: from), at: at)
            return try stored(.move(path: "commands", from: at, at: from), "commands")

        case .set, .unset, .insert, .remove(_?, _?), .move(_?, _?, _):
            let part = try editPart(action, table: EditFields.macro, tree: encode(macro), of: "macro \(number)", owner: .macro)
            guard let inverse = part.inverse else { return (logged, nil) }
            updated = try read(part.tree, "macro \(number)")
            return try stored(inverse, part.path)

        case .delete:
            warnOfReferences(to: .macro, number)
            remove(macro, machineLevel: machineLevel)
            changes.append(Editor.changed(.macro, number))
            return (logged, EditCommand(address, .create(body: encode(macro), folder: nil, title: nil)))

        case .renumber(let to):
            guard to >= 1 else { throw reject(.badValue, "a macro number is 1 or more") }
            if to == number { return (logged, nil) }
            if self.macro(to) != nil { throw reject(.duplicate, "macro \(to) exists; swap the two instead") }
            try refuseAdopting(.macro, to)
            let before = (library: library, machine: machine)
            _ = Identity.renumber(.macro, from: number, to: to, library: &library, machine: &machine)
            moveDocumentPaths("macro", [number: to])
            changes.append(Editor.changed(.macro, to))
            changes += rewritten(since: before, besides: .macro)
            return (logged, EditCommand(.numbered(.macro, to), .renumber(to: number)))

        case .swap(let other):
            guard other >= 1 else { throw reject(.badValue, "a macro number is 1 or more") }
            if other == number { return (logged, nil) }
            guard self.macro(other) != nil else { throw reject(.unknownObject, "macro \(other) does not exist") }
            let before = (library: library, machine: machine)
            _ = Identity.swap(.macro, number, other, library: &library, machine: &machine)
            moveDocumentPaths("macro", [number: other, other: number])
            changes.append(Editor.changed(.macro, other))
            changes.append(Editor.changed(.macro, number))
            changes += rewritten(since: before, besides: .macro)
            return (logged, EditCommand(address, .swap(with: other)))

        case .duplicate(let to, let title, let picks):
            if title != nil || picks.cueUuids != nil || picks.itemUuids != nil {
                throw reject(.badValue, "a macro's copy takes a number and nothing else")
            }
            let n = try freeNumber(.macro, to)
            let uuid = picks.uuid ?? makeUUID()
            if (library.macros + machine.macros).contains(where: { $0.uuid == uuid }) {
                throw reject(.duplicate, "a macro with uuid \(uuid.uuidString.lowercased()) exists")
            }
            var copy = macro
            copy.number = n
            copy.uuid = uuid
            try place(copy, replacing: nil)
            changes.append(Editor.changed(.macro, n))
            return (EditCommand(address, .duplicate(to: n, title: nil, picks: EditPicks(uuid: uuid))), EditCommand(.numbered(.macro, n), .delete))

        case .remove, .move:
            throw reject(.badValue, "a remove or move by position names both the array's path and the position")
        case .create, .archive, .section, .folder, .rename, .cueChannel:
            throw reject(.badValue, "\(action.verb) does not apply to a macro")
        }
    }

    /// Spec 5 §6, checks 4, 5 and 8 for the commands a macro gains, as a
    /// cue's are checked: in the vocabulary, their numbers on this machine,
    /// an edit one holds "validated when its holder is saved". A stack or an
    /// output a macro names must be here: naming one is what makes the macro
    /// this machine's (Spec 1 §2).
    func checkMacroCommands(_ new: [GuardedCommand], old: [GuardedCommand]) throws {
        var unchanged = old
        for entry in new {
            if let i = unchanged.firstIndex(of: entry) {
                unchanged.remove(at: i)
                continue
            }
            try checkCueCommand(entry, holder: .macro)
            guard !context.restoring else { continue }
            for type in [NumberedType.stack, .output] {
                var missing: Int?
                entry.command.forEachReference(of: type) { if !Identity.exists(type, $0, library, machine) { missing = missing ?? $0 } }
                entry.when?.forEachReference(of: type) { if !Identity.exists(type, $0, library, machine) { missing = missing ?? $0 } }
                if let missing { throw reject(.unknownReference, "the macro names \(type.displayName) \(missing), which this machine doesn't have") }
            }
        }
    }

    /// Puts a macro in the root its scope gives it, taking `old` out of the
    /// root it was in. Spec 5 §2 — "a macro whose edit makes it name a stack
    /// or an output moves from the library root to the machine root (Spec 1
    /// §2)", and back when it stops: the file it leaves is removed in the same
    /// write. Spec 5 §6, check 8 — "A macro edit passes Spec 2 §5's cycle and
    /// depth checks", over every macro, since a deeper callee can push a
    /// caller past the cap.
    mutating func place(_ macro: Macro, replacing old: Macro?) throws {
        let wasMachine = old.map { self.macro($0.number)?.machineLevel ?? false }
        let isMachine = macro.isMachineLevel
        // Spec 5 §7 — a macro that stops naming a stack becomes a library object, which a `readOnlyMasters` machine doesn't write.
        if wasMachine == true, !isMachine, machine.settings.libraryMode == .readOnlyMasters, !context.dryRun {
            throw reject(.readOnlyLibrary, "macro \(macro.number) would no longer name a stack or an output, so it would move to the library, whose masters are read-only on this machine")
        }
        let failing = macrosThatCannotRun()
        if let old, let wasMachine { remove(old, machineLevel: wasMachine, keepingFile: wasMachine == isMachine) }
        if isMachine {
            machine.macros.insert(macro, at: machine.macros.firstIndex { $0.number > macro.number } ?? machine.macros.count)
        } else {
            library.macros.insert(macro, at: library.macros.firstIndex { $0.number > macro.number } ?? library.macros.count)
        }
        for (number, rejection) in macrosThatCannotRun().sorted(by: { $0.key < $1.key }) where failing[number] == nil {
            throw reject(.cycle, rejection.message)
        }
    }

    /// The macros Spec 2 §5 wouldn't run whole: in a loop, or nested past the cap.
    func macrosThatCannotRun() -> [Int: Rejection] {
        var out: [Int: Rejection] = [:]
        for macro in library.macros + machine.macros {
            if let rejection = MacroCalls.check(macro.number, levels: MacroCalls.maxDepth, library: library, machine: machine),
               rejection.reason == .macroCycle || rejection.reason == .macroDepth {
                out[macro.number] = rejection
            }
        }
        return out
    }

    /// Takes a macro out of its root, and its file with it unless it stays where it is.
    mutating func remove(_ macro: Macro, machineLevel: Bool, keepingFile: Bool = false) {
        let key = "macro/\(macro.number)"
        if machineLevel {
            machine.macros.removeAll { $0.number == macro.number }
            if !keepingFile, let path = machine.documentPaths.removeValue(forKey: key) {
                structure.append(.removeDocument(.machineMacro(macro.number), path: path))
            }
        } else {
            library.macros.removeAll { $0.number == macro.number }
            if !keepingFile, let path = library.documentPaths.removeValue(forKey: key) {
                structure.append(.removeDocument(.libraryMacro(macro.number), path: path))
            }
        }
    }
}
