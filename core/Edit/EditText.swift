// OCore — Spec 5 §3 and §4, the edit family's canonical text: parsing and printing.

import Foundation

// MARK: - Parsing

extension CommandParser {
    /// Spec 5 §4 — "The text form is `edit OBJECT ADDRESS [VERB] [ARGUMENTS]`.
    /// When the word after the address is a path, the verb is `set` ... The
    /// other verbs are reserved words that no field uses." Spec 5 §3 — "The
    /// command bar accepts `list 42 cue 3`, `playlist "Sunday"` and `playlist
    /// "Sunday" item 4` as short forms. It expands them to uuids when it
    /// parses": with the library and machine in `ParseOptions`.
    mutating func parseEditCommand() throws -> Command {
        let address = try parseEditAddress()
        let action = try parseEditAction(for: address)
        return .edit(EditCommand(address, action))
    }

    // MARK: Spec 5 §3, the address

    mutating func parseEditAddress() throws -> EditAddress {
        guard let t = next() else {
            throw reject(.missingArgument, "edit needs what it changes: list, folder, playlist, channel, ...")
        }
        guard case .word(let raw) = t else { throw reject(.badArgument, "edit needs what it changes, not \(t.described)") }
        let word = raw.lowercased()
        switch word {
        case "list":
            guard let number = try optionalPositiveInt("a list number") else { return .list(nil) }
            guard peekWordLower() == "cue" else { return .list(number) }
            advance()
            return .cue(list: number, cue: try cueRef(list: number))
        case "folder":
            guard let t = next() else { throw reject(.missingArgument, "folder needs its path in quotes") }
            guard case .string(let path) = t else { throw reject(.badArgument, "folder needs its path in quotes, not \(t.described)") }
            return .folder(path)
        case "playlist":
            guard let playlist = try playlistRef() else { return .playlist(nil) }
            guard peekWordLower() == "item" else { return .playlist(playlist) }
            advance()
            return .item(playlist: playlist, item: try itemRef(playlist: playlist))
        case "stack":
            guard let number = try optionalPositiveInt("a stack number") else { return .numbered(.stack, nil) }
            guard peekWordLower() == "slot" else { return .numbered(.stack, number) }
            advance()
            return .slot(stack: number, channel: try intToken(what: "slot needs its channel's number"))
        case "keys":
            // `keys DEVICE "KEY"` names a binding; `keys` alone the document.
            if case .string(let key)? = token(at: 1) {
                switch peek() {
                case .word(let device)?, .string(let device)?:
                    advance()
                    advance()
                    return .key(device: device, key: key)
                default:
                    break
                }
            }
            return .keys
        case "machine":
            return .machine
        case "media":
            guard let t = next() else { throw reject(.missingArgument, "media needs an id (sha256:...)") }
            guard case .word(let w) = t else { throw reject(.badArgument, "media needs an id (sha256:...), not \(t.described)") }
            return .media(try mediaRef(w))
        default:
            guard let type = NumberedType(editWord: word), type != .list else {
                throw reject(.unknownTarget, "\(raw) is not something an edit changes")
            }
            return .numbered(type, try optionalPositiveInt("a \(type.displayName) number"))
        }
    }

    mutating func optionalPositiveInt(_ what: String) throws -> Int? {
        guard case .number(let lexeme)? = peek() else { return nil }
        guard let n = Int(lexeme), n >= 1 else { throw reject(.badArgument, "\(what) must be 1 or more, not \(lexeme)") }
        advance()
        return n
    }

    /// A cue by uuid, or, with the library, by its 1-based number (Spec 5 §3's short form).
    mutating func cueRef(list number: Int) throws -> UUID {
        guard let t = next() else { throw reject(.missingArgument, "cue needs its uuid") }
        switch t {
        case .word(let w):
            guard let uuid = UUID(uuidString: w) else { throw reject(.badArgument, "\(w) is not a cue uuid") }
            return uuid
        case .number(let lexeme):
            guard let position = Int(lexeme) else { throw reject(.badArgument, "\(lexeme) is not a cue number") }
            guard let library = options.library else {
                throw reject(.badArgument, "list \(number) cue \(position) is a short form; name the cue by its uuid")
            }
            guard let cue = library.list(number: number)?.cue(at: position) else {
                throw reject(.badArgument, "list \(number) has no cue \(position)")
            }
            return cue.uuid
        default:
            throw reject(.badArgument, "cue needs its uuid, not \(t.described)")
        }
    }

    /// A playlist by uuid, or, with the machine, by its title (Spec 5 §3's
    /// short form); nil when none follows, as in `edit playlist create "Sunday"`.
    mutating func playlistRef() throws -> UUID? {
        switch peek() {
        case .word(let w)?:
            guard let uuid = UUID(uuidString: w) else { return nil }
            advance()
            return uuid
        case .string(let title)?:
            // `edit playlist create "Sunday"` puts the title after the verb, never here.
            advance()
            guard let machine = options.machine else {
                throw reject(.badArgument, "playlist \"\(title)\" is a short form; name the playlist by its uuid")
            }
            guard let playlist = machine.playlist(titled: title) else {
                throw reject(.badArgument, "no playlist \"\(title)\" on this machine")
            }
            return playlist.uuid
        default:
            return nil
        }
    }

    /// An item by uuid, or, with the machine, by its 1-based position (Spec 5 §3's short form).
    mutating func itemRef(playlist uuid: UUID) throws -> UUID {
        guard let t = next() else { throw reject(.missingArgument, "item needs its uuid") }
        switch t {
        case .word(let w):
            guard let item = UUID(uuidString: w) else { throw reject(.badArgument, "\(w) is not an item uuid") }
            return item
        case .number(let lexeme):
            guard let position = Int(lexeme) else { throw reject(.badArgument, "\(lexeme) is not an item number") }
            guard let machine = options.machine else {
                throw reject(.badArgument, "item \(position) is a short form; name the item by its uuid")
            }
            guard let playlist = machine.playlist(uuid: uuid), position >= 1, position <= playlist.items.count else {
                throw reject(.badArgument, "the playlist has no item \(position)")
            }
            return playlist.items[position - 1].uuid
        default:
            throw reject(.badArgument, "item needs its uuid, not \(t.described)")
        }
    }

    // MARK: Spec 5 §4, the verb and its arguments

    mutating func parseEditAction(for address: EditAddress) throws -> EditAction {
        guard let t = peek() else { throw reject(.missingArgument, "edit needs a verb or a field path after what it changes") }
        guard case .word(let raw) = t else { throw reject(.badArgument, "expected a verb or a field path, not \(t.described)") }
        let verb = raw.lowercased()
        switch verb {
        case "unset":
            advance()
            return .unset(path: try pathWord())
        case "create":
            advance()
            return try parseCreate(for: address)
        case "delete":
            advance()
            return .delete
        case "renumber":
            advance()
            return .renumber(to: try intToken(what: "renumber needs the new number"))
        case "swap":
            advance()
            return .swap(with: try intToken(what: "swap needs the other number"))
        case "insert":
            advance()
            let path = try pathWord()
            let at = try intToken(what: "insert needs a position, counted from 0")
            return .insert(path: path, at: at, value: try parseEditValue())
        case "remove":
            advance()
            guard case .word? = peek() else { return .remove(path: nil, at: nil) }
            let path = try pathWord()
            return .remove(path: path, at: try intToken(what: "remove needs the position to remove, counted from 0"))
        case "move":
            advance()
            if case .number? = peek() {
                return .move(path: nil, from: nil, at: try intToken(what: "move needs a position"))
            }
            let path = try pathWord()
            let from = try intToken(what: "move needs the position it moves from, counted from 0")
            return .move(path: path, from: from, at: try intToken(what: "move needs the position it moves to, counted from 0"))
        case "duplicate":
            advance()
            var to: Int?
            var title: String?
            switch peek() {
            case .number?: to = try intToken(what: "duplicate takes the copy's number")
            case .string(let s)?:
                advance()
                title = s
            default: break
            }
            return .duplicate(to: to, title: title, picks: try parsePicks())
        case "archive" where address.object == "playlist":
            advance()
            var title: String?
            if case .string(let s)? = peek() {
                advance()
                title = s
            }
            return .archive(title: title, picks: try parsePicks())
        case "section" where address.object == "cue" && ["duplicate", "move", "remove"].contains(lowerWord(at: 1) ?? ""):
            advance()
            let action = lowerWord(at: 0) ?? ""
            advance()
            switch action {
            case "duplicate": return .section(.duplicate)
            case "move": return .section(.move(at: try intToken(what: "section move needs a position, counted from 0")))
            default: return .section(.remove)
            }
        case "folder" where address.object == "list":
            advance()
            guard let p = next() else { throw reject(.missingArgument, "folder needs the folder's path in quotes, \"\" for the top") }
            guard case .string(let path) = p else { throw reject(.badArgument, "folder needs the folder's path in quotes, not \(p.described)") }
            return .folder(path)
        case "rename" where address.object == "folder":
            advance()
            guard let p = next() else { throw reject(.missingArgument, "rename needs the new path in quotes") }
            guard case .string(let path) = p else { throw reject(.badArgument, "rename needs the new path in quotes, not \(p.described)") }
            return .rename(to: path)
        case "channel" where address.object == "cue":
            advance()
            return .cueChannel(try parseCueChannel())
        default:
            // Spec 5 §4 — "When the word after the address is a path, the verb is `set`."
            advance()
            return .set(path: raw, value: try parseEditValue())
        }
    }

    func lowerWord(at offset: Int) -> String? {
        if case .word(let w)? = token(at: offset) { return w.lowercased() }
        return nil
    }

    /// Spec 5 §3 — "field names as they appear on disk, joined by dots, with
    /// array positions as numbers from 0 and map keys as written". Kept as written.
    mutating func pathWord() throws -> String {
        guard let t = next() else { throw reject(.missingArgument, "expected a field path") }
        guard case .word(let path) = t else { throw reject(.badArgument, "expected a field path, not \(t.described)") }
        return path
    }

    /// `create [folder "PATH"] ["TITLE"] [{body}]`: a list in a folder, a
    /// playlist with its title, any object with a JSON body (Spec 5 §4, Spec 7 §2–§3).
    mutating func parseCreate(for address: EditAddress) throws -> EditAction {
        var folder: String?
        var title: String?
        var body: JSONValue?
        if address.object == "list", peekWordLower() == "folder" {
            advance()
            guard let p = next() else { throw reject(.missingArgument, "folder needs the folder's path in quotes") }
            guard case .string(let path) = p else { throw reject(.badArgument, "folder needs the folder's path in quotes, not \(p.described)") }
            folder = path
        }
        if address.object == "playlist", case .string(let s)? = peek() {
            advance()
            title = s
        }
        if case .json(let value)? = peek() {
            guard value.objectValue != nil else { throw reject(.badArgument, "a create's body is a JSON object") }
            advance()
            body = value
        }
        return .create(body: body, folder: folder, title: title)
    }

    /// Spec 5 §3 — "In the text form a value is a Spec 2 §2 token (integer,
    /// decimal, duration, string, ref or keyword), or a JSON literal for
    /// anything structured ... `null` is a value". A bare word other than
    /// `true`, `false` and `null` is read as a string.
    mutating func parseEditValue() throws -> JSONValue {
        guard let t = next() else { throw reject(.missingArgument, "the edit needs a value") }
        switch t {
        case .json(let value): return value
        case .string(let s): return .string(s)
        case .number(let lexeme):
            guard let d = Double(lexeme) else { throw reject(.badArgument, "\(lexeme) is not a number") }
            return .number(d)
        case .word(let w):
            switch w {
            case "true": return .bool(true)
            case "false": return .bool(false)
            case "null": return .null
            default: return .string(w)
            }
        case .bracket:
            throw reject(.badArgument, "expected a value (a quoted string, a number, true, false, null or JSON), not \(t.described)")
        }
    }

    /// Spec 7 §3, Spec 5 §4 as corrected — the uuids an edit made, printed as
    /// one JSON object at the end: `uuid`, `cueUuids`, `itemUuids`.
    mutating func parsePicks() throws -> EditPicks {
        guard case .json(let value)? = peek() else { return .none }
        advance()
        guard let object = value.objectValue else { throw reject(.badArgument, "what the engine picked is a JSON object") }
        let unknown = Set(object.keys).subtracting(["uuid", "cueUuids", "itemUuids"])
        guard unknown.isEmpty else { throw reject(.badArgument, "unknown keys in the picks: \(unknown.sorted().joined(separator: ", "))") }
        do {
            return try EditCommand.picks(object)
        } catch {
            throw reject(.badArgument, "the picks did not read: \(JSONCoding.describe(error))")
        }
    }

    // MARK: Spec 5 §4, `channel N ...` on a cue

    /// `channel N [ATTRIBUTES] (write CONTENT [RIDERS] | clear | hold)
    /// [{"at": K}]`, attributes also accepted after `clear` and `hold`, as
    /// Spec 5's `… channel 2 hold grade 5` writes them.
    mutating func parseCueChannel() throws -> CueChannelEdit {
        let channel = try intToken(what: "channel needs a number")
        var attributes: [Command] = []
        try parseAttributes(channel: channel, into: &attributes)
        guard let t = next() else { throw reject(.missingArgument, "channel \(channel) needs write, clear or hold") }
        guard case .word(let w) = t else { throw reject(.badArgument, "expected write, clear or hold, not \(t.described)") }
        let state: CueChannelState
        switch w.lowercased() {
        case "write":
            var object: [String: JSONValue] = ["cmd": .string("channel.write"), "channel": .number(Double(channel))]
            try parseWrite(into: &object)
            guard case .channelWrite(let write) = try decode(object) else { throw reject(.malformed, "the write did not read") }
            state = .write(write.content, write.riders)
        case "clear":
            state = .clear
            try parseAttributes(channel: channel, into: &attributes)
        case "hold":
            state = .hold
            try parseAttributes(channel: channel, into: &attributes)
        default:
            throw reject(.badArgument, "expected write, clear or hold, not \(w)")
        }
        var at: Int?
        if case .json(let value)? = peek() {
            advance()
            guard let object = value.objectValue, Set(object.keys) == ["at"], let n = object["at"]?.intValue else {
                throw reject(.badArgument, "a channel edit records only where it goes: {\"at\": N}")
            }
            at = n
        }
        return CueChannelEdit(channel: channel, state: state, attributes: attributes, at: at)
    }

    /// The standalone attribute writes, each in `channel N VERB ...`'s form:
    /// `grade R [DURATION]`, `transition R [DURATION]`, `audiotransition R
    /// [DURATION]`, `gain DB`, each optionally ending in `track` (Spec 2 §2).
    mutating func parseAttributes(channel: Int, into attributes: inout [Command]) throws {
        while let word = peekWordLower() {
            let verb = Vocabulary.canonicalVerb(word, target: "channel")
            let command: Command
            switch verb {
            case "grade", "transition", "audiotransition":
                advance()
                let ref = try intToken(what: "\(verb) needs a number")
                var ms: Int?
                if let d = peek(), !isScopeWord(d), let value = durationMs(d) {
                    advance()
                    ms = value
                }
                switch verb {
                case "grade": command = .channelGrade(channel: .number(channel), ref: ref, ms: ms)
                case "transition": command = .channelTransition(channel: .number(channel), ref: ref, ms: ms)
                default: command = .channelAudioTransition(channel: .number(channel), ref: ref, ms: ms)
                }
            case "gain":
                advance()
                command = .channelGain(channel: .number(channel), db: try decimalToken(what: "gain needs a number in decibels"))
            default:
                return
            }
            if peekWordLower() == "track" {
                advance()
            } else if peekWordLower() == "once" {
                throw reject(.badArgument, "a standalone attribute write is always tracked (Spec 3 §3); for once, put the rider on a write")
            }
            attributes.append(command)
        }
    }
}

// MARK: - Printing

extension CommandPrinter {
    /// Spec 5 §3 — "Only the uuid form is printed and logged, so
    /// `parse(print(x)) == x` needs no library."
    static func printEdit(_ edit: EditCommand) -> String {
        var words = ["edit"] + addressWords(edit.address)
        switch edit.action {
        case .set(let path, let value):
            words += [path, valueText(value)]
        case .unset(let path):
            words += ["unset", path]
        case .create(let body, let folder, let title):
            words.append("create")
            if let folder { words += ["folder", quoted(folder)] }
            if let title { words.append(quoted(title)) }
            if let body { words.append(JSONCanonical.line(body)) }
        case .delete:
            words.append("delete")
        case .renumber(let to):
            words += ["renumber", String(to)]
        case .swap(let with):
            words += ["swap", String(with)]
        case .insert(let path, let at, let value):
            words += ["insert", path, String(at), valueText(value)]
        case .remove(let path, let at):
            words.append("remove")
            if let path, let at { words += [path, String(at)] }
        case .move(let path, let from, let at):
            words.append("move")
            if let path, let from { words += [path, String(from)] }
            words.append(String(at))
        case .duplicate(let to, let title, let picks):
            words.append("duplicate")
            if let to { words.append(String(to)) }
            if let title { words.append(quoted(title)) }
            if let text = picksText(picks) { words.append(text) }
        case .archive(let title, let picks):
            words.append("archive")
            if let title { words.append(quoted(title)) }
            if let text = picksText(picks) { words.append(text) }
        case .section(let action):
            words += ["section", action.name]
            if case .move(let at) = action { words.append(String(at)) }
        case .folder(let path):
            words += ["folder", quoted(path)]
        case .rename(let to):
            words += ["rename", quoted(to)]
        case .cueChannel(let c):
            words += ["channel", String(c.channel)]
            for attribute in c.attributes { words += attributeWords(attribute) }
            switch c.state {
            case .write(let content, let riders):
                // The write's own canonical text, without its `channel N`.
                words += printWrite(ChannelWrite(channel: .number(c.channel), content: content, riders: riders))
                    .split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true).dropFirst(2).map(String.init)
            case .clear: words.append("clear")
            case .hold: words.append("hold")
            }
            if let at = c.at { words.append(JSONCanonical.line(.object(["at": .number(Double(at))]))) }
        }
        return words.joined(separator: " ")
    }

    static func addressWords(_ address: EditAddress) -> [String] {
        func uuid(_ u: UUID) -> String { u.uuidString.lowercased() }
        switch address {
        case .list(let n): return ["list"] + (n.map { [String($0)] } ?? [])
        case .cue(let list, let cue): return ["list", String(list), "cue", uuid(cue)]
        case .folder(let path): return ["folder", quoted(path)]
        case .playlist(let u): return ["playlist"] + (u.map { [uuid($0)] } ?? [])
        case .item(let playlist, let item): return ["playlist", uuid(playlist), "item", uuid(item)]
        case .numbered(let type, let n): return [type.editWord] + (n.map { [String($0)] } ?? [])
        case .slot(let stack, let channel): return ["stack", String(stack), "slot", String(channel)]
        case .key(let device, let key): return ["keys", isBareWord(device) ? device : quoted(device), quoted(key)]
        case .keys: return ["keys"]
        case .machine: return ["machine"]
        case .media(let id): return ["media", id]
        }
    }

    /// A value as the text form writes it: strings quoted, numbers without an
    /// exponent, structured values as one-line JSON.
    static func valueText(_ value: JSONValue) -> String {
        switch value {
        case .null: return "null"
        case .bool(let b): return b ? "true" : "false"
        case .number(let n): return decimalText(n)
        case .string(let s): return quoted(s)
        case .array, .object: return JSONCanonical.line(value)
        }
    }

    static func picksText(_ picks: EditPicks) -> String? {
        guard !picks.isEmpty else { return nil }
        var object: [String: JSONValue] = [:]
        if let u = picks.uuid { object["uuid"] = .string(u.uuidString.lowercased()) }
        if let cues = picks.cueUuids { object["cueUuids"] = .array(cues.map { .string($0.uuidString.lowercased()) }) }
        if let items = picks.itemUuids { object["itemUuids"] = .array(items.map { .string($0.uuidString.lowercased()) }) }
        return JSONCanonical.line(.object(object))
    }

    /// A standalone attribute write's words after `channel N`: its verb and arguments.
    static func attributeWords(_ command: Command) -> [String] {
        switch command {
        case .channelGrade(_, let ref, let ms):
            return ["grade", String(ref)] + (ms.map { [DurationText.text(ms: $0, style: .seconds)] } ?? [])
        case .channelTransition(_, let ref, let ms):
            return ["transition", String(ref)] + (ms.map { [DurationText.text(ms: $0, style: .seconds)] } ?? [])
        case .channelAudioTransition(_, let ref, let ms):
            return ["audiotransition", String(ref)] + (ms.map { [DurationText.text(ms: $0, style: .seconds)] } ?? [])
        case .channelGain(_, let db):
            return ["gain", decimalText(db)]
        default:
            return []
        }
    }
}
