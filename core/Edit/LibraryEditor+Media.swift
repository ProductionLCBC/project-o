// OCore — Spec 5 §3 and §6, the defaults of media index entries, which Spec 7 §7 gives Area 8.

import Foundation

extension Editor {
    /// Spec 5 §3 — "Media index entries are named by id (`media sha256:…`).
    /// Only their `defaults` can be edited; the rest is read from the file
    /// (Spec 1 §7). An edit writes whichever index tier holds the entry: the
    /// library index, or the machine index for media that exists only on
    /// this machine (M11)." Spec 8 §5 — "after an edit changes
    /// `defaults.trimInMs`. The new in-point gives the poster a new name":
    /// a video's `poster` names the frame at its new in-point in the same
    /// edit, and the media worker then makes that frame and its tile.
    ///
    /// `set` takes a value of the field's type in its range (Spec 5 §6, check
    /// 4; Spec 2 §8's ±60 dB gain and ±1000 ms offset); a grade or channel it
    /// names exists (check 5). `unset` puts a field back to none (`loop` to
    /// false), as an import leaves it. Each inverts to `set` with the value
    /// before.
    mutating func editMedia(_ id: String, _ action: EditAction) throws -> (EditCommand, EditCommand?) {
        guard let (entry, tier) = MediaResolver.entry(for: id, library: library.mediaIndex, machine: machine.mediaLocal) else {
            throw reject(.unknownObject, "\(id) isn't in either media index")
        }
        let field: String
        let value: JSONValue
        switch action {
        case .set(let path, let given):
            field = try mediaField(path)
            value = given
        case .unset(let path):
            field = try mediaField(path)
            value = field == "loop" ? .bool(false) : .null
        default:
            throw reject(.badValue, "\(action.verb) doesn't apply to media: only its defaults are set and unset")
        }
        var defaults = entry.defaults
        let previous = Self.mediaDefault(field, of: defaults)
        try setMediaDefault(field, value, in: &defaults, of: entry)
        let logged = EditCommand(.media(id), action)
        guard defaults != entry.defaults else { return (logged, nil) }
        var updated = entry
        updated.defaults = defaults
        var paths = ["defaults." + field]
        if field == "trimInMs", updated.kind == .video, updated.poster != nil {
            updated.poster = MediaPosters.posterPath(of: updated)
            if updated.poster != entry.poster { paths.append("poster") }
        }
        switch tier {
        case .library:
            if let i = library.mediaIndex.position(of: id) { library.mediaIndex.entries[i] = updated }
        case .machine:
            if let i = machine.mediaLocal.position(of: id) { machine.mediaLocal.entries[i] = updated }
        }
        changes.append(LibraryChange(object: "media", address: ["media": .string(id)], paths: paths))
        return (logged, EditCommand(.media(id), .set(path: "defaults." + field, value: previous)))
    }

    /// Spec 5 §6, check 3 — the path names one of the defaults; the entry's
    /// other fields are "read from the file".
    func mediaField(_ path: String) throws -> String {
        let fields = ["trimInMs", "trimOutMs", "loop", "gain", "grade", "syncOffsetMs", "defaultChannel"]
        if path.hasPrefix("defaults.") {
            let field = String(path.dropFirst("defaults.".count))
            guard fields.contains(field) else { throw reject(.unknownPath, "a media item's defaults have no \(field)") }
            return field
        }
        let fromFile = ["id", "path", "kind", "size", "modified", "durationMs", "fps", "width", "height", "hasAudio", "hasAlpha",
                        "codec", "poster", "addedAt", "folder", "deletedAt", "defaults"]
        if fromFile.contains(path) {
            throw reject(.readOnlyField, "a media item's \(path) is read from its file; only its defaults are edited")
        }
        throw reject(.unknownPath, "a media item has no field \(path)")
    }

    /// A default's value as the index writes it.
    static func mediaDefault(_ field: String, of d: MediaDefaults) -> JSONValue {
        func number(_ n: Int?) -> JSONValue { n.map { .number(Double($0)) } ?? .null }
        switch field {
        case "trimInMs": return number(d.trimInMs)
        case "trimOutMs": return number(d.trimOutMs)
        case "loop": return .bool(d.loop)
        case "gain": return d.gain.map { .number($0) } ?? .null
        case "grade": return number(d.grade)
        case "syncOffsetMs": return number(d.syncOffsetMs)
        default: return number(d.defaultChannel)
        }
    }

    /// Spec 5 §6, checks 4 and 5 — one default, typed and range-checked.
    func setMediaDefault(_ field: String, _ value: JSONValue, in d: inout MediaDefaults, of entry: MediaEntry) throws {
        func integer() throws -> Int? {
            if value.isNull { return nil }
            guard let n = value.doubleValue, n.rounded() == n, abs(n) < 1e12 else {
                throw reject(.badValue, "defaults.\(field) is a whole number or null, not \(CommandPrinter.valueText(value))")
            }
            return Int(n)
        }
        switch field {
        case "trimInMs", "trimOutMs":
            let ms = try integer()
            if let ms {
                guard ms >= 0 else { throw reject(.badValue, "defaults.\(field) is 0 or more") }
                if let duration = entry.durationMs, ms > duration {
                    throw reject(.badValue, "defaults.\(field) \(ms) is past the item's end, \(duration) ms")
                }
            }
            if field == "trimInMs" { d.trimInMs = ms } else { d.trimOutMs = ms }
            if let inMs = d.trimInMs, let outMs = d.trimOutMs, outMs <= inMs {
                throw reject(.badValue, "the out-point \(outMs) ms comes before the in-point \(inMs) ms")
            }
        case "loop":
            guard let b = value.boolValue else { throw reject(.badValue, "defaults.loop is true or false") }
            d.loop = b
        case "gain":
            if value.isNull {
                d.gain = nil
            } else {
                guard let db = value.doubleValue, db >= -60, db <= 60 else { throw reject(.badValue, "defaults.gain is within ±60 dB, or null") }
                d.gain = db
            }
        case "grade":
            let n = try integer()
            if let n, library.grade(n) == nil { throw reject(.unknownReference, "there is no grade \(n)") }
            d.grade = n
        case "syncOffsetMs":
            let n = try integer()
            if let n, abs(n) > 1000 { throw reject(.badValue, "defaults.syncOffsetMs is within ±1000 ms, or null") }
            d.syncOffsetMs = n
        default:
            let n = try integer()
            if let n, library.channel(n) == nil { throw reject(.unknownReference, "there is no channel \(n)") }
            d.defaultChannel = n
        }
    }
}
