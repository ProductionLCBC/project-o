// OEngine — Spec 10 §3, the `preview` topic.

import CoreGraphics
import Foundation
import ImageIO
import IOSurface
import OCore

/// Spec 10 §3 — "LAN clients also have `preview`, which the app doesn't use:
/// a JPEG of each stack the client names when it subscribes (`"stacks": [1,
/// 2]`), 480 pixels wide, twice a second (Spec 4 §10)."
///
/// Control side, once a build. Twice a second, and only while someone is
/// subscribed, each named stack's preview is copied out of the oldest of its
/// three surfaces and handed to a worker that scales it, encodes it and sends
/// the event. The oldest surface is the one the next preview will be drawn
/// into, so its last frame was finished two previews ago and nothing draws
/// into it until the next build's plan reaches the render thread: the copy,
/// made here before that build starts, never reads a frame half drawn. The
/// frame is some 70 ms old, which a picture sent twice a second can be.
///
/// Area 19 readings: the event is `{"stack", "width", "height", "jpeg"}` with
/// the JPEG as base64, since the API's messages are JSON text; any connection
/// may subscribe, the local socket included; and nothing is sent for a stack
/// while the GPU is over budget and its previews are being skipped.
final class ApiPreview {
    static let width = 480
    static let intervalNanoseconds: Int64 = 500_000_000
    static let quality = 0.7

    private var next: Int64 = .min
    /// How many stack pictures have been copied for encoding, for the tests.
    private(set) var copies = 0

    func publish(engine: Engine, snapshot: ApiSnapshot, now: MonotonicTime) {
        guard next == .min || now.nanoseconds >= next else { return }
        let wanted = engine.api.previewSubscribers()
        guard !wanted.isEmpty else { return }
        next = now.nanoseconds + Self.intervalNanoseconds
        guard !engine.render.isSkippingAux else { return }
        let control = engine.control
        let seq = snapshot.seq
        for stack in wanted.keys.sorted() {
            guard let connections = wanted[stack], let surfaces = control.previewSurfaces[stack], surfaces.count == FrameRing.depth,
                  let planned = control.previewSlots[stack], (control.previewsPlanned[stack] ?? 0) > FrameRing.depth,
                  let surface = engine.surface(of: surfaces[(planned + 1) % FrameRing.depth]),
                  let pixels = PreviewJPEG.copy(surface) else { continue }
            copies += 1
            engine.api.workers.async {
                guard let jpeg = PreviewJPEG.encode(pixels, width: Self.width, quality: Self.quality) else { return }
                let event = ApiEvents.event("preview", ["stack": .number(Double(stack)), "width": .number(Double(jpeg.width)),
                                                        "height": .number(Double(jpeg.height)), "jpeg": .string(jpeg.data.base64EncodedString())],
                                            seq: seq)
                let line = Data(JSONCanonical.line(event).utf8)
                for connection in connections { connection.send(line: line) }
            }
        }
    }
}

/// A stack's preview as a JPEG.
enum PreviewJPEG {
    /// A surface's pixels, copied: BGRA, premultiplied, sRGB.
    struct Pixels: Sendable {
        var data: Data
        var width: Int
        var height: Int
        var rowBytes: Int
    }

    static func copy(_ surface: IOSurfaceRef) -> Pixels? {
        guard IOSurfaceLock(surface, .readOnly, nil) == KERN_SUCCESS else { return nil }
        defer { IOSurfaceUnlock(surface, .readOnly, nil) }
        let width = IOSurfaceGetWidth(surface), height = IOSurfaceGetHeight(surface), rowBytes = IOSurfaceGetBytesPerRow(surface)
        guard width > 0, height > 0, rowBytes >= width * 4 else { return nil }
        return Pixels(data: Data(bytes: IOSurfaceGetBaseAddress(surface), count: rowBytes * height), width: width, height: height, rowBytes: rowBytes)
    }

    /// The pixels over black, scaled to `width` pixels wide with their shape kept, as a JPEG.
    static func encode(_ pixels: Pixels, width: Int, quality: Double) -> (data: Data, width: Int, height: Int)? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB), let provider = CGDataProvider(data: pixels.data as CFData) else { return nil }
        let layout = CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue)
        guard let image = CGImage(width: pixels.width, height: pixels.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: pixels.rowBytes,
                                  space: space, bitmapInfo: layout, provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { return nil }
        let height = max(1, Int((Double(width) * Double(pixels.height) / Double(pixels.width)).rounded()))
        let opaque = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: opaque) else { return nil }
        // A stack is drawn over nothing; a JPEG has no alpha, and what an output shows where a stack is clear is black.
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let scaled = context.makeImage() else { return nil }
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, scaled, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return (out as Data, width, height)
    }
}
