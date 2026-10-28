import Foundation
import XCTest
@testable import OCore

/// Spec 1 §10 — Cue addressing: "Inserting, deleting and reordering cues
/// renumbers positions and keeps `uuid`s; `list N cue M` and `item N cue M`
/// resolve to the expected cue after each edit." Spec 1 §4: "A cue's number is
/// its 1-based position in its list, recomputed whenever cues are inserted,
/// removed or reordered; it is never stored."
final class CueAddressingTests: XCTestCase {
    typealias F = FixtureLibrary

    private func fresh() -> (Library, Machine) {
        let loaded = F.load()
        return (loaded.library, loaded.machine)
    }

    private func positions(_ list: List) -> [UUID] { list.cues.map(\.uuid) }

    func test_insertRemoveAndMoveRenumberPositionsAndKeepUuids() throws {
        var (library, _) = fresh()
        var list = try XCTUnwrap(library.list(number: 42))
        let original = positions(list)
        XCTAssertEqual(original, F.list42Cues)
        XCTAssertEqual(list.cue(at: 3)?.uuid, F.list42Cues[2])
        XCTAssertEqual(list.position(of: F.list42Cues[2]), 3)
        XCTAssertNil(list.cue(at: 0))
        XCTAssertNil(list.cue(at: 5))

        let bridge = Cue(uuid: F.uuid("b12d", 9), label: "Bridge", section: "Bridge", commands: [Command]())
        list.insert(bridge, at: 2)
        XCTAssertEqual(positions(list), [original[0], bridge.uuid, original[1], original[2], original[3]])
        XCTAssertEqual(list.cue(at: 2)?.uuid, bridge.uuid)
        XCTAssertEqual(list.position(of: original[1]), 3, "the old cue 2 is now cue 3; its uuid is unchanged")

        XCTAssertEqual(list.removeCue(at: 1)?.uuid, original[0])
        XCTAssertEqual(positions(list), [bridge.uuid, original[1], original[2], original[3]])
        XCTAssertEqual(list.cue(at: 1)?.uuid, bridge.uuid)

        list.moveCue(from: 4, to: 1)
        XCTAssertEqual(positions(list), [original[3], bridge.uuid, original[1], original[2]])
        list.moveCue(from: 1, to: 4)
        XCTAssertEqual(positions(list), [bridge.uuid, original[1], original[2], original[3]])

        list.insert(Cue(uuid: F.uuid("e4d0", 1), label: "End", commands: [Command]()), at: 99)
        XCTAssertEqual(list.cues.count, 5, "past the end appends")
        XCTAssertNil(list.removeCue(at: 9))
        list.moveCue(from: 9, to: 1)
        XCTAssertEqual(list.cues.count, 5, "out-of-range moves do nothing")

        library.replace(list: list)
        XCTAssertEqual(library.list(number: 42).map(positions), positions(list))
    }

    /// Spec 1 §4 — "`list 42 cue 3` through list number and position, `item 4
    /// cue 3` through playlist position and cue position", both resolved at the
    /// moment of use.
    func test_listAndItemAddressesResolveAfterEachEdit() throws {
        var (library, machine) = fresh()
        let playlist = try XCTUnwrap(machine.playlists.first)
        // Items: 1 header, 2 linked 42, 3 the local copy of 42, 4 header, 5 linked 7.

        XCTAssertEqual(CueAddressing.cue(list: 42, cue: 3, in: library)?.uuid, F.list42Cues[2])
        XCTAssertEqual(CueAddressing.cue(item: 2, cue: 3, in: playlist, library: library, machine: machine)?.uuid, F.list42Cues[2])
        XCTAssertEqual(CueAddressing.cue(item: 3, cue: 2, in: playlist, library: library, machine: machine)?.uuid, F.list42Cues[1],
                       "the local copy kept the master's cue uuids when it was cut")
        XCTAssertEqual(CueAddressing.cue(item: 5, cue: 1, in: playlist, library: library, machine: machine)?.uuid, F.list7Cues[0])
        XCTAssertNil(CueAddressing.cue(item: 1, cue: 1, in: playlist, library: library, machine: machine), "a header has no cues")
        XCTAssertNil(CueAddressing.cue(item: 4, cue: 1, in: playlist, library: library, machine: machine))
        XCTAssertNil(CueAddressing.cue(item: 6, cue: 1, in: playlist, library: library, machine: machine))
        XCTAssertNil(CueAddressing.cue(item: 2, cue: 5, in: playlist, library: library, machine: machine))
        XCTAssertNil(CueAddressing.cue(item: 2, cue: 0, in: playlist, library: library, machine: machine))
        XCTAssertNil(CueAddressing.cue(list: 43, cue: 1, in: library))
        XCTAssertNil(CueAddressing.cue(list: 42, cue: 9, in: library))

        var list = try XCTUnwrap(library.list(number: 42))
        list.insert(Cue(uuid: F.uuid("b12d", 9), label: "Bridge", commands: [Command]()), at: 1)
        library.replace(list: list)
        XCTAssertEqual(CueAddressing.cue(list: 42, cue: 3, in: library)?.uuid, F.list42Cues[1])
        XCTAssertEqual(CueAddressing.cue(item: 2, cue: 1, in: playlist, library: library, machine: machine)?.label, "Bridge")

        list.removeCue(at: 1)
        list.moveCue(from: 1, to: 4)
        library.replace(list: list)
        XCTAssertEqual(CueAddressing.cue(list: 42, cue: 4, in: library)?.uuid, F.list42Cues[0])
        XCTAssertEqual(CueAddressing.cue(item: 2, cue: 1, in: playlist, library: library, machine: machine)?.uuid, F.list42Cues[1])

        // A local copy edited on this machine resolves through the machine root.
        var local = try XCTUnwrap(machine.localLists.first)
        local.removeCue(at: 1)
        machine.replace(localList: local)
        XCTAssertEqual(CueAddressing.cue(item: 3, cue: 1, in: playlist, library: library, machine: machine)?.uuid, F.list42Cues[1])
        XCTAssertNil(CueAddressing.cue(item: 3, cue: 2, in: playlist, library: library, machine: machine))
    }

    /// The projection resolves the same way (Spec 3 §5): `list.goto` and
    /// `playlist.goto` land on the cue the address names after an edit.
    func test_theProjectionAgreesWithTheResolver() throws {
        var (library, machine) = fresh()
        var list = try XCTUnwrap(library.list(number: 42))
        list.moveCue(from: 4, to: 1)
        library.replace(list: list)
        let context = ProjectionContext(frame: 100, library: library, machine: machine, source: CommandSource(kind: .ui))
        let (state, _) = project(ShowState.fresh(library: library, machine: machine), [.listCue(list: 42, cue: 1)], context: context)
        XCTAssertEqual(state.pointer?.cueUuid, F.list42Cues[3])
        XCTAssertEqual(state.pointer?.cueUuid, CueAddressing.cue(list: 42, cue: 1, in: library)?.uuid)
    }
}
