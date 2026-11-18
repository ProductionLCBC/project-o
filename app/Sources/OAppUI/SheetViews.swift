// OAppUI — Spec 10 §14, the sheets a restore is chosen from.

import AppKit
import OApp
import OCore

/// A sheet of things to choose one of: a list's kept versions, the
/// snapshots (Spec 10 §14). Each row says what it is and has the button that
/// acts on it; Close, or Escape, closes the sheet and does nothing.
@MainActor
final class PickerSheetView: Surface {
    struct Row {
        var title: String
        var detail: String
        var isEnabled = true
        var reason: String?
        var act: () -> Void
    }

    static let width: CGFloat = 520
    let heading = Kit.content(Kit.label(size: 14, weight: .semibold))
    let note = Kit.label(size: 12)
    let empty = Kit.label(size: 12.5)
    /// What the sheet says while a restore runs, or when one was refused.
    let status = Kit.label(size: 12, weight: .medium)
    let close = FlatButton(Strings.text(.sheetClose), style: .plain)
    private let scroll = NSScrollView()
    private let document = Surface()
    private(set) var titles: [NSTextField] = []
    private(set) var details: [NSTextField] = []
    private(set) var buttons: [FlatButton] = []
    var onClose: (() -> Void)?

    init(heading text: String, note noteText: String?, empty emptyText: String, button: String, rows: [Row]) {
        super.init(frame: .zero)
        fill = Palette.panel
        heading.stringValue = text
        note.stringValue = noteText ?? ""
        note.isHidden = noteText == nil
        note.textColor = Palette.browsing
        note.maximumNumberOfLines = 2
        note.lineBreakMode = .byWordWrapping
        note.cell?.wraps = true
        empty.stringValue = emptyText
        empty.textColor = Palette.dimText
        empty.isHidden = !rows.isEmpty
        status.textColor = Palette.dimText
        status.maximumNumberOfLines = 2
        status.lineBreakMode = .byWordWrapping
        status.cell?.wraps = true
        status.isHidden = true
        close.onPress = { [weak self] in self?.onClose?() }
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.documentView = document
        for view in [heading, note, empty, scroll, status, close] as [NSView] { addSubview(view) }
        for row in rows {
            let title = Kit.content(Kit.label(row.title, size: 12.5, weight: .medium))
            let detail = Kit.content(Kit.label(row.detail, size: 11.5, color: Palette.dimText))
            let act = FlatButton(button, style: .plain)
            act.isEnabled = row.isEnabled
            act.reason = row.reason
            act.setAccessibilityLabel(button + " " + row.title)
            act.onPress = row.act
            for view in [title, detail, act] as [NSView] { document.addSubview(view) }
            titles.append(title)
            details.append(detail)
            buttons.append(act)
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(text)
        let inner = Self.width - 40
        let noteHeight = noteText == nil ? 0 : ceil(note.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: inner, height: 100)).height ?? 16) + 8
        let listHeight = rows.isEmpty ? 30 : min(CGFloat(rows.count) * 46, 322)
        frame.size = NSSize(width: Self.width, height: 20 + 22 + 10 + noteHeight + listHeight + 14 + 34 + 18)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// Says something at the sheet's foot: that a restore is running, or why one was refused.
    func show(status text: String?, isProblem: Bool = false) {
        status.stringValue = text ?? ""
        status.isHidden = text == nil
        status.textColor = isProblem ? Palette.live : Palette.dimText
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let inner = bounds.width - 40
        var y: CGFloat = 20
        heading.frame = NSRect(x: 20, y: y, width: inner, height: 20)
        y += 32
        if !note.isHidden {
            let height = ceil(note.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: inner, height: 100)).height ?? 16)
            note.frame = NSRect(x: 20, y: y, width: inner, height: height)
            y += height + 8
        }
        let closeWidth = max(72, close.fitting.width)
        close.frame = NSRect(x: bounds.width - 20 - closeWidth, y: bounds.height - 18 - 26, width: closeWidth, height: 26)
        status.frame = NSRect(x: 20, y: close.frame.minY - 2, width: max(0, close.frame.minX - 32), height: 30)
        let listHeight = max(0, close.frame.minY - 18 - y)
        scroll.frame = NSRect(x: 20, y: y, width: inner, height: listHeight)
        empty.frame = NSRect(x: 20, y: y + 4, width: inner, height: 18)
        var rowY: CGFloat = 0
        for index in titles.indices {
            let buttonWidth = max(84, buttons[index].fitting.width)
            buttons[index].frame = NSRect(x: inner - buttonWidth - 2, y: rowY + 8, width: buttonWidth, height: 26)
            titles[index].frame = NSRect(x: 0, y: rowY + 4, width: inner - buttonWidth - 14, height: 17)
            details[index].frame = NSRect(x: 0, y: rowY + 23, width: inner - buttonWidth - 14, height: 15)
            rowY += 46
        }
        document.frame = NSRect(x: 0, y: 0, width: inner, height: max(rowY, listHeight))
    }

    /// Escape closes it: "A button that deletes, restores or quits is never a sheet's default" (Spec 10 §9).
    override func cancelOperation(_ sender: Any?) { onClose?() }
}

/// The sheets of Spec 10 §14, each built over the model's flow for it.
@MainActor
enum Sheets {
    /// "Restore a Version… on a list opens a sheet of its kept versions ...,
    /// newest first, each with when it was kept, its title and how many cues
    /// it had."
    static func versions(title: String, versions: [KeptVersion], onAir: Bool, cannot: CannotEdit?, restore: @escaping (KeptVersion) -> Void) -> PickerSheetView {
        let rows = versions.sorted { $0.version > $1.version }.map { version in
            PickerSheetView.Row(title: Strings.text(.versionsRow, version.version, EditWording.when(version.keptAt)),
                                detail: Strings.text(.versionsDetail, version.title, Strings.counted(.gridCues, version.cues)),
                                isEnabled: cannot == nil, reason: cannot.map(EditWording.reason)) { restore(version) }
        }
        return PickerSheetView(heading: Strings.text(.versionsHeading, title), note: onAir && !versions.isEmpty ? Strings.text(.versionsOnAir) : nil,
                               empty: Strings.text(.versionsEmpty), button: Strings.text(.versionsRestore), rows: rows)
    }
}
