// OApp — Spec 11 §4, what each control of the Cues page sends.

import Foundation
import OCore

/// One of a cue's commands the Commands column lists, with its place in the cue's commands.
public struct CueCommandRow: Equatable, Sendable {
    public var position: Int
    public var entry: GuardedCommand
}

/// Spec 11 §4 — the Cues page's edits, each a row of §13's table: one
/// function, one edit or one group, source `ui`. Spec 11 §1 — "A control
/// sends one Spec 5 edit, or one group of them, when it commits; the app
/// writes nothing in the roots".
public enum CueEdits {
    private static func edit(_ address: EditAddress, _ action: EditAction) -> Sending {
        Sending([.edit(EditCommand(address, action))])
    }

    private static func value<T: Encodable>(_ encodable: T) -> JSONValue {
        (try? JSONCoding.encode(encodable)) ?? .null
    }

    /// One `edit.cueChannel`, or nil when it would say what the cue says already.
    private static func cueChannel(_ channel: Int, _ state: CueChannelState, _ attributes: [Command], cue: Cue, list: Int) -> Sending? {
        let says = CueSays.about(channel, in: cue)
        guard says.state != state || says.attributes != attributes else { return nil }
        return edit(.cue(list: list, cue: cue.uuid), .cueChannel(CueChannelEdit(channel: channel, state: state, attributes: attributes)))
    }

    /// Several cues' edits as one group; nil when none has anything to send.
    public static func group(_ sendings: [Sending?]) -> Sending? {
        let commands = sendings.compactMap { $0 }.flatMap(\.commands)
        return commands.isEmpty ? nil : Sending(commands)
    }

    // MARK: - Write, Clear, Hold (Spec 11 §4, "The Channel column")

    /// Which attribute a standalone attribute command writes.
    static func kind(of command: Command) -> CueAttribute.Kind? {
        switch command {
        case .channelTransition: return .transition
        case .channelAudioTransition: return .audioTransition
        case .channelGrade: return .grade
        case .channelGain: return .gain
        default: return nil
        }
    }

    /// "Leaving a write for Clear or Hold keeps each of its `track` riders as
    /// a standalone attribute write and drops its `once` riders, so what
    /// tracks from this cue on doesn't change (Spec 3 §3)."
    private static func leaving(_ says: CueSays, channel: Int) -> [Command] {
        guard case .write(_, let riders) = says.state else { return says.attributes }
        var tracked: [Command] = []
        if let r = riders.transition, r.scope == .track { tracked.append(.channelTransition(channel: .number(channel), ref: r.ref, ms: r.ms)) }
        if let r = riders.audioTransition, r.scope == .track { tracked.append(.channelAudioTransition(channel: .number(channel), ref: r.ref, ms: r.ms)) }
        if let r = riders.grade, r.scope == .track { tracked.append(.channelGrade(channel: .number(channel), ref: r.ref, ms: r.ms)) }
        if let r = riders.gain, r.scope == .track { tracked.append(.channelGain(channel: .number(channel), db: r.db)) }
        let kinds = Set(tracked.compactMap(kind))
        return says.attributes.filter { command in kind(of: command).map { !kinds.contains($0) } ?? true } + tracked
    }

    /// "Clear writes `empty`", "keeping the channel's standalone attribute writes".
    public static func clear(channel: Int, cue: Cue, list: Int) -> Sending? {
        cueChannel(channel, .clear, leaving(CueSays.about(channel, in: cue), channel: channel), cue: cue, list: list)
    }

    /// "Hold removes the content command."
    public static func hold(channel: Int, cue: Cue, list: Int) -> Sending? {
        cueChannel(channel, .hold, leaving(CueSays.about(channel, in: cue), channel: channel), cue: cue, list: list)
    }

    /// Whether two contents are the same thing edited, rather than a new pick.
    private static func isSame(_ a: ContentExpression, _ b: ContentExpression) -> Bool {
        switch (a, b) {
        case (.text, .text), (.input, .input): return true
        case (.media(let x), .media(let y)): return x.ref == y.ref
        case (.slide(let x, _), .slide(let y, _)): return x == y
        default: return false
        }
    }

    /// What the content popover commits. The same write edited (its text's
    /// fields, its item's trim and loop) keeps every rider; "a new pick for a
    /// write keeps its transition and audio-transition riders and the
    /// attribute writes, as a drop does (Spec 10 §10)". On a held or cleared
    /// cell this is the first thing the cell writes.
    public static func write(_ content: ContentExpression, channel: Int, cue: Cue, list: Int) -> Sending? {
        let says = CueSays.about(channel, in: cue)
        var riders = Riders()
        if case .write(let before, let had) = says.state {
            if isSame(before, content) {
                riders = had
            } else {
                riders.transition = had.transition
                riders.audioTransition = had.audioTransition
            }
        }
        return cueChannel(channel, .write(content, riders), says.attributes, cue: cue, list: list)
    }

    /// A media item picked in the popover or dropped on a cell: Spec 10
    /// §10's drop, "with the item's default grade as a `grade G once` rider".
    public static func pick(media id: String, defaultGrade: Int?, channel: Int, cue: Cue, list: Int) -> Sending {
        Edits.write(media: id, defaultGrade: defaultGrade, on: channel, cue: cue, list: list)
    }

    /// The same pick with the popover's overrides on it: "for the chosen
    /// item its trim (in and out) and loop as overrides on the write (choice
    /// A-6)". Nil when the cue writes exactly that already.
    public static func pick(_ content: MediaContent, defaultGrade: Int?, channel: Int, cue: Cue, list: Int) -> Sending? {
        let says = CueSays.about(channel, in: cue)
        var riders = Riders()
        if case .write(_, let before) = says.state {
            riders.transition = before.transition
            riders.audioTransition = before.audioTransition
        }
        riders.grade = defaultGrade.map { GradeRider(ref: $0, scope: .once) }
        return cueChannel(channel, .write(.media(content), riders), says.attributes, cue: cue, list: list)
    }

    /// "Loop only turns looping on, since a write can't refuse an item's own
    /// loop (Spec 3 §4)": off is no override, and the item's own loop stands.
    public static func loop(_ on: Bool, on content: MediaContent) -> MediaContent {
        var content = content
        content.loop = on
        return content
    }

    // MARK: - Chips (Spec 11 §4, "Attribute chips")

    private static func command(_ attribute: CueAttribute, channel: Int) -> Command {
        switch attribute.kind {
        case .transition: return .channelTransition(channel: .number(channel), ref: attribute.ref ?? 1, ms: attribute.ms)
        case .audioTransition: return .channelAudioTransition(channel: .number(channel), ref: attribute.ref ?? 1, ms: attribute.ms)
        case .grade: return .channelGrade(channel: .number(channel), ref: attribute.ref ?? 0, ms: attribute.ms)
        case .gain: return .channelGain(channel: .number(channel), db: attribute.db ?? 0)
        }
    }

    /// "On a write the chip is a rider; with Clear or Hold it is a standalone
    /// attribute command, which is always `track` (Spec 1 §6) ... Each change
    /// is one `edit.cueChannel`." Nil when the cue says it already.
    public static func set(_ attribute: CueAttribute, channel: Int, cue: Cue, list: Int) -> Sending? {
        let says = CueSays.about(channel, in: cue)
        var attributes = says.attributes
        if case .write(let content, var riders) = says.state {
            switch attribute.kind {
            case .transition: riders.transition = TransitionRider(ref: attribute.ref ?? 1, ms: attribute.ms, scope: attribute.scope)
            case .audioTransition: riders.audioTransition = TransitionRider(ref: attribute.ref ?? 1, ms: attribute.ms, scope: attribute.scope)
            case .grade: riders.grade = GradeRider(ref: attribute.ref ?? 0, ms: attribute.ms, scope: attribute.scope)
            case .gain: riders.gain = GainRider(db: attribute.db ?? 0, scope: attribute.scope)
            }
            // The chip is the rider now: a standalone write of the same attribute would only argue with it.
            attributes.removeAll { kind(of: $0) == attribute.kind }
            return cueChannel(channel, .write(content, riders), attributes, cue: cue, list: list)
        }
        let standalone = command(attribute, channel: channel)
        if let index = attributes.lastIndex(where: { kind(of: $0) == attribute.kind }) {
            attributes[index] = standalone
        } else {
            attributes.append(standalone)
        }
        return cueChannel(channel, says.state, attributes, cue: cue, list: list)
    }

    /// A chip's Remove.
    public static func remove(_ kind: CueAttribute.Kind, channel: Int, cue: Cue, list: Int) -> Sending? {
        let says = CueSays.about(channel, in: cue)
        var state = says.state
        if case .write(let content, var riders) = says.state {
            switch kind {
            case .transition: riders.transition = nil
            case .audioTransition: riders.audioTransition = nil
            case .grade: riders.grade = nil
            case .gain: riders.gain = nil
            }
            state = .write(content, riders)
        }
        return cueChannel(channel, state, says.attributes.filter { self.kind(of: $0) != kind }, cue: cue, list: list)
    }

    /// Spec 11 §4, "Multi-cue editing" — "A change sends one group with one
    /// edit per selected cue ... "This cue only" applies to the selected cues
    /// that write content on that channel and skips the rest, saying how
    /// many it skipped, since on a cue that clears or holds the channel an
    /// attribute command always tracks."
    public static func set(_ attribute: CueAttribute, channel: Int, cues: [Cue], list: Int) -> (sending: Sending?, skipped: Int) {
        var skipped = 0
        var sendings: [Sending?] = []
        for cue in cues {
            if attribute.scope == .once, !CueSays.about(channel, in: cue).writesContent {
                skipped += 1
            } else {
                sendings.append(set(attribute, channel: channel, cue: cue, list: list))
            }
        }
        return (group(sendings), skipped)
    }

    /// A chip's Remove over several cues, as one group.
    public static func remove(_ kind: CueAttribute.Kind, channel: Int, cues: [Cue], list: Int) -> Sending? {
        group(cues.map { remove(kind, channel: channel, cue: $0, list: list) })
    }

    // MARK: - Cues (Spec 11 §4, "Selecting")

    /// "A new cue holds every channel, has a Go trigger, an empty label and
    /// note, and the section of the cue before it: `edit list L insert cues
    /// K {…}` with a uuid the app makes, so a group can name the cue it
    /// inserts". After `cue`, or at the end for the + header.
    public static func newCue(uuid: UUID, after cue: Cue?, in list: List) -> Sending {
        let before = cue ?? list.cues.last
        let position = cue.flatMap { list.position(of: $0.uuid) } ?? list.cues.count
        var body: [String: JSONValue] = ["uuid": .string(uuid.uuidString.lowercased())]
        if let section = before?.section, !section.isEmpty { body["section"] = .string(section) }
        return edit(.list(list.number), .insert(path: "cues", at: position, value: .object(body)))
    }

    /// "Duplicate (`… duplicate`)".
    public static func duplicate(cue: Cue, list: Int) -> Sending {
        edit(.cue(list: list, cue: cue.uuid), .duplicate(to: nil, title: nil, picks: .none))
    }

    /// "Delete (`… remove`, several as one group)".
    public static func remove(cues: [Cue], list: Int) -> Sending {
        Sending(cues.map { .edit(EditCommand(.cue(list: list, cue: $0.uuid), .remove(path: nil, at: nil))) })
    }

    /// "Deleting cues asks first only when the cues hold edits, or include
    /// the live cue or the armed one (choice A-11); otherwise undo is the way back."
    public static func deleteAsks(cues: [Cue], live: String?, armed: String?) -> Bool {
        cues.contains { cue in
            let uuid = cue.uuid.uuidString.lowercased()
            if uuid == live || uuid == armed { return true }
            return cue.commands.contains { entry in
                if case .edit = entry.command { return true }
                return false
            }
        }
    }

    /// The inspector's label field: "each an `edit.set` on commit".
    public static func label(_ label: String, cue: Cue, list: Int) -> Sending? {
        guard label != cue.label else { return nil }
        return edit(.cue(list: list, cue: cue.uuid), .set(path: "label", value: .string(label)))
    }

    /// The section field; an empty name is no section.
    public static func section(_ section: String, cue: Cue, list: Int) -> Sending? {
        let name = section.trimmingCharacters(in: .whitespaces)
        guard name != (cue.section ?? "") else { return nil }
        return edit(.cue(list: list, cue: cue.uuid), .set(path: "section", value: name.isEmpty ? .null : .string(name)))
    }

    /// Spec 11 §4 — "A section carries forward in the editor alone (Adam,
    /// 2026-11-24): set on one cue, it is set too on the cues after it whose
    /// section was the same as that cue's, up to the first that differs, all
    /// as one group". Nil when the cue has that section already.
    public static func sectionRun(_ section: String, from cue: Cue, in list: List) -> Sending? {
        guard let start = list.cues.firstIndex(where: { $0.uuid == cue.uuid }) else { return nil }
        let old = cue.section ?? ""
        var run: [Sending?] = []
        for next in list.cues[start...] {
            guard (next.section ?? "") == old else { break }
            run.append(Self.section(section, cue: next, list: list.number))
        }
        return group(run)
    }

    /// "Headers drag to a new place: `edit list L cue C move K`, several in
    /// their order as one group." `before` is the place in the list as it
    /// stands, from 0 to its count, that the cues are dropped ahead of. Each
    /// step names the place its cue ends at, as the engine counts it, and
    /// lands right after the cue before it in the new order. Nil when
    /// nothing would move.
    public static func move(cues: [Cue], before: Int, in list: List) -> Sending? {
        let moving = Set(cues.map(\.uuid))
        let moved = list.cues.map(\.uuid).filter(moving.contains)
        guard !moved.isEmpty else { return nil }
        var current = list.cues.map(\.uuid)
        let others = current.enumerated().filter { !moving.contains($0.element) }
        let ahead = others.filter { $0.offset < before }.map(\.element)
        var commands: [Command] = []
        var previous = ahead.last
        for cue in moved {
            guard let from = current.firstIndex(of: cue) else { continue }
            current.remove(at: from)
            let to = previous.flatMap { current.firstIndex(of: $0) }.map { $0 + 1 } ?? 0
            current.insert(cue, at: to)
            if to != from { commands.append(.edit(EditCommand(.cue(list: list.number, cue: cue), .move(path: nil, from: nil, at: to)))) }
            previous = cue
        }
        return commands.isEmpty ? nil : Sending(commands)
    }

    // MARK: - Commands (Spec 11 §4, "The Commands column")

    /// "the cue's commands other than its channel writes and attribute
    /// writes, in their order": everything but what the grid's cells show.
    public static func others(in cue: Cue) -> [CueCommandRow] {
        cue.commands.enumerated().compactMap { index, entry in
            entry.command.namedChannel == nil ? CueCommandRow(position: index, entry: entry) : nil
        }
    }

    /// "Add inserts the command after the selected one, or at the end."
    public static func insert(_ command: Command, after position: Int?, cue: Cue, list: Int) -> Sending {
        let at = position.map { min($0 + 1, cue.commands.count) } ?? cue.commands.count
        return edit(.cue(list: list, cue: cue.uuid), .insert(path: "commands", at: at, value: value(GuardedCommand(command))))
    }

    /// A command's Edit: "`edit.set` ... on `commands`", one command at its place.
    public static func setCommand(_ command: Command, at position: Int, cue: Cue, list: Int) -> Sending? {
        guard position >= 0, position < cue.commands.count, cue.commands[position].command != command else { return nil }
        var entry = cue.commands[position]
        entry.command = command
        return edit(.cue(list: list, cue: cue.uuid), .set(path: "commands.\(position)", value: value(entry)))
    }

    /// A command's Remove: "`edit.remove` on `commands`", by position.
    public static func removeCommand(at position: Int, cue: Cue, list: Int) -> Sending {
        edit(.cue(list: list, cue: cue.uuid), .remove(path: "commands", at: position))
    }

    /// Move Up and Move Down: "`edit.move` by position", to the place of the
    /// listed command before or after it. Nil when there is none.
    public static func moveCommand(at position: Int, up: Bool, cue: Cue, list: Int) -> Sending? {
        let rows = others(in: cue).map(\.position)
        guard let index = rows.firstIndex(of: position) else { return nil }
        let target = up ? index - 1 : index + 1
        guard rows.indices.contains(target) else { return nil }
        return edit(.cue(list: list, cue: cue.uuid), .move(path: "commands", from: position, at: rows[target]))
    }

    // MARK: - The list (Spec 11 §4, "The list")

    /// "Renumber… (`edit list N renumber M`, or Swap for a taken number)".
    public static func renumber(list: Int, to number: Int) -> Sending {
        edit(.list(list), .renumber(to: number))
    }

    public static func swap(list: Int, with number: Int) -> Sending {
        edit(.list(list), .swap(with: number))
    }

    /// "On a "No channel" row the only action is Hold, sent as `edit.remove`
    /// of those commands in one group": from the last, so each position
    /// still names its command when its turn comes.
    public static func holdMissing(channel: Int, cue: Cue, list: Int) -> Sending? {
        let positions = cue.commands.indices.filter { cue.commands[$0].command.namedChannel == channel }
        guard !positions.isEmpty else { return nil }
        return Sending(positions.reversed().map { .edit(EditCommand(.cue(list: list, cue: cue.uuid), .remove(path: "commands", at: $0))) })
    }
}

/// Spec 11 §4, "Attribute chips" and "Tracking off" — the scope a chip's
/// popover starts on, and the scope a chip reads.
public enum CueChips {
    /// "Tracking off (Spec 3 §3 rule 7). A new chip for that attribute is
    /// "this cue only" ... and an existing `track` rider keeps its scope
    /// when its value changes".
    public static func scope(for kind: CueAttribute.Kind, in says: CueSays, tracking: Bool) -> Scope {
        if let attribute = says.attribute(kind), attribute.isRider { return attribute.scope }
        return tracking ? .track : .once
    }

    /// "A standalone command reads "this cue only", since that is how it plays here".
    public static func shownScope(of attribute: CueAttribute, tracking: Bool) -> Scope {
        attribute.isRider ? attribute.scope : (tracking ? .track : .once)
    }

    /// "with Clear or Hold it is a standalone attribute command, which is
    /// always `track` (Spec 1 §6), so its popover offers no scope."
    public static func offersScope(in says: CueSays) -> Bool { says.writesContent }
}

/// Spec 11 §4, "Commands as text" — "the cue's whole command list, one
/// command per line, in order, in canonical text, parsed as it is typed with
/// OCore's parser (Spec 2 §4), each error beside its line."
public enum CommandsText {
    /// What the text area's text parses to: the commands of the lines that
    /// read, and each error by its line, from 0.
    public struct Parsed: Equatable, Sendable {
        public var commands: [GuardedCommand]
        public var errors: [Int: String]
    }

    private static func line(_ entry: GuardedCommand) -> String {
        if let text = CommandText.print(entry) { return text }
        // "A command kept verbatim because it is unknown has no text form, so it shows as its JSON on one locked line".
        return (try? JSONCoding.encode(entry)).map(JSONCanonical.line) ?? entry.command.cmd
    }

    /// "A multi-line body shows with Spec 2 §2's escapes", so every command is one line.
    public static func lines(of cue: Cue) -> [String] {
        lines(of: cue.commands)
    }

    /// A cue's or a macro's commands, one line each (Spec 11 §9: "Commands as Text works as in §4").
    public static func lines(of commands: [GuardedCommand]) -> [String] {
        commands.map(line)
    }

    /// The lines the area locks: the commands kept verbatim.
    public static func locked(in cue: Cue) -> [Int] {
        cue.commands.indices.filter { CommandText.print(cue.commands[$0]) == nil }
    }

    /// Parses the area's text. A line that reads as it did before stands for
    /// the command it was, with everything a newer version wrote beside it
    /// (Spec 1 §6); a blank line is no command.
    public static func parse(_ text: String, cue: Cue, options: ParseOptions = ParseOptions()) -> Parsed {
        parse(text, commands: cue.commands, options: options)
    }

    /// The same for any commands the text stands for, a cue's or a macro's.
    public static func parse(_ text: String, commands: [GuardedCommand], options: ParseOptions = ParseOptions()) -> Parsed {
        var originals: [String: [GuardedCommand]] = [:]
        for entry in commands { originals[line(entry), default: []].append(entry) }
        var parsed = Parsed(commands: [], errors: [:])
        for (index, raw) in text.components(separatedBy: "\n").enumerated() {
            let text = raw.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }
            if var same = originals[text], !same.isEmpty {
                parsed.commands.append(same.removeFirst())
                originals[text] = same
            } else if text.hasPrefix("{") {
                // "goes back as the object it was".
                if let value = try? JSONValue.parse(text), let entry = try? JSONCoding.decode(GuardedCommand.self, from: value) {
                    parsed.commands.append(entry)
                } else {
                    parsed.errors[index] = "not a command object"
                }
            } else {
                switch CommandText.parse(text, options: options) {
                case .success(let entry): parsed.commands.append(entry)
                case .failure(let rejection): parsed.errors[index] = rejection.message
                }
            }
        }
        return parsed
    }

    public static func hasErrors(_ text: String, cue: Cue, options: ParseOptions = ParseOptions()) -> Bool {
        !parse(text, cue: cue, options: options).errors.isEmpty
    }

    /// "⌘Return, or leaving the area, sends one `edit.set` of the cue's
    /// `commands` with the parsed list, but only while no line has an error:
    /// with one, nothing is sent". Nil too when nothing changed.
    public static func edit(_ text: String, cue: Cue, list: Int, options: ParseOptions = ParseOptions()) -> Sending? {
        let parsed = parse(text, cue: cue, options: options)
        guard parsed.errors.isEmpty, parsed.commands != cue.commands else { return nil }
        let values = parsed.commands.compactMap { try? JSONCoding.encode($0) }
        guard values.count == parsed.commands.count else { return nil }
        return Sending([.edit(EditCommand(.cue(list: list, cue: cue.uuid), .set(path: "commands", value: .array(values))))])
    }
}
