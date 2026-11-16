import Foundation
import IOSurface
import OCore
@testable import OEngine

/// A surface for each preview and picture texture of a headless engine, made
/// when first asked for. The headless backend draws nothing, so what these
/// hold is what a test puts there; what is sent of them, when and to whom is
/// the engine's own (Spec 10 §2, the Mach channel; Spec 10 §3, `preview`).
final class TestSurfaces: @unchecked Sendable {
    private let lock = NSLock()
    private var made: [Int32: IOSurfaceRef] = [:]
    private let sizes: [Int32: (Int, Int)]

    init(_ control: ControlLoop) {
        var sizes: [Int32: (Int, Int)] = [:]
        for (stack, handles) in control.previewSurfaces {
            let size = control.geometry.stackSize(stack)
            for handle in handles { sizes[handle.rawValue] = (max(16, size.width / 4), max(9, size.height / 4)) }
        }
        for handles in control.pictureSurfaces.values {
            for handle in handles { sizes[handle.rawValue] = (ControlLoop.pictureSize.width, ControlLoop.pictureSize.height) }
        }
        self.sizes = sizes
    }

    func find(_ handle: TextureHandle) -> IOSurfaceRef? {
        lock.lock()
        defer { lock.unlock() }
        if let surface = made[handle.rawValue] { return surface }
        guard let size = sizes[handle.rawValue] else { return nil }
        let surface = IOSurface(properties: [.width: size.0, .height: size.1, .bytesPerElement: 4, .pixelFormat: UInt32(0x42475241)])
        made[handle.rawValue] = surface
        return surface
    }

    /// Fills a texture's surface with one colour: blue, green, red, alpha, as the surface holds them.
    func fill(_ handle: TextureHandle, blue: UInt8, green: UInt8, red: UInt8, alpha: UInt8 = 255) {
        guard let surface = find(handle), IOSurfaceLock(surface, [], nil) == KERN_SUCCESS else { return }
        defer { IOSurfaceUnlock(surface, [], nil) }
        let rowBytes = IOSurfaceGetBytesPerRow(surface), width = IOSurfaceGetWidth(surface), height = IOSurfaceGetHeight(surface)
        let base = IOSurfaceGetBaseAddress(surface)
        for y in 0..<height {
            let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: UInt8.self)
            for x in 0..<width {
                row[x * 4] = blue
                row[x * 4 + 1] = green
                row[x * 4 + 2] = red
                row[x * 4 + 3] = alpha
            }
        }
    }
}
