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
        return try ThumbnailService(library: library, machine: machine, media: EngineFixtures.media, backend: metal,
                                    posters: ImagePosterProvider(backend: metal, media: EngineFixtures.media, log: log),
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
        let machine = try EngineFixtures.fixtureMachine()
        let list = try XCTUnwrap(library.list(number: 42))
        func version(_ library: Library, _ list: List, missing: Set<String> = []) -> String {
            LibraryVersion.hash(library: library, machine: machine, list: list, missing: missing)
        }
        let base = version(library, list)
        XCTAssertEqual(base.count, 16)
        XCTAssertEqual(version(library, list), base, "stable across calls")
        var grades = library
        grades.grades[0].hue += 1
        XCTAssertNotEqual(version(grades, list), base, "a grade edit")
        var styles = library
        styles.textStyles[0].values.size.value += 1
        XCTAssertNotEqual(version(styles, list), base, "a text style edit")
        var presets = library
        presets.presets[0].layouts[.any]?.boxes[0].frame = Frame(x: 0, y: 0, w: 0.5, h: 0.5)
        XCTAssertNotEqual(version(presets, list), base, "a preset edit")
        var transitions = library
        transitions.transitions[1].ms = 600
        XCTAssertNotEqual(version(transitions, list), base, "a transition edit")
        var channels = library
        channels.channels[0].defaultPreset = 3
        XCTAssertNotEqual(version(channels, list), base, "a channel's default preset")
        // Spec 4 §10 as Spec 8 corrected it — "the resolved id, poster path and presence of each media
        // item the list's cues use": list 42 writes dawn, and nothing else from the pool.
        XCTAssertTrue(LibraryVersion.media(of: list, library: library, machine: machine).contains(EngineFixtures.dawn))
        var posters = library
        posters.mediaIndex.entries[try XCTUnwrap(posters.mediaIndex.position(of: EngineFixtures.dawn))].poster = ".posters/other-1500.png"
        XCTAssertNotEqual(version(posters, list), base, "a trim edit's new poster redraws the lists that use the item")
        XCTAssertNotEqual(version(library, list, missing: [EngineFixtures.dawn]), base, "its presence")
        var replaced = library
        replaced.mediaIndex.replaced[EngineFixtures.dawn] = EngineFixtures.cross
        XCTAssertNotEqual(version(replaced, list), base, "a re-export: the id it resolves to")
        var elsewhere = library
        elsewhere.mediaIndex.entries[try XCTUnwrap(elsewhere.mediaIndex.position(of: EngineFixtures.mountains))].poster = ".posters/x-0.png"
        elsewhere.mediaIndex.add(MediaEntry(id: "sha256:" + String(repeating: "ab", count: 32), path: "imports/new.mov", kind: .video, size: 1))
        XCTAssertEqual(version(elsewhere, list, missing: [EngineFixtures.mountains]), base, "an import elsewhere redraws none")
        // Spec 8 §5 — "a change under `.posters/` makes it look again and redraws the tiles and thumbnails that
        // went without it": the version notes whether each poster was found; a poster arriving for another item redraws none.
        let dawnPoster = MediaLocation(.mediaRoot, ".posters/\(String(EngineFixtures.dawn.dropFirst(7)))-0.png")!
        let mountainsPoster = MediaLocation(.mediaRoot, ".posters/\(String(EngineFixtures.mountains.dropFirst(7)))-1500.png")!
        let found = LibraryVersion.hash(library: library, machine: machine, list: list, missing: [], posters: [dawnPoster])
        XCTAssertNotEqual(found, base, "dawn's poster found: list 42's thumbnails redraw")
        XCTAssertEqual(LibraryVersion.hash(library: library, machine: machine, list: list, missing: [], posters: [dawnPoster, mountainsPoster]),
                       found, "a poster arriving for an item list 42 doesn't use redraws none of its thumbnails")
        // Spec 4 §10 as corrected 2026-11-24 — "the list's own fields other than its version number".
        var newer = list
        newer.version += 1
        XCTAssertEqual(version(library, newer), base, "a save that changed nothing draws nothing again")
        // Spec 6 §3 — field boxes fall back to the list's title, author, copyright and ccli, so they are in it.
        for edit in [\List.title, \List.author, \List.copyright, \List.ccli] {
            var changed = list
            changed[keyPath: edit] += " (edited)"
            XCTAssertNotEqual(version(library, changed), base, "a list's \(edit) is drawn by a field box")
        }
        var renoted = list
        renoted.cues[0].note = "A new note"
        XCTAssertNotEqual(version(library, renoted), base, "the cues themselves are in it")
    }

    /// Spec 4 §10 as corrected 2026-11-24 — "an edit to a cue redraws its thumbnail and those of the cues after it,
    /// and the cues before it stay cached"; a stack whose boxes look ahead redraws as many cues before the edit.
    func test_anEditRedrawsTheEditedCueAndThoseAfterItAndNoneBefore() throws {
        let library = try EngineFixtures.library()
        let machine = try EngineFixtures.fixtureMachine()
        let list = try XCTUnwrap(library.list(number: 42))
        let count = list.cues.count
        XCTAssertGreaterThanOrEqual(count, 3)
        func versions(_ list: List, lookAhead: Int = 0) -> [String] {
            LibraryVersion.versions(library: library, machine: machine, list: list, missing: [], lookAhead: lookAhead)
        }
        let before = versions(list)
        XCTAssertEqual(before.count, count)
        XCTAssertEqual(Set(before).count, count, "each cue has its own")
        XCTAssertEqual(before.last, LibraryVersion.hash(library: library, machine: machine, list: list, missing: []),
                       "the list's version is its last cue's")
        var edited = list
        edited.cues[1].label += " (edited)"
        edited.version += 1
        let after = versions(edited)
        XCTAssertEqual(after[0], before[0], "cue 1, before the edit, keeps its thumbnail")
        for k in 1..<count { XCTAssertNotEqual(after[k], before[k], "cue \(k + 1) draws again") }
        // A +1 box shows the next cue: cue 1 shows cue 2's edit, and cue 2's thumbnail shows cue 3.
        XCTAssertNotEqual(versions(edited, lookAhead: 1)[0], versions(list, lookAhead: 1)[0], "cue 1 shows cue 2 in its +1 box")
        // An insert at position 2 moves every cue from there on, and none before.
        var inserted = list
        inserted.cues.insert(list.cues[2], at: 1)
        inserted.cues[1].uuid = UUID()
        let moved = versions(inserted)
        XCTAssertEqual(moved[0], before[0])
        XCTAssertNotEqual(moved[2], before[1], "the old cue 2, now third, follows another cue")
        // The service draws again only what changed.
        let service = try service()
        let stackObject = try XCTUnwrap(service.machine.stack(service.stack))
        let ahead = service.furthestOffset(of: stackObject, library: service.library)
        for k in 1...count { _ = try service.render(cue: k, of: list) }
        var last = list
        last.cues[count - 1].label += " (edited)"
        last.version += 1
        for k in 1...count {
            let outcome = try service.render(cue: k, of: last).outcome
            XCTAssertEqual(outcome, k >= count - ahead ? .rendered : .cached, "cue \(k) of \(count), the stack looking \(ahead) ahead")
        }
        XCTAssertEqual(service.thumbnailURL(forCue: list.cues[0].uuid, in: last), service.thumbnailURL(forCue: list.cues[0].uuid, in: list))
    }

    /// Spec 6 §3 — a field box in a projected state reads the list whose cue
    /// wrote the content: in a thumbnail, the list being drawn.
    func test_aFieldBoxInAThumbnailFallsBackToTheListsMetadata() throws {
        var library = try EngineFixtures.library()
        library.lists.append(FieldBoxTests.slideA)
        var machine = try EngineFixtures.spikeMachine()
        machine.settings.thumbnailStack = 2
        machine.stacks[1].slots[0].preset = 4   // the fixture's Credits
        let service = try service(library: library, machine: machine)
        let list = FieldBoxTests.slideA
        let roots = (library: service.library, machine: service.machine)
        let pass = service.stackPass(states: service.projectedStates(of: list, through: 0, roots: roots), index: 0, roots: roots, list: list)
        XCTAssertEqual(pass.boxes.filter { $0.channel == 2 }.compactMap(\.text), ["Song A", "Author A", "Copyright A", "1001"])
    }

    /// Spec 6 §3 — "In a projected state, such as a thumbnail or the cue
    /// inspector's canvas (Spec 3 §7's cue view), a +K box folds the next K cues
    /// of the same list from the cue being drawn. That fold has no playlist, so
    /// past the list's end the box draws nothing." Spec 6 §11: "In a thumbnail,
    /// a +1 box shows the list's next cue, and nothing past its last."
    func test_aPlusOneBoxInAThumbnailShowsTheListsNextCueAndNothingPastItsLast() throws {
        var machine = try EngineFixtures.spikeMachine()
        machine.settings.thumbnailStack = 2   // Preset 1's "2" layout: a body box and a body box at +1
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
        XCTAssertGreaterThan(lit(try XCTUnwrap(rendered.frame), Frame(x: 0.03, y: 0.7, w: 0.6, h: 0.27)), 30, "the +1 lyric is drawn")
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
                                        media: EngineFixtures.media, metal: metal, thumbnailFolder: folder)
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
