// OEngine — Spec 10 §3 and §13, the devices of this Mac.

import AppKit
import CoreGraphics
import Foundation
import OCore
import ODeckLink

/// Spec 10 §3 — the `devices` query's answer, read from the Mac: the screens
/// from AppKit and Core Graphics, the DeckLink output ports from the driver
/// through the DeckLink module, the audio output devices from Core Audio.
///
/// AppKit names screens only on the main thread, so the screens are read
/// there (`refreshScreens`, at launch and at every change of screens) and
/// kept; `devices()` answers from any thread with the kept screens and a
/// fresh reading of the ports and the audio devices.
public final class SystemDevices: DeviceLister, @unchecked Sendable {
    private let lock = NSLock()
    private var screens: [DetectedScreen] = []

    @MainActor
    public init() {
        refreshScreens()
    }

    /// Reads the screens again; the change of screens calls it before anything asks.
    @MainActor
    public func refreshScreens() {
        let read = Self.readScreens()
        lock.lock()
        screens = read
        lock.unlock()
    }

    /// The screens as they were last read.
    public var keptScreens: [DetectedScreen] {
        lock.lock()
        defer { lock.unlock() }
        return screens
    }

    public func devices() -> DetectedDevices {
        DetectedDevices(screens: keptScreens, ports: Self.readPorts(), audio: HALOutputDevice.outputDevices())
    }

    /// Spec 10 §3 — each screen with its `display:<uuid>`, name, frame,
    /// current mode and whether it mirrors. macOS reports a mirrored set as
    /// one screen (Spec 10 §13), and that one says `mirrored`.
    @MainActor
    static func readScreens() -> [DetectedScreen] {
        NSScreen.screens.compactMap { screen in
            guard let id = displayID(of: screen), let uuid = uuid(of: id) else { return nil }
            let bounds = CGDisplayBounds(id)
            let mode = CGDisplayCopyDisplayMode(id)
            let refresh = mode.map(\.refreshRate).flatMap { $0 > 0 ? $0 : nil } ?? Double(max(1, screen.maximumFramesPerSecond))
            let pixels = (width: mode?.pixelWidth ?? Int(bounds.width * screen.backingScaleFactor),
                          height: mode?.pixelHeight ?? Int(bounds.height * screen.backingScaleFactor))
            return DetectedScreen(device: DetectedScreen.devicePrefix + uuid, name: screen.localizedName,
                                  frame: ScreenFrame(x: bounds.origin.x, y: bounds.origin.y, width: bounds.width, height: bounds.height),
                                  mode: VideoFormat(width: pixels.width, height: pixels.height, rate: .nearest(hertz: refresh), interlaced: false),
                                  mirrored: CGDisplayIsInMirrorSet(id) != 0)
        }
    }

    /// Spec 10 §2 — "opens when a screen with its id appears": the screen
    /// whose display has this uuid, or nil when no screen has it now.
    @MainActor
    public static func screen(uuid: String) -> NSScreen? {
        let wanted = uuid.uppercased()
        return NSScreen.screens.first { screen in displayID(of: screen).flatMap(Self.uuid(of:)) == wanted }
    }

    @MainActor
    static func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber).map { CGDirectDisplayID($0.uint32Value) }
    }

    /// A display's uuid as macOS prints it, in capitals: what `display:<uuid>` holds.
    static func uuid(of id: CGDirectDisplayID) -> String? {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(id) else { return nil }
        return (CFUUIDCreateString(nil, uuid.takeRetainedValue()) as String).uppercased()
    }

    /// Spec 10 §13 — "ports in the order the driver lists them", each with
    /// the modes it plays. None without the SDK, the driver or a card.
    static func readPorts() -> [DetectedPort] {
        let capacity = 8
        var ports = [odl_port_t](repeating: odl_port_t(), count: capacity)
        let count = min(capacity, Int(odl_list_output_ports(&ports, Int32(capacity))))
        guard count > 0 else { return [] }
        return ports.prefix(count).map { port in
            let id = withUnsafeBytes(of: port.persistent_id) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            let name = withUnsafeBytes(of: port.name) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            let modes = withUnsafeBytes(of: port.modes) { raw in
                Array(raw.bindMemory(to: odl_mode_t.self).prefix(max(0, Int(port.mode_count))))
            }
            return DetectedPort(device: DetectedPort.devicePrefix + id, name: name, modes: modes.map { mode in
                VideoFormat(width: Int(mode.width), height: Int(mode.height), rate: FrameRate(num: Int(mode.rate_num), den: Int(mode.rate_den)),
                            interlaced: mode.interlaced)
            })
        }
    }
}
