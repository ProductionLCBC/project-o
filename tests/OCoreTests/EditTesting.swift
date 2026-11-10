import Foundation
import XCTest
@testable import OCore

/// The fixture library as the edit path's tests use it: on a `writable`
/// machine (Spec 5 §7 — "the pilot machine runs `writable`"), with edits run
/// from their text form and the uuids an edit picks counted out in order, so
/// a test can name them.
struct Edits {
    typealias F = FixtureLibrary

    var library: Library
    var machine: Machine
    var context: EditContext
    var picked = 0
    var log: [EditOutcome] = []

    init(writable: Bool = true, today: String = "2026-11-08") {
        let (library, machine, _) = F.load()
        self.library = library
        self.machine = machine
        if writable { self.machine.settings.libraryMode = .writable }
        context = EditContext(today: today)
    }

    /// The nth uuid an edit picks.
    static func pick(_ n: Int) -> UUID { F.uuid("e0e0", n) }

    func edit(_ text: String, file: StaticString = #filePath, line: UInt = #line) -> EditCommand? {
        switch CommandText.parse(text, options: ParseOptions(library: library, machine: machine)) {
        case .success(let entry):
            guard case .edit(let edit) = entry.command else {
                XCTFail("\(text) is not an edit", file: file, line: line)
                return nil
            }
            return edit
        case .failure(let rejection):
            XCTFail("\(text) → \(rejection.reason): \(rejection.message)", file: file, line: line)
            return nil
        }
    }

    mutating func run(_ edit: EditCommand, restoring: Bool = false) -> Result<[EditOutcome], Rejection> {
        var context = self.context
        context.restoring = restoring
        let result = LibraryEditor.apply(edit, library: library, machine: machine, context: context, makeUUID: {
            picked += 1
            return Edits.pick(picked)
        })
        if case .success(let outcomes) = result, let last = outcomes.last {
            library = last.library
            machine = last.machine
            log += outcomes
        }
        return result
    }

    /// Runs an edit that must apply; its outcomes.
    @discardableResult
    mutating func apply(_ text: String, file: StaticString = #filePath, line: UInt = #line) -> [EditOutcome] {
        guard let edit = edit(text, file: file, line: line) else { return [] }
        switch run(edit) {
        case .success(let outcomes): return outcomes
        case .failure(let rejection):
            XCTFail("\(text) → \(rejection.reason): \(rejection.message)", file: file, line: line)
            return []
        }
    }

    /// Runs an edit that must be refused, checking nothing changed; its rejection.
    mutating func refuse(_ text: String, file: StaticString = #filePath, line: UInt = #line) -> Rejection? {
        guard let edit = edit(text, file: file, line: line) else { return nil }
        return refuse(edit, file: file, line: line)
    }

    mutating func refuse(_ edit: EditCommand, file: StaticString = #filePath, line: UInt = #line) -> Rejection? {
        let (library, machine) = (self.library, self.machine)
        switch run(edit) {
        case .success:
            XCTFail("\(CommandText.print(.edit(edit)) ?? "the edit") was accepted", file: file, line: line)
            return nil
        case .failure(let rejection):
            XCTAssertEqual(self.library, library, "nothing changes", file: file, line: line)
            XCTAssertEqual(self.machine, machine, "nothing changes", file: file, line: line)
            return rejection
        }
    }

    /// Puts back what the outcomes changed: their inverses, last first, as
    /// an undo will (Spec 5 §8), with references put back as they were.
    mutating func undo(_ outcomes: [EditOutcome], file: StaticString = #filePath, line: UInt = #line) {
        for outcome in outcomes.reversed() {
            guard let inverse = outcome.inverse else { continue }
            if case .failure(let rejection) = run(inverse, restoring: true) {
                XCTFail("the inverse \(CommandText.print(.edit(inverse)) ?? "") → \(rejection.reason): \(rejection.message)", file: file, line: line)
            }
        }
    }

    /// Both roots' documents as the writer would put them on disk, and the folders.
    var documents: (library: [String: Data], machine: [String: Data], folders: [String]) {
        (Writer.snapshot(of: library).files, Writer.snapshot(of: machine).files, library.folders)
    }

    var sunday: Playlist { machine.playlist(uuid: F.playlistUuid) ?? Playlist(uuid: UUID(), title: "", items: []) }
    var night: Playlist { machine.playlist(uuid: F.sundayNightUuid) ?? Playlist(uuid: UUID(), title: "", items: []) }
    var archived: Playlist { machine.playlist(uuid: F.archivedSundayUuid) ?? Playlist(uuid: UUID(), title: "", items: []) }

    func list(_ number: Int) -> List? { library.list(number: number) }
}

extension XCTestCase {
    /// Spec 5 §11 — "apply an edit and then its inverse. Every document is
    /// byte-identical to before".
    func assertRoundTrip(_ texts: [String], writable: Bool = true, file: StaticString = #filePath, line: UInt = #line) {
        var edits = Edits(writable: writable)
        let before = edits.documents
        var outcomes: [EditOutcome] = []
        for text in texts { outcomes += edits.apply(text, file: file, line: line) }
        XCTAssertTrue(outcomes.contains { !$0.isNoop }, "\(texts) changed something", file: file, line: line)
        edits.undo(outcomes, file: file, line: line)
        let after = edits.documents
        XCTAssertEqual(after.folders, before.folders, "\(texts): folders", file: file, line: line)
        XCTAssertEqual(Set(after.library.keys), Set(before.library.keys), "\(texts): library files", file: file, line: line)
        XCTAssertEqual(Set(after.machine.keys), Set(before.machine.keys), "\(texts): machine files", file: file, line: line)
        for (path, data) in before.library where after.library[path] != data {
            XCTFail("\(texts): \(path) " + ByteDiff.describe(expected: data, actual: after.library[path] ?? Data()), file: file, line: line)
        }
        for (path, data) in before.machine where after.machine[path] != data {
            XCTFail("\(texts): \(path) " + ByteDiff.describe(expected: data, actual: after.machine[path] ?? Data()), file: file, line: line)
        }
    }
}
