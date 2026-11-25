// OApp — Spec 11 §6, the Stacks page's selection and its edits; and the Delete every numbered object's page shares.

import Foundation
import OCore

extension EditModel {
    // MARK: - The selection (Spec 11 §6, "a click on a stack selects that stack")

    /// The stack the page edits: the one chosen last, else the one output 1 shows, else the first.
    public var stackNumber: Int? {
        let stacks = model.store.catalog?.stacks.map(\.number).sorted() ?? []
        if let chosen = model.settings.editStack, stacks.contains(chosen) { return chosen }
        if let shown = model.outputDots.first?.stack, stacks.contains(shown) { return shown }
        return stacks.first
    }

    /// The output whose properties show: the one chosen last, else the first showing the stack, else the first.
    public var outputNumber: Int? {
        let outputs = model.store.catalog?.outputs.map(\.number).sorted() ?? []
        if let chosen = model.settings.editOutput, outputs.contains(chosen) { return chosen }
        if let stack = stackNumber, let showing = model.outputDots.first(where: { $0.stack == stack }) { return showing.number }
        return outputs.first
    }

    /// Spec 11 §6 — the page as the catalog and the outputs have it now.
    public var stackPage: StackPage {
        guard let catalog = model.store.catalog else { return StackPage() }
        return StackPage.make(catalog: catalog, stack: stackNumber, dots: model.outputDots)
    }

    /// "a click on a stack selects that stack".
    public func selectStack(_ number: Int) {
        model.settings.editStack = number
        model.changed([.edit])
    }

    /// "A click on an output selects the stack it shows."
    public func selectOutput(_ number: Int) {
        model.settings.editOutput = number
        if let stack = model.outputDots.first(where: { $0.number == number })?.stack { model.settings.editStack = stack }
        model.changed([.edit])
    }

    // MARK: - The slots (Spec 11 §6)

    public func setSlotPreset(channel: Int, preset: Int?) {
        guard let stack = stackNumber else { return }
        _ = send(StackEdits.slotPreset(stack: stack, channel: channel, preset: preset))
    }

    public func setSlotOpacity(channel: Int, opacity: Double) {
        guard let stack = stackNumber else { return }
        _ = send(StackEdits.slotOpacity(stack: stack, channel: channel, opacity: opacity))
    }

    /// "Rows drag to a new place (`edit stack S slot C move K`)": dropped above the row at `row`, top first.
    public func moveSlot(channel: Int, toRow row: Int) {
        let page = stackPage
        guard let stack = page.stack, let from = page.slots.first(where: { $0.channel == channel }) else { return }
        var target = page.slotIndex(droppedAt: row)
        if from.index < target { target -= 1 }
        target = min(max(0, target), page.slots.count - 1)
        guard target != from.index else { return }
        _ = send(StackEdits.moveSlot(stack: stack.number, channel: channel, to: target))
    }

    /// "Move Up and Move Down in a row's menu do the same by keyboard": up is toward the top of the stack.
    public func moveSlot(channel: Int, up: Bool) {
        let page = stackPage
        guard let stack = page.stack, let from = page.slots.first(where: { $0.channel == channel }) else { return }
        let target = from.index + (up ? 1 : -1)
        guard target >= 0, target < page.slots.count else { return }
        _ = send(StackEdits.moveSlot(stack: stack.number, channel: channel, to: target))
    }

    /// "A channel the stack already holds is refused before the drop lands, since a channel appears once per stack."
    public func canAddSlot(channel: Int) -> Bool {
        guard let stack = stackPage.stack, model.store.catalog?.channels.contains(where: { $0.number == channel }) == true else { return false }
        return !stack.slots.contains { $0.channel == channel }
    }

    /// "A channel dragged in from the right column adds a slot where it lands", asking first on a stack on air.
    public func addSlot(channel: Int, atRow row: Int) {
        let page = stackPage
        guard let stack = page.stack, canAddSlot(channel: channel) else { return }
        let sending = StackEdits.insertSlot(stack: stack.number, channel: channel, at: page.slotIndex(droppedAt: row))
        let label = page.channels.first { $0.number == channel }?.label ?? ""
        askOnAir(page, channel: channel, label: label, adding: true, sending)
    }

    /// "A row's menu has Remove from Stack (`edit stack S slot C remove`)", asking first on a stack on air.
    public func removeSlot(channel: Int) {
        let page = stackPage
        guard let stack = page.stack else { return }
        let label = page.slots.first { $0.channel == channel }?.label ?? ""
        askOnAir(page, channel: channel, label: label, adding: false, StackEdits.removeSlot(stack: stack.number, channel: channel))
    }

    /// "On a stack an output shows, adding or removing a slot asks first, since it changes the picture at once."
    private func askOnAir(_ page: StackPage, channel: Int, label: String, adding: Bool, _ sending: Sending) {
        guard !page.shownOn.isEmpty else {
            _ = send(sending)
            return
        }
        model.ask(.slotOnAir(channel: channel, label: label, outputs: page.shownOn, adding: adding)) { [weak self] in
            _ = self?.send(sending)
        }
    }

    // MARK: - The stack (Spec 11 §6, "The stack's own fields")

    public func setStack(_ path: String, _ value: JSONValue) {
        guard let stack = stackNumber else { return }
        _ = send(StackEdits.set(stack: stack, path, value))
    }

    /// "New Stack (`edit stack create` ...)": the new stack is selected when the engine names it.
    public func newStack() {
        _ = send(StackEdits.create()) { [weak self] outcome in
            guard let number = outcome.applied.first?.command.objectValue?["stack"]?.intValue else { return }
            self?.selectStack(number)
        }
    }

    public func duplicateStack() {
        guard let stack = stackNumber else { return }
        _ = send(StackEdits.duplicate(stack: stack)) { [weak self] outcome in
            guard let number = outcome.applied.first?.command.objectValue?["stack"]?.intValue, number != stack else { return }
            self?.selectStack(number)
        }
    }

    /// "Renumber…, with swap for a taken number".
    public func renumberStack(to number: Int) {
        guard let stack = stackNumber, number >= 1, number != stack else { return }
        let taken = model.store.catalog?.stacks.contains { $0.number == number } ?? false
        _ = send(StackEdits.renumber(stack: stack, to: number, swap: taken)) { [weak self] outcome in
            guard outcome.kind == .ok else { return }
            self?.selectStack(number)
        }
    }

    /// "Delete, refused while an output shows the stack (E-7) and asking first when anything refers to it, with the
    /// counts from `uses`".
    public func deleteStack() {
        let page = stackPage
        guard let stack = page.stack, page.shownOn.isEmpty else { return }
        deleteAsking("stack", stack.number, name: Self.name(of: stack), always: false, StackEdits.delete(stack: stack.number))
    }

    /// "with an empty label the page shows as "Stack N" until one is typed".
    public static func name(of stack: Stack) -> String {
        stack.label.isEmpty ? Strings.text(.editStackUntitled, stack.number) : "\(stack.number) \(stack.label)"
    }

    // MARK: - The outputs and the audio routing (Spec 11 §6, "The right column")

    public func setOutput(_ path: String, _ value: Int?) {
        guard let output = outputNumber else { return }
        _ = send(StackEdits.output(output, path, value))
    }

    /// "Set as Default makes the output's live stack its default stack".
    public func setAsDefault() {
        guard let output = outputNumber, let live = model.outputDots.first(where: { $0.number == output })?.stack else { return }
        _ = send(StackEdits.output(output, "defaultStack", live))
    }

    public func setAudio(channel: Int, output: Int, on: Bool) {
        guard let current = model.store.catalog?.channels.first(where: { $0.number == channel })?.audioOutputs else { return }
        _ = send(StackEdits.audioOutputs(channel: channel, current: current, output: output, on: on))
    }

    // MARK: - Delete, on every numbered object's page

    /// Spec 11 §6, §7, §8 — Delete "asking first ..., with the counts from `uses` (§3)": the engine is asked what
    /// refers to the object; `always` asks even when nothing does.
    func deleteAsking(_ object: String, _ number: Int, name: String, always: Bool, _ sending: Sending) {
        model.ask(.query("uses", ["object": .string(object), object: .number(Double(number))])) { [weak self] answer in
            guard let self else { return }
            var counts: [String: Int] = [:]
            for (kind, value) in answer?["counts"]?.objectValue ?? [:] {
                if let count = value.intValue, count > 0 { counts[kind] = count }
            }
            guard always || !counts.isEmpty else {
                _ = self.send(sending)
                return
            }
            self.model.ask(.deleteNumbered(name: name, uses: counts)) { [weak self] in _ = self?.send(sending) }
        }
    }
}
