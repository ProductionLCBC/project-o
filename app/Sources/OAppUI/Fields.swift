// OAppUI — Spec 10 §9, "A text field": the fields the app makes, each knowing its kind.

import AppKit
import OApp

/// Spec 10 §9, "A text field" — a field the app made says which kind it is,
/// so plain Escape does in it what §9 says for that kind and the top bar can
/// say what its keys do (§8). A field that isn't one of these, in a sheet of
/// the system's or a file dialog, keeps its own Escape.
@MainActor
protocol KeyField: NSTextField {
    var fieldKind: FieldKind { get }
    /// Called after Escape has done what the kind says, for whatever else the field's owner shows.
    var onEscape: (() -> Void)? { get }
}

extension KeyField {
    /// Plain Escape: "In a field that edits ..., plain Escape discards what
    /// was typed and leaves the field; in any other field it leaves the
    /// field and keeps the text, apart from the go-to field, which it clears."
    func escape() {
        switch fieldKind.escape {
        case .discardAndLeave:
            // Puts back what the field held when the cursor went into it.
            abortEditing()
        case .clearAndLeave:
            abortEditing()
            stringValue = ""
        case .leave:
            // What was typed is the field's when the cursor leaves it.
            break
        }
        handKeysBack()
        onEscape?()
    }

    /// "hands the focus back to the window ..., so the next Space sends `next`."
    func handKeysBack() {
        if let window = window as? MainWindow { window.handKeysBack() } else { window?.makeFirstResponder(nil) }
    }
}

/// A one-line field of the window's: the go-to field, a popup or timer row's, the command bar.
@MainActor
class ShowField: NSTextField, KeyField {
    let fieldKind: FieldKind
    var onEscape: (() -> Void)?

    init(kind: FieldKind) {
        fieldKind = kind
        super.init(frame: .zero)
        // The field acts on Return and on nothing else: leaving it, by Escape, Tab or a click elsewhere, sends nothing.
        (cell as? NSTextFieldCell)?.sendsActionOnEndEditing = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }
}

/// A search field: "Search fields and the command bar keep the focus until
/// Escape or a click elsewhere", and Escape "leaves the field and keeps the text".
@MainActor
final class ShowSearchField: NSSearchField, KeyField {
    let fieldKind = FieldKind.search
    var onEscape: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }
}
