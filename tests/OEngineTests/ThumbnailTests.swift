import XCTest
import OCore
@testable import OEngine

/// Spec 4 §10 — "Thumbnails. The thumbnail job renders a cue's projected state
/// (Spec 3) on the thumbnail stack at 480 px wide, on the background queue,
/// using the normal stack pass against poster frames and rasterized text.
/// Results are written as PNG into a disk cache keyed by (cue uuid, stack,
/// library version) so thumbnails survive a relaunch; the UI reads them
/// through the same IOSurface path or as files." Spec 4 §8 — "Thumbnails use
/// the same rasterizer at thumbnail scale so a cue's thumbnail shows the real
/// line breaks". Spec 4 §12 — memory pressure shrinks the thumbnail cache.
final class ThumbnailTests: XCTestCase {
    var metal: MetalBackend!
    var folder: URL!

    override func setUpWithError() throws {
        metal = try MetalHarness.backend()
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("oengine-thumbnails-\(UUID().uuidString)")
    }

    override func tearDown() {
        if let folder { try? FileManager.default.removeItem(at: folder) }
    }

    func service(library: Library? = nil, machine: Machine? = nil) throws -> ThumbnailService {
        let library = try library ?? EngineFixtures.library()
        let machine = try machine ?? EngineFixtures.spikeMachine()
        let log = EngineLog(category: "test-thumbnails")
        return try ThumbnailService(library: library, machine: machine, mediaRoot: EngineFixtures.mediaRoot, backend: metal,
                                    posters: ImagePosterProvider(backend: metal, mediaRoot: EngineFixtures.mediaRoot, log: log),
                                    variables: VariableProvider(settings: machine.settings, wallClock: HeadlessEngine.fixedWallClock),
                                    cacheFolder: folder, log: log)
    }

    func list42(_ service: ThumbnailService) throws -> List {
        try XCTUnwrap(service.library.list(number: 42))
    }

    func lit(_ frame: CapturedFrame, _ rect: Frame) -> Int {
        var count = 0
        for y in Int(rect.y * Double(frame.height))..<Int((rect.y + rect.h) * Double(frame.height)) {
            for x in Int(rect.x * Double(frame.width))..<Int((rect.x + rect.w) * Double(frame.width)) where frame[x, y].r + frame[x, y].g + frame[x, y].b > 0.3 {
                count += 1
            }
        }
        return count
    }

    func test_aCueThumbnailIsTheProjectedStateFromTheTopOfTheListAt480Wide() throws {
        let service = try service()
        let list = try list42(service)
        XCTAssertEqual(service.stack, 1, "the machine's thumbnailStack")
        XCTAssertEqual(service.size, PixelSize(width: 480, height: 270))
        let result = try service.render(cue: 2, of: list)
        XCTAssertEqual(result.outcome, .rendered)
        XCTAssertEqual(result.cue, list.cues[1].uuid)
        let frame = try XCTUnwrap(result.frame)
        XCTAssertEqual(frame.width, 480)
        XCTAssertEqual(frame.height, 270)
        // Cue 1 wrote the dawn background to channel 1 and cue 2 only the text, so the thumbnail of cue 2 is
        // tracked state: the poster under the lyric. The lyric sits in preset 1's body box.
        XCTAssertGreaterThan(lit(frame, Frame(x: 0.05, y: 0.1, w: 0.9, h: 0.8)), 100, "cue 2's text is drawn")
        let edge = frame[4, 135]
        XCTAssertGreaterThan(edge.r + edge.g + edge.b, 0.02, "cue 1's poster shows under it, out at the edge where no text is")
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.url.path))
        XCTAssertEqual(result.url.deletingLastPathComponent().lastPathComponent, "1", "one folder per stack")
        XCTAssertTrue(result.url.lastPathComponent.hasPrefix(list.cues[1].uuid.uuidString.lowercased() + "-"), result.url.lastPathComponent)
        XCTAssertEqual(result.url.pathExtension, "png")
        XCTAssertNotNil(result.surfaceID, "the same IOSurface path as the previews")
        let fromDisk = try GoldenImage.frame(fromPNG: Data(contentsOf: result.url))
        XCTAssertEqual(fromDisk.width, 480)
        XCTAssertLessThanOrEqual(GoldenImage.compare(fromDisk, frame).maxCodeDifference, 2, "the PNG is the frame")
        try MetalHarness.assertGolden(MetalHarness.goldens("aux"), "thumbnail-list42-cue2", frame, tolerance: .text)
        let first = try service.render(cue: 1, of: list)
        XCTAssertGreaterThan(GoldenImage.compare(try XCTUnwrap(first.frame), frame).maxCodeDifference, 20, "cue 1 and cue 2 differ")
    }

    func test_thumbnailsAreCachedOnDiskByCueStackAndLibraryVersion() throws {
        let service = try service()
        let list = try list42(service)
        let first = try service.render(cue: 1, of: list)
        XCTAssertEqual(first.outcome, .rendered)
        let again = try service.render(cue: 1, of: list)
        XCTAssertEqual(again.outcome, .cached, "the second request is served from the cache")
        XCTAssertEqual(again.url, first.url)
        XCTAssertEqual(service.statistics.rendered, 1)
        XCTAssertEqual(service.statistics.hits, 1)
        XCTAssertEqual(service.thumbnailURL(forCue: list.cues[0].uuid, in: list), first.url)
        // A relaunch reads the file back: a fresh service over the same folder hits the disk.
        let relaunched = try self.service()
        let afterRelaunch = try relaunched.render(cue: 1, of: list)
        XCTAssertEqual(afterRelaunch.outcome, .cached)
        XCTAssertEqual(relaunched.statistics.diskHits, 1)
        // A preset edit changes the library version: a miss, and the stale file goes.
        var edited = try EngineFixtures.library()
        edited.presets[0].layouts[.any]?.boxes[1].frame = Frame(x: 0.1, y: 0.1, w: 0.8, h: 0.8)
        let changed = try self.service(library: edited)
        let third = try changed.render(cue: 1, of: list)
        XCTAssertEqual(third.outcome, .rendered)
        XCTAssertNotEqual(third.url, first.url)
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.url.path), "the stale version is removed on write")
        XCTAssertNil(service.thumbnailURL(forCue: list.cues[0].uuid, in: list), "the old version's file is gone for the old service too")
    }

    /// Area 5 reading — "library version": Spec 1 has no library-wide
    /// version, so it is a content hash of the documents a render depends on
    /// plus the list's own version.
    func test_libraryVersionFollowsTheRenderingDocumentsAndTheListVersion() throws {
        let library = try EngineFixtures.library()
        let list = try XCTUnwrap(library.list(number: 42))
        let base = LibraryVersion.hash(library: library, list: list)
        XCTAssertEqual(base.count, 16)
        XCTAssertEqual(LibraryVersion.hash(library: library, list: list), base, "stable across calls")
        var grades = library
        grades.grades[0].hue += 1
        XCTAssertNotEqual(LibraryVersion.hash(library: grades, list: list), base, "a grade edit")
        var styles = library
        styles.textStyles[0].values.size.value += 1
        XCTAssertNotEqual(LibraryVersion.hash(library: styles, list: list), base, "a text style edit")
        var presets = library
        presets.presets[0].layouts[.any]?.boxes[0].frame = Frame(x: 0, y: 0, w: 0.5, h: 0.5)
        XCTAssertNotEqual(LibraryVersion.hash(library: presets, list: list), base, "a preset edit")
        var transitions = library
        transitions.transitions[1].ms = 600
        XCTAssertNotEqual(LibraryVersion.hash(library: transitions, list: list), base, "a transition edit")
        var channels = library
        channels.channels[0].defaultPreset = 3
        XCTAssertNotEqual(LibraryVersion.hash(library: channels, list: list), base, "a channel's default preset")
        var posters = library
        posters.mediaIndex.entries[0].poster = "posters/other.png"
        XCTAssertNotEqual(LibraryVersion.hash(library: posters, list: list), base, "a poster path")
        var newer = list
        newer.version += 1
        XCTAssertNotEqual(LibraryVersion.hash(library: library, list: newer), base, "the list's version, incremented on every save")
        var retitled = list
        retitled.title = "Another title"
        XCTAssertEqual(LibraryVersion.hash(library: library, list: retitled), base, "the list's text is not in the hash; its version is")
    }

    /// Spec 6 §3 — "In a projected state, such as a thumbnail or the cue
    /// inspector's canvas (Spec 3 §7's cue view), a +K box folds the next K cues
    /// of the same list from the cue being drawn. That fold has no playlist, so
    /// past the list's end the box draws nothing." Spec 6 §11: "In a thumbnail,
    /// a +1 box shows the list's next cue, and nothing past its last."
    func test_aPlusOneBoxInAThumbnailShowsTheListsNextCueAndNothingPastItsLast() throws {
        var machine = try EngineFixtures.spikeMachine()
        machine.settings.thumbnailStack = 2   // preset 2: a body box, the [Time] box and a body box at +1
        let service = try service(machine: machine)
        let list = try list42(service)
        let roots = (library: service.library, machine: service.machine)
        let states = service.projectedStates(of: list, through: list.cues.count - 1, roots: roots)
        let first = service.stackPass(states: states, index: 0, roots: roots, list: list)
        XCTAssertEqual(first.boxes.first { $0.offset == 1 }?.text, "There is no shadow\nof turning with Thee", "cue 2's text, ahead of cue 1")
        XCTAssertEqual(first.boxes.first { $0.offset == 0 && $0.binding.isText && $0.text?.contains("faithfulness") == true }?.text,
                       "Great is Thy faithfulness,\nO God my Father")
        let last = service.stackPass(states: states, index: list.cues.count - 1, roots: roots, list: list)
        XCTAssertNil(last.boxes.first { $0.offset == 1 }, "past the list's last cue the +1 box draws nothing")
        let rendered = try service.render(cue: 1, of: list)
        XCTAssertEqual(rendered.outcome, .rendered)
        XCTAssertGreaterThan(lit(try XCTUnwrap(rendered.frame), Frame(x: 0.03, y: 0.82, w: 0.6, h: 0.16)), 30, "the +1 lyric is drawn")
    }

    /// Spec 4 §8 — "Thumbnails use the same rasterizer at thumbnail scale so a
    /// cue's thumbnail shows the real line breaks, not an approximation."
    func test_thumbnailTextIsLaidOutAtThumbnailScaleWithTheRealLineBreaks() throws {
        let service = try service()
        let list = try list42(service)
        _ = try service.render(cue: 2, of: list)
        let box = try XCTUnwrap(service.library.resolvedPreset(1).layout(for: 1)?.boxes[1])
        let text = "There is no shadow\nof turning with Thee"
        let small = SlotResolver.textJob(text, box: box, frame: PixelRect(box.frame, in: service.size), outputHeight: service.size.height)
        let layout = try XCTUnwrap(service.textCache.layout(for: small.key), "rasterized at thumbnail scale: 270 lines of output height")
        XCTAssertEqual(layout.lines.map(\.text), ["There is no shadow", "of turning with Thee"])
        let full = TextCache(renderer: CoreTextLineRasterizer(fallbackFont: "HelveticaNeue"), backend: RecordingBackend(), synchronous: true)
        let large = SlotResolver.textJob(text, box: box, frame: PixelRect(box.frame, in: PixelSize(width: 1920, height: 1080)), outputHeight: 1080)
        full.request(large)
        XCTAssertEqual(full.layout(for: large.key)?.lines.map(\.text), layout.lines.map(\.text), "the same breaks as on the output")
        XCTAssertEqual(layout.pointSize, try XCTUnwrap(full.layout(for: large.key)).pointSize, accuracy: 0.5, "the same point size on the 1080 canvas")
    }

    /// Spec 4 §4 — aux work is "skipped first under pressure": the job waits
    /// while the render thread is skipping aux passes.
    func test_theJobWaitsWhileTheRenderThreadSkipsAux() throws {
        let service = try service()
        let list = try list42(service)
        let blocked = SettableCounter()
        blocked.set(1)
        service.auxBlocked = { blocked.value > 0 }
        service.warm(list: list)
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertEqual(service.statistics.rendered, 0, "nothing renders while aux work is being skipped")
        blocked.set(0)
        XCTAssertTrue(waitUntil(20) { service.statistics.rendered == list.cues.count }, "rendered \(service.statistics.rendered)")
        for cue in list.cues { XCTAssertNotNil(service.thumbnailURL(forCue: cue.uuid, in: list)) }
        service.warm(list: list)
        service.waitUntilIdle()
        XCTAssertEqual(service.statistics.rendered, list.cues.count, "warming again renders nothing: every cue is cached")
    }

    /// Spec 4 §12 — "memory pressure ... shrinks the text and thumbnail caches".
    func test_memoryPressureShrinksTheThumbnailCacheAndTheDiskSurvives() throws {
        let service = try service()
        let list = try list42(service)
        for position in 1...list.cues.count { _ = try service.render(cue: position, of: list) }
        let before = service.bytesInUse
        XCTAssertGreaterThan(before, 0)
        XCTAssertEqual(service.name, "thumbnails")
        service.setPressureCeiling(1)
        XCTAssertLessThan(service.bytesInUse, before, "the in-memory thumbnails and the text rasters go")
        service.setPressureCeiling(nil)
        let result = try service.render(cue: 1, of: list)
        XCTAssertEqual(result.outcome, .cached, "the file on disk still serves")
        XCTAssertEqual(service.statistics.diskHits, 1)
    }

    /// Area 5 reading — "when the live list changes, the engine queues that
    /// list's cues for the thumbnail stack, so the soak exercises the job".
    func test_theEngineWarmsTheLiveListOnTheThumbnailStack() throws {
        let engine = try HeadlessEngine(library: EngineFixtures.library(), machine: EngineFixtures.spikeMachine(mainSize: Size(width: 480, height: 270)),
                                        mediaRoot: EngineFixtures.mediaRoot, metal: metal, thumbnailFolder: folder)
        let service = try XCTUnwrap(engine.engine.thumbnails)
        XCTAssertTrue(engine.engine.pressure.caches.contains { $0 === service }, "registered for memory pressure")
        engine.tick()
        XCTAssertEqual(service.statistics.rendered, 0, "no list is live")
        engine.send("list 42 cue 1")
        engine.tick(count: 2)
        let list = try XCTUnwrap(engine.engine.library.list(number: 42))
        XCTAssertTrue(waitUntil(20) { service.statistics.rendered == list.cues.count }, "rendered \(service.statistics.rendered)")
        for cue in list.cues { XCTAssertNotNil(service.thumbnailURL(forCue: cue.uuid, in: list)) }
        engine.send("next")
        engine.tick(count: 2)
        service.waitUntilIdle()
        XCTAssertEqual(service.statistics.rendered, list.cues.count, "the same list stays warm; nothing renders twice")
    }
}
