import XCTest
import CoreGraphics
import ImageIO
import OCore
@testable import OEngine

/// Spec 11 §3 — the `render` query's pictures, on the GPU: "`render` draws a
/// picture for an editor's canvas", "so that what an editor shows is what the
/// engine draws". Each subject, its size, and what a layout reports. The
/// thumbnail job's own drawing, asked directly (the queue and the API are
/// `RenderQueueTests` and `ApiRenderTests`).
final class RenderPictureTests: XCTestCase {
    typealias E = EngineFixtures
    typealias S = StageFixtures

    var metal: MetalBackend!
    var folder: URL!
    var library: Library!
    var machine: Machine!

    override func setUpWithError() throws {
        metal = try MetalHarness.backend()
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("oengine-render-\(UUID().uuidString)")
        library = try E.library()
        machine = try E.spikeMachine()
        // Preset 20: a body box across the top fifth, a `title` box across the bottom fifth and a body box at +1 in the middle.
        library.presets.append(S.preset(20, "Canvas", boxes: [
            S.body(0, y: 0.0, size: 0.2), S.body(0, y: 0.8, name: "title", size: 0.2), S.body(1, y: 0.4, size: 0.2),
        ]))
    }

    override func tearDown() {
        if let folder { try? FileManager.default.removeItem(at: folder) }
    }

    func service() throws -> ThumbnailService {
        let log = EngineLog(category: "test-render")
        return try ThumbnailService(library: library, machine: machine, media: E.media, backend: metal,
                                    posters: ImagePosterProvider(backend: metal, media: E.media, log: log),
                                    variables: VariableProvider(settings: machine.settings, wallClock: HeadlessEngine.fixedWallClock),
                                    cacheFolder: folder, log: log)
    }

    func draw(_ service: ThumbnailService, _ subject: RenderSubject, width: Int = 480, geometry: MachineGeometry? = nil,
              file: StaticString = #filePath, line: UInt = #line) throws -> RenderDrawn {
        let job = RenderQueue.Job(connection: 1, id: .number(1), fileID: "1", request: RenderRequest(canvas: "test", width: width, subject: subject),
                                  library: library, machine: machine, geometry: geometry ?? MachineGeometry(library: library, machine: machine),
                                  answer: { _ in })
        switch service.draw(job) {
        case .success(let drawn): return drawn
        case .failure(let rejection):
            XCTFail("\(rejection.reason): \(rejection.message)", file: file, line: line)
            throw rejection
        }
    }

    /// A PNG's pixels as 8-bit RGBA rows, top row first.
    struct Picture {
        var width: Int
        var height: Int
        var bytes: [UInt8]

        init(_ png: Data) throws {
            let source = try XCTUnwrap(CGImageSourceCreateWithData(png as CFData, nil))
            let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
            width = image.width
            height = image.height
            bytes = [UInt8](repeating: 0, count: width * height * 4)
            let space = CGColorSpaceCreateDeviceRGB()
            let context = try XCTUnwrap(CGContext(data: &bytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }

        /// How many pixels of the band from `top` to `bottom` (fractions of the height) are lit.
        func lit(_ top: Double, _ bottom: Double) -> Int {
            var count = 0
            for y in Int(top * Double(height))..<Int(bottom * Double(height)) {
                for x in 0..<width {
                    let i = (y * width + x) * 4
                    if Int(bytes[i]) + Int(bytes[i + 1]) + Int(bytes[i + 2]) > 90 { count += 1 }
                }
            }
            return count
        }

        func differs(from other: Picture) -> Int {
            guard width == other.width, height == other.height else { return Int.max }
            var count = 0
            for i in stride(from: 0, to: bytes.count, by: 4) {
                let red = abs(Int(bytes[i]) - Int(other.bytes[i]))
                let green = abs(Int(bytes[i + 1]) - Int(other.bytes[i + 1]))
                let blue = abs(Int(bytes[i + 2]) - Int(other.bytes[i + 2]))
                if red > 2 || green > 2 || blue > 2 { count += 1 }
            }
            return count
        }
    }

    func textSample(_ body: String, next: [String] = [], list: List? = nil, cue: UUID? = nil) -> RenderSample {
        RenderSample(content: .text(fields: ["body": body]), next: next.map { .text(fields: ["body": $0]) }, list: list, cue: cue)
    }

    // MARK: - A cue

    /// "The cue's projected state on that stack, Spec 3 §7's cue view, as the thumbnail job draws it (Spec 4 §10)".
    func test_aCueIsThePictureItsThumbnailIsAtAnyWidthAndOnAnyStack() throws {
        let service = try service()
        let list = try XCTUnwrap(library.list(number: 42))
        let stack1 = try XCTUnwrap(machine.stack(1))
        let drawn = try draw(service, .cue(list: list, index: 1, stack: stack1))
        XCTAssertEqual(drawn.size, PixelSize(width: 480, height: 270))
        let picture = try Picture(drawn.png)
        XCTAssertEqual(picture.width, 480)
        XCTAssertEqual(picture.height, 270)
        // The thumbnail of the same cue, on the thumbnail stack at 480 wide, is the same picture.
        let thumbnail = try Picture(try Data(contentsOf: service.render(cue: 2, of: list).url))
        XCTAssertEqual(picture.differs(from: thumbnail), 0)
        XCTAssertGreaterThan(picture.lit(0, 1), 0, "it draws something")
        XCTAssertFalse(drawn.missing)

        // Twice as wide, in the same shape.
        let wide = try draw(service, .cue(list: list, index: 1, stack: stack1), width: 960)
        XCTAssertEqual(wide.size, PixelSize(width: 960, height: 540))
        XCTAssertEqual(try Picture(wide.png).width, 960)
        // Another stack is another picture.
        let stack2 = try XCTUnwrap(machine.stack(2))
        let other = try Picture(try draw(service, .cue(list: list, index: 1, stack: stack2)).png)
        XCTAssertGreaterThan(other.differs(from: picture), 0)
    }

    /// "The height follows the stack's size ... the size its stack pass and
    /// preview use at that moment ..., so a picture's shape is the screen's."
    /// Spec 11 §3 as corrected 2026-11-24 — "the channels `hide` lists by number draw nothing (§4's hidden rows; a
    /// number no channel has is ignored)".
    func test_aCuesHiddenChannelsDrawNothing() throws {
        let service = try service()
        let list = try XCTUnwrap(library.list(number: 42))
        let stack1 = try XCTUnwrap(machine.stack(1))
        let whole = try Picture(try draw(service, .cue(list: list, index: 1, stack: stack1)).png)
        // Cue 2 holds cue 1's background on channel 1 and writes its lyric on channel 2.
        let noLyric = try Picture(try draw(service, .cue(list: list, index: 1, stack: stack1, hide: [2])).png)
        XCTAssertGreaterThan(noLyric.differs(from: whole), 0, "the lyric is gone")
        let neither = try Picture(try draw(service, .cue(list: list, index: 1, stack: stack1, hide: [1, 2, 99])).png)
        XCTAssertEqual(neither.lit(0, 1), 0, "with both hidden nothing is drawn, and channel 99 is ignored")
        XCTAssertEqual(try Picture(try draw(service, .cue(list: list, index: 1, stack: stack1, hide: [99])).png).differs(from: whole), 0)
    }

    func test_aPicturesShapeIsItsStacksAtThatMoment() throws {
        let service = try service()
        let list = try XCTUnwrap(library.list(number: 42))
        let stack1 = try XCTUnwrap(machine.stack(1))
        // Stack 1 is on a 2560 by 1080 wall just now.
        var wide = machine!
        wide.outputs[0].format.width = 2560
        let geometry = MachineGeometry(library: library, machine: wide)
        XCTAssertEqual(geometry.stackSize(1), PixelSize(width: 2560, height: 1080))
        let drawn = try draw(service, .cue(list: list, index: 0, stack: stack1), width: 640, geometry: geometry)
        XCTAssertEqual(drawn.size, PixelSize(width: 640, height: 270))
    }

    // MARK: - A layout with a sample

    func test_aLayoutDrawsItsSampleInItsBoxes() throws {
        let service = try service()
        let preset = try XCTUnwrap(library.preset(20))
        let stack = try XCTUnwrap(machine.stack(1))
        let text = try Picture(try draw(service, .layout(preset: preset, layout: .any, stack: stack, sample: textSample("Amazing grace"))).png)
        XCTAssertGreaterThan(text.lit(0.0, 0.2), 50, "the body box, across the top")
        XCTAssertEqual(text.lit(0.4, 0.6), 0, "the +1 box has nothing next to draw")
        XCTAssertEqual(text.lit(0.8, 1.0), 0, "the title box: the sample has no title, and no list to fall back to")

        // "`next`, up to three more contents for boxes at +1 to +3".
        let next = try Picture(try draw(service, .layout(preset: preset, layout: .any, stack: stack, sample: textSample("Amazing grace", next: ["how sweet"]))).png)
        XCTAssertGreaterThan(next.lit(0.4, 0.6), 50)

        // "Field boxes draw the text's fields, falling back to that list's metadata (Spec 6 §3)".
        let list = try XCTUnwrap(library.list(number: 42))
        XCTAssertFalse(list.title.isEmpty)
        let from = try Picture(try draw(service, .layout(preset: preset, layout: .any, stack: stack,
                                                         sample: textSample("Amazing grace", list: list, cue: list.cues[0].uuid))).png)
        XCTAssertGreaterThan(from.lit(0.8, 1.0), 50, "the list's title")

        // Nothing on the channel: nothing drawn.
        let empty = try Picture(try draw(service, .layout(preset: preset, layout: .any, stack: stack, sample: RenderSample())).png)
        XCTAssertEqual(empty.lit(0, 1), 0)
    }

    /// "a stack's own layout at that stack's size and number, the `*` layout
    /// at the size and number of the stack `stack` names".
    func test_aStacksOwnLayoutAndTheStarLayoutAreToldApart() throws {
        var preset = S.preset(21, "Two", boxes: [S.body(0, y: 0.0, size: 0.2)])
        preset.layouts[.stack(2)] = Layout(boxes: [S.body(0, y: 0.8, size: 0.2)])
        library.presets.append(preset)
        let service = try service()
        let stack2 = try XCTUnwrap(machine.stack(2))
        // The `*` layout drawn for stack 2 is the `*` layout, though the preset has one of stack 2's own.
        let star = try Picture(try draw(service, .layout(preset: preset, layout: .any, stack: stack2, sample: textSample("Amazing grace"))).png)
        XCTAssertGreaterThan(star.lit(0.0, 0.2), 50)
        XCTAssertEqual(star.lit(0.8, 1.0), 0)
        let own = try Picture(try draw(service, .layout(preset: preset, layout: .stack(2), stack: stack2, sample: textSample("Amazing grace"))).png)
        XCTAssertEqual(own.lit(0.0, 0.2), 0)
        XCTAssertGreaterThan(own.lit(0.8, 1.0), 50)
    }

    /// "`overflow` lists each text box whose sample text overflows (Spec 6
    /// §4) as `{ "box": 2, "offset": 0, "linesCut": 2 }`, and `fallbackFonts`
    /// each box whose font fell back to `fallbackFont`, with the font's name.
    /// Boxes are numbered by their place in the layout, from 0."
    func test_aLayoutReportsOverflowAndFallbackFonts() throws {
        var cut = S.body(0, y: 0.5, size: 0.3)
        cut.fit = .text(TextFit(policy: .maxLines, maxLines: 2, minSize: 12))
        var strange = S.body(0, y: 0.0, size: 0.2)
        strange.textStyle?.values.font = "NoSuchFont-Bold"
        let preset = S.preset(22, "Reports", boxes: [strange, cut])
        library.presets.append(preset)
        let service = try service()
        let stack = try XCTUnwrap(machine.stack(1))
        let lines = "one\ntwo\nthree\nfour\nfive"
        let drawn = try draw(service, .layout(preset: preset, layout: .any, stack: stack, sample: textSample(lines)))
        XCTAssertEqual(drawn.overflow.count, 1, "\(drawn.overflow)")
        let overflow = try XCTUnwrap(drawn.overflow.first?.objectValue)
        XCTAssertEqual(overflow["box"], .number(1))
        XCTAssertEqual(overflow["offset"], .number(0))
        XCTAssertEqual(overflow["linesCut"], .number(3), "five lines, two kept")
        XCTAssertTrue(drawn.fallbackFonts.contains(.object(["box": .number(0), "font": .string("NoSuchFont-Bold")])), "\(drawn.fallbackFonts)")
        XCTAssertFalse(drawn.fallbackFonts.contains { $0.objectValue?["box"] == .number(1) }, "the second box's own font drew it")

        // Text that fits reports nothing.
        let fits = try draw(service, .layout(preset: preset, layout: .any, stack: stack, sample: textSample("one")))
        XCTAssertEqual(fits.overflow, [])
    }

    /// "pixel boxes draw the media as its poster or still"; "a media item
    /// whose file is missing draws nothing for the pixel boxes, and the
    /// answer says `missing: true`."
    func test_aMediaSampleDrawsItsPosterAndAMissingFileSaysSo() throws {
        let preset = S.preset(23, "Pixels", boxes: [S.pixels(0)])
        library.presets.append(preset)
        let service = try service()
        let stack = try XCTUnwrap(machine.stack(1))
        let dawn = try draw(service, .layout(preset: preset, layout: .any, stack: stack, sample: RenderSample(content: .media(MediaContent(ref: E.dawn)))))
        XCTAssertFalse(dawn.missing)
        XCTAssertGreaterThan(try Picture(dawn.png).lit(0, 1), 1000, "the poster fills the box")
        let gone = try draw(service, .layout(preset: preset, layout: .any, stack: stack, sample: RenderSample(content: .media(MediaContent(ref: E.mountains)))))
        XCTAssertTrue(gone.missing, "the fixture's mountains item has no file")
        XCTAssertEqual(try Picture(gone.png).lit(0, 1), 0)
    }

    /// Spec 11 §3 as corrected 2026-11-24 — "the test pattern, which the engine draws itself at the stack's size, so a
    /// box's fit, crop and place read at once"; "it ships in the engine's code".
    func test_thePatternSampleFillsAPixelBoxAtTheStacksSize() throws {
        let preset = S.preset(24, "Pattern", boxes: [S.pixels(0)])
        library.presets.append(preset)
        let service = try service()
        let stack = try XCTUnwrap(machine.stack(1))
        let drawn = try draw(service, .layout(preset: preset, layout: .any, stack: stack, sample: RenderSample(content: TestPattern.content)), width: 640)
        XCTAssertFalse(drawn.missing, "the pattern is never a missing file")
        let picture = try Picture(drawn.png)
        XCTAssertGreaterThan(picture.lit(0, 1), 1000, "the pattern fills the box")
        // The color bars across its middle: a saturated yellow and a saturated blue among them.
        func some(_ test: (Int, Int, Int) -> Bool) -> Bool {
            stride(from: 0, to: picture.bytes.count, by: 4).contains { test(Int(picture.bytes[$0]), Int(picture.bytes[$0 + 1]), Int(picture.bytes[$0 + 2])) }
        }
        XCTAssertTrue(some { r, g, b in r > 150 && g > 150 && b < 60 }, "a yellow bar")
        XCTAssertTrue(some { r, g, b in r < 60 && g < 60 && b > 150 }, "a blue bar")
        // A second picture of the same size draws the same.
        let again = try Picture(try draw(service, .layout(preset: preset, layout: .any, stack: stack, sample: RenderSample(content: TestPattern.content)), width: 640).png)
        XCTAssertEqual(again.differs(from: picture), 0)
    }

    // MARK: - A grade

    /// "The item's poster or still through the grade, or as it is when `grade` is null, over black"; "the item's for a grade".
    func test_aMediaItemAsItIsAndThroughAGrade() throws {
        var dim = try XCTUnwrap(library.grades.first)
        dim.number = 40
        dim.uuid = UUID()
        dim.brightness = -0.6
        library.grades.append(dim)
        let service = try service()
        let entry = try XCTUnwrap(MediaResolver.resolve(E.dawn, library: library, machine: machine)?.entry)
        let plain = try draw(service, .grade(nil, media: E.dawn), width: 320)
        let height = Int((320 * Double(entry.height ?? 9) / Double(entry.width ?? 16)).rounded())
        XCTAssertEqual(plain.size, PixelSize(width: 320, height: height), "the item's shape")
        XCTAssertFalse(plain.missing)
        let asItIs = try Picture(plain.png)
        XCTAssertGreaterThan(asItIs.lit(0, 1), 1000)
        let graded = try Picture(try draw(service, .grade(dim, media: E.dawn), width: 320).png)
        XCTAssertGreaterThan(graded.differs(from: asItIs), 1000, "the grade changes the picture")
        XCTAssertLessThan(graded.lit(0, 1), asItIs.lit(0, 1), "darker")

        let gone = try draw(service, .grade(nil, media: E.mountains), width: 320)
        XCTAssertTrue(gone.missing)
        XCTAssertEqual(try Picture(gone.png).lit(0, 1), 0)
    }

    // MARK: - The thumbnail job after an edit

    /// Spec 11 §6 — the thumbnail stack is edited like any other: the job
    /// reads it at each render, and a thumbnail's version follows it.
    func test_theThumbnailJobFollowsAnEditOfItsStack() throws {
        let service = try service()
        let list = try XCTUnwrap(library.list(number: 42))
        let before = try service.render(cue: 2, of: list)
        XCTAssertEqual(before.outcome, .rendered)
        XCTAssertEqual(try service.render(cue: 2, of: list).outcome, .cached)

        // Channel 2's slot leaves the thumbnail stack.
        var edited = machine!
        edited.stacks[0].slots.removeAll { $0.channel == 2 }
        service.update(library: library, machine: edited)
        let after = try service.render(cue: 2, of: list)
        XCTAssertEqual(after.outcome, .rendered, "the stack changed, so the version did")
        XCTAssertNotEqual(after.version, before.version)

        // The stack's shape changes: thumbnails are 480 wide in the new shape.
        edited.outputs[0].format.width = 2560
        service.update(library: library, machine: edited)
        XCTAssertEqual(service.size, PixelSize(width: 480, height: 203))
        let reshaped = try service.render(cue: 2, of: list)
        XCTAssertEqual(reshaped.size, PixelSize(width: 480, height: 203))
        XCTAssertEqual(reshaped.frame?.height, 203)

        // The thumbnail stack is deleted: nothing to draw on, and no trap.
        edited.stacks.removeAll { $0.number == edited.settings.thumbnailStack }
        service.update(library: library, machine: edited)
        XCTAssertThrowsError(try service.render(cue: 1, of: list)) { error in
            XCTAssertEqual(error as? ThumbnailError, .noSuchStack(1))
        }
    }

    /// Spec 11 §3 — "ahead of thumbnails": work asked for while a list is
    /// being warmed is taken before the rest of that list's thumbnails.
    func test_renderWorkIsTakenAheadOfThumbnails() throws {
        let service = try service()
        let list = try XCTUnwrap(library.list(number: 42))
        XCTAssertGreaterThanOrEqual(list.cues.count, 3)
        let order = Order()
        service.onWritten = { result, _ in order.add("thumbnail") }
        service.warm(list: list)
        service.performAhead { order.add("render") }
        service.waitUntilIdle()
        let seen = order.all
        XCTAssertEqual(seen.filter { $0 == "thumbnail" }.count, list.cues.count)
        let place = try XCTUnwrap(seen.firstIndex(of: "render"))
        XCTAssertLessThan(place, seen.count - 1, "before the last thumbnails of the list: \(seen)")
    }

    final class Order: @unchecked Sendable {
        private let lock = NSLock()
        private var seen: [String] = []

        func add(_ what: String) {
            lock.lock()
            seen.append(what)
            lock.unlock()
        }

        var all: [String] {
            lock.lock()
            defer { lock.unlock() }
            return seen
        }
    }
}
