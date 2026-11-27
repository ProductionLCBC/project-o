import Foundation
import XCTest
import OCore
@testable import OApp

/// Spec 11 §13, "Area 14, the Cues page" — "The grid of a fixture list: the
/// section band's runs; each header's number, trigger, thumbnail and label,
/// and the live cue's dot; a row per channel and one for a channel number no
/// channel has; each cell's state from the fold ...". The lists are the
/// recorded fixture's: 42, Great Is Thy Faithfulness, and 7, Doxology.
final class CueGridTests: XCTestCase {
    private func grid(_ name: String, uuid: String, folds: [Int: Bool] = [:],
                      change: (inout ListDocument, inout Catalog) -> Void = { _, _ in }) throws -> CueGridModel {
        var document = try Recorded.list(name)
        var catalog = try Recorded.catalog()
        change(&document, &catalog)
        var inputs = try Recorded.inputs(.list(uuid))
        inputs.catalog = catalog
        inputs.lists[uuid] = document
        let section = try XCTUnwrap(GridModel.make(inputs).sections.first)
        return CueGridModel.make(document: document, section: section, catalog: catalog, media: try Recorded.media(), folds: folds)
    }

    private func grid42(folds: [Int: Bool] = [:], change: (inout ListDocument, inout Catalog) -> Void = { _, _ in }) throws -> CueGridModel {
        try grid("list-42", uuid: Recorded.list42, folds: folds, change: change)
    }

    private func grid7() throws -> CueGridModel { try grid("list-7", uuid: Recorded.list7) }

    // MARK: - The band, the headers and the rows (Spec 11 §4, "The cue grid")

    func test_theSectionBandRunsOverCuesThatShareASection() throws {
        let grid = try grid42()
        // "over each run of cues that share a section, the section's name under a rule of its color".
        XCTAssertEqual(grid.runs.map(\.name), ["Verse 1", "Chorus"])
        XCTAssertEqual(grid.runs.map(\.first), [0, 3])
        XCTAssertEqual(grid.runs.map(\.count), [3, 1])
        XCTAssertEqual(grid.runs.map(\.hue), [SectionHue.index(for: "Verse 1"), SectionHue.index(for: "Chorus")])
        // A cue with no section breaks the band and has none of its own.
        let broken = try grid42 { document, _ in document.list.cues[1].section = nil }
        XCTAssertEqual(broken.runs.map(\.name), ["Verse 1", "Verse 1", "Chorus"])
        XCTAssertEqual(broken.runs.map(\.first), [0, 2, 3])
    }

    func test_aHeaderIsTheCueAsTheShowGridHasIt() throws {
        let grid = try grid42()
        XCTAssertEqual(grid.title, "Great Is Thy Faithfulness")
        XCTAssertEqual(grid.cueCount, 4)
        XCTAssertEqual(grid.version, 17)
        XCTAssertEqual(grid.listNumber, 42)
        XCTAssertEqual(grid.headers.map(\.number), [1, 2, 3, 4])
        XCTAssertEqual(grid.headers.map(\.label), ["Verse 1", "Verse 1", "Verse 1", "Chorus"])
        XCTAssertEqual(grid.headers[2].trigger, .time(ms: 8000))
        XCTAssertEqual(grid.headers[2].advanceAfterMs, 12000)
    }

    func test_aRowPerChannelThenOneForEachChannelNumberNoChannelHas() throws {
        XCTAssertEqual(try grid42().rows.map(\.channel), [1, 2, 3])
        XCTAssertEqual(try grid42().rows.map(\.label), ["Background", "Foreground", "Clock"])
        XCTAssertEqual(try grid42().rows.map(\.exists), [true, true, true])
        // "then one for each channel number the list's cues write that no channel has (E7)".
        let grid = try grid42 { document, _ in
            document.list.cues[1].commands.append(GuardedCommand(.channelWrite(ChannelWrite(channel: .number(7), content: .text(fields: ["body": "Stray"])))))
            document.list.cues[2].commands.append(GuardedCommand(.channelGain(channel: .number(9), db: -3)))
        }
        XCTAssertEqual(grid.rows.map(\.channel), [1, 2, 3, 7, 9])
        XCTAssertEqual(grid.rows.map(\.exists), [true, true, true, false, false])
        XCTAssertEqual(grid.cells[3][1].state, .write)
        XCTAssertEqual(grid.cells[3][2].content, .text("Stray"), "a channel the machine lacks still holds what the list wrote, as its cues say")
    }

    func test_rowsStartOpenForTheChannelsTheListWritesContentToAndFoldedForTheRest() throws {
        // "At first the rows of the channels the list writes content to are open and the rest are folded".
        XCTAssertEqual(try grid42().rows.map(\.isFolded), [false, false, true])
        // "a row the operator folds or opens stays so for every list, by channel number".
        XCTAssertEqual(try grid42(folds: [1: true, 3: false]).rows.map(\.isFolded), [true, false, false])
    }

    // MARK: - A cell (Spec 11 §4, "A cell")

    func test_aWriteIsATileOfWhatItWrites() throws {
        let grid = try grid42()
        let media = try Recorded.media()
        let dawn = try XCTUnwrap(media.first { $0.id.hasPrefix("sha256:55c8") })
        // Channel 1, cue 1: media, with its transition rider's duration as the badge.
        let first = grid.cells[0][0]
        XCTAssertEqual(first.state, .write)
        XCTAssertEqual(first.content, .media(id: dawn.id, tile: MediaPool.tile(dawn)))
        XCTAssertEqual(first.badgeMs, 1000)
        XCTAssertFalse(first.hasMark, "its only rider is the transition, which the badge gives")
        XCTAssertTrue(first.hasTail, "the next cue holds the channel")
        // Channel 2 writes text on every cue: no bar leaves a tile for another tile.
        XCTAssertEqual(grid.cells[1].map(\.state), [.write, .write, .write, .write])
        XCTAssertEqual(grid.cells[1].map(\.hasTail), [false, false, false, false])
        // Cue 4's text carries an audio transition and a grade: a mark, and no badge.
        let chorus = grid.cells[1][3]
        XCTAssertNil(chorus.badgeMs)
        XCTAssertTrue(chorus.hasMark)
        XCTAssertEqual(chorus.attributes.map(\.kind), [.audioTransition, .grade])
        XCTAssertEqual(chorus.attributes.map(\.isRider), [true, true])
    }

    func test_aTextTileFollowsTheChannelsTextThumbnail() throws {
        let body = try grid42 { _, catalog in
            guard let index = catalog.channels.firstIndex(where: { $0.number == 2 }) else { return }
            catalog.channels[index].textThumbnail = .body
        }
        XCTAssertEqual(body.cells[1][0].content, .text("Great is Thy faithfulness,\nO God my Father"))
        let line = try grid42 { _, catalog in
            guard let index = catalog.channels.firstIndex(where: { $0.number == 2 }) else { return }
            catalog.channels[index].textThumbnail = .firstLine
        }
        XCTAssertEqual(line.cells[1][0].content, .text("Great is Thy faithfulness,"))
    }

    func test_aHoldIsABarOnlyWhileTheChannelHoldsSomething() throws {
        let grid = try grid42()
        // Channel 1 holds cue 1's media through cues 2 to 4.
        XCTAssertEqual(grid.cells[0].map(\.state), [.write, .hold, .hold, .hold])
        XCTAssertEqual(grid.cells[0][1].content, grid.cells[0][0].content)
        XCTAssertEqual(grid.cells[0].map(\.heldFrom), [nil, 1, 1, 1])
        // Channel 3 is never written: "nothing while it holds nothing".
        XCTAssertEqual(grid.cells[2].map(\.state), [.hold, .hold, .hold, .hold])
        XCTAssertEqual(grid.cells[2].map(\.content), [nil, nil, nil, nil])
        XCTAssertEqual(grid.cells[2].map(\.isHolding), [false, false, false, false])
        XCTAssertEqual(grid.cells[0].map(\.isHolding), [false, true, true, true])
    }

    func test_attributeWritesOnAHeldCellAreAMark() throws {
        // List 42's last cue sets channel 1's gain while it holds; list 7's second sets its transition.
        let held = try grid42().cells[0][3]
        XCTAssertEqual(held.state, .hold)
        XCTAssertTrue(held.hasMark)
        XCTAssertEqual(held.attributes, [CueAttribute(kind: .gain, db: -6, scope: .track, isRider: false)])
        let other = try grid7().cells[0][1]
        XCTAssertEqual(other.attributes, [CueAttribute(kind: .transition, ref: 2, ms: 750, scope: .track, isRider: false)])
        XCTAssertTrue(other.hasMark)
        XCTAssertFalse(try grid42().cells[0][1].hasMark)
    }

    // MARK: - Tracking (Spec 11 §4, "Tracking", G-45)

    private typealias Mark = TrackingLane.Mark

    /// "each open row gets a thin lane under its cells for each of those attributes that some cue of the list sets on
    /// that channel"; "the cue that sets the attribute shows a block with its value"; "a line carries it through each
    /// cue after that holds it"; "A `once` value's block is outlined and its line dashed, since it holds only until the
    /// channel's next content write".
    func test_aLaneForEachAttributeACueSetsWithItsBlockAndItsLine() throws {
        let grid = try grid42()
        // Channel 1: cue 1's write dissolves once (transition 2 for 1 s), and nothing writes the channel after it, so
        // the once value holds to the end; cue 4 sets its gain from there on.
        XCTAssertEqual(grid.rows[0].lanes.map(\.kind), [.transition, .gain])
        XCTAssertEqual(grid.rows[0].lanes[0].marks, [
            .set(CueAttribute(kind: .transition, ref: 2, ms: 1000, scope: .once, isRider: true), isRedundant: false),
            .carried(from: 0, isOnce: true), .carried(from: 0, isOnce: true), .carried(from: 0, isOnce: true),
        ])
        XCTAssertEqual(grid.rows[0].lanes[1].marks, [.none, .none, .none,
                                                     .set(CueAttribute(kind: .gain, db: -6, scope: .track, isRider: false), isRedundant: false)])
        // Channel 2: cue 4's text writes an audio transition once and grade 1 from here on.
        XCTAssertEqual(grid.rows[1].lanes.map(\.kind), [.audioTransition, .grade])
        XCTAssertEqual(grid.rows[1].lanes[0].marks.last, .set(CueAttribute(kind: .audioTransition, ref: 2, scope: .once, isRider: true), isRedundant: false))
        XCTAssertEqual(grid.rows[1].lanes[1].marks.last, .set(CueAttribute(kind: .grade, ref: 1, ms: 2000, scope: .track, isRider: true), isRedundant: false))
        XCTAssertEqual(grid.rows[1].lanes[1].marks.dropLast(), [.none, .none, .none], "the channel's default shows as nothing")
        // Channel 3: nothing sets anything, so no lane.
        XCTAssertEqual(grid.rows[2].lanes, [])
    }

    /// "stops where another cue sets it, a reset returns it to the channel's default, or a write's `once` value falls
    /// back"; "a redundant write's block is amber".
    func test_aLineStopsAtTheNextSettingAResetOrTheFallBackAndARedundantWriteIsMarked() throws {
        let grid = try grid42 { document, _ in
            // Cue 2 sets channel 2's grade 1 from here on; cue 3 sets it again, to the same; cue 4's rider sets grade 1 too.
            document.list.cues[1].commands.append(GuardedCommand(.channelGrade(channel: .number(2), ref: 1, ms: nil)))
            document.list.cues[2].commands.append(GuardedCommand(.channelGrade(channel: .number(2), ref: 1, ms: nil)))
            // Cue 2 writes channel 1 again: cue 1's once transition falls back there.
            document.list.cues[1].commands.append(GuardedCommand(.channelWrite(ChannelWrite(channel: .number(1), content: .text(fields: ["body": "Again"])))))
            // Cue 3 resets channel 1: its gain, set by nothing yet, stays default; cue 4 sets it.
            document.list.cues[2].commands.append(GuardedCommand(.channelReset(channel: .number(1))))
        }
        let transition = try XCTUnwrap(grid.rows[0].lanes.first { $0.kind == .transition })
        XCTAssertEqual(transition.marks.map(\.isSet), [true, false, false, false])
        XCTAssertEqual(transition.marks[1], .none, "the once value fell back at cue 2's write")
        let grade = try XCTUnwrap(grid.rows[1].lanes.first { $0.kind == .grade })
        XCTAssertEqual(grade.marks[0], .none)
        XCTAssertEqual(grade.marks[1], .set(CueAttribute(kind: .grade, ref: 1, scope: .track, isRider: false), isRedundant: false))
        XCTAssertEqual(grade.marks[2], .set(CueAttribute(kind: .grade, ref: 1, scope: .track, isRider: false), isRedundant: true), "the value it already had")
        // A reset ends a line: cue 2 sets channel 1's gain, cue 3 resets the channel.
        let reset = try grid42 { document, _ in
            document.list.cues[1].commands.append(GuardedCommand(.channelGain(channel: .number(1), db: -3)))
            document.list.cues[2].commands.append(GuardedCommand(.channelReset(channel: .number(1))))
        }
        let gain = try XCTUnwrap(reset.rows[0].lanes.first { $0.kind == .gain })
        XCTAssertEqual(gain.marks[0], .none)
        XCTAssertTrue(gain.marks[1].isSet)
        XCTAssertEqual(gain.marks[2], .none, "a reset returns it to the channel's default")
        XCTAssertTrue(gain.marks[3].isSet)
        // "A click on a block or a line selects the cue that set it".
        XCTAssertEqual(TrackingLane.Mark.carried(from: 1, isOnce: false).settingCue(at: 3), 1)
        XCTAssertEqual(gain.marks[1].settingCue(at: 1), 1)
        XCTAssertNil(gain.marks[0].settingCue(at: 0))
    }

    /// "a folded row gets none": the geometry gives an open row its lanes while the switch is on, and a folded one none.
    func test_theSwitchGivesOpenRowsTheirLanesInTheGeometry() throws {
        let grid = try grid42()
        let off = CueGridGeometry(column: 140, cues: 4, folded: grid.rows.map(\.isFolded))
        let on = CueGridGeometry(column: 140, cues: 4, folded: grid.rows.map(\.isFolded), lanes: grid.rows.map { $0.isFolded ? 0 : $0.lanes.count })
        XCTAssertEqual(on.rowHeight(0), off.rowHeight(0) + 2 * CueGridGeometry.laneHeight)
        XCTAssertEqual(on.rowHeight(2), off.rowHeight(2), "a folded row has no lane")
        // Under a row's cells, a point is over a lane; in the channel column, over the row.
        let laneY = on.y(row: 0) + off.rowHeight(0) + CueGridGeometry.laneHeight * 1.5
        XCTAssertEqual(on.hit(x: CueGridGeometry.channelColumn + 140 * 2 + 10, y: laneY), .lane(cue: 2, row: 0, lane: 1))
        XCTAssertEqual(on.hit(x: 60, y: laneY), .channel(row: 0))
        XCTAssertEqual(on.hit(x: CueGridGeometry.channelColumn + 10, y: on.y(row: 0) + 10), .cell(cue: 0, row: 0))
    }

    func test_aClearEndsTheBarAtACap() throws {
        let grid = try grid7()
        // Doxology's last cue clears channel 2, which held text, and writes a slide on channel 1.
        XCTAssertEqual(grid.cells[1].map(\.state), [.write, .write, .clear])
        XCTAssertTrue(grid.cells[1][2].endsBar)
        XCTAssertNil(grid.cells[1][2].content)
        XCTAssertEqual(grid.cells[0][2].content, .slide(ref: "slide:51de0000-0000-4000-8000-000000000001"))
        // A clear of a channel that held nothing has no bar to end; a write of `empty` reads as a clear.
        let empty = try grid42 { document, _ in
            document.list.cues[0].commands.append(GuardedCommand(.channelClear(channel: .number(3))))
            document.list.cues[1].commands[0] = GuardedCommand(.channelWrite(ChannelWrite(channel: .number(2), content: .empty)))
        }
        XCTAssertEqual(empty.cells[2][0].state, .clear)
        XCTAssertFalse(empty.cells[2][0].endsBar)
        XCTAssertEqual(empty.cells[1][1].state, .clear)
        XCTAssertTrue(empty.cells[1][1].endsBar)
    }

    func test_aMissingItemsTileCarriesItsOverlay() throws {
        let media = try Recorded.media()
        let missing = try XCTUnwrap(media.first { $0.isMissing })
        let grid = try grid42 { document, _ in
            document.list.cues[1].commands.append(GuardedCommand(.channelWrite(ChannelWrite(channel: .number(1), content: .media(MediaContent(ref: missing.id))))))
            document.list.cues[2].commands.append(GuardedCommand(.channelWrite(ChannelWrite(channel: .number(1), content: .media(MediaContent(ref: "sha256:gone"))))))
        }
        guard case .media(_, let tile?) = grid.cells[0][1].content else { return XCTFail("a media tile") }
        XCTAssertEqual(tile.overlay, .missing)
        // An id the pool doesn't know has no tile at all, and reads as missing.
        XCTAssertEqual(grid.cells[0][2].content, .media(id: "sha256:gone", tile: nil))
    }

    func test_anEmptyListAndAListNotYetHeld() throws {
        let empty = try grid42 { document, _ in document.list.cues = [] }
        XCTAssertEqual(empty.cueCount, 0)
        XCTAssertTrue(empty.headers.isEmpty)
        XCTAssertEqual(empty.rows.map(\.channel), [1, 2, 3], "the rows stand, with nothing in them")
        XCTAssertEqual(empty.rows.map(\.isFolded), [true, true, true])
        XCTAssertEqual(empty.cells.map(\.count), [0, 0, 0])
        let none = CueGridModel.make(document: nil, section: nil, catalog: try Recorded.catalog(), media: [], folds: [:])
        XCTAssertNil(none.listNumber)
        XCTAssertTrue(none.headers.isEmpty)
    }

    // MARK: - Zoom and geometry (Spec 11 §4, "Zoom")

    func test_theZoomRunsFrom72To480PointsAndDropsTextBelow96() {
        // "from 72 to 480 points, 140 at first" (Adam, 2026-11-24).
        XCTAssertEqual(CueGridZoom.standard, 140)
        XCTAssertEqual(CueGridZoom.clamped(10), 72)
        XCTAssertEqual(CueGridZoom.clamped(500), 480)
        XCTAssertEqual(CueGridZoom.clamped(118.6), 119)
        // "Below 96 points a header drops its trigger and its label, and a tile its name, its text and its badge".
        XCTAssertTrue(CueGridZoom.showsText(column: 96))
        XCTAssertFalse(CueGridZoom.showsText(column: 95))
        // "The rows' tiles keep their shape": a 16 by 9 tile inside the cell's padding.
        XCTAssertEqual(CueGridZoom.rowHeight(column: 140), (140 - 12) * 9 / 16 + 12)
        // A pinch scales the column, within the range.
        XCTAssertEqual(CueGridZoom.pinched(140, by: 0.5), 210)
        XCTAssertEqual(CueGridZoom.pinched(140, by: -0.9), 72)
        XCTAssertEqual(CueGridZoom.pinched(200, by: 1), 400)
        XCTAssertEqual(CueGridZoom.pinched(300, by: 1), 480)
    }

    /// Spec 11 §4 as corrected 2026-11-24 — "At a row's left are its number, its label, a control that folds it ...,
    /// and an eye that hides the channel from the Preview monitor's picture alone".
    func test_aRowsEyeSitsAtTheChannelColumnsRightEnd() {
        let g = CueGridGeometry(column: 140, cues: 4, folded: [false, false])
        let middle = g.y(row: 1) + g.rowHeight(1) / 2
        XCTAssertEqual(g.hit(x: 4, y: middle), .fold(row: 1))
        XCTAssertEqual(g.hit(x: CueGridGeometry.channelColumn - 4, y: middle), .eye(row: 1))
        XCTAssertEqual(g.hit(x: CueGridGeometry.channelColumn - CueGridGeometry.eyeWidth - 2, y: middle), .channel(row: 1))
    }

    func test_theGridsGeometryFindsWhatIsUnderAPoint() {
        let g = CueGridGeometry(column: 140, cues: 4, folded: [false, false, true])
        let row = CueGridZoom.rowHeight(column: 140)
        XCTAssertEqual(g.width, CueGridGeometry.channelColumn + 4 * 140 + CueGridGeometry.addColumn)
        XCTAssertEqual(g.height, CueGridGeometry.band + g.header + 2 * row + CueGridGeometry.foldedRow)
        // With nothing scrolled.
        XCTAssertEqual(g.hit(x: 10, y: 10), .corner)
        XCTAssertEqual(g.hit(x: CueGridGeometry.channelColumn + 150, y: 10), .band(cue: 1))
        XCTAssertEqual(g.hit(x: CueGridGeometry.channelColumn + 150, y: CueGridGeometry.band + 5), .header(cue: 1))
        XCTAssertEqual(g.hit(x: CueGridGeometry.channelColumn + 4 * 140 + 5, y: CueGridGeometry.band + 5), .add)
        XCTAssertEqual(g.hit(x: 60, y: CueGridGeometry.band + g.header + 5), .channel(row: 0))
        XCTAssertEqual(g.hit(x: 8, y: CueGridGeometry.band + g.header + row / 2), .fold(row: 0))
        XCTAssertEqual(g.hit(x: CueGridGeometry.channelColumn + 5, y: CueGridGeometry.band + g.header + row + 5), .cell(cue: 0, row: 1))
        XCTAssertEqual(g.hit(x: CueGridGeometry.channelColumn + 3 * 140 + 5, y: CueGridGeometry.band + g.header + 2 * row + 5), .cell(cue: 3, row: 2))
        XCTAssertEqual(g.hit(x: CueGridGeometry.channelColumn + 5, y: g.height + 5), .nothing)
        // "This column, the band and the headers stay in place while the grid scrolls": a point
        // over them is theirs wherever the grid has scrolled to, and the cells move under them.
        XCTAssertEqual(g.hit(x: 60, y: CueGridGeometry.band + g.header + 5, scrollX: 300, scrollY: 0), .channel(row: 0))
        XCTAssertEqual(g.hit(x: CueGridGeometry.channelColumn + 5, y: CueGridGeometry.band + 5, scrollX: 300, scrollY: 40), .header(cue: 2))
        XCTAssertEqual(g.hit(x: CueGridGeometry.channelColumn + 5, y: CueGridGeometry.band + g.header + 5, scrollX: 300, scrollY: row), .cell(cue: 2, row: 1))
        // Where a cue's column and a row sit, for drawing and for keeping the selection in view.
        XCTAssertEqual(g.x(cue: 2), CueGridGeometry.channelColumn + 280)
        XCTAssertEqual(g.y(row: 2), CueGridGeometry.band + g.header + 2 * row)
        XCTAssertEqual(g.rowHeight(2), CueGridGeometry.foldedRow)
        XCTAssertEqual(g.scrollX(toShow: 3, from: 0, viewWidth: CueGridGeometry.channelColumn + 300), 4 * 140 - 300)
        XCTAssertEqual(g.scrollX(toShow: 0, from: 200, viewWidth: CueGridGeometry.channelColumn + 300), 0)
        XCTAssertEqual(g.scrollX(toShow: 1, from: 100, viewWidth: CueGridGeometry.channelColumn + 300), 100, "already in view")
    }
}
