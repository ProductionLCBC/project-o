// OEngine — Spec 11 §3, the `render` query: what a request asks for.

import Foundation
import OCore

/// Spec 11 §3 — "The sample is what a channel could hold: `content`, one text
/// write's `fields` (`{"kind": "text", "fields": {…}}`), one media item
/// (`{"kind": "media", "ref": "sha256:…"}`) or nothing (`{"kind": "empty"}`);
/// `next`, up to three more contents for boxes at +1 to +3; and optionally
/// `listUuid` and `cue`, naming where the sample came from."
struct RenderSample: Equatable, Sendable {
    var content: ContentExpression = .empty
    var next: [ContentExpression] = []
    /// Where the sample came from: "Without `listUuid` and `cue`, metadata
    /// and context values draw nothing."
    var list: List?
    var cue: UUID?
}

/// Spec 11 §3 — what a `render` draws, each object found in the roots the
/// request was read against: a cue on a stack, a preset's layout with a
/// sample, or a media item through a grade.
enum RenderSubject: Equatable, Sendable {
    /// "The cue's projected state on that stack"; `index` is the cue's place in its list, from 0. Spec 11 §3 as
    /// corrected 2026-11-24 — "the channels `hide` lists by number draw nothing".
    case cue(list: List, index: Int, stack: Stack, hide: Set<Int> = [])
    /// "a stack's own layout at that stack's size and number, the `*` layout
    /// at the size and number of the stack `stack` names".
    case layout(preset: Preset, layout: LayoutKey, stack: Stack, sample: RenderSample)
    /// "The item's poster or still through the grade, or as it is when `grade` is null, over black".
    case grade(Grade?, media: String)
}

/// Spec 11 §3 — one `render` request, read and checked: its canvas, its
/// width and what it draws.
struct RenderRequest: Equatable, Sendable {
    /// "`width` is 160 to 1920 pixels."
    static let widths = 160...1920
    /// "A request names its `canvas`, up to 16 letters and digits".
    static let canvasLength = 16

    var canvas: String
    var width: Int
    var subject: RenderSubject

    /// Letters and digits, the ones a file's name carries on any disk: A to Z, a to z and 0 to 9.
    static func isName(_ text: String, upTo length: Int) -> Bool {
        !text.isEmpty && text.utf8.count <= length && text.utf8.allSatisfy { byte in
            (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A)
        }
    }

    /// Spec 11 §3 — "The files. `machine/thumbnails/render/`, named by
    /// connection, canvas and request `id` (`c3-inspector-61.png`)": the id
    /// as the name carries it, a whole number or up to 32 letters and
    /// digits; nil for an id a file's name can't carry.
    static func fileID(_ id: JSONValue) -> String? {
        if let number = id.intValue, number >= 0 { return String(number) }
        if let text = id.stringValue, isName(text, upTo: 32) { return text }
        return nil
    }

    /// Spec 11 §3 — "Errors. An unknown list, cue, preset, layout, grade or
    /// media id is `unknownObject`; a width outside 160 to 1920, a canvas
    /// name that isn't letters and digits or is longer than 16 ... is
    /// `badValue`". A member that is missing is `missingArgument`, one of the
    /// wrong kind `badValue`, and a stack the machine doesn't have
    /// `unknownObject` like the other objects.
    static func parse(_ members: [String: JSONValue], library: Library, machine: Machine) -> Result<RenderRequest, Rejection> {
        func fail(_ reason: RejectionReason, _ message: String) -> Result<RenderRequest, Rejection> {
            .failure(Rejection(reason: reason, message: message))
        }
        guard let canvasValue = members["canvas"] else { return fail(.missingArgument, "render names its canvas") }
        guard let canvas = canvasValue.stringValue, isName(canvas, upTo: canvasLength) else {
            return fail(.badValue, "a canvas is named in up to \(canvasLength) letters and digits")
        }
        guard let widthValue = members["width"] else { return fail(.missingArgument, "render names its width") }
        guard let width = widthValue.intValue, widths.contains(width) else {
            return fail(.badValue, "a render is \(widths.lowerBound) to \(widths.upperBound) pixels wide")
        }
        guard let subjectValue = members["subject"] else { return fail(.missingArgument, "render names its subject") }
        guard case .object(let subject) = subjectValue, let kind = subject["kind"]?.stringValue else {
            return fail(.badValue, "a render's subject is an object with its kind: cue, layout or grade")
        }

        // A list by `listUuid` or a local copy by `local`, as the other queries name them (Spec 10 §3).
        func list(in object: [String: JSONValue]) -> Result<List?, Rejection> {
            for (member, local) in [("listUuid", false), ("local", true)] {
                guard let value = object[member] else { continue }
                guard let text = value.stringValue, let uuid = UUID(uuidString: text) else {
                    return .failure(Rejection(reason: .badValue, message: "\(member) isn't a uuid"))
                }
                guard let found = local ? machine.localList(uuid: uuid) : library.list(uuid: uuid) else {
                    return .failure(Rejection(reason: .unknownObject, message: local ? "no local copy has the uuid \(text)" : "no list has the uuid \(text)"))
                }
                return .success(found)
            }
            return .success(nil)
        }
        func cue(in object: [String: JSONValue], of list: List) -> Result<Int?, Rejection> {
            guard let value = object["cue"] else { return .success(nil) }
            guard let text = value.stringValue, let uuid = UUID(uuidString: text) else {
                return .failure(Rejection(reason: .badValue, message: "cue isn't a uuid"))
            }
            guard let index = list.cues.firstIndex(where: { $0.uuid == uuid }) else {
                return .failure(Rejection(reason: .unknownObject, message: "list \(list.number) has no cue with the uuid \(text)"))
            }
            return .success(index)
        }
        func stack(_ value: JSONValue?, _ what: String) -> Result<Stack, Rejection> {
            guard let value else { return .failure(Rejection(reason: .missingArgument, message: what)) }
            guard let number = value.intValue else { return .failure(Rejection(reason: .badValue, message: "a stack is named by its number")) }
            guard let found = machine.stack(number) else { return .failure(Rejection(reason: .unknownObject, message: "stack \(number) does not exist")) }
            return .success(found)
        }

        switch kind {
        case "cue":
            let found: List
            switch list(in: subject) {
            case .failure(let rejection): return .failure(rejection)
            case .success(nil): return fail(.missingArgument, "a cue's render names its list as \"listUuid\" or \"local\"")
            case .success(let some?): found = some
            }
            let index: Int
            switch cue(in: subject, of: found) {
            case .failure(let rejection): return .failure(rejection)
            case .success(nil): return fail(.missingArgument, "a cue's render names its cue")
            case .success(let some?): index = some
            }
            // "optionally `hide`": channel numbers; "a number no channel has is ignored".
            var hide: Set<Int> = []
            if let listed = subject["hide"] {
                guard let items = listed.arrayValue else { return fail(.badValue, "a cue's render lists the channels it hides as \"hide\": [numbers]") }
                for item in items {
                    guard let number = item.intValue else { return fail(.badValue, "\"hide\" lists channel numbers, not \(item)") }
                    hide.insert(number)
                }
            }
            switch stack(subject["stack"], "a cue's render names its stack") {
            case .failure(let rejection): return .failure(rejection)
            case .success(let on): return .success(RenderRequest(canvas: canvas, width: width, subject: .cue(list: found, index: index, stack: on, hide: hide)))
            }

        case "layout":
            guard let presetValue = subject["preset"] else { return fail(.missingArgument, "a layout's render names its preset") }
            guard let presetNumber = presetValue.intValue else { return fail(.badValue, "a preset is named by its number") }
            guard let preset = library.preset(presetNumber) else { return fail(.unknownObject, "preset \(presetNumber) does not exist") }
            guard let layoutValue = subject["layout"] else { return fail(.missingArgument, "a layout's render names its layout: \"*\" or a stack's number") }
            let key: LayoutKey
            if layoutValue.stringValue == "*" {
                key = .any
            } else if let number = layoutValue.intValue ?? layoutValue.stringValue.flatMap({ Int($0) }) {
                key = .stack(number)
            } else {
                return fail(.badValue, "a layout is \"*\" or a stack's number")
            }
            guard preset.layouts[key] != nil else {
                return fail(.unknownObject, "preset \(presetNumber) has no layout \(key.string)")
            }
            // "a stack's own layout at that stack's size and number, the `*` layout at the size and number of the stack `stack` names".
            let on: Stack
            if case .stack(let number) = key {
                switch stack(.number(Double(number)), "") {
                case .failure(let rejection): return .failure(rejection)
                case .success(let found): on = found
                }
            } else {
                switch stack(subject["stack"], "the \"*\" layout's render names the stack it is drawn for") {
                case .failure(let rejection): return .failure(rejection)
                case .success(let found): on = found
                }
            }
            var sample = RenderSample()
            if let sampleValue = subject["sample"] {
                guard case .object(let members) = sampleValue else { return fail(.badValue, "a sample is an object") }
                let known = MediaResolver.knownIds(library: library.mediaIndex, machine: machine.mediaLocal)
                func content(_ value: JSONValue) -> Result<ContentExpression, Rejection> {
                    guard case .object(let object) = value, let kind = object["kind"]?.stringValue else {
                        return .failure(Rejection(reason: .badValue, message: "a sample's content is an object with its kind: text, media, pattern or empty"))
                    }
                    switch kind {
                    case "empty":
                        return .success(.empty)
                    case "pattern":
                        // Spec 11 §3 as corrected 2026-11-24 — "the engine's test pattern (`{"kind": "pattern"}`)".
                        return .success(TestPattern.content)
                    case "text":
                        guard case .object(let given)? = object["fields"] else {
                            return .failure(Rejection(reason: .badValue, message: "a text sample carries its fields"))
                        }
                        var fields: [String: String] = [:]
                        for (name, value) in given {
                            guard let text = value.stringValue else {
                                return .failure(Rejection(reason: .badValue, message: "the field \(name) of a text sample isn't text"))
                            }
                            fields[name] = text
                        }
                        return .success(.text(fields: fields))
                    case "media":
                        guard let ref = object["ref"]?.stringValue else {
                            return .failure(Rejection(reason: .badValue, message: "a media sample names its item as \"ref\""))
                        }
                        guard known.contains(ref) else {
                            return .failure(Rejection(reason: .unknownObject, message: "\(ref) isn't in either media index"))
                        }
                        return .success(.media(MediaContent(ref: ref)))
                    default:
                        return .failure(Rejection(reason: .badValue, message: "a sample is text, media, the test pattern or empty, not \(kind)"))
                    }
                }
                if let value = members["content"] {
                    switch content(value) {
                    case .failure(let rejection): return .failure(rejection)
                    case .success(let expression): sample.content = expression
                    }
                }
                if let value = members["next"] {
                    guard case .array(let later) = value, later.count <= 3 else {
                        return fail(.badValue, "a sample's next is up to three more contents, for boxes at +1 to +3")
                    }
                    for value in later {
                        switch content(value) {
                        case .failure(let rejection): return .failure(rejection)
                        case .success(let expression): sample.next.append(expression)
                        }
                    }
                }
                switch list(in: members) {
                case .failure(let rejection): return .failure(rejection)
                case .success(let from):
                    sample.list = from
                    if let from {
                        switch cue(in: members, of: from) {
                        case .failure(let rejection): return .failure(rejection)
                        case .success(let index): sample.cue = index.map { from.cues[$0].uuid }
                        }
                    } else if members["cue"] != nil {
                        return fail(.badValue, "a sample's cue comes with its list, as \"listUuid\" or \"local\"")
                    }
                }
            }
            return .success(RenderRequest(canvas: canvas, width: width, subject: .layout(preset: preset, layout: key, stack: on, sample: sample)))

        case "grade":
            var grade: Grade?
            if let value = subject["grade"], value != .null {
                guard let number = value.intValue else { return fail(.badValue, "a grade is named by its number, or null") }
                guard let found = library.grade(number) else { return fail(.unknownObject, "grade \(number) does not exist") }
                grade = found
            }
            guard let mediaValue = subject["media"] else { return fail(.missingArgument, "a grade's render names its media item") }
            guard let id = mediaValue.stringValue else { return fail(.badValue, "a media item is named by its id") }
            guard MediaResolver.knownIds(library: library.mediaIndex, machine: machine.mediaLocal).contains(id) else {
                return fail(.unknownObject, "\(id) isn't in either media index")
            }
            return .success(RenderRequest(canvas: canvas, width: width, subject: .grade(grade, media: id)))

        default:
            return fail(.badValue, "a render's subject is a cue, a layout or a grade, not \(kind)")
        }
    }
}
