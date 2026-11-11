// OCore — Spec 1 §3, machine settings.

import Foundation

/// Spec 1 §3 — machine settings `tracking` (per-attribute booleans). Spec 3
/// §3 rule 7: "With tracking off, every write of that attribute behaves as
/// `once` regardless of its stored scope."
public struct TrackingSwitches: Codable, Equatable, Sendable {
    public var grade: Bool
    public var transition: Bool
    public var audioTransition: Bool
    public var gain: Bool
    public var chase: Bool
    public var extra: [String: JSONValue]

    public init(grade: Bool = true, transition: Bool = true, audioTransition: Bool = true, gain: Bool = true,
                chase: Bool = true, extra: [String: JSONValue] = [:]) {
        self.grade = grade
        self.transition = transition
        self.audioTransition = audioTransition
        self.gain = gain
        self.chase = chase
        self.extra = extra
    }

    private enum CodingKeys: String, CodingKey, CaseIterable { case grade, transition, audioTransition, gain, chase }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        grade = try c.value(.grade, default: true)
        transition = try c.value(.transition, default: true)
        audioTransition = try c.value(.audioTransition, default: true)
        gain = try c.value(.gain, default: true)
        chase = try c.value(.chase, default: true)
        extra = try decoder.unknownKeys(besides: CodingKeys.known)
    }

    public func encode(to encoder: Encoder) throws {
        try encoder.encode(unknownKeys: extra)
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(grade, forKey: .grade)
        try c.encode(transition, forKey: .transition)
        try c.encode(audioTransition, forKey: .audioTransition)
        try c.encode(gain, forKey: .gain)
        try c.encode(chase, forKey: .chase)
    }
}

/// Spec 1 §3 — `defaultRole`; the UX spec's three roles.
public enum Role: String, Codable, Equatable, Sendable {
    case editor, `operator`, librarian
}

/// Spec 1 §3 — `libraryMode` (`readOnlyMasters` or `writable`).
public enum LibraryMode: String, Codable, Equatable, Sendable {
    case readOnlyMasters, writable
}

/// Spec 1 §3 — `operatorLock` ("enabled flag; the passcode hash lives in the
/// Keychain, never here").
public struct OperatorLock: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var extra: [String: JSONValue]

    public init(enabled: Bool = false, extra: [String: JSONValue] = [:]) {
        self.enabled = enabled
        self.extra = extra
    }

    private enum CodingKeys: String, CodingKey, CaseIterable { case enabled }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.value(.enabled, default: false)
        extra = try decoder.unknownKeys(besides: CodingKeys.known)
    }

    public func encode(to encoder: Encoder) throws {
        try encoder.encode(unknownKeys: extra)
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(enabled, forKey: .enabled)
    }
}

/// Spec 1 §3 — `snapshots` `{cadence, retention}`.
public struct SnapshotPolicy: Codable, Equatable, Sendable {
    public var cadence: String
    public var retention: String
    public var extra: [String: JSONValue]

    public init(cadence: String = "launchAndService", retention: String = "7d-daily-weekly", extra: [String: JSONValue] = [:]) {
        self.cadence = cadence
        self.retention = retention
        self.extra = extra
    }

    private enum CodingKeys: String, CodingKey, CaseIterable { case cadence, retention }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        cadence = try c.value(.cadence, default: "launchAndService")
        retention = try c.value(.retention, default: "7d-daily-weekly")
        extra = try decoder.unknownKeys(besides: CodingKeys.known)
    }

    public func encode(to encoder: Encoder) throws {
        try encoder.encode(unknownKeys: extra)
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(cadence, forKey: .cadence)
        try c.encode(retention, forKey: .retention)
    }
}

/// Spec 1 §3 — one `oscOutTargets` entry: a host and a port.
public struct OSCTarget: Codable, Equatable, Sendable {
    public var host: String
    public var port: Int
    public var extra: [String: JSONValue]

    public init(host: String, port: Int, extra: [String: JSONValue] = [:]) {
        self.host = host
        self.port = port
        self.extra = extra
    }

    private enum CodingKeys: String, CodingKey, CaseIterable { case host, port }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        host = try c.value(.host, default: "")
        port = try c.value(.port, default: 9000)
        extra = try decoder.unknownKeys(besides: CodingKeys.known)
    }

    public func encode(to encoder: Encoder) throws {
        try encoder.encode(unknownKeys: extra)
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(host, forKey: .host)
        try c.encode(port, forKey: .port)
    }
}

/// Spec 1 §3 — `network` `{oscInPort, oscOutTargets, apiPort, apiToken
/// reference}`. The token itself lives in the Keychain; the field says so.
public struct NetworkSettings: Codable, Equatable, Sendable {
    public var oscInPort: Int
    public var oscOutTargets: [OSCTarget]
    public var apiPort: Int
    public var apiToken: String
    public var extra: [String: JSONValue]

    public init(oscInPort: Int = 8000, oscOutTargets: [OSCTarget] = [], apiPort: Int = 8220, apiToken: String = "keychain",
                extra: [String: JSONValue] = [:]) {
        self.oscInPort = oscInPort
        self.oscOutTargets = oscOutTargets
        self.apiPort = apiPort
        self.apiToken = apiToken
        self.extra = extra
    }

    private enum CodingKeys: String, CodingKey, CaseIterable { case oscInPort, oscOutTargets, apiPort, apiToken }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        oscInPort = try c.value(.oscInPort, default: 8000)
        oscOutTargets = try c.value(.oscOutTargets, default: [])
        apiPort = try c.value(.apiPort, default: 8220)
        apiToken = try c.value(.apiToken, default: "keychain")
        extra = try decoder.unknownKeys(besides: CodingKeys.known)
    }

    public func encode(to encoder: Encoder) throws {
        try encoder.encode(unknownKeys: extra)
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(oscInPort, forKey: .oscInPort)
        try c.encode(oscOutTargets, forKey: .oscOutTargets)
        try c.encode(apiPort, forKey: .apiPort)
        try c.encode(apiToken, forKey: .apiToken)
    }
}

/// Spec 8 §8 — "`dropChannels` is a new machine setting (M8): `{video, image,
/// audio}`, each a channel number or null. An item's
/// `defaults.defaultChannel` overrides it. The pool's double-click and its
/// drops use them ... First run writes `{"video": 1, "image": 1, "audio":
/// null}`: channel 1 is the background, and a first-run machine has no
/// channel meant for audio, so the pool asks (choice M-6)."
public struct DropChannels: Codable, Equatable, Sendable {
    public var video: Int?
    public var image: Int?
    public var audio: Int?
    public var extra: [String: JSONValue]

    public init(video: Int? = nil, image: Int? = nil, audio: Int? = nil, extra: [String: JSONValue] = [:]) {
        self.video = video
        self.image = image
        self.audio = audio
        self.extra = extra
    }

    /// Spec 8 §8 — what first run writes (Spec 10 §13, Area 19).
    public static let firstRun = DropChannels(video: 1, image: 1, audio: nil)

    /// Spec 8 §8 — the channel a pool drop of an item goes to: its
    /// `defaults.defaultChannel`, else the setting for its kind; nil means
    /// the pool asks. Slides and templates have none until the slide
    /// designer (Spec 8 §1); an audio set counts as audio.
    public func channel(for kind: MediaKind, defaultChannel: Int?) -> Int? {
        if let defaultChannel { return defaultChannel }
        switch kind {
        case .video: return video
        case .image: return image
        case .audio, .audioSet: return audio
        case .slide, .template: return nil
        }
    }

    private enum CodingKeys: String, CodingKey, CaseIterable { case video, image, audio }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        video = try c.decodeIfPresent(Int.self, forKey: .video)
        image = try c.decodeIfPresent(Int.self, forKey: .image)
        audio = try c.decodeIfPresent(Int.self, forKey: .audio)
        extra = try decoder.unknownKeys(besides: CodingKeys.known)
    }

    public func encode(to encoder: Encoder) throws {
        try encoder.encode(unknownKeys: extra)
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeNullable(video, forKey: .video)
        try c.encodeNullable(image, forKey: .image)
        try c.encodeNullable(audio, forKey: .audio)
    }
}

/// Spec 1 §3 — Machine settings (one document, `machine.json`): machine
/// `uuid` and `campusName`, `defaultRole`, `operatorLock`, `libraryMode`,
/// `mediaRoot`, `defaultImportFolder`, `dropChannels` ("a channel per media
/// kind for drops from the pool, Spec 8 §8"), `fallbackFont`,
/// `thumbnailStack`, `decoderCapDefault`, `tracking`, `timers` and `popups`
/// (slot counts), `timeFormat`, `timeZone`, `startupMacro`, `shutdownMacro`,
/// `restoreLastState` (default false), `snapshots`, `commandBar` (default
/// false), `network`. The defaults are the UX spec's first-run defaults.
/// `dropChannels` is nil when `machine.json` doesn't hold it, and is then
/// written back absent, so a machine root from before Spec 8 round-trips
/// unchanged; read as a setting, nil means the pool asks for every kind.
public struct MachineSettings: Codable, Equatable, Sendable {
    public var uuid: UUID
    public var campusName: String
    public var defaultRole: Role
    public var operatorLock: OperatorLock
    public var libraryMode: LibraryMode
    public var mediaRoot: String
    public var defaultImportFolder: String
    public var dropChannels: DropChannels?
    public var fallbackFont: String
    public var thumbnailStack: Int
    public var decoderCapDefault: Int
    public var tracking: TrackingSwitches
    public var timers: Int
    public var popups: Int
    public var timeFormat: String
    public var timeZone: String
    public var startupMacro: Int?
    public var shutdownMacro: Int?
    public var restoreLastState: Bool
    public var snapshots: SnapshotPolicy
    public var commandBar: Bool
    public var network: NetworkSettings
    public var extra: [String: JSONValue]

    public init(uuid: UUID = UUID(), campusName: String = "", defaultRole: Role = .editor,
                operatorLock: OperatorLock = OperatorLock(), libraryMode: LibraryMode = .readOnlyMasters,
                mediaRoot: String = "../library/media", defaultImportFolder: String = "imports",
                dropChannels: DropChannels? = nil,
                fallbackFont: String = "HelveticaNeue", thumbnailStack: Int = 1, decoderCapDefault: Int = 2,
                tracking: TrackingSwitches = TrackingSwitches(), timers: Int = 4, popups: Int = 4,
                timeFormat: String = "h:mm a", timeZone: String = "America/New_York", startupMacro: Int? = nil,
                shutdownMacro: Int? = nil, restoreLastState: Bool = false, snapshots: SnapshotPolicy = SnapshotPolicy(),
                commandBar: Bool = false, network: NetworkSettings = NetworkSettings(), extra: [String: JSONValue] = [:]) {
        self.uuid = uuid
        self.campusName = campusName
        self.defaultRole = defaultRole
        self.operatorLock = operatorLock
        self.libraryMode = libraryMode
        self.mediaRoot = mediaRoot
        self.defaultImportFolder = defaultImportFolder
        self.dropChannels = dropChannels
        self.fallbackFont = fallbackFont
        self.thumbnailStack = thumbnailStack
        self.decoderCapDefault = decoderCapDefault
        self.tracking = tracking
        self.timers = timers
        self.popups = popups
        self.timeFormat = timeFormat
        self.timeZone = timeZone
        self.startupMacro = startupMacro
        self.shutdownMacro = shutdownMacro
        self.restoreLastState = restoreLastState
        self.snapshots = snapshots
        self.commandBar = commandBar
        self.network = network
        self.extra = extra
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case uuid, campusName, defaultRole, operatorLock, libraryMode, mediaRoot, defaultImportFolder, dropChannels, fallbackFont
        case thumbnailStack, decoderCapDefault, tracking, timers, popups, timeFormat, timeZone, startupMacro, shutdownMacro
        case restoreLastState, snapshots, commandBar, network
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        uuid = try c.uuid(.uuid)
        campusName = try c.value(.campusName, default: "")
        defaultRole = try c.value(.defaultRole, default: .editor)
        operatorLock = try c.value(.operatorLock, default: OperatorLock())
        libraryMode = try c.value(.libraryMode, default: .readOnlyMasters)
        mediaRoot = try c.value(.mediaRoot, default: "../library/media")
        defaultImportFolder = try c.value(.defaultImportFolder, default: "imports")
        dropChannels = try c.decodeIfPresent(DropChannels.self, forKey: .dropChannels)
        fallbackFont = try c.value(.fallbackFont, default: "HelveticaNeue")
        thumbnailStack = try c.value(.thumbnailStack, default: 1)
        decoderCapDefault = try c.value(.decoderCapDefault, default: 2)
        tracking = try c.value(.tracking, default: TrackingSwitches())
        timers = try c.value(.timers, default: 4)
        popups = try c.value(.popups, default: 4)
        timeFormat = try c.value(.timeFormat, default: "h:mm a")
        timeZone = try c.value(.timeZone, default: "America/New_York")
        startupMacro = try c.decodeIfPresent(Int.self, forKey: .startupMacro)
        shutdownMacro = try c.decodeIfPresent(Int.self, forKey: .shutdownMacro)
        restoreLastState = try c.value(.restoreLastState, default: false)
        snapshots = try c.value(.snapshots, default: SnapshotPolicy())
        commandBar = try c.value(.commandBar, default: false)
        network = try c.value(.network, default: NetworkSettings())
        extra = try decoder.unknownKeys(besides: CodingKeys.known)
    }

    public func encode(to encoder: Encoder) throws {
        try encoder.encode(unknownKeys: extra)
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(uuid: uuid, forKey: .uuid)
        try c.encode(campusName, forKey: .campusName)
        try c.encode(defaultRole, forKey: .defaultRole)
        try c.encode(operatorLock, forKey: .operatorLock)
        try c.encode(libraryMode, forKey: .libraryMode)
        try c.encode(mediaRoot, forKey: .mediaRoot)
        try c.encode(defaultImportFolder, forKey: .defaultImportFolder)
        // Spec 8 §8 — written when the document holds it, so older machine roots round-trip.
        try c.encodeIfPresent(dropChannels, forKey: .dropChannels)
        try c.encode(fallbackFont, forKey: .fallbackFont)
        try c.encode(thumbnailStack, forKey: .thumbnailStack)
        try c.encode(decoderCapDefault, forKey: .decoderCapDefault)
        try c.encode(tracking, forKey: .tracking)
        try c.encode(timers, forKey: .timers)
        try c.encode(popups, forKey: .popups)
        try c.encode(timeFormat, forKey: .timeFormat)
        try c.encode(timeZone, forKey: .timeZone)
        try c.encodeNullable(startupMacro, forKey: .startupMacro)
        try c.encodeNullable(shutdownMacro, forKey: .shutdownMacro)
        try c.encode(restoreLastState, forKey: .restoreLastState)
        try c.encode(snapshots, forKey: .snapshots)
        try c.encode(commandBar, forKey: .commandBar)
        try c.encode(network, forKey: .network)
    }
}
