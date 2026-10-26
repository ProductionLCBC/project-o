import Foundation
import OCore

/// The in-test library and machine the Spec 3 §9 table runs against.
///
/// §9: "Frames are at 60 fps; channel defaults are transition 1 (cut), no
/// grade, gain 0; `A`, `B`, `C` are media ids; `S` is a slide." The fixture
/// library on disk (tests/fixtures/library-v1, Spec 1 §10) does not exist
/// yet, so this is built in code with fixed UUIDs.
enum Fixtures {
    // MARK: - Identifiers

    static func uuid(_ n: Int) -> UUID {
        let hex = String(n, radix: 16)
        let padded = String(repeating: "0", count: 12 - hex.count) + hex
        guard let u = UUID(uuidString: "00000000-0000-0000-0000-" + padded) else {
            preconditionFailure("fixture uuid \(n)")
        }
        return u
    }

    // Lists: uuid(1000 + list number). Cues: uuid(list * 100 + position).
    static func listUuid(_ list: Int) -> UUID { uuid(1000 + list) }
    static func cueUuid(list: Int, cue: Int) -> UUID { uuid(list * 100 + cue) }
    static let playlistUuid = uuid(5000)

    static let mediaA = "A"
    static let mediaB = "B"
    static let mediaC = "C"
    static let slideS = "slide:S"

    // MARK: - Command builders

    static func write(_ channel: Int, media ref: String, riders: Riders = .none) -> Command {
        .channelWrite(ChannelWrite(channel: .number(channel), content: .media(MediaContent(ref: ref)), riders: riders))
    }

    static func write(_ channel: Int, text body: String, riders: Riders = .none) -> Command {
        .channelWrite(ChannelWrite(channel: .number(channel), content: .text(fields: ["body": body]), riders: riders))
    }

    static func write(_ channel: Int, slide ref: String, build: Int?, riders: Riders = .none) -> Command {
        .channelWrite(ChannelWrite(channel: .number(channel), content: .slide(ref: ref, build: build), riders: riders))
    }

    // MARK: - Library

    static let channels: [Channel] = (1...3).map {
        Channel(number: $0, label: "Channel \($0)",
                defaults: ChannelDefaults(transition: 1, audioTransition: 1, gain: 0), decoderCap: 2)
    }

    static let transitions: [Transition] = [
        Transition(number: 1, type: .cut, ms: 0),
        Transition(number: 2, type: .dissolve, ms: 500),
        Transition(number: 3, type: .fadeThroughColor, ms: 1000),
    ]

    static let audioTransitions: [AudioTransition] = [
        AudioTransition(number: 1, type: .cut, ms: 0),
        AudioTransition(number: 2, type: .crossfade, ms: 500),
    ]

    static func cue(list: Int, _ position: Int, section: String? = nil, trigger: CueTrigger = .go,
                    advanceAfterMs: Int? = nil, commands: [Command] = []) -> Cue {
        Cue(uuid: cueUuid(list: list, cue: position), label: "L\(list) cue \(position)", section: section,
            trigger: trigger, advanceAfterMs: advanceAfterMs, commands: commands)
    }

    /// L1: a three-cue hymn.
    static let list1 = List(uuid: listUuid(1), number: 1, title: "Hymn one", cues: [
        cue(list: 1, 1, section: "verse", commands: [write(1, media: mediaA), write(2, text: "verse 1")]),
        cue(list: 1, 2, section: "chorus", commands: [write(2, text: "chorus")]),
        cue(list: 1, 3, section: "verse", commands: [write(2, text: "verse 2")]),
    ])

    /// L2: `trackThrough` off; cue 2 holds (no commands).
    static let list2 = List(uuid: listUuid(2), number: 2, title: "Hymn two", trackThrough: false, cues: [
        cue(list: 2, 1, commands: [write(1, media: mediaB)]),
        cue(list: 2, 2),
    ])

    /// L3: `trackThrough` off; the last item of the playlist.
    static let list3 = List(uuid: listUuid(3), number: 3, title: "Hymn three", trackThrough: false, cues: [
        cue(list: 3, 1, commands: [write(1, media: mediaC)]),
        cue(list: 3, 2),
    ])

    /// L4: triggers. Cue 2 has Time 5 s; cue 1's advance-after is a parameter
    /// (rows 20 and 21). Seven cues so `cue 7` exists and is last.
    static func triggerList(advanceAfterMs: Int?) -> List {
        var cues: [Cue] = [
            cue(list: 4, 1, advanceAfterMs: advanceAfterMs, commands: [write(3, text: "one")]),
            cue(list: 4, 2, trigger: .time(ms: 5000), commands: [write(3, text: "two")]),
        ]
        for n in 3...7 { cues.append(cue(list: 4, n, commands: [write(3, text: "cue \(n)")])) }
        return List(uuid: listUuid(4), number: 4, title: "Triggers", cues: cues)
    }
    static let list4 = triggerList(advanceAfterMs: nil)

    /// L5: lookahead (row 18). Cue 1 writes y, cue 2 writes z, cue 3 leaves
    /// channel 2 alone.
    static let list5 = List(uuid: listUuid(5), number: 5, title: "Lookahead", cues: [
        cue(list: 5, 1, commands: [write(2, text: "y")]),
        cue(list: 5, 2, commands: [write(2, text: "z")]),
        cue(list: 5, 3, commands: [write(1, media: mediaA)]),
    ])

    /// L6: a medley, `trackThrough` on (row 8).
    static let list6 = List(uuid: listUuid(6), number: 6, title: "Medley", trackThrough: true, cues: [
        cue(list: 6, 1, commands: [write(1, media: mediaC)]),
        cue(list: 6, 2),
    ])

    /// L7: a cue that runs a macro (lock through a macro, Spec 3 §8).
    static let list7 = List(uuid: listUuid(7), number: 7, title: "Macro cue", cues: [
        cue(list: 7, 1, commands: [.macro(2)]),
    ])

    static let macros: [Macro] = [
        // Macro 1: a guarded welcome.
        Macro(number: 1, commands: [
            GuardedCommand(write(2, text: "Welcome"),
                           when: Guard(variable: "Channel 2 Content", op: .isEmpty)),
        ]),
        // Macro 2: writes channel 2 unconditionally.
        Macro(number: 2, commands: [GuardedCommand(write(2, text: "from macro"))]),
    ]

    static let library = Library(
        channels: channels, transitions: transitions, audioTransitions: audioTransitions,
        lists: [list1, list2, list3, list4, list5, list6, list7], macros: macros)

    // MARK: - Machine

    /// Items: 1 header, 2 L1, 3 L2, 4 header, 5 L3 (rows 16 and 17).
    static let playlist = Playlist(uuid: playlistUuid, title: "Sunday", serviceDate: "2026-11-01", items: [
        .header(label: "Welcome"),
        .linked(list: 1),
        .linked(list: 2),
        .header(label: "Sermon"),
        .linked(list: 3),
    ])

    static let machine = Machine(
        stacks: [
            Stack(number: 1, slots: [StackSlot(channel: 1), StackSlot(channel: 2)]),
            Stack(number: 2, slots: [StackSlot(channel: 2), StackSlot(channel: 2, offset: 1)]),
        ],
        outputs: [
            Output(number: 1, defaultStack: 1, transitions: OutputTransitions(switch: 2, blackout: 3)),
            Output(number: 2, defaultStack: 2, transitions: OutputTransitions(switch: 1, blackout: 2)),
        ],
        playlists: [playlist],
        tracking: TrackingSwitches(),
        decoderCapDefault: 2)

    // MARK: - State and context

    static func fresh() -> ShowState {
        ShowState.fresh(library: library, machine: machine)
    }

    static func context(frame: Int, source: SourceKind = .ui, library: Library = library,
                        machine: Machine = machine, missing: Set<String> = [],
                        variables: @escaping @Sendable (String) -> String? = { _ in nil }) -> ProjectionContext {
        ProjectionContext(frame: frame, rate: .fps60, library: library, machine: machine, missing: missing,
                          source: CommandSource(kind: source), variables: variables)
    }

    /// A pointer on a cue of the playlist.
    static func pointer(item: Int, list: Int, cue: Int) -> LivePointer {
        LivePointer(playlist: playlistUuid, item: item, listUuid: listUuid(list), cueUuid: cueUuid(list: list, cue: cue))
    }

    /// A pointer on a cue of a library list fired directly.
    static func pointer(list: Int, cue: Int) -> LivePointer {
        LivePointer(playlist: nil, item: nil, listUuid: listUuid(list), cueUuid: cueUuid(list: list, cue: cue))
    }
}
