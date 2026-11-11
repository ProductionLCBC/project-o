// OCore — Spec 2 §6, OSC: the address mapping both ways, feedback shapes and
// client requests, as pure functions. No sockets in core/.

import Foundation

/// An OSC 1.0 argument, with the extended types common senders use.
public enum OSCArgument: Equatable, Sendable {
    case int32(Int32)
    case float32(Float)
    case string(String)
    case blob(Data)
    case int64(Int64)
    case double(Double)
    case timetag(UInt64)
    case bool(Bool)
    case null
    case impulse
}

/// One OSC message: an address and its arguments.
public struct OSCMessage: Equatable, Sendable {
    public var address: String
    public var arguments: [OSCArgument]

    public init(_ address: String, _ arguments: [OSCArgument] = []) {
        self.address = address
        self.arguments = arguments
    }
}

/// Spec 2 §6 — "Bundles run as one group, in order". The time tag `1` means
/// immediately.
public struct OSCBundle: Equatable, Sendable {
    public static let immediately: UInt64 = 1

    public var timetag: UInt64
    public var elements: [OSCPacket]

    public init(timetag: UInt64 = OSCBundle.immediately, elements: [OSCPacket] = []) {
        self.timetag = timetag
        self.elements = elements
    }
}

/// A packet on the wire: a message or a bundle.
public indirect enum OSCPacket: Equatable, Sendable {
    case message(OSCMessage)
    case bundle(OSCBundle)
}

/// Spec 2 §6 — "The OSC address is the text form with slashes:
/// `/o/TARGET/NUMBER/VERB`, and the arguments are the rest of the command."
public enum OSCMapping {
    /// Spec 2 §6 — "The `/o` prefix is fixed so console maps written for one
    /// campus work at every campus."
    public static let prefix = "/o"

    // MARK: - Command to message

    /// Spec 2 §6 — the typed form: "integers for numbers and seconds, floats
    /// for decibels and decimal durations, strings for text and keywords". A
    /// write or an edit travels as one string, the rest of its text form. Nil
    /// for a command the vocabulary does not know.
    public static func message(for command: Command) -> OSCMessage? {
        guard let row = Vocabulary.row(cmd: command.cmd), let text = CommandText.print(command),
              let object = (try? JSONCoding.encode(command))?.objectValue else { return nil }
        let head = CommandPrinter.head(row, object)
        let address = prefix + "/" + head.joined(separator: "/")
        if row.isSpecial {
            let pieces = text.split(separator: " ", maxSplits: head.count, omittingEmptySubsequences: true)
            let remainder = pieces.count > head.count ? String(pieces[head.count]) : ""
            return OSCMessage(address, [.string(remainder)])
        }
        var arguments: [OSCArgument] = []
        for arg in row.args {
            // Spec 8 §2 — a recorded body travels as one string, its canonical JSON.
            if case .body(let keys, _) = arg.kind {
                if let body = CommandPrinter.bodyValue(keys, object) { arguments.append(.string(JSONCanonical.line(body))) }
                continue
            }
            guard let value = object[arg.key] else { continue }
            switch arg.kind {
            case .int:
                arguments.append(.int32(Int32(clamping: value.intValue ?? 0)))
            case .decimal:
                arguments.append(real(value.doubleValue ?? 0))
            case .duration, .optionalDuration, .optionalKeywordSeconds:
                arguments.append(seconds(ms: value.intValue ?? 0))
            case .string, .optionalString, .keyword, .hash:
                arguments.append(.string(value.stringValue ?? ""))
            case .flag(let word):
                // Spec 2 §6 — "`up` follows as `s:"up"`".
                if value.boolValue == true { arguments.append(.string(word)) }
            case .write, .edit, .body:
                break
            }
        }
        return OSCMessage(address, arguments)
    }

    /// A float when the value survives 32 bits exactly, else a double, so
    /// the object round-trips and ordinary controllers still see `f`.
    static func real(_ x: Double) -> OSCArgument {
        let f = Float(x)
        return Double(f) == x ? .float32(f) : .double(x)
    }

    /// Spec 2 §6 — whole seconds as an integer, otherwise decimal seconds.
    static func seconds(ms: Int) -> OSCArgument {
        ms % 1000 == 0 ? .int32(Int32(clamping: ms / 1000)) : real(Double(ms) / 1000)
    }

    // MARK: - Message to command

    /// Spec 2 §6 — "Typed OSC arguments map positionally to the verb's
    /// arguments ... As an alternative for any command, a single string
    /// argument is parsed as the remainder of the text form". One string is
    /// tried as the remainder first, then as the typed argument, so both
    /// spellings reach the same object.
    public static func command(from message: OSCMessage, options: ParseOptions = ParseOptions()) -> Result<Command, Rejection> {
        do {
            return .success(try parse(message, options: options))
        } catch let rejection as Rejection {
            return .failure(rejection)
        } catch {
            return .failure(Rejection(reason: .malformed, message: "\(error)"))
        }
    }

    /// Spec 2 §6 — "Bundles run as one group, in order, and either all
    /// validate or none run." Every message in order, or the first rejection
    /// with its place in the bundle.
    public static func commands(from bundle: OSCBundle, options: ParseOptions = ParseOptions()) -> Result<[Command], Rejection> {
        var commands: [Command] = []
        var index = 0
        func walk(_ packet: OSCPacket) throws {
            switch packet {
            case .message(let message):
                switch command(from: message, options: options) {
                case .success(let command):
                    commands.append(command)
                case .failure(var rejection):
                    rejection.index = index
                    rejection.message = "message \(index + 1), \(message.address): " + rejection.message
                    throw rejection
                }
                index += 1
            case .bundle(let inner):
                for element in inner.elements { try walk(element) }
            }
        }
        do {
            for element in bundle.elements { try walk(element) }
        } catch let rejection as Rejection {
            return .failure(rejection)
        } catch {
            return .failure(Rejection(reason: .malformed, message: "\(error)"))
        }
        return .success(commands)
    }

    static func reject(_ reason: RejectionReason, _ message: String) -> Rejection {
        Rejection(reason: reason, message: message)
    }

    static func parse(_ message: OSCMessage, options: ParseOptions) throws -> Command {
        let lower = message.address.lowercased()
        guard lower == prefix || lower.hasPrefix(prefix + "/") else {
            throw reject(.malformed, "\(message.address) does not start with \(prefix)/")
        }
        let words = lower.dropFirst(prefix.count + 1).split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard let first = words.first, !first.isEmpty else {
            throw reject(.malformed, "\(message.address) names no target")
        }
        guard words.allSatisfy({ !$0.isEmpty }) else {
            throw reject(.malformed, "\(message.address) has an empty part")
        }
        let target = Vocabulary.canonicalTarget(first)
        guard Vocabulary.targets.contains(target) else {
            throw reject(.unknownTarget, "\(first) is not a target")
        }
        if target == "edit" {
            let original = message.address.dropFirst(prefix.count + 1).split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            return try parseEdit(original, message, options: options)
        }
        let rows = Vocabulary.rows(target: target)
        let hasNumber = rows.first?.hasNumber ?? false
        let hasVerb = rows.contains(where: \.hasVerb)
        let expected = 1 + (hasNumber ? 1 : 0) + (hasVerb ? 1 : 0)
        if words.count < expected {
            throw reject(.missingArgument, "\(message.address) is missing its \(hasNumber && words.count == 1 ? "number" : "verb")")
        }
        if words.count > expected {
            throw reject(.unexpectedToken, "\(message.address) has more parts than \(target) takes")
        }
        var head = [target]
        if hasNumber {
            let n = words[1]
            if Vocabulary.takesAll(target: target), n == "all" {
                head.append("all")
            } else {
                guard let value = Int(n), value >= 1 else { throw reject(.badArgument, "\(n) is not a \(target) number") }
                head.append(n)
            }
        }
        let row: VocabularyRow
        if hasVerb {
            let verb = Vocabulary.canonicalVerb(words[expected - 1], target: target)
            guard let found = Vocabulary.row(target: target, verb: verb) else {
                throw reject(.unknownVerb, "\(words[expected - 1]) is not a \(target) verb")
            }
            // Spec 2 §3 — `all` is the named row's to take (`stack all blackout`, not `stack all mute`).
            if hasNumber, head[1] == "all", !found.takesAll {
                throw reject(.badArgument, "\(target) \(verb) takes a number, not all")
            }
            row = found
            head.append(verb)
        } else {
            guard let only = Vocabulary.row(target: target, verb: nil) else {
                throw reject(.unknownTarget, "\(first) is not a target")
            }
            row = only
        }
        let headText = head.joined(separator: " ")

        // One string: the remainder of the text form first.
        if message.arguments.count == 1, case .string(let remainder) = message.arguments[0] {
            switch CommandText.parse(headText + " " + remainder, options: options) {
            case .success(let entry):
                guard entry.when == nil else { throw reject(.unexpectedToken, "a guard is not accepted over OSC") }
                return entry.command
            case .failure(let rejection):
                if row.isSpecial { throw rejection }
            }
        }
        if row.isSpecial {
            if message.arguments.isEmpty {
                throw reject(.missingArgument, "\(headText) needs one string argument: the rest of the command")
            }
            throw reject(.badArgument, "\(headText) takes one string argument: the rest of the command")
        }

        // Typed arguments, positionally.
        var pieces = [headText]
        for (k, argument) in message.arguments.enumerated() {
            guard k < row.args.count else {
                throw reject(.unexpectedToken, "\(headText) takes \(row.args.count) argument(s), not \(message.arguments.count)")
            }
            let kind = row.args[k].kind
            let piece: String
            switch argument {
            case .int32(let n): piece = String(n)
            case .int64(let n): piece = String(n)
            case .float32(let x): piece = x.description
            case .double(let x): piece = x.description
            case .string(let s):
                switch kind {
                case .string, .optionalString: piece = CommandPrinter.quoted(s)
                default: piece = s
                }
            default:
                throw reject(.badArgument, "argument \(k + 1) of \(message.address) has a type the vocabulary does not use")
            }
            if case .optionalKeywordSeconds(let word) = kind { pieces.append(word) }
            pieces.append(piece)
        }
        switch CommandText.parse(pieces.joined(separator: " "), options: options) {
        case .success(let entry): return entry.command
        case .failure(let rejection): throw rejection
        }
    }

    /// Spec 5 §2 — an edit arrives "over OSC as `/o/edit/...` (the text form
    /// with slashes, Spec 2 §6)": `/o/edit` with the rest of the text form as
    /// one string, or the text form's words in the address up to the value,
    /// as in `/o/edit/list/42/title s:"Great Is Thy Faithfulness"`. A field
    /// path keeps its case. One string is read as the remainder first and,
    /// with words in the address, as the value when that fails (Spec 2 §6).
    /// A folder's path holds a slash, so a folder edit goes as one string.
    static func parseEdit(_ words: [String], _ message: OSCMessage, options: ParseOptions) throws -> Command {
        let head = (["edit"] + words.dropFirst()).joined(separator: " ")
        func command(_ text: String) -> Result<Command, Rejection> {
            switch CommandText.parse(text, options: options) {
            case .success(let entry):
                guard entry.when == nil else { return .failure(reject(.unexpectedToken, "a guard is not accepted over OSC")) }
                return .success(entry.command)
            case .failure(let rejection):
                return .failure(rejection)
            }
        }
        if message.arguments.count == 1, case .string(let s) = message.arguments[0] {
            switch command(head + " " + s) {
            case .success(let c): return c
            case .failure(let rejection):
                guard words.count > 1, case .success(let c) = command(head + " " + CommandPrinter.quoted(s)) else { throw rejection }
                return c
            }
        }
        var pieces = [head]
        for (k, argument) in message.arguments.enumerated() {
            switch argument {
            case .int32(let n): pieces.append(String(n))
            case .int64(let n): pieces.append(String(n))
            case .float32(let x): pieces.append(x.description)
            case .double(let x): pieces.append(CommandPrinter.decimalText(x))
            case .string(let s): pieces.append(CommandPrinter.quoted(s))
            case .bool(let b): pieces.append(b ? "true" : "false")
            case .null: pieces.append("null")
            default:
                throw reject(.badArgument, "argument \(k + 1) of \(message.address) has a type an edit does not use")
            }
        }
        switch command(pieces.joined(separator: " ")) {
        case .success(let c): return c
        case .failure(let rejection): throw rejection
        }
    }
}

/// Spec 2 §6 — `/o/channel/N/state` values: "`empty`, `playing`, `paused`,
/// `held`, `missing`".
public enum ChannelFeedbackState: String, CaseIterable, Equatable, Sendable {
    case empty, playing, paused, held, missing
}

/// Spec 2 §6 — Feedback: "Feedback addresses mirror state, not commands."
/// The shapes of the table, as messages the engine sends to every target.
public enum OSCFeedback {
    public static func livePlaylist(_ title: String) -> OSCMessage { OSCMessage("/o/live/playlist", [.string(title)]) }
    public static func liveItem(_ item: Int) -> OSCMessage { OSCMessage("/o/live/item", [.int32(Int32(clamping: item))]) }
    public static func liveCue(_ cue: Int) -> OSCMessage { OSCMessage("/o/live/cue", [.int32(Int32(clamping: cue))]) }
    public static func liveLabel(_ label: String) -> OSCMessage { OSCMessage("/o/live/label", [.string(label)]) }

    /// Spec 7 §6 — "`/o/live/armed` carries `i:item` `i:cue` `i:ms` ... and
    /// with no arguments when the trigger disarms, lapses or fires".
    public static func liveArmed(_ armed: (item: Int, cue: Int, ms: Int)?) -> OSCMessage {
        guard let armed else { return OSCMessage("/o/live/armed") }
        return OSCMessage("/o/live/armed", [.int32(Int32(clamping: armed.item)), .int32(Int32(clamping: armed.cue)),
                                            .int32(Int32(clamping: armed.ms))])
    }

    /// "`s:kind` `s:label`: content changes, including clear".
    public static func channelContent(_ channel: Int, kind: String, label: String) -> OSCMessage {
        OSCMessage("/o/channel/\(channel)/content", [.string(kind), .string(label)])
    }

    public static func channelState(_ channel: Int, _ state: ChannelFeedbackState) -> OSCMessage {
        OSCMessage("/o/channel/\(channel)/state", [.string(state.rawValue)])
    }

    /// "Once a second while timed content plays, only to clients that subscribed".
    public static func channelRemaining(_ channel: Int, ms: Int) -> OSCMessage {
        OSCMessage("/o/channel/\(channel)/remaining", [.int32(Int32(clamping: ms))])
    }

    public static func outputStack(_ output: Int, stack: Int) -> OSCMessage {
        OSCMessage("/o/output/\(output)/stack", [.int32(Int32(clamping: stack))])
    }

    public static func stackBlackout(_ stack: Int, on: Bool) -> OSCMessage {
        OSCMessage("/o/stack/\(stack)/blackout", [.int32(on ? 1 : 0)])
    }

    /// "`s:formatted` `i:ms`: once a second while running, and on set".
    public static func timer(_ timer: Int, formatted: String, ms: Int) -> OSCMessage {
        OSCMessage("/o/timer/\(timer)", [.string(formatted), .int32(Int32(clamping: ms))])
    }

    /// Spec 6 §8 — "An unset timer sends `s:""` alone."
    public static func timerUnset(_ timer: Int) -> OSCMessage {
        OSCMessage("/o/timer/\(timer)", [.string("")])
    }

    public static func popup(_ popup: Int, text: String) -> OSCMessage {
        OSCMessage("/o/popup/\(popup)", [.string(text)])
    }

    public static func lock(_ channel: Int, locked: Bool) -> OSCMessage {
        OSCMessage("/o/lock/\(channel)", [.int32(locked ? 1 : 0)])
    }

    /// "Errors go back to the sender as `/o/error` `s:address` `s:reason`."
    public static func error(address: String, reason: String) -> OSCMessage {
        OSCMessage("/o/error", [.string(address), .string(reason)])
    }
}

/// Spec 2 §6 — what a client asks of the engine besides commands: `/o/register
/// s:host i:port` ("lasts 60 seconds and is renewed by repeating it"),
/// `/o/subscribe` and `/o/unsubscribe` with an address, and `/o/query` with
/// an address. The timing is the engine's; the shapes are here.
public enum OSCClientRequest: Equatable, Sendable {
    case register(host: String, port: Int)
    case subscribe(String)
    case unsubscribe(String)
    case query(String)

    /// Spec 2 §6 — a registration "lasts 60 seconds".
    public static let registrationSeconds = 60

    public init?(_ message: OSCMessage) {
        let arguments = message.arguments
        switch (message.address.lowercased(), arguments.count) {
        case ("/o/register", 2):
            guard case .string(let host) = arguments[0], let port = OSCClientRequest.int(arguments[1]) else { return nil }
            self = .register(host: host, port: port)
        case ("/o/subscribe", 1):
            guard case .string(let address) = arguments[0] else { return nil }
            self = .subscribe(address)
        case ("/o/unsubscribe", 1):
            guard case .string(let address) = arguments[0] else { return nil }
            self = .unsubscribe(address)
        case ("/o/query", 1):
            guard case .string(let address) = arguments[0] else { return nil }
            self = .query(address)
        default:
            return nil
        }
    }

    static func int(_ argument: OSCArgument) -> Int? {
        switch argument {
        case .int32(let n): return Int(n)
        case .int64(let n): return Int(exactly: n)
        default: return nil
        }
    }
}
