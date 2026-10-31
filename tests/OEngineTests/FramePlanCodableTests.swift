import XCTest
import OCore
@testable import OEngine

/// Spec 4 §4 — "A frame plan is a plain value"; Spec 4 §15 — "The headless
/// harness reproduces a tick from a saved frame plan". A plan survives a trip
/// through JSON with sorted keys unchanged.
final class FramePlanCodableTests: XCTestCase {
    static func samplePlan() -> FramePlan {
        let incoming = SourceBinding(source: .instance(InstanceHandle(rawValue: 3), mediaTimeMs: 1234.5),
                                     layout: .p010, matrix: .bt709, range: .limited, size: PixelSize(width: 3840, height: 2160))
        let outgoing = SourceBinding(source: .texture(TextureHandle(rawValue: 11)),
                                     layout: .linearRGBA16, matrix: .bt709, range: .full, size: PixelSize(width: 1920, height: 1080))
        let channel = ChannelPass(
            channel: 1, target: TextureHandle(rawValue: 1), size: PixelSize(width: 4096, height: 2160),
            incoming: incoming, outgoing: outgoing,
            transition: TransitionState(type: .fadeThroughColor, progress: 0.25, color: ColorValue(r: 0, g: 0, b: 0, a: 1)),
            grade: GradeParameters(hue: 8, saturation: 1.15, brightness: -0.05, contrast: 1.1, blur: 0,
                                   tint: ColorValue(r: 1, g: 0.85, b: 0.6, a: 0.12), opacity: 1),
            generateMips: true)
        let lines = [TextLine(texture: TextureHandle(rawValue: 40), frame: PixelRect(x: 96, y: 108, width: 1700, height: 90)),
                     TextLine(texture: TextureHandle(rawValue: 41), frame: PixelRect(x: 96, y: 210, width: 1500, height: 90))]
        let boxes = [
            ResolvedBox(channel: 1, frame: PixelRect(x: 0, y: 0, width: 1920, height: 1080),
                        content: .pixels(PixelQuad(texture: TextureHandle(rawValue: 1), frame: PixelRect(x: 0, y: 60, width: 1920, height: 960),
                                                   uv: UVRect(u: 0, v: 0.05, width: 1, height: 0.9))),
                        opacity: 1, transition: nil, grade: nil),
            ResolvedBox(channel: 2, frame: PixelRect(x: 96, y: 108, width: 1728, height: 864),
                        content: .lines(lines), opacity: 0.5,
                        transition: BoxTransitionState(type: .dissolve, progress: 0.5, outgoing: .lines([])),
                        grade: GradeParameters.identity),
        ]
        let stack = StackPass(stack: 1, target: TextureHandle(rawValue: 20), size: PixelSize(width: 1920, height: 1080),
                              base: .transparent, gammaBlend: true, boxes: boxes)
        let sink = SinkPass(output: 1, stack: TextureHandle(rawValue: 20), second: .black, mix: 0.5,
                            encode: .display10Bit, destination: 2)
        let text = TextJob(key: TextKey(hash: 0xDEADBEEF), text: "Great is Thy faithfulness",
                           style: BoxTextStyle(), box: PixelSize(width: 1728, height: 864),
                           fit: TextFit(policy: .maxLines, maxLines: 8, minSize: 20), outputHeight: 1080)
        return FramePlan(frame: 7, channelPasses: [channel], textJobs: [text], stackPasses: [stack], sinkPasses: [sink],
                         auxPasses: [AuxPass(kind: .preview, stack: 1, target: TextureHandle(rawValue: 50))])
    }

    func test_planRoundTripsThroughJSON() throws {
        let plan = Self.samplePlan()
        let data = try SavedPlan.encode(plan)
        let decoded = try SavedPlan.decode(data)
        XCTAssertEqual(decoded, plan)
    }

    /// CLAUDE.md, code conventions — JSON on disk: sorted keys, two-space indent, LF.
    func test_savedPlanIsCanonicalJSON() throws {
        let data = try SavedPlan.encode(Self.samplePlan())
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("{\n  \"auxPasses\""), String(text.prefix(40)))
        XCTAssertFalse(text.contains("\r"))
        let keys = text.split(separator: "\n").filter { $0.hasPrefix("  \"") }.map { $0.trimmingCharacters(in: .whitespaces) }
        XCTAssertEqual(keys, keys.sorted())
    }

    func test_decodingRejectsAnUnknownSource() {
        let json = Data("""
        {"frame": 1, "channelPasses": [{"channel": 1, "target": 1, "size": {"width": 1, "height": 1},
          "incoming": {"source": {"nonsense": {}}, "layout": "nv12", "matrix": "bt709", "range": "limited", "size": {"width": 1, "height": 1}},
          "grade": {"hue": 0, "saturation": 1, "brightness": 0, "contrast": 1, "blur": 0, "tint": {"r": 0, "g": 0, "b": 0, "a": 0}, "opacity": 1},
          "generateMips": false}], "textJobs": [], "stackPasses": [], "sinkPasses": [], "auxPasses": []}
        """.utf8)
        XCTAssertThrowsError(try SavedPlan.decode(json))
    }
}
