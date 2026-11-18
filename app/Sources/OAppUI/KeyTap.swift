// OAppUI — Spec 10 §9, every key the app is given, read before any view sees it.

import AppKit
import OApp

/// Spec 10 §9, "When bindings fire" — "Whenever a Project O window is the
/// key window, a key goes to the first of these that is open or has the
/// focus, and to the bindings only when none of them takes it".
///
/// The app reads each key-down before it is handed to a window, whichever
/// of its windows has the keys: the main window, a sheet, a popover, a file
/// dialog. It says what is open and focused, asks the keys' model where the
/// key goes, and either keeps the key or passes it on untouched. While a
/// menu is open the system hands the app no keys at all, which is §9's
/// second step as macOS has it.
@MainActor
final class KeyTap {
    private let keys: KeysModel
    private unowned let window: MainWindow
    private unowned let regions: ShowWindowView
    private var monitor: Any?
    /// The window that has the keys; a test names it, since nothing it builds is on a screen.
    var keyWindow: () -> NSWindow? = { NSApplication.shared.keyWindow }

    init(keys: KeysModel, window: MainWindow, regions: ShowWindowView) {
        self.keys = keys
        self.window = window
        self.regions = regions
    }

    /// Starts reading the app's keys.
    func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let taken = MainActor.assumeIsolated { self?.take(event) ?? false }
            return taken ? nil : event
        }
    }

    func remove() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    /// The press as §9 names it: the key's position, ⌃ ⌥ ⇧ ⌘, and whether a
    /// held key is repeating. Caps Lock and Fn are left out (Area 13 reading).
    static func stroke(_ event: NSEvent) -> KeyStroke {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return KeyStroke(code: event.keyCode, ctrl: flags.contains(.control), alt: flags.contains(.option), shift: flags.contains(.shift),
                         command: flags.contains(.command), isRepeat: event.isARepeat)
    }

    /// The field the cursor is in, when it is one the app made.
    static func field(_ responder: NSResponder?) -> (any KeyField)? {
        guard let editor = responder as? NSText, editor.isFieldEditor else { return nil }
        return editor.delegate as? any KeyField
    }

    /// The kind of text field that has the focus, or nil with none. "A text
    /// field is any control that takes typing: text and search fields, date
    /// pickers, steppers' fields, combo boxes and the key recorder."
    static func fieldKind(_ responder: NSResponder?) -> FieldKind? {
        if let field = field(responder) { return field.fieldKind }
        if responder is NSText || responder is NSDatePicker { return .other }
        return nil
    }

    private static func isList(_ responder: NSResponder?) -> Bool {
        responder is NSTableView || responder is NSCollectionView || responder is NSBrowser || responder is any KeyList
    }

    /// What is open or has the focus now.
    func context() -> KeyContext {
        let key = keyWindow()
        let responder = (key ?? window).firstResponder
        // Another window of the app's has the keys: a sheet, a popover, a file dialog or a panel.
        let elsewhere = key != nil && key !== window
        var context = KeyContext()
        context.field = Self.fieldKind(responder)
        context.sheet = elsewhere || window.attachedSheet != nil || regions.hasPopover
        context.dialog = key is NSSavePanel || window.attachedSheet is NSSavePanel || (context.sheet && Self.isList(responder))
        context.overlay = regions.isShowingKeys
        return context
    }

    /// Reads one key-down. Says whether the app took it; a key it didn't take goes on as if the app had never looked.
    func take(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return false }
        let responder = (keyWindow() ?? window).firstResponder
        // An input method composing a character has every key until it is done.
        if let editor = responder as? NSTextView, editor.hasMarkedText() { return false }
        let route = keys.press(Self.stroke(event), context: context())
        switch route {
        case .passed:
            return false
        case .fire, .digit, .completeDigits, .nothing, .escape(.digits):
            return true
        case .escape(.overlay):
            regions.hideKeys()
            return true
        case .escape(.field):
            guard let field = Self.field(responder) else { return false }
            field.escape()
            return true
        }
    }
}
