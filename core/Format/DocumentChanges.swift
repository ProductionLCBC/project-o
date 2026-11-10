// OCore — Spec 1 §5 and Spec 5 §2: which documents an applied edit changed,
// so the writer saves each one on its own.

import Foundation

/// Spec 1 §5 — "Saves are debounced per document": one document the writer
/// saves on its own. These are the documents Area 9's edits change, directly
/// or through the references a list renumber or swap rewrites (Spec 1 §4):
/// list masters, macros of either root, playlists, local copies and the key
/// bindings. The catalogs come with the areas that edit them (Spec 7 §7).
public enum DocumentRef: Hashable, Sendable, CustomStringConvertible {
    case list(UUID)
    case libraryMacro(Int)
    case playlist(UUID)
    case localList(UUID)
    case machineMacro(Int)
    case keys

    public var description: String {
        switch self {
        case .list(let uuid): return "list " + uuid.uuidString.lowercased()
        case .libraryMacro(let number): return "macro \(number)"
        case .playlist(let uuid): return "playlist " + uuid.uuidString.lowercased()
        case .localList(let uuid): return "local copy " + uuid.uuidString.lowercased()
        case .machineMacro(let number): return "machine macro \(number)"
        case .keys: return "key bindings"
        }
    }

    /// The document lives in the library root (else the machine root).
    public var inLibrary: Bool {
        switch self {
        case .list, .libraryMacro: return true
        case .playlist, .localList, .machineMacro, .keys: return false
        }
    }
}

/// Spec 5 §2 — "The engine writes a changed document": the documents that
/// differ between the roots before an applied group and after it, created
/// ones included, in the roots' order. A deleted document isn't among them:
/// its file goes by the edit's `StructureChange`. A move alone isn't either:
/// "Moving a list or a folder is a rename on disk, not a save" (Spec 7 §2).
public enum DocumentChanges {
    public static func between(_ old: (library: Library, machine: Machine),
                               _ new: (library: Library, machine: Machine)) -> [DocumentRef] {
        var out: [DocumentRef] = []
        let lists = Dictionary(old.library.lists.map { ($0.uuid, $0) }, uniquingKeysWith: { first, _ in first })
        for list in new.library.lists where lists[list.uuid] != list { out.append(.list(list.uuid)) }
        let macros = Dictionary(old.library.macros.map { ($0.number, $0) }, uniquingKeysWith: { first, _ in first })
        for macro in new.library.macros where macros[macro.number] != macro { out.append(.libraryMacro(macro.number)) }
        let playlists = Dictionary(old.machine.playlists.map { ($0.uuid, $0) }, uniquingKeysWith: { first, _ in first })
        for playlist in new.machine.playlists where playlists[playlist.uuid] != playlist { out.append(.playlist(playlist.uuid)) }
        let locals = Dictionary(old.machine.localLists.map { ($0.uuid, $0) }, uniquingKeysWith: { first, _ in first })
        for list in new.machine.localLists where locals[list.uuid] != list { out.append(.localList(list.uuid)) }
        let machineMacros = Dictionary(old.machine.macros.map { ($0.number, $0) }, uniquingKeysWith: { first, _ in first })
        for macro in new.machine.macros where machineMacros[macro.number] != macro { out.append(.machineMacro(macro.number)) }
        if old.machine.keys != new.machine.keys { out.append(.keys) }
        return out
    }

    /// Whether the roots hold the document.
    public static func exists(_ ref: DocumentRef, library: Library, machine: Machine) -> Bool {
        switch ref {
        case .list(let uuid): return library.list(uuid: uuid) != nil
        case .libraryMacro(let number): return library.macro(number) != nil
        case .playlist(let uuid): return machine.playlist(uuid: uuid) != nil
        case .localList(let uuid): return machine.localList(uuid: uuid) != nil
        case .machineMacro(let number): return machine.macro(number) != nil
        case .keys: return true
        }
    }
}
