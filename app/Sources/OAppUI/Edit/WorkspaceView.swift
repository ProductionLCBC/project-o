// OAppUI — Spec 11 §2 and §4, the workspace: the page's editing space; on the Cues page, the cue grid under its header.

import AppKit
import OApp
import OCore

/// Spec 11 §2 — "Workspace: the page's editing space; on the Cues page, the
/// cue grid (§4)". Spec 11 §4, "The list" — "The workspace's header names
/// the list, its cue count and its version, and holds the zoom slider
/// (below), Open in Text Editor (§5) and Renumber…".
@MainActor
final class WorkspaceView: PanelView {
    private let model: ShowModel
    /// "its cue count and its version", then why the list is read-only, or that another shares its number.
    let meta = Kit.content(Kit.label(size: 12))
    let zoom = NSSlider(value: CueGridZoom.standard, minValue: CueGridZoom.range.lowerBound, maxValue: CueGridZoom.range.upperBound, target: nil, action: nil)
    let openText = FlatButton(Strings.text(.editCuesOpenText), style: .plain)
    let renumber = FlatButton(Strings.text(.editCuesRenumber), style: .plain)
    /// What stands in the workspace when there is no grid to show: no list chosen, a page not built yet, a list deleted.
    let message = Kit.label(size: 13)
    /// "A page whose object is deleted under it says "Deleted", with Undo while that delete is the history's top group."
    let undo = FlatButton(Strings.text(.menuUndo), style: .plain)
    let grid: CueGridView
    var machineRoot: URL? {
        didSet { grid.machineRoot = machineRoot }
    }
    /// The window, which opens the popovers the page's controls ask for.
    weak var host: ShowWindowView? {
        didSet { grid.host = host }
    }

    init(model: ShowModel) {
        self.model = model
        grid = CueGridView(model: model)
        super.init(title: "")
        Kit.content(title)
        meta.textColor = Palette.dimText
        zoom.controlSize = .small
        zoom.target = self
        zoom.action = #selector(zoomed)
        zoom.isContinuous = true
        zoom.setAccessibilityLabel(Strings.text(.editCuesZoom))
        zoom.toolTip = Strings.text(.editCuesZoom)
        // "Open in Text Editor ... stays disabled until it lands" (Spec 11 §11).
        openText.isEnabled = false
        openText.reason = Strings.text(.unavailableLater)
        openText.fontSize = 11.5
        renumber.fontSize = 11.5
        renumber.onPress = { [weak self] in self?.askRenumber() }
        message.textColor = Palette.faintText
        message.alignment = .center
        message.maximumNumberOfLines = 2
        message.lineBreakMode = .byWordWrapping
        message.cell?.wraps = true
        undo.onPress = { [weak model] in model?.undo() }
        for view in [meta, zoom, openText, renumber, grid, message, undo] as [NSView] { addSubview(view) }
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    @objc private func zoomed() {
        model.editing.zoom(to: zoom.doubleValue)
    }

    /// "Renumber… (`edit list N renumber M`, or Swap for a taken number)": a small panel with the number.
    private func askRenumber() {
        guard let list = model.editing.list else { return }
        let panel = PromptView(heading: Strings.text(.editCuesRenumber), width: 240)
        let field = panel.text(Strings.text(.editCuesRenumber), String(list.number), placeholder: String(list.number))
        panel.onSave = { [weak model] in
            guard let model, let number = Int(field.stringValue.trimmingCharacters(in: .whitespaces)), number > 0 else { return nil }
            // A list that shares its number is read-only here, and the offer is to renumber the other, which comes first.
            if model.editing.cannotEdit == .renumberToEdit { model.editing.renumberOther(to: number) } else { model.editing.renumber(to: number) }
            return nil
        }
        panel.finish()
        host?.present(panel, at: renumber)
    }

    func refresh() {
        let editing = model.editing
        let onCues = editing.page == .cues
        let deleted = onCues && editing.isListDeleted
        let hasList = onCues && editing.listUuid != nil && !deleted
        undo.isHidden = !(deleted && editing.canUndoDelete)
        title.stringValue = hasList ? editing.grid.title : EditModeWording.page(editing.page)
        title.isHidden = false
        var words: [String] = []
        if hasList, let version = editing.grid.version { words.append(EditModeWording.meta(cues: editing.grid.cueCount, version: version)) }
        // "A page that is read-only says why in its workspace's header (§1)."
        let cannot = hasList ? editing.cannotEdit : nil
        if let cannot { words.append(EditModeWording.readOnly(cannot)) }
        if hasList, cannot == nil, let number = editing.grid.listNumber, sharesNumber(number) { words.append(EditModeWording.sharedNumber(number)) }
        meta.stringValue = words.joined(separator: " · ")
        meta.textColor = cannot == nil ? Palette.dimText : Palette.browsing
        for view in [zoom, openText, renumber] as [NSView] { view.isHidden = !hasList }
        zoom.doubleValue = model.settings.gridZoom
        zoom.setAccessibilityValueDescription(Strings.text(.editCuesZoomValue, Int(model.settings.gridZoom)))
        // "the other's opens read-only, offering to renumber the first".
        let offersOther = cannot == .renumberToEdit
        renumber.title = Strings.text(offersOther ? .editCuesRenumberOther : .editCuesRenumber)
        renumber.isEnabled = cannot == nil || offersOther
        renumber.reason = cannot.map(EditModeWording.readOnly)
        grid.isHidden = !hasList
        if hasList {
            grid.refresh()
            // "An empty list shows, with its + header, "No cues yet. Add one with +, or paste the song's text in the text editor"".
            message.stringValue = editing.grid.cueCount == 0 ? Strings.text(.editCuesEmpty) : ""
        } else if deleted {
            message.stringValue = Strings.text(.editDeleted)
        } else {
            message.stringValue = onCues ? Strings.text(.editCuesNoList) : Strings.text(.editPageLater)
        }
        message.isHidden = message.stringValue.isEmpty
        needsLayout = true
    }

    /// Whether another master has this list's number: "that list's page says "Another list shares number 57"".
    private func sharesNumber(_ number: Int) -> Bool {
        (model.store.catalog?.lists.filter { $0.number == number && !$0.local }.count ?? 0) > 1
    }

    override func layout() {
        super.layout()
        let h = Self.headerHeight
        var right = bounds.width - 12
        for button in [renumber, openText] where !button.isHidden {
            let size = button.fitting
            button.frame = NSRect(x: right - size.width, y: (h - 24) / 2, width: size.width, height: 24)
            right -= size.width + 8
        }
        if !zoom.isHidden {
            zoom.frame = NSRect(x: right - 96, y: (h - 18) / 2, width: 96, height: 18)
            right -= 96 + 12
        }
        let titleWidth = min(Kit.width(of: title), max(0, right - 12 - 40))
        title.frame = NSRect(x: 12, y: (h - 16) / 2, width: titleWidth, height: 16)
        meta.frame = NSRect(x: title.frame.maxX + 10, y: (h - 16) / 2, width: max(0, right - title.frame.maxX - 16), height: 16)
        grid.frame = body
        let width = min(360, bounds.width - 40)
        // Under the grid's band and headers, where an empty list has nothing.
        let top = grid.isHidden ? body.midY - 18 : body.minY + CGFloat(CueGridGeometry.band + grid.geometry.header) + 28
        message.frame = NSRect(x: (bounds.width - width) / 2, y: top, width: width, height: 36)
        let undoWidth = undo.fitting.width
        undo.frame = NSRect(x: (bounds.width - undoWidth) / 2, y: top + 30, width: undoWidth, height: 24)
    }
}
