// OApp — Spec 11 §2, "What is live": when an edit to a cue shows on air at once.

import Foundation
import OCore

/// Spec 11 §2, "What is live" — "a cue's commands and trigger at the cue's
/// next fire (L3), but at once in a box at +1 to +3 on air, such as the
/// confidence screen's, which shows what will happen (Spec 5 §2, Spec 6 §3)".
public enum EditOnAir {
    /// The outputs that show cues ahead of the live one: those presenting a
    /// stack one of whose slots draws a box at +1 to +3. A slot's preset is
    /// its own, else the stack's default, else the channel's, else Preset 1
    /// (Spec 6 §2); its layout is the stack's own, else `*`.
    public static func lookaheadOutputs(catalog: Catalog, dots: [OutputDot]) -> [Int] {
        func looksAhead(_ stack: Stack) -> Bool {
            stack.slots.contains { slot in
                let number = slot.preset ?? stack.defaultPreset ?? catalog.channels.first { $0.number == slot.channel }?.defaultPreset ?? 1
                guard let preset = catalog.presets.first(where: { $0.number == number }),
                      let layout = preset.layouts[.stack(stack.number)] ?? preset.layouts[.any] else { return false }
                return layout.boxes.contains { (1...3).contains($0.offset) }
            }
        }
        let ahead = Set(catalog.stacks.filter(looksAhead).map(\.number))
        return dots.filter { $0.state == .presenting && ahead.contains($0.stack) }.map(\.number).sorted()
    }

    /// Which cues of a list, by their place from 0, are among "the three
    /// cues after the live cue, in playlist order; near a song's end they
    /// are the next song's first cues" (Spec 11 §5, "Near the live cue").
    /// `isLive` says the list is the live one, where it is live; `isNext`
    /// that it is the list after it in the live playlist. `liveIndex` and
    /// `liveCount` are the live cue's place in its list and that list's length.
    /// Spec 11 §5, "Near the live cue" — the cues of the list `uuid`, by their
    /// uuids, among "the three cues after the live cue, in playlist order;
    /// near a song's end they are the next song's first cues (Spec 3 §7)".
    /// They are counted across the items after the live one as Spec 3 §5's
    /// `next` walks them, past headers, missing lists and lists with no cues,
    /// a local copy's cues counting as any list's; a list fired from the
    /// library stays inside itself. `lists` holds the lists the app has whole;
    /// another list counts by the catalog's summary.
    public static func ahead(of uuid: String, live: LiveStatus, catalog: Catalog, lists: [String: ListDocument]) -> Set<String> {
        guard let liveList = live.listUuid, let liveCue = live.cue else { return [] }
        func count(_ list: String) -> Int {
            lists[list]?.list.cues.count ?? catalog.list(uuid: list)?.cues ?? 0
        }
        let cues = lists[uuid]?.list.cues.map { $0.uuid.uuidString.lowercased() } ?? []
        let liveIndex = lists[liveList]?.list.cues.firstIndex { $0.uuid.uuidString.lowercased() == liveCue } ?? (live.cuePosition - 1)
        guard liveIndex >= 0 else { return [] }
        var result = Set<String>()
        var remaining = 3
        let after = max(0, count(liveList) - liveIndex - 1)
        let here = min(remaining, after)
        if liveList == uuid, here > 0 { result.formUnion(cues[min(cues.count, liveIndex + 1)..<min(cues.count, liveIndex + 1 + here)]) }
        remaining -= here
        guard remaining > 0, let playlist = live.playlist, let entry = catalog.playlist(uuid: playlist)?.playlist,
              let at = entry.items.firstIndex(where: { $0.uuid.uuidString.lowercased() == live.item }) else { return result }
        for item in entry.items[(at + 1)...] {
            guard remaining > 0 else { break }
            guard let list = GridModel.listUuid(of: item, catalog: catalog) else { continue }
            let take = min(remaining, count(list))
            if list == uuid, take > 0 { result.formUnion(cues.prefix(take)) }
            remaining -= take
        }
        return result
    }

    public static func lookahead(isLive: Bool, isNext: Bool, liveIndex: Int?, liveCount: Int) -> Range<Int> {
        guard let liveIndex else { return 0..<0 }
        if isLive { return (liveIndex + 1)..<(liveIndex + 4) }
        let left = max(0, liveCount - liveIndex - 1)
        return isNext && left < 3 ? 0..<(3 - left) : 0..<0
    }
}
