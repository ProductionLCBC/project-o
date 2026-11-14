import Foundation
import XCTest
@testable import OCore

/// Spec 8 §6 — `media replace` and `media unreplace`, pure, against the
/// fixture. Spec 8 §11, Replace: "References are rewritten across lists,
/// presets, macros, key bindings and scheduler entries, local copies follow
/// the mapping, and a re-import of the old file resolves to the new one. A
/// new item with empty defaults takes the old ones, one with its own keeps
/// them. Reversing a replacement removes the mapping and makes no loop.
/// `media unreplace` puts the references, the mappings and the defaults back
/// exactly (Area 12 for the undo)." And Adam's answer of 2026-11-11 (5):
/// only write refs, in cues, macros, key bindings, scheduler entries and
/// cues' held `cueChannel` edits; held media commands and `edit media` keep
/// naming their entry.
final class MediaReplaceTests: XCTestCase {
    typealias F = FixtureLibrary

    /// A new video, as an import leaves it: empty defaults, its poster at 0.
    static let fresh = "sha256:" + String(repeating: "f7e5", count: 16)
    var freshHex: String { String(Self.fresh.dropFirst(7)) }

    /// The fixture on a writable machine, with a write of mountains in a key
    /// binding and a scheduler entry, and in list 7's second cue a held
    /// `cueChannel` edit that writes mountains, an `edit media` of it and a
    /// `media delete` of it; and the new video in the library index.
    func roots(writable: Bool = true) -> (library: Library, machine: Machine) {
        var (library, machine, _) = F.load()
        machine.settings.libraryMode = writable ? .writable : .readOnlyMasters
        let write = Command.channelWrite(ChannelWrite(channel: .number(1), content: .media(MediaContent(ref: F.mountains))))
        machine.keys.append(KeyBinding(device: "keyboard", key: "m", command: write))
        machine.keys.append(KeyBinding(device: "scheduler", when: Schedule(days: ["sunday"], time: "10:30"), command: write))
        let list = library.lists.firstIndex { $0.number == 7 }!
        let held: [Command] = [
            .edit(EditCommand(.cue(list: 7, cue: F.list7Cues[2]),
                              .cueChannel(CueChannelEdit(channel: 2, state: .write(.media(MediaContent(ref: F.mountains)), .none))))),
            .edit(EditCommand(.media(F.mountains), .set(path: "defaults.gain", value: .number(-6)))),
            .media(.delete(id: F.mountains, files: nil)),
        ]
        library.lists[list].cues[1].commands += held.map { GuardedCommand($0) }
        library.mediaIndex.add(MediaEntry(id: Self.fresh, path: "imports/Mountains v2.mp4", kind: .video, size: 10,
                                          poster: ".posters/\(freshHex)-0.png", addedAt: "2026-11-14T09:00:00Z"))
        return (library, machine)
    }

    func replace(_ old: String, _ new: String, _ roots: (library: Library, machine: Machine),
                 file: StaticString = #filePath, line: UInt = #line) -> MediaEdits.Outcome? {
        switch MediaEdits.replace(old: old, new: new, library: roots.library, machine: roots.machine) {
        case .success(let outcome): return outcome
        case .failure(let rejection):
            XCTFail("\(rejection.reason): \(rejection.message)", file: file, line: line)
            return nil
        }
    }

    func reason(_ result: Result<MediaEdits.Outcome, Rejection>) -> RejectionReason? {
        if case .failure(let r) = result { return r.reason }
        return nil
    }

    func list7(_ library: Library) -> List { library.list(number: 7)! }

    // MARK: - What it rewrites

    func test_replaceRewritesEveryWriteThisMachineWrites() throws {
        let roots = self.roots()
        let outcome = try XCTUnwrap(replace(F.mountains, Self.fresh, roots))
        let library = outcome.library
        let machine = outcome.machine
        XCTAssertEqual(list7(library).cues[0].commands[0].command.mediaRef, Self.fresh, "a cue's write")
        XCTAssertEqual(machine.keys[machine.keys.count - 2].command.mediaRef, Self.fresh, "a key binding")
        XCTAssertEqual(machine.keys.last?.command.mediaRef, Self.fresh, "a scheduler entry")
        let heldEdits = list7(library).cues[1].commands.suffix(3).map(\.command)
        guard case .edit(let cueChannel) = heldEdits[0], case .cueChannel(let c) = cueChannel.action,
              case .write(let content, _) = c.state else { return XCTFail("the held cueChannel edit") }
        XCTAssertEqual(content.mediaRef, Self.fresh, "a cue's held cueChannel edit")
        XCTAssertEqual(heldEdits[1], .edit(EditCommand(.media(F.mountains), .set(path: "defaults.gain", value: .number(-6)))),
                       "an edit media keeps naming its entry")
        XCTAssertEqual(heldEdits[2], .media(.delete(id: F.mountains, files: nil)), "a held media delete still deletes OLD")
        // "records `OLD → NEW` in the `replaced` map of the index that holds OLD"; "OLD's entry and file stay".
        XCTAssertEqual(library.mediaIndex.replaced[F.mountains], Self.fresh)
        XCTAssertEqual(library.mediaIndex.entry(F.mountains)?.path, "backgrounds/mountains.mp4")
        // "local copies follow the mapping": the copy of list 42 isn't edited, and still resolves through it.
        XCTAssertEqual(machine.localLists, roots.machine.localLists)
        XCTAssertEqual(MediaResolver.resolve(F.mountains, library: library, machine: machine)?.id, Self.fresh)
        // "a re-import of the old file resolves to the new one".
        XCTAssertEqual(MediaImport.decide(id: F.mountains, libraryWritable: true, library: library.mediaIndex, machine: machine.mediaLocal,
                                          presence: { _ in .ok }), .known(Self.fresh))
        // The logged command records what it did; its inverse is unreplace with the same record.
        guard case .replace(_, _, let record?) = outcome.logged else { return XCTFail("the logged replace records what it did") }
        XCTAssertEqual(record.refs.count, 4)
        XCTAssertEqual(record.refs.first, MediaReference(object: "cue", address: ["list": .number(7), "listUuid": .string(F.listUuid(7).uuidString.lowercased()),
                                                                             "cue": .string(F.list7Cues[0].uuidString.lowercased())],
                                                         path: "commands.0.content.ref"))
        XCTAssertEqual(record.refs.last?.address, ["at": .number(Double(machine.keys.count - 1))], "a scheduler entry by its position")
        XCTAssertEqual(record.mapping, MediaMappingChanges(added: [MediaMapping(index: .library, from: F.mountains, to: Self.fresh)]))
        XCTAssertEqual(outcome.inverse, .unreplace(old: F.mountains, new: Self.fresh, record: record))
        XCTAssertTrue(outcome.changes.contains(LibraryChange(object: "media", address: ["media": .string(F.mountains)], paths: ["replaced"])))
        XCTAssertTrue(outcome.changes.contains(LibraryChange(object: "keys", address: [:])))
    }

    /// Choice M-3 — "NEW takes OLD's defaults when it has none of its own,
    /// every default empty as an import leaves them; an item someone has set
    /// up keeps its own", with the poster name its new in-point gives (§5).
    func test_aNewItemWithEmptyDefaultsTakesTheOldOnesAndOneWithItsOwnKeepsThem() throws {
        let roots = self.roots()
        let mountains = try XCTUnwrap(roots.library.mediaIndex.entry(F.mountains))
        let taken = try XCTUnwrap(replace(F.mountains, Self.fresh, roots))
        XCTAssertEqual(taken.library.mediaIndex.entry(Self.fresh)?.defaults, mountains.defaults)
        XCTAssertEqual(taken.library.mediaIndex.entry(Self.fresh)?.poster, ".posters/\(freshHex)-1500.png", "the poster at its new in-point")
        guard case .replace(_, _, let record?) = taken.logged else { return XCTFail() }
        XCTAssertEqual(record.defaults, MediaDefaults(), "NEW's defaults before the command")
        let dawn = try XCTUnwrap(roots.library.mediaIndex.entry(F.dawn))
        let kept = try XCTUnwrap(replace(F.mountains, F.dawn, roots))
        XCTAssertEqual(kept.library.mediaIndex.entry(F.dawn)?.defaults, dawn.defaults, "set up by someone: its own")
        guard case .replace(_, _, let none?) = kept.logged else { return XCTFail() }
        XCTAssertNil(none.defaults)
    }

    /// "If NEW's chain already leads back to OLD, as when a replacement is
    /// reversed, the mapping that leaves NEW is removed first, so no loop forms."
    func test_reversingAReplacementRemovesTheMappingAndMakesNoLoop() throws {
        let first = try XCTUnwrap(replace(F.mountains, Self.fresh, roots()))
        let back = try XCTUnwrap(replace(Self.fresh, F.mountains, (first.library, first.machine)))
        XCTAssertNil(back.library.mediaIndex.replaced[F.mountains], "the mapping that left NEW went")
        XCTAssertEqual(back.library.mediaIndex.replaced[Self.fresh], F.mountains)
        for id in [F.mountains, Self.fresh] {
            let chain = MediaResolver.chain(from: id, library: back.library.mediaIndex, machine: back.machine.mediaLocal)
            XCTAssertNil(chain.loop, "no loop from \(id)")
            XCTAssertEqual(chain.reached, F.mountains)
        }
        guard case .replace(_, _, let record?) = back.logged else { return XCTFail() }
        XCTAssertEqual(record.mapping.removed, [MediaMapping(index: .library, from: F.mountains, to: Self.fresh)])
        XCTAssertEqual(list7(back.library).cues[0].commands[0].command.mediaRef, F.mountains, "the references go back too")
    }

    // MARK: - Its inverse

    /// "Its inverse, `media unreplace`, puts all three back": the roots are
    /// what they were, exactly, and unreplace's own inverse is the replace.
    func test_unreplacePutsTheReferencesTheMappingsAndTheDefaultsBackExactly() throws {
        let roots = self.roots()
        let replaced = try XCTUnwrap(replace(F.mountains, Self.fresh, roots))
        guard case .unreplace(let old, let new, let record)? = replaced.inverse else { return XCTFail() }
        let undone = MediaEdits.unreplace(old: old, new: new, record: record, library: replaced.library, machine: replaced.machine)
        guard case .success(let outcome) = undone else { return XCTFail("\(undone)") }
        XCTAssertEqual(outcome.library, roots.library)
        XCTAssertEqual(outcome.machine, roots.machine)
        XCTAssertEqual(outcome.inverse, .replace(old: F.mountains, new: Self.fresh, record: record))
        // A reference edited since no longer names NEW: Spec 5 §8's `conflict`, and nothing changes.
        var edited = replaced.library
        let list = edited.lists.firstIndex { $0.number == 7 }!
        edited.lists[list].cues[0].commands[0].command = edited.lists[list].cues[0].commands[0].command.mapMediaRefs { _ in F.dawn }
        XCTAssertEqual(reason(MediaEdits.unreplace(old: old, new: new, record: record, library: edited, machine: replaced.machine)), .conflict)
    }

    /// A replace with nothing to do is a `noop`: no inverse, no changes.
    func test_aReplaceThatChangesNothingIsANoop() throws {
        let once = try XCTUnwrap(replace(F.mountains, F.dawn, roots()))
        let again = try XCTUnwrap(replace(F.mountains, F.dawn, (once.library, once.machine)))
        XCTAssertTrue(again.isNoop)
        XCTAssertEqual(again.changes, [])
        XCTAssertEqual(again.library, once.library)
    }

    // MARK: - Refusals

    func test_whatReplaceRefuses() {
        let roots = self.roots()
        XCTAssertEqual(reason(MediaEdits.replace(old: "sha256:" + String(repeating: "0", count: 64), new: F.dawn,
                                                 library: roots.library, machine: roots.machine)), .unknownObject)
        XCTAssertEqual(reason(MediaEdits.replace(old: F.dawn, new: F.dawn, library: roots.library, machine: roots.machine)), .badValue,
                       "NEW can't be OLD")
        var deleted = roots.library
        deleted.mediaIndex.entries[deleted.mediaIndex.position(of: Self.fresh)!].deletedAt = "2026-11-14T09:30:00Z"
        XCTAssertEqual(reason(MediaEdits.replace(old: F.mountains, new: Self.fresh, library: deleted, machine: roots.machine)), .badValue,
                       "NEW can't be a deleted item")
    }

    /// "On a `readOnlyMasters` machine, replacing library media is refused
    /// with `readOnlyLibrary`, and replacing local-only media rewrites
    /// machine documents only (§2)": a library item with empty defaults
    /// stays empty there, since the library isn't written.
    func test_onAReadOnlyMachineOnlyMachineDocumentsChange() throws {
        var roots = self.roots(writable: false)
        XCTAssertEqual(reason(MediaEdits.replace(old: F.mountains, new: Self.fresh, library: roots.library, machine: roots.machine)),
                       .readOnlyLibrary)
        // The announcement is local-only; a cue in the library and a key binding both write it.
        let write = Command.channelWrite(ChannelWrite(channel: .number(1), content: .media(MediaContent(ref: F.announcement))))
        roots.machine.keys.append(KeyBinding(device: "keyboard", key: "a", command: write))
        let list = roots.library.lists.firstIndex { $0.number == 7 }!
        roots.library.lists[list].cues[2].commands.append(GuardedCommand(write))
        let outcome = try XCTUnwrap(replace(F.announcement, Self.fresh, roots))
        XCTAssertEqual(outcome.library, roots.library, "nothing in the library is written")
        XCTAssertEqual(outcome.machine.mediaLocal.replaced[F.announcement], Self.fresh, "the machine index records the mapping")
        XCTAssertEqual(outcome.machine.keys.last?.command.mediaRef, Self.fresh)
        XCTAssertEqual(list7(outcome.library).cues[2].commands.last?.command.mediaRef, F.announcement, "the library's cue resolves through the map instead")
        XCTAssertEqual(MediaResolver.resolve(F.announcement, library: outcome.library, machine: outcome.machine)?.id, Self.fresh)
    }
}
