// OEngine — Spec 4 §15, "The DeckLink output is frame-accurate against the
// capture; the 1080i weave ... is verified field-correct ... the same way":
// the frame stamp a test run writes into the SDI picture so the capture can
// name every frame and every field (Area 7, Adam's answer of 2026-11-22).

import Foundation

/// Spec 4 §15 — a tick number written into the first eleven v210 words (the
/// first 16½ pixels) of the first line of each field: rows 0 and 1 of the
/// frame. Bit `i` of the tick's low 32 bits is component `i`, at peak white
/// (940) for a one and black (64) for a zero, and component 32 is always
/// peak white as a marker; three components a word, as v210 packs them. Only
/// a run that asks for it (`--stamp-sdi`) carries it; a show never does.
///
/// Encode.metal's `stampWord` writes the same words on the GPU.
public enum FrameStamp {
    /// Words of a row the stamp takes.
    public static let words = 11
    static let one: UInt32 = 940
    static let zero: UInt32 = 64

    /// The v210 word `index` (0 to 10) of the stamp for `tick`.
    public static func word(tick: UInt32, index: Int) -> UInt32 {
        var word: UInt32 = 0
        for k in 0..<3 {
            let component = index * 3 + k
            let value: UInt32 = component >= 32 ? one : (((tick >> UInt32(component)) & 1) == 1 ? one : zero)
            word |= value << UInt32(10 * k)
        }
        return word
    }

    /// The tick a row starting with these words carries, or nil when they are
    /// not a stamp exactly (another picture, a black frame, a damaged line).
    public static func read(_ row: UnsafePointer<UInt32>) -> UInt32? {
        var tick: UInt32 = 0
        for component in 0..<33 {
            let value = (row[component / 3] >> UInt32(10 * (component % 3))) & 0x3FF
            if component == 32 {
                guard value == one else { return nil }
            } else if value == one {
                tick |= 1 << UInt32(component)
            } else if value != zero {
                return nil
            }
        }
        return tick
    }

    /// The tick in a buffer of words, from word `offset` on.
    public static func read(_ words: [UInt32], offset: Int = 0) -> UInt32? {
        guard words.count >= offset + FrameStamp.words else { return nil }
        return words.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return nil }
            return read(base + offset)
        }
    }
}

/// Spec 4 §10 — what the encode pass stamps on one SDI frame: the tick of
/// each field's stack frame. A progressive frame has one tick in both rows; a
/// woven frame has the first field's tick in row 0 and the second's in row 1.
public struct SinkStamp: Equatable, Codable, Sendable {
    public var firstField: Int64
    public var secondField: Int64

    public init(firstField: Int64, secondField: Int64) {
        self.firstField = firstField
        self.secondField = secondField
    }
}
