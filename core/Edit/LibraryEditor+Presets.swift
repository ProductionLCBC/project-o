// OCore — Spec 5 §4 and §6 for presets, their layouts and boxes (Spec 11 §8,
// Spec 6 §3). A box has no identity of its own and is named by position
// (Spec 5 §3).

import Foundation

extension Editor {
    /// Spec 11 §8 — "New Preset (`edit preset create`, with an empty `*`
    /// layout), Duplicate ... and Delete ... Preset 1 can be edited but not
    /// deleted, renumbered or swapped (Spec 5 §6)."
    static var presets: Shelf<Preset> {
        var rules = ObjectRules<Preset>()
        rules.held = { _, preset, verb in
            preset.number == 1 ? Rejection(reason: .protected, message: "Preset 1 is built in: it can be edited, not \(verb)") : nil
        }
        rules.heldPair = { _, a, b in
            a.number == 1 || b.number == 1 ? Rejection(reason: .protected, message: "Preset 1 is built in: it can be edited, not swapped") : nil
        }
        rules.settled = { editor, old, preset in
            // A copy or a new preset is never the built-in one.
            if old == nil, preset.number != 1 { preset.builtIn = false }
            // Spec 1 §2 — "plus one entry under `"*"` that applies to any stack not named".
            guard preset.layouts[.any] != nil else {
                throw editor.reject(.badValue, "preset \(preset.number) keeps its * layout, which every stack without one of its own draws")
            }
            // Spec 1 §2 — a box's `fit` is a pixel fit or a text fit, as its binding is: the boxes this edit
            // made or whose kind it changed are checked, so a box "never holds half of each" (Spec 11 §8).
            for (key, layout) in preset.layouts {
                let before = old?.layouts[key]?.boxes ?? []
                for (index, box) in layout.boxes.enumerated() {
                    if index < before.count, before[index].binding.isText == box.binding.isText, before[index].fit.isText == box.fit.isText { continue }
                    guard box.binding.isText == box.fit.isText else {
                        throw editor.reject(.badValue, "preset \(preset.number) layout \(key.string) box \(index): "
                            + (box.binding.isText ? "a text box takes shrinkToFit or maxLines" : "a pixel box takes fill, fit, stretch or crop")
                            + "; set the whole box when its binding changes kind")
                    }
                }
            }
            editor.warnOfStackDefault(preset, stacks: editor.machine.stacks)
        }
        rules.document = "preset"
        return Shelf(type: .preset, table: EditFields.preset, read: { $0.library.presets }, write: { $0.library.presets = $1 },
                     fresh: { Preset(number: $0, label: "", uuid: $1, layouts: [.any: Layout(boxes: [])]) }, rules: rules)
    }
}

extension BoxFit {
    /// Whether this is a text box's fit policy.
    var isText: Bool {
        if case .text = self { return true }
        return false
    }
}
