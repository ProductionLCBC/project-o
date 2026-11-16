// OEngine — Spec 2 §9 and Spec 10 §3, the result that answers a command.

import Foundation
import OCore

/// Spec 2 §9 — `{ "id": 17, "type": "result", "result": "ok", "seq": 4822 }`.
/// Spec 10 §3, "Results" — "An applied edit's result also carries its `group`
/// and, as `applied`, each of its commands as the log keeps it, with what the
/// engine picked, and its inverse, so the app can find a new object, or
/// revert exactly what it sent without reaching for `undo`".
enum ApiResults {
    /// The fields of the result of one group that ran, without its `id` and
    /// `type`.
    ///
    /// A group's lines hold more than the commands that were sent: a macro's
    /// inner commands, the cue a navigation fired, the edits an undo ran
    /// again. The sent commands' own lines are the ones under the id the
    /// group was sent with and from its sender's source, or folded into a
    /// typing run; the result speaks for those.
    ///
    /// One command (`command`) answers with its own result and `seq`.
    /// Several (`commands`, Area 19 reading: the spec shows only one) answer
    /// `ok` with the last line's `seq` and `results`, one per command in order.
    static func fields(of result: GroupResult, sentBy kind: SourceKind, commands: Int, single: Bool) -> [String: JSONValue] {
        let own = result.lines.filter { line in
            line.folded || (line.executed.group == result.id && line.executed.source.kind == kind && line.executed.source.macro == nil)
        }
        var fields: [String: JSONValue] = [:]
        if single, let line = own.first {
            fields["result"] = .string(line.executed.result.name)
            fields["seq"] = .number(Double(line.seq))
            // Spec 5 §2 — an edit a holder couldn't run "yields `blocked` with its reason".
            if let refusal = line.executed.refusal { fields["reason"] = .string("\(refusal.reason.rawValue): \(refusal.message)") }
        } else {
            fields["result"] = .string("ok")
            if let last = own.last { fields["seq"] = .number(Double(last.seq)) }
            fields["results"] = .array(own.map { .object(["result": .string($0.executed.result.name), "seq": .number(Double($0.seq))]) })
        }

        // "An applied edit's result also carries its `group` and, as `applied`, each of its commands as the log keeps it".
        let applied = own.filter { $0.executed.result == .ok && ($0.executed.command.logKind == .edit || $0.executed.inverse != nil) }
        if let first = applied.first {
            fields["group"] = .string(first.executed.group.rawValue)
            fields["applied"] = .array(applied.map { line in
                .object(["command": (try? JSONCoding.encode(line.executed.command)) ?? .null,
                         "inverse": line.executed.inverse.flatMap { try? JSONCoding.encode($0) } ?? .null])
            })
        }
        // Spec 5 §6 — "it may carry `warnings`".
        let warnings = own.flatMap(\.executed.warnings)
        if !warnings.isEmpty { fields["warnings"] = .array(warnings.map(JSONValue.string)) }
        // Spec 8 §7 — "A `media import` result also carries the `job`".
        if let job = own.compactMap(\.executed.job).first { fields["job"] = .string(job) }
        // Spec 9 §3 — `system snapshot`'s result "names it".
        if let snapshot = own.compactMap(\.executed.snapshot).first { fields["snapshot"] = .string(snapshot) }
        return fields
    }
}
