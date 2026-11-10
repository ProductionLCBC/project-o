// OCore — Spec 7 §2, folder edits.

import Foundation

extension Editor {
    /// Spec 7 §2 — "A folder path is one or more names joined by `/`. A name
    /// can't be empty, start with a dot or contain a colon."
    func checkFolderPath(_ path: String) throws {
        let names = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.isEmpty, names.allSatisfy({ !$0.isEmpty && !$0.hasPrefix(".") && !$0.contains(":") }) else {
            throw reject(.badValue, "\"\(path)\" is not a folder path: names joined by /, none empty, none starting with a dot, none with a colon")
        }
    }

    /// The parent of a folder path, "" at the top.
    static func parent(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return "" }
        return String(path[..<slash])
    }

    static func lastName(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return path }
        return String(path[path.index(after: slash)...])
    }

    /// Whether `path` is `folder` or inside it, without regard to case.
    static func isWithin(_ path: String, _ folder: String) -> Bool {
        let p = path.lowercased()
        let f = folder.lowercased()
        return p == f || p.hasPrefix(f + "/")
    }

    mutating func editFolder(_ path: String, _ action: EditAction) throws -> (EditCommand, EditCommand?) {
        switch action {
        case .create(let body, let folder, let title):
            if body != nil || folder != nil || title != nil { throw reject(.badValue, "a folder is created with its path alone") }
            return try createFolder(path)
        case .rename(let to):
            return try renameFolder(path, to: to)
        case .delete:
            return try deleteFolder(path)
        case .set(let field, _), .unset(let field):
            _ = try resolveFolder(path)
            throw reject(.unknownPath, "a folder has no field \(field)")
        default:
            throw reject(.badValue, "\(action.verb) does not apply to a folder")
        }
    }

    /// Spec 7 §2 — "`edit folder "Worship/Hymns" create` Creates the folder.
    /// Its parent must exist (`unknownObject` otherwise), so a deeper path is
    /// a group of creates". A folder that exists, ignoring case, is
    /// `duplicate`; the parent keeps the case it was made with.
    mutating func createFolder(_ path: String) throws -> (EditCommand, EditCommand?) {
        try checkFolderPath(path)
        let parent = try resolveFolder(Editor.parent(of: path))
        let created = (parent.isEmpty ? "" : parent + "/") + Editor.lastName(of: path)
        if library.folders.contains(where: { $0.lowercased() == created.lowercased() }) {
            throw reject(.duplicate, "folder \"\(created)\" exists")
        }
        library.folders.append(created)
        library.folders.sort()
        structure.append(.makeFolder(created))
        changes.append(.folder(created))
        return (EditCommand(.folder(created), .create(body: nil, folder: nil, title: nil)),
                EditCommand(.folder(created), .delete))
    }

    /// Spec 7 §2 — "Renames the folder, or moves it when the parent changes,
    /// in one directory rename that carries everything in it ... A rename is
    /// refused with `duplicate` when the new path exists, ignoring case,
    /// unless only the case changes; with `badValue` when the new path is
    /// inside the old one; and with `unknownObject` when the new parent
    /// doesn't exist."
    mutating func renameFolder(_ path: String, to: String) throws -> (EditCommand, EditCommand?) {
        let source = try resolveFolder(path)
        try checkFolderPath(to)
        let onlyCase = to.lowercased() == source.lowercased()
        if !onlyCase, Editor.isWithin(to, source) {
            throw reject(.badValue, "\"\(to)\" is inside \"\(source)\"; a folder can't move into itself")
        }
        // The new parent as it exists, in the case it was made with.
        let parent = try resolveFolder(Editor.parent(of: to))
        let target = (parent.isEmpty ? "" : parent + "/") + Editor.lastName(of: to)
        let logged = EditCommand(.folder(source), .rename(to: target))
        if target == source { return (logged, nil) }
        if !onlyCase, library.folders.contains(where: { $0.lowercased() == target.lowercased() }) {
            throw reject(.duplicate, "folder \"\(target)\" exists")
        }
        func moved(_ p: String, under prefix: String) -> String {
            target + String(p.dropFirst(prefix.count))
        }
        library.folders = library.folders.map { Editor.isWithin($0, source) ? moved($0, under: source) : $0 }.sorted()
        let old = "lists/" + source
        for (key, file) in library.documentPaths where key.hasPrefix("list/") && Editor.isWithin(file, old) {
            library.documentPaths[key] = "lists/" + moved(String(file.dropFirst("lists/".count)), under: source)
            if let uuid = UUID(uuidString: String(key.dropFirst("list/".count))), let list = library.list(uuid: uuid) {
                changes.append(.list(list))
            }
        }
        library.otherFiles = Set(library.otherFiles.map { file in
            Editor.isWithin(file, old) ? "lists/" + moved(String(file.dropFirst("lists/".count)), under: source) : file
        })
        structure.append(.renameFolder(from: source, to: target))
        changes.insert(.folder(target), at: 0)
        return (logged, EditCommand(.folder(target), .rename(to: source)))
    }

    /// Spec 7 §2 — "Deletes the folder when it is empty: no lists, no visible
    /// files and no folders other than hidden ones. Hidden files and folders
    /// go with it, as in the Finder, and an undo doesn't bring them back.
    /// Otherwise `notEmpty`."
    mutating func deleteFolder(_ path: String) throws -> (EditCommand, EditCommand?) {
        let folder = try resolveFolder(path)
        let inside = "lists/" + folder
        let holdsList = library.documentPaths.contains { key, file in key.hasPrefix("list/") && file.lowercased().hasPrefix(inside.lowercased() + "/") }
        let holdsFile = library.otherFiles.contains { $0.lowercased().hasPrefix(inside.lowercased() + "/") }
        let holdsFolder = library.folders.contains { $0.lowercased().hasPrefix(folder.lowercased() + "/") }
        if holdsList || holdsFile || holdsFolder {
            throw reject(.notEmpty, "folder \"\(folder)\" isn't empty: it holds " + (holdsList ? "lists" : holdsFolder ? "folders" : "files"))
        }
        library.folders.removeAll { $0 == folder }
        structure.append(.removeFolder(folder))
        changes.append(.folder(folder))
        return (EditCommand(.folder(folder), .delete), EditCommand(.folder(folder), .create(body: nil, folder: nil, title: nil)))
    }
}
