import Foundation
import XCTest
@testable import OCore

/// Spec 3 §4 Media — "`inMs`, `outMs`, `loop`, `gainOverride`, `syncOffsetMs`
/// taken from the content expression, falling back to the pool item's
/// defaults, then to none." Spec 3 §6 — the context's `library` carries "the
/// media index whose entry defaults a media write falls back to". This closes
/// the Area 1 brief's deviation 1. Spec 1 §7 fixes the lookup order: the
/// machine index first, then the library index.
final class PoolDefaultsTests: XCTestCase {
    typealias F = FixtureLibrary

    private func write(_ content: MediaContent, library: Library, machine: Machine, frame: Int = 100) -> MediaInstance? {
        let context = ProjectionContext(frame: frame, library: library, machine: machine, source: CommandSource(kind: .ui))
        let command = Command.channelWrite(ChannelWrite(channel: .number(1), content: .media(content)))
        let (state, _) = project(ShowState.fresh(library: library, machine: machine), [command], context: context)
        return state.channels[1]?.content.media
    }

    func test_aMediaWriteFallsBackToThePoolItemsDefaults() {
        let (library, machine, _) = F.load()
        // The mountains entry: trim 1500–58000, loop, gain -3, sync 40.
        let instance = write(MediaContent(ref: F.mountains), library: library, machine: machine)
        XCTAssertEqual(instance?.inMs, 1500)
        XCTAssertEqual(instance?.outMs, 58000)
        XCTAssertEqual(instance?.loop, true)
        XCTAssertEqual(instance?.endBehavior, .loop)
        XCTAssertEqual(instance?.gainOverride, -3)
        XCTAssertEqual(instance?.syncOffsetMs, 40)
        XCTAssertEqual(instance?.startedAtFrame, 100)
        XCTAssertEqual(instance?.transport, .playing)
    }

    func test_theExpressionWinsOverTheDefaults() {
        let (library, machine, _) = F.load()
        let instance = write(MediaContent(ref: F.mountains, inMs: 0, outMs: 30000, loop: false, gain: 0, syncOffsetMs: 0), library: library, machine: machine)
        XCTAssertEqual(instance?.inMs, 0)
        XCTAssertEqual(instance?.outMs, 30000)
        XCTAssertEqual(instance?.gainOverride, 0)
        XCTAssertEqual(instance?.syncOffsetMs, 0)
        XCTAssertEqual(instance?.loop, true, "the expression can ask for a loop, not refuse the pool's; `end hold` is the way to stop one")
    }

    func test_thenToNone() {
        let (library, machine, _) = F.load()
        // The dawn entry carries loop only; cross carries nothing; an unindexed id has no entry at all.
        let dawn = write(MediaContent(ref: F.dawn), library: library, machine: machine)
        XCTAssertEqual(dawn?.loop, true)
        XCTAssertNil(dawn?.inMs)
        XCTAssertNil(dawn?.gainOverride)
        let cross = write(MediaContent(ref: F.cross), library: library, machine: machine)
        XCTAssertEqual(cross?.loop, false)
        XCTAssertEqual(cross?.endBehavior, .hold)
        let ghost = write(MediaContent(ref: "sha256:" + String(repeating: "cd", count: 32)), library: library, machine: machine)
        XCTAssertEqual(ghost, MediaInstance(ref: "sha256:" + String(repeating: "cd", count: 32), startedAtFrame: 100))
    }

    /// Spec 1 §7 — "Resolve an id in the machine index first, then the library index."
    func test_theMachineIndexIsConsultedFirst() {
        var (library, machine, _) = F.load()
        var local = library.mediaIndex.entries.first { $0.id == F.mountains }
        local?.defaults = MediaDefaults(trimInMs: 7000, trimOutMs: nil, loop: false, gain: nil, grade: nil, syncOffsetMs: -10, defaultChannel: nil)
        machine.mediaLocal.entries.append(local.map { $0 } ?? MediaEntry(id: F.mountains, path: "x", kind: .video, size: 0))
        let instance = write(MediaContent(ref: F.mountains), library: library, machine: machine)
        XCTAssertEqual(instance?.inMs, 7000)
        XCTAssertNil(instance?.outMs, "the machine entry's nil is none, not a fall-through to the library entry")
        XCTAssertEqual(instance?.loop, false)
        XCTAssertEqual(instance?.syncOffsetMs, -10)

        let resolved = MediaResolver.resolve(F.mountains, library: library, machine: machine)
        XCTAssertEqual(resolved?.tier, .machine)
        // Spec 8 §2 — "an override ... is a path relative to `machine/media/` ... and wins over its entry's `path`."
        XCTAssertEqual(MediaResolver.resolve(F.cross, library: library, machine: machine)?.location, MediaLocation(.machineMedia, "cross-fast.png"),
                       "an override moves the file, not the entry")
        XCTAssertEqual(MediaResolver.resolve(F.cross, library: library, machine: machine)?.tier, .library)
        XCTAssertEqual(MediaResolver.resolve(F.dawn, library: library, machine: machine)?.location, MediaLocation(.mediaRoot, "backgrounds/dawn.mp4"))
        XCTAssertEqual(MediaResolver.resolve(F.announcement, library: library, machine: machine)?.tier, .machine)
        XCTAssertEqual(MediaResolver.resolve(F.announcement, library: library, machine: machine)?.location, MediaLocation(.machineMedia, "announcement.png"))
        XCTAssertNil(MediaResolver.resolve("sha256:" + String(repeating: "cd", count: 32), library: library, machine: machine))
        library.mediaIndex.replaced[F.mountains] = F.dawn
        XCTAssertEqual(MediaResolver.resolve(F.mountains, library: library, machine: machine)?.entry.id, F.dawn,
                       "a replaced id means its replacement before either index is consulted")
        machine.mediaLocal.entries.removeAll()
        XCTAssertEqual(MediaResolver.resolve(F.mountains, library: library, machine: machine)?.entry.id, F.dawn)
        XCTAssertEqual(MediaResolver.resolve(F.mountains, library: library, machine: machine)?.tier, .library)
    }

    /// Spec 8 §11, Resolver — "A write of a replaced id takes the defaults of
    /// the item it resolves to, and a later edit of that item's defaults
    /// reaches it." Spec 3 §4 as Spec 8 corrected it: "falling back to the
    /// defaults of the pool item the ref resolves to".
    func test_aWriteOfAReplacedIdTakesItsReplacementsDefaults() throws {
        var (library, machine, _) = F.load()
        library.mediaIndex.replaced[F.mountains] = F.dawn
        let first = write(MediaContent(ref: F.mountains), library: library, machine: machine)
        XCTAssertEqual(first?.ref, F.mountains, "the cue still names the id it wrote")
        XCTAssertNil(first?.inMs, "dawn's defaults, not mountains' 1500")
        XCTAssertEqual(first?.loop, true)
        let at = try XCTUnwrap(library.mediaIndex.position(of: F.dawn))
        library.mediaIndex.entries[at].defaults.trimInMs = 250
        library.mediaIndex.entries[at].defaults.loop = false
        let later = write(MediaContent(ref: F.mountains), library: library, machine: machine)
        XCTAssertEqual(later?.inMs, 250)
        XCTAssertEqual(later?.loop, false)
        // Through the machine index's own map too (Spec 8 §2, "the machine index's and then the library's").
        machine.mediaLocal.replaced[F.cross] = F.announcement
        XCTAssertEqual(write(MediaContent(ref: F.cross), library: library, machine: machine)?.loop, false)
    }

    /// Spec 3 §4 — Missing media, as Spec 8 §2 and §6 make it: the id the ref
    /// reaches is in the caller's set, or its entry is deleted.
    func test_aWriteIsMissingWhenWhatItResolvesToIsMissingOrDeleted() throws {
        var (library, machine, _) = F.load()
        library.mediaIndex.replaced[F.cross] = F.mountains
        let context = ProjectionContext(frame: 100, library: library, machine: machine, missing: [F.mountains], source: CommandSource(kind: .ui))
        let command = Command.channelWrite(ChannelWrite(channel: .number(1), content: .media(MediaContent(ref: F.cross))))
        let (state, _) = project(ShowState.fresh(library: library, machine: machine), [command], context: context)
        XCTAssertEqual(state.channels[1]?.content.media?.missing, true, "cross resolves to mountains, whose file is absent")
        library.mediaIndex.replaced = [:]
        let at = try XCTUnwrap(library.mediaIndex.position(of: F.dawn))
        library.mediaIndex.entries[at].deletedAt = "2026-11-11T09:00:00Z"
        library.mediaIndex.entries[at].path = ""
        XCTAssertEqual(write(MediaContent(ref: F.dawn), library: library, machine: machine)?.missing, true,
                       "a deleted item shows missing even before the caller's set knows")
    }

    /// Spec 3 §4 Media still holds with the defaults applied: writing the same
    /// ref restarts from its in-point rather than from the previous content.
    func test_aRestartKeepsTheDefaults() {
        let (library, machine, _) = F.load()
        let context = ProjectionContext(frame: 100, library: library, machine: machine, source: CommandSource(kind: .ui))
        let command = Command.channelWrite(ChannelWrite(channel: .number(1), content: .media(MediaContent(ref: F.mountains))))
        let (first, _) = project(ShowState.fresh(library: library, machine: machine), [command], context: context)
        let again = ProjectionContext(frame: 400, library: library, machine: machine, source: CommandSource(kind: .ui))
        let (second, effects) = project(first, [command], context: again)
        XCTAssertEqual(second.channels[1]?.content.media?.inMs, 1500)
        XCTAssertEqual(second.channels[1]?.content.media?.startedAtFrame, 400)
        XCTAssertEqual(effects.compactMap(\.transitionEffect).first?.restart, true)
    }
}
