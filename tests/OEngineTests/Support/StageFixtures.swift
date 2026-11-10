import Foundation
import OCore
@testable import OEngine

/// Small in-code additions to the fixture library for the Spec 6 tests: lists
/// with known cues, presets of a few boxes, and a stack slot that uses them.
/// Everything else is the fixture's (Spec 1 §10).
enum StageFixtures {
    typealias E = EngineFixtures

    // MARK: - Commands

    static func text(_ body: String, channel: Int = 2) -> Command {
        .channelWrite(ChannelWrite(channel: .number(channel), content: .text(fields: ["body": body])))
    }

    static func fields(_ fields: [String: String], channel: Int = 2) -> Command {
        .channelWrite(ChannelWrite(channel: .number(channel), content: .text(fields: fields)))
    }

    static func media(_ ref: String = E.dawn, channel: Int = 2) -> Command {
        .channelWrite(ChannelWrite(channel: .number(channel), content: .media(MediaContent(ref: ref))))
    }

    // MARK: - Lists

    /// A list numbered `number` whose cues run the given commands, one cue each.
    static func list(_ number: Int, title: String = "", author: String = "", copyright: String = "", ccli: String = "",
                     cues: [[Command]]) -> List {
        List(uuid: listUuid(number), number: number, title: title, trackThrough: false,
             cues: cues.enumerated().map { index, commands in
                 Cue(uuid: cueUuid(list: number, index + 1), label: "cue \(index + 1)", commands: commands)
             },
             author: author, copyright: copyright, ccli: ccli)
    }

    static func listUuid(_ number: Int) -> UUID { E.uuid("a9f0", number) }
    static func cueUuid(list: Int, _ position: Int) -> UUID { E.uuid(String(format: "c%03d", list), position) }

    /// Spec 3 §9 row 18 — "channel 2 text y; next two cues write channel 2 z then nothing".
    static let lookahead = list(50, title: "Lookahead", cues: [[text("y")], [text("z")], [media(channel: 1)]])
    /// Three cues of different text, for transitions and prefetch.
    static let three = list(51, title: "Three", cues: [[text("a")], [text("b")], [text("c")]])

    // MARK: - Boxes and presets

    static func body(_ offset: Int, y: Double = 0.1, fallback: Bool = false, transition: BoxTransition = BoxTransition(ref: 1),
                     name: String = "body", size: Double = 0.1) -> Box {
        Box(binding: .field(name: name), frame: Frame(x: 0.05, y: y, w: 0.9, h: size),
            fit: .text(TextFit(policy: .shrinkToFit, maxLines: 6, minSize: 12)), textStyle: BoxTextStyle(),
            transition: transition, fallback: fallback, offset: offset)
    }

    static func label(_ text: String, _ offset: Int, y: Double = 0.85) -> Box {
        Box(binding: .static(text: text), frame: Frame(x: 0.05, y: y, w: 0.9, h: 0.1),
            fit: .text(TextFit(policy: .shrinkToFit, maxLines: 1, minSize: 12)), textStyle: BoxTextStyle(),
            transition: BoxTransition(ref: 1), offset: offset)
    }

    static func pixels(_ offset: Int) -> Box {
        Box(binding: .pixels, frame: .full, fit: .pixels(.fit), transition: BoxTransition(ref: 1), offset: offset)
    }

    static func preset(_ number: Int, _ label: String = "Test", boxes: [Box]) -> Preset {
        Preset(number: number, label: label, uuid: E.uuid("c0de", number), layouts: [.any: Layout(boxes: boxes)])
    }

    // MARK: - Engines

    /// The fixture library and the spike machine, with `presets` and `lists`
    /// added and stack 2's slot for channel 2 given `preset`.
    static func engine(preset: Preset? = nil, presets: [Preset] = [], lists: [List] = [lookahead, three],
                       playlists: [Playlist] = [], edit: (inout Library, inout Machine) -> Void = { _, _ in }) throws -> HeadlessEngine {
        var library = try E.library()
        var machine = try E.spikeMachine()
        library.presets.append(contentsOf: presets + (preset.map { [$0] } ?? []))
        library.lists.append(contentsOf: lists)
        machine.playlists.append(contentsOf: playlists)
        if let preset { machine.stacks[1].slots[0].preset = preset.number }
        edit(&library, &machine)
        return try HeadlessEngine(library: library, machine: machine, mediaRoot: E.mediaRoot)
    }
}

extension HeadlessEngine {
    /// The resolved boxes of `stack` in the last plan, for `channel` when given.
    func boxes(stack: Int, channel: Int? = nil) -> [ResolvedBox] {
        let all = lastPlan?.stackPasses.first { $0.stack == stack }?.boxes ?? []
        guard let channel else { return all }
        return all.filter { $0.channel == channel }
    }

    /// Spec 6 §3 — the text each offset of `stack` draws for `channel`, one box per offset.
    func texts(stack: Int = 2, channel: Int = 2) -> [Int: String] {
        var out: [Int: String] = [:]
        for box in boxes(stack: stack, channel: channel) { out[box.offset] = box.text ?? "" }
        return out
    }
}
