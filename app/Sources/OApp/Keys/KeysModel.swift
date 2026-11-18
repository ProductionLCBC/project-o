// OApp — Spec 10 §9, the keys' model: the table as the catalog has it, the digits waiting, the command bar.

import Foundation
import OCore

/// Spec 10 §9 — holds what the keys need between presses and does what a
/// press comes to: a binding's command goes "with source `key`", a digit
/// waits in the go-to field, Return fires `cue N`. The window tells it what
/// is open or focused; it tells the window nothing but that something it
/// shows changed.
@MainActor
public final class KeysModel {
    public let model: ShowModel
    private let clock: any AppClock

    /// The keyboard's bindings, from the catalog's `keys`.
    public private(set) var table = BindingTable()
    public private(set) var digits = DigitEntry()
    public private(set) var bar = CommandBar()
    private var digitTask: (any ClockTask)?
    private var barRequests = 0

    /// Called when the digits waiting or the command bar changed.
    public var onChange: (() -> Void)?

    public init(model: ShowModel, clock: any AppClock) {
        self.model = model
        self.clock = clock
        model.store.observe { [weak self] changes in
            if !changes.isDisjoint(with: [.catalog, .connection]) { self?.readTable() }
        }
        readTable()
    }

    private func readTable() {
        let next = BindingTable(model.store.catalog?.keys ?? [])
        guard next != table else { return }
        table = next
        onChange?()
    }

    // MARK: - A key (Spec 10 §9, "When bindings fire")

    /// A key was pressed with `context` open or focused. Does what the key
    /// comes to in the model and says where it went, so the window can pass
    /// it on, leave a field or close the overlay.
    @discardableResult
    public func press(_ stroke: KeyStroke, context: KeyContext = KeyContext()) -> KeyRoute {
        var context = context
        // A field took the focus: what waited in the go-to field is no longer the keys' to complete.
        if context.field != nil, digits.isWaiting { clearDigits() }
        context.digitsWaiting = digits.isWaiting
        context.goToEnabled = model.nextRow.goToEnabled
        let route = KeyRouter.route(stroke, table: table, context: context)
        switch route {
        case .fire(let binding):
            // Spec 10 §2 — "a key that would send a command is dropped, never queued": `send` sends nothing while the engine is away.
            model.send(Sending([binding.command], source: .key))
        case .digit(let digit):
            digits.type(digit, at: clock.now)
            digitTask?.cancel()
            digitTask = clock.after(DigitEntry.seconds) { [weak self] in self?.digitsTimedOut() }
            onChange?()
        case .completeDigits:
            // "Return fires `cue N` in the live list"; the source is `key`, since a key fired it (Area 13 reading).
            if let number = digits.number { model.send(Actions.goTo(cue: number, source: .key)) }
            clearDigits()
        case .escape(.digits):
            clearDigits()
        case .passed, .nothing, .escape:
            break
        }
        return route
    }

    /// "Escape, or three seconds without a key, clears the digits".
    public func clearDigits() {
        digitTask?.cancel()
        digitTask = nil
        guard digits.isWaiting else { return }
        digits.clear()
        onChange?()
    }

    private func digitsTimedOut() {
        if digits.expire(at: clock.now) { onChange?() }
    }

    // MARK: - The command bar (Spec 10 §9)

    /// Whether the machine's settings turn the command bar on (`commandBar`).
    public var showsCommandBar: Bool { model.store.catalog?.settings?.commandBar ?? false }

    private var mediaIDs: Set<String> { Set(model.store.media.map(\.id)) }

    public func typeInBar(_ text: String) {
        bar.type(text, mediaIDs: mediaIDs)
        onChange?()
    }

    /// ↑ or ↓ in the bar.
    public func recallInBar(earlier: Bool) {
        bar.recall(earlier: earlier, mediaIDs: mediaIDs)
        onChange?()
    }

    /// Return in the bar: "sends the command with source `commandbar` and
    /// shows the result or the rejection beside it". While the engine is
    /// away nothing goes and the text stays (Spec 10 §2).
    public func submitBar() {
        guard case .canonical = bar.preview else { return }
        guard model.store.cannotSend == nil, let transmit = model.transmit else {
            bar.answered(nil)
            onChange?()
            return
        }
        guard let command = bar.submit() else { return }
        barRequests += 1
        let request = barRequests
        transmit(.command(command, source: .commandbar)) { [weak self] reply in
            // Only the last command's answer is the one shown beside the bar.
            guard let self, request == self.barRequests else { return }
            self.bar.answered(reply)
            self.onChange?()
        }
        onChange?()
    }
}
