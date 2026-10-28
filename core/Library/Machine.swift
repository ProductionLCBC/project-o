// OCore — Spec 1 §3 and §5, the machine root in memory.

import Foundation

/// Spec 1 §5 — the machine root: "local, never synced". The machine-level
/// objects of §3 in number order, the machine index of §7, the reserved clocks
/// document as read, the last state, and what the loader needs to write each
/// document back where it found it. Spec 3 §6 reads it as the context's
/// `machine` "(stacks, outputs, playlists and local copies, tracking switches,
/// decoder cap default)".
public struct Machine: Equatable, Sendable {
    public var settings: MachineSettings
    public var stacks: [Stack]
    public var outputs: [Output]
    public var audioOutputs: [AudioOutput]
    public var inputs: [Input]
    /// Spec 1 §5 — `clocks.json` is reserved; its body is kept as read.
    public var clocks: JSONValue
    public var keys: [KeyBinding]
    public var mediaLocal: MediaLocalIndex
    public var macros: [Macro]
    public var playlists: [Playlist]
    public var localLists: [List]
    /// Spec 1 §5 — `state/last.json`, "channel state at last clean shutdown".
    public var lastState: ShowState?
    public var documentExtras: [DocumentKind: [String: JSONValue]]
    public var documentPaths: [String: String]

    public init(stacks: [Stack] = [], outputs: [Output] = [], playlists: [Playlist] = [], localLists: [List] = [],
                tracking: TrackingSwitches = TrackingSwitches(), decoderCapDefault: Int = 2,
                settings: MachineSettings? = nil, audioOutputs: [AudioOutput] = [], inputs: [Input] = [],
                clocks: JSONValue = .object(["clocks": .array([])]), keys: [KeyBinding] = [],
                mediaLocal: MediaLocalIndex = MediaLocalIndex(), macros: [Macro] = [], lastState: ShowState? = nil,
                documentExtras: [DocumentKind: [String: JSONValue]] = [:], documentPaths: [String: String] = [:]) {
        var settings = settings ?? MachineSettings()
        if settings.tracking != tracking { settings.tracking = tracking }
        if settings.decoderCapDefault != decoderCapDefault { settings.decoderCapDefault = decoderCapDefault }
        self.settings = settings
        self.stacks = stacks
        self.outputs = outputs
        self.audioOutputs = audioOutputs
        self.inputs = inputs
        self.clocks = clocks
        self.keys = keys
        self.mediaLocal = mediaLocal
        self.macros = macros
        self.playlists = playlists
        self.localLists = localLists
        self.lastState = lastState
        self.documentExtras = documentExtras
        self.documentPaths = documentPaths
    }

    /// Spec 3 §6 — the tracking switches the projection reads.
    public var tracking: TrackingSwitches {
        get { settings.tracking }
        set { settings.tracking = newValue }
    }

    /// Spec 3 §4 — the decoder cap for channels without one of their own.
    public var decoderCapDefault: Int {
        get { settings.decoderCapDefault }
        set { settings.decoderCapDefault = newValue }
    }

    // MARK: - Lookups

    public func stack(_ number: Int) -> Stack? { stacks.first { $0.number == number } }
    public func output(_ number: Int) -> Output? { outputs.first { $0.number == number } }
    public func audioOutput(_ number: Int) -> AudioOutput? { audioOutputs.first { $0.number == number } }
    public func input(_ number: Int) -> Input? { inputs.first { $0.number == number } }
    public func macro(_ number: Int) -> Macro? { macros.first { $0.number == number } }
    public func playlist(uuid: UUID) -> Playlist? { playlists.first { $0.uuid == uuid } }
    public func localList(uuid: UUID) -> List? { localLists.first { $0.uuid == uuid } }

    /// Replace the local copy with the same `uuid`, or append it.
    public mutating func replace(localList: List) {
        if let index = localLists.firstIndex(where: { $0.uuid == localList.uuid }) {
            localLists[index] = localList
        } else {
            localLists.append(localList)
        }
    }
}
