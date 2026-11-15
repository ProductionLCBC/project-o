// OEngine — the harness's device list.

import Foundation
import OCore

/// Spec 10 §16 — "Area 19's tests run the first-run writer against fake
/// device lists (screens, ports, audio devices)": a `DeviceLister` that
/// answers what a test gave it, and can be changed as a screen coming or
/// going would change the Mac's.
public final class FakeDevices: DeviceLister, @unchecked Sendable {
    private let lock = NSLock()
    private var held: DetectedDevices

    public init(_ devices: DetectedDevices = DetectedDevices()) {
        held = devices
    }

    public var list: DetectedDevices {
        get {
            lock.lock()
            defer { lock.unlock() }
            return held
        }
        set {
            lock.lock()
            held = newValue
            lock.unlock()
        }
    }

    public func devices() -> DetectedDevices { list }

    /// A screen for a test: `display:<uuid>` at a place among the screens,
    /// 1920 by 1080 at 60 unless the test says otherwise.
    public static func screen(_ uuid: String, name: String = "Screen", x: Double = 0, y: Double = 0, width: Int = 1920, height: Int = 1080,
                              hertz: Double = 60, mirrored: Bool = false) -> DetectedScreen {
        DetectedScreen(device: DetectedScreen.devicePrefix + uuid.uppercased(), name: name,
                       frame: ScreenFrame(x: x, y: y, width: Double(width), height: Double(height)),
                       mode: VideoFormat(width: width, height: height, rate: .nearest(hertz: hertz), interlaced: false), mirrored: mirrored)
    }
}
