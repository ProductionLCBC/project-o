import Foundation
import XCTest
@testable import OCore

/// Area 1 brief, deviation 2: "the command decoder accepts the bare cmd names
/// Spec 1 §6 used before its correction ("next", "macro") on input and prints
/// only the Spec 2 §3 object names." Decision 4 of the Area 3 plan: on a slide
/// write the build belongs to the content; a `build` rider is folded into it.
final class CommandAliasTests: XCTestCase {
    typealias F = FixtureLibrary

    func decoded(_ object: JSONValue) throws -> Command {
        try JSONCoding.decode(Command.self, from: object)
    }

    func test_bareVerbNamesDecodeAndPrintTheObjectNames() throws {
        let pairs: [(JSONValue, Command, String)] = [
            (.object(["cmd": .string("next")]), .next, "playlist.next"),
            (.object(["cmd": .string("previous")]), .previous, "playlist.previous"),
            (.object(["cmd": .string("cue"), "cue": .number(7)]), .cue(7), "playlist.cue"),
            (.object(["cmd": .string("undo")]), .undo, "history.undo"),
            (.object(["cmd": .string("redo")]), .redo, "history.redo"),
            (.object(["cmd": .string("macro"), "macro": .number(12)]), .macro(12), "macro.run"),
        ]
        for (object, command, name) in pairs {
            let read = try decoded(object)
            XCTAssertEqual(read, command, "\(object)")
            XCTAssertFalse(read.isUnknown)
            XCTAssertEqual(read.cmd, name)
            XCTAssertEqual(try JSONCoding.encode(read)["cmd"], .string(name))
        }
        for name in ["next", "previous", "cue", "undo", "redo", "macro"] {
            XCTAssertTrue(Command.knownNames.contains(name), name)
        }
        // A bare name with bad parameters is still an invalid command, kept whole.
        let bad = try decoded(.object(["cmd": .string("cue"), "cue": .string("seven")]))
        XCTAssertTrue(bad.isInvalid)
        XCTAssertEqual(bad.cmd, "cue")
    }

    func test_aBuildRiderOnASlideWriteFoldsIntoTheContent() throws {
        let slide = F.welcomeSlide
        let folded = try decoded(.object([
            "cmd": .string("channel.write"), "channel": .number(3),
            "content": .object(["kind": .string("slide"), "ref": .string(slide)]), "build": .number(2),
        ]))
        XCTAssertEqual(folded, .channelWrite(ChannelWrite(channel: .number(3), content: .slide(ref: slide, build: 2))))
        XCTAssertEqual(try JSONCoding.encode(folded), .object([
            "cmd": .string("channel.write"), "channel": .number(3),
            "content": .object(["kind": .string("slide"), "ref": .string(slide), "build": .number(2)]),
        ]))

        // With the content's own build present, the rider stays a rider.
        let both = try decoded(.object([
            "cmd": .string("channel.write"), "channel": .number(3),
            "content": .object(["kind": .string("slide"), "ref": .string(slide), "build": .number(1)]), "build": .number(2),
        ]))
        XCTAssertEqual(both, .channelWrite(ChannelWrite(channel: .number(3), content: .slide(ref: slide, build: 1), riders: Riders(build: 2))))

        // On media content the rider stays where it was (a noop at run time, Spec 3 §3 rule 8).
        let media = try decoded(.object([
            "cmd": .string("channel.write"), "channel": .number(1),
            "content": .object(["kind": .string("media"), "ref": .string(F.dawn)]), "build": .number(2),
        ]))
        XCTAssertEqual(media, .channelWrite(ChannelWrite(channel: .number(1), content: .media(MediaContent(ref: F.dawn)), riders: Riders(build: 2))))

        // The fixture's slide write (list 7, cue 3) carries its build in the content.
        let (library, _, _) = F.load()
        let cue = try XCTUnwrap(library.list(number: 7)?.cues[2])
        XCTAssertEqual(cue.commands[2].command, .channelWrite(ChannelWrite(channel: .number(1), content: .slide(ref: slide, build: 2))))
    }
}
