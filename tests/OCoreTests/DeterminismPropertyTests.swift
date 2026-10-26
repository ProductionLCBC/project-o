import XCTest
@testable import OCore

/// Spec 3 §10 — "a property test that `project` is deterministic over random
/// command sequences from the fixture library." Also checks that a group
/// folds the same whether applied at once or one command at a time (Spec 2
/// §8, "Commands run in array order, and later commands see earlier ones'
/// effects").
final class DeterminismPropertyTests: XCTestCase {
    typealias F = Fixtures

    /// SplitMix64: a tiny seeded generator so the sequences are reproducible.
    struct SeededGenerator: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    private func randomCommand(_ rng: inout SeededGenerator) -> Command {
        let channel = Target.number(Int.random(in: 1...3, using: &rng))
        let scope: Scope = Bool.random(using: &rng) ? .once : .track
        switch Int.random(in: 0..<22, using: &rng) {
        case 0: return F.write(Int.random(in: 1...3, using: &rng), media: [F.mediaA, F.mediaB, F.mediaC].randomElement(using: &rng) ?? F.mediaA)
        case 1: return F.write(Int.random(in: 1...3, using: &rng), text: ["x", "y", "z"].randomElement(using: &rng) ?? "x")
        case 2: return F.write(Int.random(in: 1...3, using: &rng), slide: F.slideS, build: Int.random(in: 1...3, using: &rng))
        case 3:
            return F.write(Int.random(in: 1...3, using: &rng), media: F.mediaB, riders: Riders(
                transition: TransitionRider(ref: Int.random(in: 1...3, using: &rng), ms: nil, scope: scope),
                grade: GradeRider(ref: Int.random(in: 0...7, using: &rng), scope: scope),
                gain: GainRider(db: Double(Int.random(in: -12...0, using: &rng)), scope: scope)))
        case 4: return .channelClear(channel: channel)
        case 5: return .channelReset(channel: channel)
        case 6: return .channelGrade(channel: channel, ref: Int.random(in: 0...7, using: &rng), ms: Bool.random(using: &rng) ? 500 : nil)
        case 7: return .channelTransition(channel: channel, ref: Int.random(in: 1...3, using: &rng), ms: nil)
        case 8: return .channelGain(channel: channel, db: -6)
        case 9: return .channelTransport(channel: channel, mode: [.play, .pause, .stop].randomElement(using: &rng) ?? .play)
        case 10: return .channelLock(channel: channel, locked: Bool.random(using: &rng))
        case 11: return .next
        case 12: return .previous
        case 13: return .listCue(list: Int.random(in: 1...7, using: &rng), cue: Int.random(in: 1...3, using: &rng))
        case 14: return .itemCue(item: Int.random(in: 1...5, using: &rng), cue: Int.random(in: 1...2, using: &rng))
        case 15: return .outputStack(output: Int.random(in: 1...2, using: &rng), stack: Int.random(in: 1...2, using: &rng))
        case 16: return .stackBlackout(stack: 1, state: .toggle)
        case 17: return .stackMute(stack: 1, channel: Int.random(in: 1...2, using: &rng), state: .toggle)
        case 18: return .popupSet(popup: 1, text: "hello", clearAfterMs: nil)
        case 19: return .macro(Int.random(in: 1...2, using: &rng))
        case 20: return .systemClearAll
        default: return .timerSet(timer: 1, ms: 1000)
        }
    }

    private func randomContext(_ rng: inout SeededGenerator) -> ProjectionContext {
        let kinds: [SourceKind] = [.ui, .osc, .cue, .macro, .key]
        return F.context(frame: Int.random(in: 0...10_000, using: &rng),
                         source: kinds.randomElement(using: &rng) ?? .ui)
    }

    func test_projectIsDeterministicOverRandomSequences() {
        var rng = SeededGenerator(state: 0xC0FFEE)
        for iteration in 0..<300 {
            let context = randomContext(&rng)
            var state = F.fresh()
            if Bool.random(using: &rng) { state.pointer = F.pointer(item: 2, list: 1, cue: 1) }
            let commands = (0..<Int.random(in: 1...12, using: &rng)).map { _ in randomCommand(&rng) }
            let first = project(state, commands, context: context)
            let second = project(state, commands, context: context)
            XCTAssertEqual(first.0, second.0, "iteration \(iteration): \(commands)")
            XCTAssertEqual(first.1, second.1, "iteration \(iteration): \(commands)")
        }
    }

    func test_groupFoldEqualsOneCommandAtATime() {
        var rng = SeededGenerator(state: 0xBEEF)
        for iteration in 0..<300 {
            let context = randomContext(&rng)
            var state = F.fresh()
            if Bool.random(using: &rng) { state.pointer = F.pointer(item: 2, list: 1, cue: 1) }
            let commands = (0..<Int.random(in: 1...12, using: &rng)).map { _ in randomCommand(&rng) }
            let grouped = project(state, commands, context: context)
            var folded = state
            var effects: [Effect] = []
            for command in commands {
                let step = project(folded, [command], context: context)
                folded = step.0
                effects += step.1
            }
            XCTAssertEqual(grouped.0, folded, "iteration \(iteration): \(commands)")
            XCTAssertEqual(grouped.1, effects, "iteration \(iteration): \(commands)")
        }
    }

    func test_everyCommandYieldsAtLeastOneEffect() {
        // Spec 3 §6: "the fold stays total: every command in, one result out."
        var rng = SeededGenerator(state: 0x5EED)
        for _ in 0..<300 {
            let context = randomContext(&rng)
            let command = randomCommand(&rng)
            let (_, effects) = project(F.fresh(), [command], context: context)
            XCTAssertFalse(effects.isEmpty, "\(command) produced no effect")
        }
    }
}
