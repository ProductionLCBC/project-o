// OEngine — Spec 10 §3, the queries: what each one answers.

import CoreText
import Foundation
import OCore

/// Spec 10 §3, "Queries (Spec 2 §9's `query`)" — each answer is worked out
/// from one snapshot of the engine's values, taken when the build that took
/// the request finished, so "an answer reflects every event sent before it".
/// These run on the hub's worker, never the control thread: a catalog of a
/// large library is real work.
enum ApiQueries {
    /// The queries answered from a snapshot. `versions` and `snapshots` read
    /// files and stay with the area that built them (Spec 9 §6); `render`
    /// draws, on the thumbnail job's queue (Spec 11 §3).
    static let fromSnapshot: Set<String> = ["state", "catalog", "list", "media", "mediaUse", "listUse", "uses"]

    static func answer(_ what: String, _ request: [String: JSONValue], in snapshot: ApiSnapshot, machineRoot: URL?) -> Result<[String: JSONValue], Rejection> {
        switch what {
        case "state": return .success(state(in: snapshot))
        case "catalog": return .success(catalog(in: snapshot))
        case "list": return list(request, in: snapshot)
        case "media": return .success(media(in: snapshot, machineRoot: machineRoot))
        case "mediaUse": return mediaUse(request, in: snapshot)
        case "listUse": return listUse(request, in: snapshot)
        case "uses": return uses(request, in: snapshot)
        default: return .failure(Rejection(reason: .badValue, message: "there is no \(what) query"))
        }
    }

    // MARK: - state

    /// Spec 10 §3 — "ShowState (Spec 3 §2), the timers, and the `live`,
    /// `channels`, `popups`, `outputs` and `audio` events as their topics
    /// would send them now". With `seq`, the last line logged, and `rev`,
    /// the library revision (Spec 5 §2), which later events count on from.
    static func state(in snapshot: ApiSnapshot) -> [String: JSONValue] {
        ["state": (try? JSONCoding.encode(snapshot.state)) ?? .null,
         "timers": .array(ApiEvents.timers(in: snapshot)),
         "events": .array(ApiEvents.all(in: snapshot)),
         "seq": .number(Double(snapshot.seq)),
         "rev": .number(Double(snapshot.revision))]
    }

    // MARK: - catalog

    /// Spec 10 §3 — "Both roots' documents except the lists' cues and the
    /// media indexes ... and a summary of each list (number, uuid, title,
    /// author, copyright, ccli, `trackThrough`, version, folder, cue count,
    /// and whether it is a local copy); where two playlists share a title or
    /// two lists a number, it says which one the title or the number names
    /// (Spec 7 §2–§3)".
    ///
    /// `named` on a playlist is whether `playlist "TITLE"` loads it, and on a
    /// list whether `list N` fires it; it is false only for the one a twin
    /// hides. A local copy is fired through its playlist item, so its `named`
    /// is false.
    static func catalog(in snapshot: ApiSnapshot) -> [String: JSONValue] {
        let library = snapshot.library, machine = snapshot.machine
        func encoded<T: Encodable>(_ value: T) -> JSONValue { (try? JSONCoding.encode(value)) ?? .null }

        let lists: [JSONValue] = library.lists.map { list in
            summary(of: list, folder: library.folder(ofList: list.uuid) ?? "", local: false, named: library.list(number: list.number)?.uuid == list.uuid)
        } + machine.localLists.map { summary(of: $0, folder: "", local: true, named: false) }

        let playlists: [JSONValue] = machine.playlists.map { playlist in
            guard case .object(var members) = encoded(playlist) else { return .null }
            members["named"] = .bool(machine.playlist(titled: playlist.title)?.uuid == playlist.uuid)
            return .object(members)
        }

        return [
            "rev": .number(Double(snapshot.revision)),
            "library": .object([
                "info": encoded(library.info), "channels": encoded(library.channels), "textStyles": encoded(library.textStyles),
                "grades": encoded(library.grades), "transitions": encoded(library.transitions), "audioTransitions": encoded(library.audioTransitions),
                "presets": encoded(library.presets), "macros": encoded(library.macros), "folders": .array(library.folders.sorted().map(JSONValue.string)),
            ]),
            "machine": .object([
                "settings": encoded(machine.settings), "stacks": encoded(machine.stacks), "outputs": encoded(machine.outputs),
                "audioOutputs": encoded(machine.audioOutputs), "inputs": encoded(machine.inputs), "keys": encoded(machine.keys),
                "macros": encoded(machine.macros), "playlists": .array(playlists),
            ]),
            "lists": .array(lists),
        ]
    }

    static func summary(of list: List, folder: String, local: Bool, named: Bool) -> JSONValue {
        .object(["number": .number(Double(list.number)), "uuid": .string(list.uuid.uuidString.lowercased()), "title": .string(list.title),
                 "author": .string(list.author), "copyright": .string(list.copyright), "ccli": .string(list.ccli),
                 "trackThrough": .bool(list.trackThrough), "version": .number(Double(list.version)), "folder": .string(folder),
                 "cues": .number(Double(list.cues.count)), "local": .bool(local), "named": .bool(named)])
    }

    // MARK: - list

    /// Spec 10 §3 — "One list whole, by `listUuid`, `list` number or `local`
    /// uuid, with its folder. A linked item's list is asked for by its
    /// `listUuid`, since two lists can share a number (Spec 7 §2)".
    static func list(_ request: [String: JSONValue], in snapshot: ApiSnapshot) -> Result<[String: JSONValue], Rejection> {
        switch find(request, in: snapshot, allowLocal: true) {
        case .failure(let rejection): return .failure(rejection)
        case .success(let found):
            return .success(["list": (try? JSONCoding.encode(found.list)) ?? .null, "folder": .string(found.folder), "local": .bool(found.local)])
        }
    }

    /// The list a request names: a master by `listUuid` or by `list` number, or a local copy by `local` uuid.
    static func find(_ request: [String: JSONValue], in snapshot: ApiSnapshot, allowLocal: Bool) -> Result<(list: List, folder: String, local: Bool), Rejection> {
        if let text = request["listUuid"]?.stringValue {
            guard let uuid = UUID(uuidString: text) else { return .failure(Rejection(reason: .badValue, message: "listUuid isn't a uuid")) }
            guard let list = snapshot.library.list(uuid: uuid) else { return .failure(Rejection(reason: .unknownObject, message: "no list has the uuid \(text)")) }
            return .success((list, snapshot.library.folder(ofList: uuid) ?? "", false))
        }
        if let number = request["list"]?.intValue {
            guard let list = snapshot.library.list(number: number) else { return .failure(Rejection(reason: .unknownObject, message: "list \(number) does not exist")) }
            return .success((list, snapshot.library.folder(ofList: list.uuid) ?? "", false))
        }
        if allowLocal, let text = request["local"]?.stringValue {
            guard let uuid = UUID(uuidString: text) else { return .failure(Rejection(reason: .badValue, message: "local isn't a uuid")) }
            guard let list = snapshot.machine.localList(uuid: uuid) else { return .failure(Rejection(reason: .unknownObject, message: "no local copy has the uuid \(text)")) }
            return .success((list, "", true))
        }
        return .failure(Rejection(reason: .missingArgument, message: allowLocal ? "the query names its list as \"listUuid\", \"list\" or \"local\"" : "the query names its list as \"listUuid\" or \"list\""))
    }

    // MARK: - media, mediaUse, listUse

    /// Spec 10 §3 — "Every entry of both indexes, each with its index, its
    /// presence (`ok`, `missing` or `deleted`), what replaced it, its uses as
    /// `mediaUse` counts them in all, and its tile's file". The tile's file
    /// is given "relative to the machine root" (Spec 10 §3, "Thumbnails and
    /// tiles are files").
    static func media(in snapshot: ApiSnapshot, machineRoot: URL?) -> [String: JSONValue] {
        let entries = MediaCatalog.entries(library: snapshot.library, machine: snapshot.machine, files: { snapshot.mediaFiles[$0] ?? .absent }, tile: { entry in
            guard let name = MediaPosters.tileName(of: entry), snapshot.mediaTiles.contains(name), let folder = snapshot.tilesFolder else { return nil }
            return relative(folder.appendingPathComponent(name), to: machineRoot)
        })
        return ["media": .array(entries)]
    }

    /// Spec 8 §7 — "The use query answers the delete confirmation".
    static func mediaUse(_ request: [String: JSONValue], in snapshot: ApiSnapshot) -> Result<[String: JSONValue], Rejection> {
        guard let id = request["media"]?.stringValue else { return .failure(Rejection(reason: .badValue, message: "mediaUse names its item as \"media\"")) }
        guard MediaResolver.knownIds(library: snapshot.library.mediaIndex, machine: snapshot.machine.mediaLocal).contains(id) else {
            return .failure(Rejection(reason: .unknownObject, message: "\(id) isn't in either media index"))
        }
        return .success(MediaUse.of(id, library: snapshot.library, machine: snapshot.machine).fields)
    }

    /// Spec 10 §3 — "For a list (by `listUuid` or number), the playlists that
    /// link it, archived ones marked".
    static func listUse(_ request: [String: JSONValue], in snapshot: ApiSnapshot) -> Result<[String: JSONValue], Rejection> {
        switch find(request, in: snapshot, allowLocal: false) {
        case .failure(let rejection): return .failure(rejection)
        case .success(let found):
            let linking = snapshot.machine.playlists.filter { playlist in
                playlist.items.contains { snapshot.library.list(for: $0.kind)?.uuid == found.list.uuid }
            }
            return .success(["playlists": .array(linking.map { playlist in
                .object(["uuid": .string(playlist.uuid.uuidString.lowercased()), "title": .string(playlist.title), "archived": .bool(playlist.archived)])
            })])
        }
    }

    /// Spec 11 §3 — "`uses` lists what refers to a numbered object, counted
    /// over both roots' documents on this machine": `{ "what": "uses",
    /// "object": "preset", "preset": 3 }`, the number under the object's own
    /// name. "The engine answers from its loaded documents, so the answer is
    /// as fresh as the last `library` event." "`uses` is local and LAN alike."
    /// A kind that isn't one of the ten, or a number that isn't a whole
    /// number from 1, is `badValue`; a number no object has is answered for,
    /// with whatever still names it.
    static func uses(_ request: [String: JSONValue], in snapshot: ApiSnapshot) -> Result<[String: JSONValue], Rejection> {
        let names = Uses.objects.keys.sorted().joined(separator: ", ")
        guard let name = request["object"]?.stringValue else {
            return .failure(Rejection(reason: .missingArgument, message: "uses names the kind of its object as \"object\": \(names)"))
        }
        guard let type = Uses.objects[name] else {
            return .failure(Rejection(reason: .badValue, message: "uses has no object \"\(name)\": it is one of \(names)"))
        }
        guard let given = request[name] else {
            return .failure(Rejection(reason: .missingArgument, message: "uses names its \(name) by number, as \"\(name)\""))
        }
        guard let number = given.intValue, number >= 1 else {
            return .failure(Rejection(reason: .badValue, message: "uses names its \(name) by number, a whole number from 1"))
        }
        return .success(Uses.of(type, number, library: snapshot.library, machine: snapshot.machine).fields)
    }

    // MARK: - devices, fonts

    /// Spec 10 §3 — "Screens ..., DeckLink output ports ... and audio output
    /// devices", as the lister reads them now.
    static func devices(_ lister: any DeviceLister) -> [String: JSONValue] {
        guard case .object(let members)? = try? JSONCoding.encode(lister.devices()) else { return [:] }
        return members
    }

    /// Spec 10 §3 — "The fonts the engine resolves, installed and bundled
    /// (Spec 6 §4), each with its PostScript name and family". `bundled` is
    /// true for a face the engine draws from its own copy (Spec 6 §4: "an
    /// installed copy wins").
    static func fonts(_ library: FontLibrary = .shared) -> [String: JSONValue] {
        let collection = CTFontCollectionCreateFromAvailableFonts(nil)
        let descriptors = (CTFontCollectionCreateMatchingFontDescriptors(collection) as? [CTFontDescriptor]) ?? []
        var seen: Set<String> = []
        var fonts: [(name: String, family: String)] = []
        for descriptor in descriptors {
            guard let name = CTFontDescriptorCopyAttribute(descriptor, kCTFontNameAttribute) as? String, seen.insert(name).inserted else { continue }
            // A name that starts with a dot is one of the system's own interface faces, which no text style can ask for.
            guard !name.hasPrefix(".") else { continue }
            fonts.append((name, (CTFontDescriptorCopyAttribute(descriptor, kCTFontFamilyNameAttribute) as? String) ?? name))
        }
        fonts.sort { ($0.family, $0.name) < ($1.family, $1.name) }
        return ["fonts": .array(fonts.map { font in
            .object(["name": .string(font.name), "family": .string(font.family), "bundled": .bool(library.origin(of: font.name) == .bundled)])
        })]
    }

    // MARK: - thumbnails

    /// Spec 10 §3 — "For a list (by `listUuid`, number or `local` uuid) and `stack` S, each cue's thumbnail file or
    /// null. The engine queues the missing ones, and a `thumbnails` event follows each". In v1 the thumbnail job
    /// draws on the machine's thumbnail stack alone (Spec 4 §10), so another stack is refused.
    static func thumbnails(_ request: [String: JSONValue], in snapshot: ApiSnapshot, service: ThumbnailService?, machineRoot: URL?) -> Result<[String: JSONValue], Rejection> {
        let wanted = request["stack"]?.intValue ?? snapshot.machine.settings.thumbnailStack
        switch find(request, in: snapshot, allowLocal: true) {
        case .failure(let rejection): return .failure(rejection)
        case .success(let found):
            if let service, service.stack != wanted {
                return .failure(Rejection(reason: .notInV1, message: "thumbnails are drawn on the thumbnail stack, stack \(service.stack)"))
            }
            var missing = false
            let files: [JSONValue] = found.list.cues.map { cue in
                let url = service?.thumbnailURL(forCue: cue.uuid, in: found.list)
                if url == nil { missing = true }
                return .object(["cue": .string(cue.uuid.uuidString.lowercased()), "file": url.map { .string(relative($0, to: machineRoot)) } ?? .null])
            }
            if missing { service?.warm(list: found.list) }
            return .success(["stack": .number(Double(wanted)), "thumbnails": .array(files)])
        }
    }

    /// A file's path "relative to the machine root" when it is inside it, else as it is.
    static func relative(_ url: URL, to root: URL?) -> String {
        guard let root else { return url.path }
        let prefix = root.standardizedFileURL.path + "/"
        let path = url.standardizedFileURL.path
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
    }
}
