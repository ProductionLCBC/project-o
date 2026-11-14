import Foundation
import XCTest
@testable import OCore

/// Spec 8 §5 — posters and pool tiles, pure: their names, which ones a
/// machine makes, and how a made poster joins its entry. Spec 8 §11,
/// Posters: "The frame at the default in-point ... at
/// `.posters/<hex>-<in>.png` beside its media. A `defaults.trimInMs` edit
/// gives a new poster under a new name ... Images are their own poster, audio
/// has none, and only a writable machine writes library posters." Tiles: "480
/// px wide, from the poster or the image; none for audio; a new tile with a
/// new poster." (Extracting the frame, fitting it and drawing tiles are the
/// engine's tests.)
final class MediaPostersTests: XCTestCase {
    let a = MediaWalkTests.id("a"), b = MediaWalkTests.id("b"), c = MediaWalkTests.id("c"), d = MediaWalkTests.id("d")
    var hexA: String { String(a.dropFirst(7)) }

    func video(_ id: String, _ path: String, trimIn: Int? = nil, poster: String? = nil, alpha: Bool = false) -> MediaEntry {
        var e = MediaWalkTests.entry(id, path, defaults: MediaDefaults(trimInMs: trimIn))
        e.poster = poster
        e.hasAlpha = alpha
        return e
    }

    func entry(_ id: String, _ path: String, kind: MediaKind) -> MediaEntry {
        MediaEntry(id: id, path: path, kind: kind, size: 100, addedAt: "2026-11-01T09:00:00Z")
    }

    func test_namesFollowTheIdAndTheInPoint() {
        XCTAssertEqual(MediaPosters.posterPath(of: video(a, "x.mp4")), ".posters/\(hexA)-0.png")
        XCTAssertEqual(MediaPosters.posterPath(of: video(a, "x.mp4", trimIn: 1500)), ".posters/\(hexA)-1500.png")
        XCTAssertNil(MediaPosters.posterPath(of: entry(a, "x.png", kind: .image)), "an image is its own poster")
        XCTAssertNil(MediaPosters.posterPath(of: entry(a, "x.wav", kind: .audio)), "audio has none")
        XCTAssertEqual(MediaPosters.tileName(of: video(a, "x.mp4", trimIn: 1500)), "\(hexA)-1500.png")
        XCTAssertEqual(MediaPosters.tileName(of: entry(a, "x.png", kind: .image)), "\(hexA)-0.png", "`<in>` is 0 for an image")
        XCTAssertNil(MediaPosters.tileName(of: entry(a, "x.wav", kind: .audio)), "Audio has no tile")
        XCTAssertNil(MediaPosters.tileName(of: entry("slide:51de0000-0000-4000-8000-000000000001", "w.oslide", kind: .slide)))
        XCTAssertTrue(MediaPosters.belongs("\(hexA)-0.png", to: a))
        XCTAssertTrue(MediaPosters.belongs("\(hexA)-1500.png", to: a))
        XCTAssertFalse(MediaPosters.belongs("\(hexA)-1500.png", to: b))
        XCTAssertFalse(MediaPosters.belongs("\(hexA)-x.png", to: a))
        XCTAssertFalse(MediaPosters.belongs("\(hexA)-1500.png.tmp", to: a))
    }

    /// "Who. The machine that writes the entry's index, so library posters
    /// are written only on a writable machine"; "by the walk when one is
    /// missing", only for a file that is there.
    func test_aMachineMakesThePostersOfTheIndexesItWrites() {
        let library = MediaIndex(entries: [video(a, "a.mp4"), video(b, "b.mp4", poster: ".posters/\(String(b.dropFirst(7)))-0.png")])
        let machine = MediaLocalIndex(entries: [video(c, "c.mp4")])
        let present: (MediaLocation) -> MediaFileState = { l in
            [MediaLocation(.mediaRoot, "a.mp4")!: .holds(self.a), MediaLocation(.mediaRoot, "b.mp4")!: .holds(self.b),
             MediaLocation(.machineMedia, "c.mp4")!: .holds(self.c)][l] ?? .absent
        }
        let bPoster = MediaLocation(.mediaRoot, ".posters/\(String(b.dropFirst(7)))-0.png")!
        let writable = MediaPosters.posters(library: library, machine: machine, libraryWritable: true, state: present,
                                            posterExists: { $0 == bPoster })
        XCTAssertEqual(writable.map(\.id), [a, c], "b's poster is there and named; a and c have none yet")
        XCTAssertEqual(writable.first?.poster, MediaLocation(.mediaRoot, ".posters/\(hexA)-0.png"), "beside its media, in the media root")
        XCTAssertEqual(writable.last?.poster.folder, .machineMedia, "and in machine/media/ for local-only media")
        XCTAssertTrue(writable.allSatisfy(\.extract))

        let readOnly = MediaPosters.posters(library: library, machine: machine, libraryWritable: false, state: present,
                                            posterExists: { $0 == bPoster })
        XCTAssertEqual(readOnly.map(\.id), [c], "a readOnlyMasters machine never writes a library poster")

        let gone = MediaPosters.posters(library: library, machine: machine, libraryWritable: true, state: { _ in .absent },
                                        posterExists: { _ in false })
        XCTAssertEqual(gone, [], "a missing file has no frame to give")
        let unhashed = MediaPosters.posters(library: library, machine: machine, libraryWritable: true, state: { _ in .unhashed },
                                            posterExists: { _ in false })
        XCTAssertEqual(unhashed.count, 3, "a file not yet hashed counts present")
    }

    /// A poster file that is there but the entry doesn't name yet is named,
    /// not extracted again; a deleted item has no file; an override's target
    /// is the frame's source; a poster that failed this run waits.
    func test_namingOverridesDeletedAndFailures() {
        var deleted = video(d, "")
        deleted.deletedAt = "2026-11-11T09:00:00Z"
        let library = MediaIndex(entries: [video(a, "a.mp4", trimIn: 1500, alpha: true), deleted])
        let machine = MediaLocalIndex(entries: [video(c, "c.mp4")], overrides: [c: "fast/c.mp4"])
        let aPoster = MediaLocation(.mediaRoot, ".posters/\(hexA)-1500.png")!
        let state: (MediaLocation) -> MediaFileState = { l in
            [MediaLocation(.mediaRoot, "a.mp4")!: .holds(self.a), MediaLocation(.machineMedia, "fast/c.mp4")!: .holds(self.c)][l] ?? .absent
        }
        let tasks = MediaPosters.posters(library: library, machine: machine, libraryWritable: true, state: state,
                                         posterExists: { $0 == aPoster })
        XCTAssertEqual(tasks.count, 2)
        XCTAssertEqual(tasks[0], MediaPosters.PosterTask(id: a, tier: .library, source: MediaLocation(.mediaRoot, "a.mp4")!,
                                                         poster: aPoster, inMs: 1500, alpha: true, extract: false))
        XCTAssertEqual(tasks[1].source, MediaLocation(.machineMedia, "fast/c.mp4"), "an override's file gives the frame")
        let cPoster = tasks[1].poster
        let failed = MediaPosters.posters(library: library, machine: machine, libraryWritable: true, state: state,
                                          posterExists: { $0 == aPoster }, failed: [cPoster])
        XCTAssertEqual(failed.map(\.id), [a], "a poster that failed this run isn't tried again until its file changes")
    }

    /// Tiles: on every machine, both indexes; from the poster for video, once
    /// it's there, and from the image while it's present; none for audio; a
    /// tile already there isn't drawn again; a new in-point is a new tile.
    func test_tilesComeFromThePosterOrTheImage() {
        let library = MediaIndex(entries: [video(a, "a.mp4", trimIn: 1500), entry(b, "b.png", kind: .image), entry(c, "c.wav", kind: .audio)])
        let machine = MediaLocalIndex(entries: [video(d, "d.mp4")])
        let aPoster = MediaLocation(.mediaRoot, ".posters/\(hexA)-1500.png")!
        let state: (MediaLocation) -> MediaFileState = { l in l.path == "b.png" ? .holds(self.b) : .absent }
        let tiles = MediaPosters.tiles(library: library, machine: machine, state: state, posterExists: { $0 == aPoster },
                                       tileExists: { _ in false })
        XCTAssertEqual(tiles, [MediaPosters.TileTask(id: a, name: "\(hexA)-1500.png", source: aPoster),
                               MediaPosters.TileTask(id: b, name: "\(String(b.dropFirst(7)))-0.png", source: MediaLocation(.mediaRoot, "b.png")!)],
                       "d's poster isn't there yet; the audio gets none")
        let again = MediaPosters.tiles(library: library, machine: machine, state: state, posterExists: { $0 == aPoster },
                                       tileExists: { $0 == "\(self.hexA)-1500.png" })
        XCTAssertEqual(again.map(\.id), [b], "a tile already drawn isn't drawn again")
    }

    /// A made poster joins its entry only while the entry is at that
    /// in-point, isn't deleted, and sits in an index this machine writes.
    func test_aMadePosterJoinsItsEntry() {
        var library = MediaIndex(entries: [video(a, "a.mp4"), video(b, "b.mp4", trimIn: 500)])
        var machine = MediaLocalIndex(entries: [video(c, "c.mp4")])
        let changes = MediaPosters.apply([MediaPosters.Made(id: a, tier: .library, inMs: 0, path: ".posters/\(hexA)-0.png"),
                                          MediaPosters.Made(id: b, tier: .library, inMs: 0, path: ".posters/b-0.png"),
                                          MediaPosters.Made(id: c, tier: .machine, inMs: 0, path: nil)],
                                         library: &library, machine: &machine, libraryWritable: true)
        XCTAssertEqual(changes, [.poster(id: a, tier: .library, path: ".posters/\(hexA)-0.png")],
                       "b's in-point changed meanwhile; c's poster was already null")
        XCTAssertEqual(library.entry(a)?.poster, ".posters/\(hexA)-0.png")
        XCTAssertNil(library.entry(b)?.poster)
        XCTAssertEqual(changes.first?.libraryChanges, [LibraryChange(object: "media", address: ["media": .string(a)], paths: ["poster"])])

        var readOnly = MediaIndex(entries: [video(a, "a.mp4")])
        XCTAssertEqual(MediaPosters.apply([MediaPosters.Made(id: a, tier: .library, inMs: 0, path: ".posters/x-0.png")],
                                          library: &readOnly, machine: &machine, libraryWritable: false), [])
        // Extraction failed: the poster is null, and reported.
        machine.entries[0].poster = ".posters/old-0.png"
        let failed = MediaPosters.apply([MediaPosters.Made(id: c, tier: .machine, inMs: 0, path: nil)],
                                        library: &library, machine: &machine, libraryWritable: true)
        XCTAssertEqual(failed, [.poster(id: c, tier: .machine, path: nil)])
        XCTAssertNil(machine.entry(c)?.poster)
        XCTAssertTrue(failed[0].logText.contains("couldn't be extracted"))
    }
}
