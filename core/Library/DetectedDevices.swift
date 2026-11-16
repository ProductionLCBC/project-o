// OCore — Spec 10 §3, the `devices` query, and what first run reads (Spec 10 §13).

/// Spec 10 §3, the `devices` query — "Screens (`display:<uuid>`, name, frame,
/// current mode, and whether it is mirrored)". Plain data: the engine fills
/// it from the Mac, and tests from a table (Spec 10 §16: "fake device lists").
public struct DetectedScreen: Codable, Equatable, Sendable {
    /// Spec 1 §3 — an Output's `device` for this screen: `display:` and the
    /// display's uuid, in capitals as macOS prints it.
    public var device: String
    public var name: String
    /// Where the screen sits among the screens, in points, from the top left
    /// of the screen with the menu bar, y running down.
    public var frame: ScreenFrame
    /// Spec 10 §13 — "A screen's output takes its current mode, progressive
    /// and full range": the mode's size in pixels and its refresh rate.
    public var mode: VideoFormat
    /// Spec 10 §13 — mirrored screens, "which macOS reports as one screen".
    public var mirrored: Bool

    public init(device: String, name: String, frame: ScreenFrame, mode: VideoFormat, mirrored: Bool = false) {
        self.device = device
        self.name = name
        self.frame = frame
        self.mode = mode
        self.mirrored = mirrored
    }

    /// The display's uuid, without its `display:` prefix.
    public var uuid: String { DetectedScreen.uuid(ofDevice: device) ?? device }

    /// The uuid a `display:<uuid>` device names, in capitals, or nil for another kind of device.
    public static func uuid(ofDevice device: String) -> String? {
        guard device.hasPrefix(devicePrefix) else { return nil }
        return String(device.dropFirst(devicePrefix.count)).uppercased()
    }

    public static let devicePrefix = "display:"
}

/// A screen's place and size among the screens, in points.
public struct ScreenFrame: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

/// Spec 10 §3, the `devices` query — "DeckLink output ports (`decklink:<id>`,
/// name, the modes it plays)".
public struct DetectedPort: Codable, Equatable, Sendable {
    /// Spec 1 §3 — an Output's `device` for this port: `decklink:` and the
    /// port's persistent id.
    public var device: String
    public var name: String
    public var modes: [VideoFormat]

    public init(device: String, name: String, modes: [VideoFormat] = []) {
        self.device = device
        self.name = name
        self.modes = modes
    }

    public static let devicePrefix = "decklink:"
}

/// Spec 10 §3, the `devices` query — "audio output devices (UID, name,
/// channel count, whether it is the system default)".
public struct DetectedAudioDevice: Codable, Equatable, Sendable {
    public var uid: String
    public var name: String
    public var channels: Int
    public var isDefault: Bool

    public init(uid: String, name: String, channels: Int, isDefault: Bool = false) {
        self.uid = uid
        self.name = name
        self.channels = channels
        self.isDefault = isDefault
    }
}

/// Spec 10 §3 — what the `devices` query answers and the `devices` topic
/// carries; Spec 10 §13 — what first run numbers the outputs from: ports "in
/// the order the driver lists them", screens in the order the Mac reports them.
public struct DetectedDevices: Codable, Equatable, Sendable {
    public var screens: [DetectedScreen]
    public var ports: [DetectedPort]
    public var audio: [DetectedAudioDevice]

    public init(screens: [DetectedScreen] = [], ports: [DetectedPort] = [], audio: [DetectedAudioDevice] = []) {
        self.screens = screens
        self.ports = ports
        self.audio = audio
    }
}

extension FrameRate {
    /// Spec 1 §5 — "frame rates are `{num, den}` (so 59.94 is `{60000,
    /// 1001}`)": the rate a refresh in hertz names. A screen reports 59.94 or
    /// 60 as a decimal; within a hundredth of a broadcast rate it is that
    /// rate's fraction, else the nearest whole rate.
    public static func nearest(hertz: Double) -> FrameRate {
        guard hertz.isFinite, hertz > 0 else { return .fps60 }
        for whole in [24, 30, 48, 60, 120, 240] {
            let fractional = Double(whole) * 1000 / 1001
            if abs(hertz - fractional) < 0.01 { return FrameRate(num: whole * 1000, den: 1001) }
        }
        return FrameRate(num: max(1, Int(hertz.rounded())), den: 1)
    }

    /// Spec 4 §2 — "One rate family per machine ... integer (60, 30) or
    /// fractional (59.94, 29.97)".
    public var isFractional: Bool { den != 1 }
}
