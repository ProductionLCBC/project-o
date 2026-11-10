// OCore — Spec 5 §3 and §4, the edit family as command objects.

import Foundation

/// Spec 5 §3 — Addressing: "An edit names what it changes by number, by uuid
/// within its list or playlist, or by channel within a stack." The object
/// form names the type in `object` and "its number or uuid sits in a field
/// named after the type, with its parent's beside it" (Spec 5 §4).
public enum EditAddress: Equatable, Sendable {
    /// `list 42`; no number in `edit list create` until the engine picks one (Spec 7 §2).
    case list(Int?)
    /// `list 42 cue 22bb…`: "a cue, within its list".
    case cue(list: Int, cue: UUID)
    /// `folder "Worship/Hymns"`: "Library folders are real folders under `lists/`".
    case folder(String)
    /// `playlist 2b2b…`; none in `edit playlist create "Sunday"` until the engine picks one.
    case playlist(UUID?)
    /// `playlist 2b2b… item 4d4d…`: "a playlist item, within its playlist".
    case item(playlist: UUID, item: UUID)
    /// The other numbered objects (`channel 2`, `preset 3`, `textstyle 1`, ...),
    /// whose edits come with Areas 8, 14 and 17 (Spec 7 §7). Never `.list`.
    case numbered(NumberedType, Int?)
    /// `stack 2 slot 3`: "a slot, named by its channel".
    case slot(stack: Int, channel: Int)
    /// `keys keyboard "space"`: "a key binding, named by its device and key".
    case key(device: String, key: String)
    /// `keys`: the key bindings document.
    case keys
    /// `machine`: the machine settings.
    case machine
    /// `media sha256:…`: "Media index entries are named by id".
    case media(String)

    /// The `object` word of the object form.
    public var object: String {
        switch self {
        case .list: return "list"
        case .cue: return "cue"
        case .folder: return "folder"
        case .playlist: return "playlist"
        case .item: return "item"
        case .numbered(let type, _): return type.editWord
        case .slot: return "slot"
        case .key: return "key"
        case .keys: return "keys"
        case .machine: return "machine"
        case .media: return "media"
        }
    }
}

/// Spec 7 §3 — "The object form of `create`, `duplicate` and `archive` may
/// carry the uuids they make": the copy's `uuid`, and the new uuids of a
/// list's cues or a playlist's items, in order.
public struct EditPicks: Equatable, Sendable {
    public var uuid: UUID?
    public var cueUuids: [UUID]?
    public var itemUuids: [UUID]?

    public init(uuid: UUID? = nil, cueUuids: [UUID]? = nil, itemUuids: [UUID]? = nil) {
        self.uuid = uuid
        self.cueUuids = cueUuids
        self.itemUuids = itemUuids
    }

    public static let none = EditPicks()
    public var isEmpty: Bool { uuid == nil && cueUuids == nil && itemUuids == nil }
}

/// Spec 5 §4 — `edit.cueChannel`'s content state: "write with content and
/// riders, clear, or hold: the UX spec's three states".
public enum CueChannelState: Equatable, Sendable {
    case write(ContentExpression, Riders)
    case clear
    case hold

    /// The `state` word of the object form.
    public var name: String {
        switch self {
        case .write: return "write"
        case .clear: return "clear"
        case .hold: return "hold"
        }
    }
}

/// Spec 5 §4 — `edit.cueChannel`: "Sets everything a cue says about one
/// channel. That is its content state ... plus its standalone attribute
/// writes (`grade`, `transition`, `audiotransition`, `gain`; Spec 1 §6)".
/// `attributes` are the channel's `channel.grade`, `channel.transition`,
/// `channel.audioTransition` and `channel.gain` commands, in order; `at` is
/// where in the cue's commands, counted without the channel's old commands,
/// the channel's commands go, recorded when the engine picks it.
public struct CueChannelEdit: Equatable, Sendable {
    public var channel: Int
    public var state: CueChannelState
    public var attributes: [Command]
    public var at: Int?

    public init(channel: Int, state: CueChannelState, attributes: [Command] = [], at: Int? = nil) {
        self.channel = channel
        self.state = state
        self.attributes = attributes
        self.at = at
    }
}

/// Spec 5 §4 — `edit.section`: "Acts on the cue's section block ...
/// `duplicate` copies the block to just after itself with new uuids, `move`
/// moves it, `remove` removes it."
public enum SectionAction: Equatable, Sendable {
    case duplicate
    /// The block's first cue ends at position `at`, counted from 0.
    case move(at: Int)
    case remove

    public var name: String {
        switch self {
        case .duplicate: return "duplicate"
        case .move: return "move"
        case .remove: return "remove"
        }
    }
}

/// Spec 5 §4 — the verbs, each with its arguments.
public enum EditAction: Equatable, Sendable {
    /// "Sets one field at a path; a value equal to the current one is a `noop`".
    case set(path: String, value: JSONValue)
    /// "Removes a map entry or an optional key".
    case unset(path: String)
    /// "Creates a numbered object at a free number, a playlist, or a folder",
    /// with an optional JSON body; "A list can be created in a folder"; a
    /// playlist is created with its title (Spec 7 §3).
    case create(body: JSONValue?, folder: String?, title: String?)
    case delete
    case renumber(to: Int)
    /// Spec 5 §4 as Spec 7 corrected it — "`swap` names the other number as `with`".
    case swap(with: Int)
    /// "Inserts a value into an array at a path and position".
    case insert(path: String, at: Int, value: JSONValue)
    /// "Removes a child, by its own address or by position": no path for the
    /// addressed child itself.
    case remove(path: String?, at: Int?)
    /// "Moves a child to a position in its array; a child without an address
    /// of its own ... is named by its array's path and its position".
    case move(path: String?, from: Int?, at: Int)
    /// "Copies a child to just after itself with new uuids, or a numbered
    /// object to a free number ..., or a playlist under a new title".
    case duplicate(to: Int?, title: String?, picks: EditPicks)
    /// Spec 7 §5 — "Files a dated, read-only copy of a playlist".
    case archive(title: String?, picks: EditPicks)
    case section(SectionAction)
    /// `edit list 42 folder "Worship/Hymns"`: "Moves a list's file to another library folder".
    case folder(String)
    /// `edit folder "Worship" rename "Music"`.
    case rename(to: String)
    case cueChannel(CueChannelEdit)

    /// The verb of `cmd`: "`cmd` is `edit.` plus the verb".
    public var verb: String {
        switch self {
        case .set: return "set"
        case .unset: return "unset"
        case .create: return "create"
        case .delete: return "delete"
        case .renumber: return "renumber"
        case .swap: return "swap"
        case .insert: return "insert"
        case .remove: return "remove"
        case .move: return "move"
        case .duplicate: return "duplicate"
        case .archive: return "archive"
        case .section: return "section"
        case .folder: return "folder"
        case .rename: return "rename"
        case .cueChannel: return "cueChannel"
        }
    }

    /// Every verb's `cmd`.
    public static let commandNames: [String] = ["set", "unset", "create", "delete", "renumber", "swap", "insert", "remove",
                                                "move", "duplicate", "archive", "section", "folder", "rename", "cueChannel"]
        .map { "edit." + $0 }
}

/// Spec 5 §4 — one edit: "`edit OBJECT ADDRESS [VERB] [ARGUMENTS]`", stored
/// as a command object whose `cmd` is `edit.` plus the verb.
public struct EditCommand: Equatable, Sendable {
    public var address: EditAddress
    public var action: EditAction

    public init(_ address: EditAddress, _ action: EditAction) {
        self.address = address
        self.action = action
    }

    public var cmd: String { "edit." + action.verb }
}

// MARK: - Spec 5 §4, the object form

extension EditCommand {
    private static func corrupt(_ message: String) -> DecodingError {
        DecodingError.dataCorrupted(DecodingError.Context(codingPath: [], debugDescription: message))
    }

    private static func int(_ fields: [String: JSONValue], _ key: String) throws -> Int {
        guard let n = fields[key]?.intValue else { throw corrupt("\(key) must be a whole number") }
        return n
    }

    private static func intIfPresent(_ fields: [String: JSONValue], _ key: String) throws -> Int? {
        guard let value = fields[key], !value.isNull else { return nil }
        guard let n = value.intValue else { throw corrupt("\(key) must be a whole number") }
        return n
    }

    private static func string(_ fields: [String: JSONValue], _ key: String) throws -> String {
        guard let s = fields[key]?.stringValue else { throw corrupt("\(key) must be a string") }
        return s
    }

    private static func stringIfPresent(_ fields: [String: JSONValue], _ key: String) throws -> String? {
        guard let value = fields[key], !value.isNull else { return nil }
        guard let s = value.stringValue else { throw corrupt("\(key) must be a string") }
        return s
    }

    private static func uuid(_ fields: [String: JSONValue], _ key: String) throws -> UUID {
        guard let text = fields[key]?.stringValue, let u = UUID(uuidString: text) else { throw corrupt("\(key) must be a uuid") }
        return u
    }

    private static func uuidIfPresent(_ fields: [String: JSONValue], _ key: String) throws -> UUID? {
        guard let value = fields[key], !value.isNull else { return nil }
        guard let text = value.stringValue, let u = UUID(uuidString: text) else { throw corrupt("\(key) must be a uuid") }
        return u
    }

    private static func uuids(_ fields: [String: JSONValue], _ key: String) throws -> [UUID]? {
        guard let value = fields[key], !value.isNull else { return nil }
        guard let items = value.arrayValue else { throw corrupt("\(key) must be an array of uuids") }
        return try items.map { item in
            guard let text = item.stringValue, let u = UUID(uuidString: text) else { throw corrupt("\(key) must be an array of uuids") }
            return u
        }
    }

    static func picks(_ fields: [String: JSONValue]) throws -> EditPicks {
        EditPicks(uuid: try uuidIfPresent(fields, "uuid"), cueUuids: try uuids(fields, "cueUuids"),
                  itemUuids: try uuids(fields, "itemUuids"))
    }

    static func address(_ fields: [String: JSONValue]) throws -> EditAddress {
        let object = try string(fields, "object")
        switch object {
        case "list": return .list(try intIfPresent(fields, "list"))
        case "cue": return .cue(list: try int(fields, "list"), cue: try uuid(fields, "cue"))
        case "folder": return .folder(try string(fields, "folder"))
        case "playlist": return .playlist(try uuidIfPresent(fields, "playlist"))
        case "item": return .item(playlist: try uuid(fields, "playlist"), item: try uuid(fields, "item"))
        case "slot": return .slot(stack: try int(fields, "stack"), channel: try int(fields, "slot"))
        case "key": return .key(device: try string(fields, "device"), key: try string(fields, "key"))
        case "keys": return .keys
        case "machine": return .machine
        case "media": return .media(try string(fields, "media"))
        default:
            guard let type = NumberedType(editWord: object), type != .list else { throw corrupt("\(object) is not something an edit names") }
            return .numbered(type, try intIfPresent(fields, object))
        }
    }

    /// Spec 5 §4 — an edit from its object form: `cmd` and every parameter.
    /// A `DecodingError` makes the command `.invalid`, kept as read (Spec 1 §6).
    public init(cmd: String, fields: [String: JSONValue]) throws {
        let address = try EditCommand.address(fields)
        let f = fields
        let action: EditAction
        switch cmd {
        case "edit.set":
            guard let value = f["value"] else { throw EditCommand.corrupt("edit.set needs a value") }
            action = .set(path: try EditCommand.string(f, "path"), value: value)
        case "edit.unset":
            action = .unset(path: try EditCommand.string(f, "path"))
        case "edit.create":
            let body = f["value"].flatMap { $0.isNull ? nil : $0 }
            if let body, body.objectValue == nil { throw EditCommand.corrupt("a create's body must be an object") }
            let folder = address.object == "list" ? try EditCommand.stringIfPresent(f, "folder") : nil
            action = .create(body: body, folder: folder, title: try EditCommand.stringIfPresent(f, "title"))
        case "edit.delete":
            action = .delete
        case "edit.renumber":
            action = .renumber(to: try EditCommand.int(f, "to"))
        case "edit.swap":
            action = .swap(with: try EditCommand.int(f, "with"))
        case "edit.insert":
            guard let value = f["value"] else { throw EditCommand.corrupt("edit.insert needs a value") }
            action = .insert(path: try EditCommand.string(f, "path"), at: try EditCommand.int(f, "at"), value: value)
        case "edit.remove":
            let path = try EditCommand.stringIfPresent(f, "path")
            let at = try EditCommand.intIfPresent(f, "at")
            guard (path == nil) == (at == nil) else { throw EditCommand.corrupt("a remove by position needs both path and at") }
            action = .remove(path: path, at: at)
        case "edit.move":
            let path = try EditCommand.stringIfPresent(f, "path")
            let from = try EditCommand.intIfPresent(f, "from")
            guard (path == nil) == (from == nil) else { throw EditCommand.corrupt("a move by position needs both path and from") }
            action = .move(path: path, from: from, at: try EditCommand.int(f, "at"))
        case "edit.duplicate":
            action = .duplicate(to: try EditCommand.intIfPresent(f, "to"), title: try EditCommand.stringIfPresent(f, "title"),
                                picks: try EditCommand.picks(f))
        case "edit.archive":
            action = .archive(title: try EditCommand.stringIfPresent(f, "title"), picks: try EditCommand.picks(f))
        case "edit.section":
            switch try EditCommand.string(f, "action") {
            case "duplicate": action = .section(.duplicate)
            case "move": action = .section(.move(at: try EditCommand.int(f, "at")))
            case "remove": action = .section(.remove)
            case let other: throw EditCommand.corrupt("\(other) is not a section action")
            }
        case "edit.folder":
            guard address.object == "list" else { throw EditCommand.corrupt("edit.folder moves a list") }
            action = .folder(try EditCommand.string(f, "folder"))
        case "edit.rename":
            action = .rename(to: try EditCommand.string(f, "to"))
        case "edit.cueChannel":
            action = .cueChannel(try EditCommand.cueChannel(f))
        default:
            throw EditCommand.corrupt("\(cmd) is not an edit")
        }
        self.init(address, action)
    }

    static func cueChannel(_ f: [String: JSONValue]) throws -> CueChannelEdit {
        let channel = try int(f, "channel")
        let state: CueChannelState
        switch try string(f, "state") {
        case "write":
            // The write's content and riders, read by `channel.write`'s own decoder.
            var write: [String: JSONValue] = ["cmd": .string("channel.write"), "channel": .number(Double(channel))]
            for key in ["content", "transition", "audioTransition", "grade", "gain", "chase", "build"] { write[key] = f[key] }
            guard case .channelWrite(let w) = try JSONCoding.decode(Command.self, from: .object(write)) else {
                throw corrupt("the write's content or riders did not decode")
            }
            state = .write(w.content, w.riders)
        case "clear": state = .clear
        case "hold": state = .hold
        case let other: throw corrupt("\(other) is not write, clear or hold")
        }
        var attributes: [Command] = []
        if let raw = f["attributes"], !raw.isNull {
            guard let items = raw.arrayValue else { throw corrupt("attributes must be an array of commands") }
            for item in items {
                let command = try JSONCoding.decode(Command.self, from: item)
                guard command.isStandaloneAttribute(channel: channel) else {
                    throw corrupt("attributes holds channel \(channel)'s grade, transition, audiotransition and gain commands")
                }
                attributes.append(command)
            }
        }
        return CueChannelEdit(channel: channel, state: state, attributes: attributes, at: try intIfPresent(f, "at"))
    }

    /// Spec 5 §4 — the object form's parameters, everything but `cmd`.
    public var fields: [String: JSONValue] {
        var f: [String: JSONValue] = ["object": .string(address.object)]
        func put(_ key: String, _ n: Int?) { if let n { f[key] = .number(Double(n)) } }
        func put(_ key: String, _ u: UUID?) { if let u { f[key] = .string(u.uuidString.lowercased()) } }
        func put(_ key: String, _ s: String?) { if let s { f[key] = .string(s) } }
        switch address {
        case .list(let n): put("list", n)
        case .cue(let list, let cue):
            put("list", list)
            put("cue", cue)
        case .folder(let path): put("folder", path)
        case .playlist(let u): put("playlist", u)
        case .item(let playlist, let item):
            put("playlist", playlist)
            put("item", item)
        case .numbered(let type, let n): put(type.editWord, n)
        case .slot(let stack, let channel):
            put("stack", stack)
            put("slot", channel)
        case .key(let device, let key):
            put("device", device)
            put("key", key)
        case .keys, .machine: break
        case .media(let id): put("media", id)
        }
        func putPicks(_ picks: EditPicks) {
            put("uuid", picks.uuid)
            if let cues = picks.cueUuids { f["cueUuids"] = .array(cues.map { .string($0.uuidString.lowercased()) }) }
            if let items = picks.itemUuids { f["itemUuids"] = .array(items.map { .string($0.uuidString.lowercased()) }) }
        }
        switch action {
        case .set(let path, let value):
            f["path"] = .string(path)
            f["value"] = value
        case .unset(let path):
            f["path"] = .string(path)
        case .create(let body, let folder, let title):
            if let body { f["value"] = body }
            put("folder", folder)
            put("title", title)
        case .delete:
            break
        case .renumber(let to):
            put("to", to)
        case .swap(let with):
            put("with", with)
        case .insert(let path, let at, let value):
            f["path"] = .string(path)
            put("at", at)
            f["value"] = value
        case .remove(let path, let at):
            put("path", path)
            put("at", at)
        case .move(let path, let from, let at):
            put("path", path)
            put("from", from)
            put("at", at)
        case .duplicate(let to, let title, let picks):
            put("to", to)
            put("title", title)
            putPicks(picks)
        case .archive(let title, let picks):
            put("title", title)
            putPicks(picks)
        case .section(let section):
            f["action"] = .string(section.name)
            if case .move(let at) = section { put("at", at) }
        case .folder(let path):
            put("folder", path)
        case .rename(let to):
            put("to", to)
        case .cueChannel(let edit):
            put("channel", edit.channel)
            f["state"] = .string(edit.state.name)
            if case .write(let content, let riders) = edit.state,
               let object = (try? JSONCoding.encode(Command.channelWrite(ChannelWrite(channel: .number(edit.channel), content: content, riders: riders))))?.objectValue {
                for (key, value) in object where key != "cmd" && key != "channel" { f[key] = value }
            }
            if !edit.attributes.isEmpty {
                f["attributes"] = .array(edit.attributes.compactMap { try? JSONCoding.encode($0) })
            }
            put("at", edit.at)
        }
        return f
    }
}

extension EditCommand {
    /// Spec 1 §4 — "When an object's number changes, every internal
    /// reference in the library and the machine root is rewritten": an edit
    /// held by a cue or a macro names objects by number in its address, and
    /// `edit.cueChannel` names a channel and what its write refers to. JSON
    /// values are kept as written.
    public func mapReferences(_ transform: (NumberedType, Int) -> Int) -> EditCommand {
        var e = self
        switch address {
        case .list(let n?): e.address = .list(transform(.list, n))
        case .cue(let list, let cue): e.address = .cue(list: transform(.list, list), cue: cue)
        case .numbered(let type, let n?): e.address = .numbered(type, transform(type, n))
        case .slot(let stack, let channel): e.address = .slot(stack: transform(.stack, stack), channel: transform(.channel, channel))
        default: break
        }
        if case .cueChannel(var c) = action {
            c.attributes = c.attributes.map { $0.mapReferences(transform) }
            if case .write(let content, let riders) = c.state,
               case .channelWrite(let w) = Command.channelWrite(ChannelWrite(channel: .number(c.channel), content: content, riders: riders))
                .mapReferences(transform) {
                c.state = .write(w.content, w.riders)
            }
            c.channel = transform(.channel, c.channel)
            e.action = .cueChannel(c)
        }
        return e
    }
}

extension Command {
    /// Spec 5 §4 — one of the standalone attribute writes `edit.cueChannel`
    /// carries beside the content state: `channel.grade`, `channel.transition`,
    /// `channel.audioTransition` or `channel.gain` on that channel.
    public func isStandaloneAttribute(channel: Int) -> Bool {
        switch self {
        case .channelGrade(.number(let n), _, _), .channelTransition(.number(let n), _, _),
             .channelAudioTransition(.number(let n), _, _), .channelGain(.number(let n), _):
            return n == channel
        default:
            return false
        }
    }
}
