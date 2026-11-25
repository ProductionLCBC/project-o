// OEngine — Spec 11 §3, the test pattern the preset editor's sample can hold: drawn by the engine at the stack's size.

import CoreGraphics
import Foundation
import OCore

/// Spec 11 §3 as corrected 2026-11-24 — "the test pattern, which the engine draws itself at the stack's size, so a
/// box's fit, crop and place read at once: a grid at each tenth of the frame, the centre lines and a circle, the
/// action-safe and title-safe areas (93% and 90%), and a row of colour bars; it ships in the engine's code, never as a
/// file in the repository".
enum TestPattern {
    /// The reference the pattern travels under through the projection, as a media item would: never a media index id
    /// (those are `sha256:…`), so it meets no file and is never missing.
    static let ref = "engine:test-pattern"
    static let content = ContentExpression.media(MediaContent(ref: ref))

    /// The pattern as premultiplied sRGB BGRA, top row first; a size that isn't one is a single black pixel.
    static func bgra(width: Int, height: Int) -> Data {
        guard width > 0, height > 0 else { return Data([0, 0, 0, 255]) }
        var data = Data(count: width * height * 4)
        data.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress, let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(data: base, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return }
            // Drawn top down, as the bitmap's rows run.
            context.translateBy(x: 0, y: CGFloat(height))
            context.scaleBy(x: 1, y: -1)
            draw(in: context, width: CGFloat(width), height: CGFloat(height))
        }
        return data
    }

    private static func draw(in context: CGContext, width w: CGFloat, height h: CGFloat) {
        let line = max(2, (h / 360).rounded())
        // The ground.
        context.setFillColor(red: 0.08, green: 0.08, blue: 0.09, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: w, height: h))
        // A grid at each tenth of the frame.
        context.setFillColor(red: 0.3, green: 0.3, blue: 0.32, alpha: 1)
        for step in 1..<10 {
            let x = (w * CGFloat(step) / 10).rounded()
            let y = (h * CGFloat(step) / 10).rounded()
            context.fill(CGRect(x: x - line / 4, y: 0, width: max(1, line / 2), height: h))
            context.fill(CGRect(x: 0, y: y - line / 4, width: w, height: max(1, line / 2)))
        }
        // The colour bars across the middle third, at 75%: white, yellow, cyan, green, magenta, red, blue.
        let bars: [(CGFloat, CGFloat, CGFloat)] = [(0.75, 0.75, 0.75), (0.75, 0.75, 0), (0, 0.75, 0.75), (0, 0.75, 0), (0.75, 0, 0.75), (0.75, 0, 0), (0, 0, 0.75)]
        let barWidth = w / CGFloat(bars.count)
        for (index, (r, g, b)) in bars.enumerated() {
            context.setFillColor(red: r, green: g, blue: b, alpha: 1)
            context.fill(CGRect(x: (CGFloat(index) * barWidth).rounded(), y: (h / 3).rounded(), width: barWidth.rounded(.up), height: (h / 3).rounded()))
        }
        // A circle round the centre.
        context.setStrokeColor(red: 0.9, green: 0.9, blue: 0.9, alpha: 1)
        context.setLineWidth(line)
        let radius = h * 0.4
        context.strokeEllipse(in: CGRect(x: w / 2 - radius, y: h / 2 - radius, width: 2 * radius, height: 2 * radius))
        // The action-safe area (93%) in amber and the title-safe area (90%) in cyan.
        context.setStrokeColor(red: 0.9, green: 0.75, blue: 0.2, alpha: 1)
        context.stroke(CGRect(x: w * 0.035, y: h * 0.035, width: w * 0.93, height: h * 0.93))
        context.setStrokeColor(red: 0.3, green: 0.8, blue: 0.9, alpha: 1)
        context.stroke(CGRect(x: w * 0.05, y: h * 0.05, width: w * 0.9, height: h * 0.9))
        // The centre lines, on top.
        context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        context.fill(CGRect(x: (w / 2).rounded() - line / 2, y: 0, width: line, height: h))
        context.fill(CGRect(x: 0, y: (h / 2).rounded() - line / 2, width: w, height: line))
    }
}
