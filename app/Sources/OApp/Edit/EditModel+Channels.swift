// OApp — Spec 11 §7, the channel sheet's selection and its edits.

import Foundation
import OCore

extension EditModel {
    /// The channel whose form shows: the one chosen last, else the Cues page's channel, else the first.
    public var sheetChannel: Int? {
        let channels = model.store.catalog?.channels.map(\.number).sorted() ?? []
        if let chosen = model.settings.editSheetChannel, channels.contains(chosen) { return chosen }
        if let row = model.settings.editChannel, channels.contains(row) { return row }
        return channels.first
    }

    /// Spec 11 §7 — the page as the catalog, the outputs and the channels' content have it now.
    public var channelPage: ChannelPage {
        guard let catalog = model.store.catalog else { return ChannelPage() }
        let content = Set(model.store.channels.values.filter { $0.content != nil }.map(\.number))
        return ChannelPage.make(catalog: catalog, channel: sheetChannel, dots: model.outputDots, content: content)
    }

    public func selectChannel(_ number: Int) {
        model.settings.editSheetChannel = number
        model.changed([.edit])
    }

    /// "Each field is an `edit.set` on commit".
    public func setChannel(_ path: String, _ value: JSONValue) {
        guard let channel = sheetChannel else { return }
        _ = send(ChannelEdits.set(channel: channel, path, value))
    }

    public func setChannelGain(_ decibels: Double) {
        guard let channel = sheetChannel else { return }
        _ = send(ChannelEdits.gain(channel: channel, decibels: decibels))
    }

    public func setChannelAudio(output: Int, on: Bool) {
        guard let channel = channelPage.channel else { return }
        _ = send(StackEdits.audioOutputs(channel: channel.number, current: channel.audioOutputs, output: output, on: on))
    }

    // MARK: - The number (Spec 11 §7, "Number")

    /// What changing the number would do: renumber, swap with the channel that has it, or nothing; or why it can't.
    public enum ChannelRenumber: Equatable, Sendable {
        case renumber(from: Int, to: Int)
        case swap(Int, Int)
        /// "Renumber is refused while the channel has content in a stack an output shows, and Swap while either
        /// channel has content and either is in a stack an output shows".
        case onAir
        case nothing
    }

    public func renumbering(to number: Int) -> ChannelRenumber {
        guard let catalog = model.store.catalog, let channel = sheetChannel, number >= 1, number != channel else { return .nothing }
        let content = Set(model.store.channels.values.filter { $0.content != nil }.map(\.number))
        let taken = catalog.channels.contains { $0.number == number }
        let onAir = { (n: Int) in ChannelPage.isOnAir(channel: n, catalog: catalog, dots: self.model.outputDots, content: content) }
        if taken {
            // "Swap while either channel has content and either is in a stack an output shows."
            let shown = !ChannelPage.shownOn(channel: channel, catalog: catalog, dots: model.outputDots).isEmpty
                || !ChannelPage.shownOn(channel: number, catalog: catalog, dots: model.outputDots).isEmpty
            if shown && (content.contains(channel) || content.contains(number)) { return .onAir }
            return .swap(channel, number)
        }
        return onAir(channel) ? .onAir : .renumber(from: channel, to: number)
    }

    /// Sends the renumber or the swap, after the popover has said what doesn't follow; the selection follows the channel.
    public func renumberChannel(to number: Int) {
        let plan = renumbering(to: number)
        let sending: Sending
        switch plan {
        case .renumber(let from, _): sending = ChannelEdits.renumber(channel: from, to: number, swap: false)
        case .swap(let from, _): sending = ChannelEdits.renumber(channel: from, to: number, swap: true)
        case .onAir:
            model.say(.rejected(EngineRejection(code: "onAir", message: "")), at: .inspector)
            model.changed([.edit])
            return
        case .nothing: return
        }
        _ = send(sending) { [weak self] outcome in
            guard outcome.kind == .ok else { return }
            self?.selectChannel(number)
        }
    }

    // MARK: - The stacks that hold it (Spec 11 §7, "The right column")

    /// "Add to Stack ▸ for the others, which adds a slot at the stack's top, asking first on a stack an output shows".
    public func addChannel(toStack number: Int) {
        guard let channel = channelPage.channel, let stack = model.store.catalog?.stacks.first(where: { $0.number == number }),
              !stack.slots.contains(where: { $0.channel == channel.number }) else { return }
        let sending = StackEdits.insertSlot(stack: number, channel: channel.number, at: stack.slots.count)
        askIfShown(stack: number, channel: channel, adding: true, sending)
    }

    /// "each with Remove from Stack".
    public func removeChannel(fromStack number: Int) {
        guard let channel = channelPage.channel else { return }
        askIfShown(stack: number, channel: channel, adding: false, StackEdits.removeSlot(stack: number, channel: channel.number))
    }

    private func askIfShown(stack: Int, channel: Channel, adding: Bool, _ sending: Sending) {
        let outputs = model.outputDots.filter { $0.stack == stack && $0.state != .absent }.map(\.number).sorted()
        guard !outputs.isEmpty else {
            _ = send(sending)
            return
        }
        model.ask(.slotOnAir(channel: channel.number, label: channel.label, outputs: outputs, adding: adding)) { [weak self] in
            _ = self?.send(sending)
        }
    }

    // MARK: - Its menu (Spec 11 §7, "Its menu")

    public func newChannel() {
        _ = send(ChannelEdits.create()) { [weak self] outcome in
            guard let number = outcome.applied.first?.command.objectValue?["channel"]?.intValue else { return }
            self?.selectChannel(number)
        }
    }

    public func duplicateChannel() {
        guard let channel = sheetChannel else { return }
        _ = send(ChannelEdits.duplicate(channel: channel)) { [weak self] outcome in
            guard let number = outcome.applied.first?.command.objectValue?["channel"]?.intValue, number != channel else { return }
            self?.selectChannel(number)
        }
    }

    /// "A channel with content on an output's stack, or sounding on an audio output, can't be deleted (E-7,
    /// `onAir`). Otherwise Delete asks first, with the counts from `uses`".
    public func deleteChannel() {
        let page = channelPage
        guard let channel = page.channel else { return }
        if page.isOnAir {
            model.say(.rejected(EngineRejection(code: "onAir", message: "")), at: .inspector)
            model.changed([.edit])
            return
        }
        deleteAsking("channel", channel.number, name: Self.name(of: channel), always: false, ChannelEdits.delete(channel: channel.number))
    }

    /// "an empty label the page shows as "Channel N" until one is typed".
    public static func name(of channel: Channel) -> String {
        channel.label.isEmpty ? Strings.text(.editChannelUntitled, channel.number) : "\(channel.number) \(channel.label)"
    }
}
