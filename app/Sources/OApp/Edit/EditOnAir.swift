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
    public static func lookahead(isLive: Bool, isNext: Bool, liveIndex: Int?, liveCount: Int) -> Range<Int> {
        guard let liveIndex else { return 0..<0 }
        if isLive { return (liveIndex + 1)..<(liveIndex + 4) }
        let left = max(0, liveCount - liveIndex - 1)
        return isNext && left < 3 ? 0..<(3 - left) : 0..<0
    }
}
