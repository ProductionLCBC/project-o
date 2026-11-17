// OMach — Spec 10 §2, what the Mach channel carries: the message ids and the values both ends share.

@preconcurrency import Darwin
import Foundation
import IOSurface

/// Spec 10 §2, "The Mach channel" — it "carries what is too frequent or too
/// large for the socket: the preview surfaces, the channel pictures and the
/// meters (Spec 4 §10)". The messages, each a Mach message whose own bytes
/// are little-endian 32-bit words, the first always the layout's version:
///
/// | id | From | Carries |
/// | --- | --- | --- |
/// | `connect` | the app | a reply port of its own; words: version |
/// | `previewSurfaces` | the engine | three surface ports; words: version, stack, width, height |
/// | `previewFrame` | the engine | words: version, stack, the surface (0 to 2) that holds the newest frame |
/// | `pictureSurfaces` | the engine | three surface ports; words: version, channel, width, height |
/// | `pictureFrame` | the engine | words: version, channel, the surface that holds the newest picture |
/// | `channelRemoved` | the engine | words: version, channel |
/// | `meters` | the engine | words: version, count, then per channel: channel, peak, RMS (32-bit floats, dBFS) |
public enum MachWire {
    public static let version: UInt32 = 1
    public static let connect: mach_msg_id_t = 0x4F10
    public static let previewSurfaces: mach_msg_id_t = 0x4F11
    public static let previewFrame: mach_msg_id_t = 0x4F12
    public static let pictureSurfaces: mach_msg_id_t = 0x4F13
    public static let pictureFrame: mach_msg_id_t = 0x4F14
    public static let channelRemoved: mach_msg_id_t = 0x4F15
    public static let meters: mach_msg_id_t = 0x4F16
    /// Spec 10 §2 — meters read in dBFS; silence is this floor, not minus infinity.
    public static let floorDecibels: Float = -120
}

/// Spec 10 §2 — one stack's three preview surfaces, or one channel's three
/// picture surfaces, with their size.
public struct MachSurfaceSet: @unchecked Sendable {
    public var number: Int
    public var width: Int
    public var height: Int
    public var surfaces: [IOSurfaceRef]

    public init(number: Int, width: Int, height: Int, surfaces: [IOSurfaceRef]) {
        self.number = number
        self.width = width
        self.height = height
        self.surfaces = surfaces
    }
}

/// Spec 10 §2 — "Meters: 15 times a second, for each channel whose content
/// has sound, the peak and RMS level in dBFS since the last frame, after
/// gain, of its loudest audio channel."
public struct MeterReading: Equatable, Sendable {
    public var channel: Int
    public var peak: Float
    public var rms: Float

    public init(channel: Int, peak: Float, rms: Float) {
        self.channel = channel
        self.peak = peak
        self.rms = rms
    }

    /// A linear level as dBFS, never below the floor.
    public static func decibels(_ linear: Float) -> Float {
        guard linear > 0 else { return MachWire.floorDecibels }
        return max(MachWire.floorDecibels, 20 * log10f(linear))
    }
}
