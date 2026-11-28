// OApp — Spec 11 §5, the text editor's own edits shown before the engine answers them.

import Foundation
import OCore

/// Spec 11 §5 — after a split the typing goes on in the new cue's chunk, and
/// after a merge in the first cue's. The engine runs the editor's edits in the
/// order it sends them, so the editor shows the list as those edits will leave
/// it until the list comes back from the engine: the app keeps no state of its
/// own beyond that (Spec 10 §1). This applies an editor's edit to a copy of the
/// list as the engine would, for the commands the editor sends: a cue's channel,
/// a cue inserted and a cue removed.
enum LocalEdits {
    /// Whether a command is one a cue says about `channel`: its content or a standalone attribute write.
    private static func concerns(_ command: Command, _ channel: Int) -> Bool {
        switch command {
        case .channelWrite(let write): return write.channel == .number(channel)
        case .channelClear(.number(let n)): return n == channel
        default: return command.isStandaloneAttribute(channel: channel)
        }
    }

    /// Applies one of the editor's commands to `list`. Applying it again changes nothing.
    static func apply(_ command: Command, to list: inout List) {
        guard case .edit(let edit) = command else { return }
        switch (edit.address, edit.action) {
        case (.cue(_, let uuid), .cueChannel(let change)):
            guard let index = list.cues.firstIndex(where: { $0.uuid == uuid }) else { return }
            var commands = list.cues[index].commands
            let at = commands.firstIndex { concerns($0.command, change.channel) }
            let kept = commands.enumerated().filter { !concerns($0.element.command, change.channel) }
            let place = at.map { first in kept.filter { $0.offset < first }.count } ?? kept.count
            commands = kept.map(\.element)
            var added = change.attributes.map { GuardedCommand($0) }
            switch change.state {
            case .write(let content, let riders):
                added.append(GuardedCommand(.channelWrite(ChannelWrite(channel: .number(change.channel), content: content, riders: riders))))
            case .clear:
                added.append(GuardedCommand(.channelClear(channel: .number(change.channel))))
            case .hold:
                break
            }
            commands.insert(contentsOf: added, at: place)
            list.cues[index].commands = commands
        case (.list, .insert("cues", let at, let value)):
            guard let cue = try? JSONCoding.decode(Cue.self, from: value), !list.cues.contains(where: { $0.uuid == cue.uuid }) else { return }
            list.cues.insert(cue, at: min(max(0, at), list.cues.count))
        case (.cue(_, let uuid), .remove(nil, nil)):
            list.cues.removeAll { $0.uuid == uuid }
        default:
            break
        }
    }

    /// Whether the list already says what the command makes it say, so the edit no longer needs showing.
    static func isSatisfied(_ command: Command, in list: List) -> Bool {
        guard case .edit(let edit) = command else { return true }
        switch (edit.address, edit.action) {
        case (.cue(_, let uuid), .cueChannel(let change)):
            guard let cue = list.cues.first(where: { $0.uuid == uuid }) else { return false }
            return CueSays.about(change.channel, in: cue) == CueSays(state: change.state, attributes: change.attributes)
        case (.list, .insert("cues", _, let value)):
            guard let cue = try? JSONCoding.decode(Cue.self, from: value) else { return true }
            return list.cues.contains { $0.uuid == cue.uuid }
        case (.cue(_, let uuid), .remove(nil, nil)):
            return !list.cues.contains { $0.uuid == uuid }
        default:
            return true
        }
    }
}
