// OAppUI — Spec 11 §8 and G-32, the preset editor: the layout tabs, the canvas and the sample in the workspace, and
// the preset with Used by, the boxes, the box's properties and its text style in the inspector's four columns.

import AppKit
import OApp
import OCore

/// Spec 11 §8 and G-32 — the Presets page's workspace: "the layout tabs, the canvas and the sample".
@MainActor
final class PresetWorkspaceView: NSView {
    private let model: ShowModel
    private(set) var tabs: [FlatButton] = []
    let otherHeading = Kit.label(Strings.text(.editPresetOtherStacks), size: 11, color: Palette.faintText)
    /// Under the tabs: what the tab draws, and what can be done about it.
    let layoutNote = Kit.label(size: 11.5, color: Palette.dimText)
    let copyFromAny = FlatButton(Strings.text(.editPresetCopyFromAny), style: .plain)
    let removeLayout = FlatButton(Strings.text(.editPresetRemoveLayout), style: .plain)
    let canvas: LayoutCanvasView
    let sampleName = Kit.label(Strings.text(.editPresetSample), size: 11.5, color: Palette.dimText)
    let sampleKind = SegmentedView([Strings.text(.editPresetSampleText), Strings.text(.editPresetSampleMedia), Strings.text(.editPresetSampleEmpty)], small: true)
    let sampleText = EditField()
    let sampleMedia = NSPopUpButton(frame: .zero, pullsDown: false)
    let sampleSource = Kit.label(size: 11, color: Palette.faintText)
    private var tabKeys: [LayoutKey] = []
    var machineRoot: URL? { didSet { canvas.machineRoot = machineRoot } }

    override var isFlipped: Bool { true }

    init(model: ShowModel) {
        self.model = model
        canvas = LayoutCanvasView(model: model)
        super.init(frame: .zero)
        for button in [copyFromAny, removeLayout] { button.fontSize = 11.5 }
        copyFromAny.onPress = { [weak model] in model?.editing.copyLayoutFromAny() }
        removeLayout.onPress = { [weak model] in model?.editing.removeStackLayout() }
        sampleKind.setAccessibilityLabel(Strings.text(.editPresetSample))
        sampleKind.onSelect = { [weak model] index in
            model?.editing.setSample(kind: [LayoutSample.Kind.text, .media, .empty][min(2, max(0, index))])
        }
        sampleText.setAccessibilityLabel(Strings.text(.editPresetSampleField))
        sampleText.onCommit = { [weak model] text in model?.editing.setSampleText(text) }
        sampleMedia.font = .systemFont(ofSize: 12)
        sampleMedia.target = self
        sampleMedia.action = #selector(pickedMedia)
        sampleMedia.setAccessibilityLabel(Strings.text(.editPresetSampleMedia))
        for view in [otherHeading, layoutNote, copyFromAny, removeLayout, canvas, sampleName, sampleKind, sampleText, sampleMedia, sampleSource] as [NSView] {
            addSubview(view)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    @objc private func pickedMedia() {
        model.editing.setSampleMedia(sampleMedia.selectedItem?.representedObject as? String)
    }

    /// "Any stack: 1 Main, 3 Side"; "2 Confidence"; with the live dot on those an output shows.
    static func title(of tab: LayoutTab) -> String {
        let words: String
        switch tab.key {
        case .any:
            words = tab.stacks.isEmpty ? Strings.text(.editPresetAnyTabNone)
                : Strings.text(.editPresetAnyTab, tab.stacks.map { EditModel.name(of: $0) }.joined(separator: ", "))
        case .stack:
            words = tab.stacks.first.map { EditModel.name(of: $0) } ?? tab.key.string
        }
        return tab.isLive ? "● " + words : words
    }

    func refresh() {
        let editing = model.editing
        let page = editing.presetPage
        // The tabs: `*`, one per stack here, then the stacks this Mac doesn't have.
        let keys = page.tabs.map(\.key) + page.otherStacks.map { LayoutKey.stack($0) }
        let titles = page.tabs.map { Self.title(of: $0) } + page.otherStacks.map { Strings.text(.editPresetOtherTab, $0) }
        while tabs.count < keys.count {
            let button = FlatButton("", style: .bare)
            button.fontSize = 12
            addSubview(button)
            tabs.append(button)
        }
        while tabs.count > keys.count { tabs.removeLast().removeFromSuperview() }
        tabKeys = keys
        for (index, (button, key)) in zip(tabs, keys).enumerated() {
            button.title = titles[index]
            button.isOn = key == page.tab
            button.onPress = { [weak model] in model?.editing.selectTab(key) }
            button.setAccessibilityLabel(titles[index].replacingOccurrences(of: "● ", with: ""))
        }
        otherHeading.isHidden = page.otherStacks.isEmpty
        // Under the tabs.
        switch page.tab {
        case .any:
            let stack = editing.canvasStack.flatMap { number in model.store.catalog?.stacks.first { $0.number == number } }
            layoutNote.stringValue = stack.map { Strings.text(.editPresetDrawnAt) + " " + EditModel.name(of: $0) } ?? ""
            copyFromAny.isHidden = true
            removeLayout.isHidden = true
        case .stack:
            layoutNote.stringValue = page.ownsLayout ? "" : Strings.text(.editPresetUsesAny)
            copyFromAny.isHidden = page.ownsLayout
            removeLayout.isHidden = !page.ownsLayout
        }
        canvas.refresh()
        // The sample.
        let sample = editing.layoutSample
        sampleKind.selected = LayoutSample.Kind.allCases.firstIndex(of: sample.kind)
        sampleText.isHidden = sample.kind != .text
        sampleMedia.isHidden = sample.kind != .media
        sampleText.show(editing.presetState.sampleText ?? "", placeholder: (sample.fields ?? LayoutSample.builtIn(verse: 0))["body"]?
            .components(separatedBy: "\n").first ?? "", subject: AnyHashable(sample.cue ?? "built-in"))
        switch sample.kind {
        case .text:
            if let cue = sample.cue, let list = editing.list, let index = list.cues.firstIndex(where: { $0.uuid.uuidString.lowercased() == cue }) {
                sampleSource.stringValue = Strings.text(.editPresetSampleFromCue, index + 1, editing.grid.title)
                _ = list
            } else {
                sampleSource.stringValue = Strings.text(.editPresetSampleBuiltIn)
            }
        case .media:
            let items = model.store.media.filter { [.video, .image].contains($0.entry.kind) && $0.presence == "ok" }
            // The engine's test pattern first, then the pool's videos and images.
            let titles = [Strings.text(.editPresetSamplePattern)] + items.map { ($0.entry.path as NSString).lastPathComponent }
            if sampleMedia.itemTitles != titles {
                sampleMedia.removeAllItems()
                for (index, title) in titles.enumerated() {
                    sampleMedia.addItem(withTitle: title)
                    sampleMedia.lastItem?.representedObject = index == 0 ? nil : items[index - 1].entry.id
                }
            }
            sampleMedia.selectItem(at: (items.firstIndex { $0.entry.id == sample.media }).map { $0 + 1 } ?? 0)
            sampleSource.stringValue = ""
        case .empty:
            sampleSource.stringValue = ""
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let w = bounds.width
        guard w > 120 else { return }
        // The tabs, in a row that wraps.
        var x: CGFloat = 10
        var y: CGFloat = 10
        for (index, button) in tabs.enumerated() {
            if case .stack(let number) = tabKeys[index], model.editing.presetPage.otherStacks.contains(number),
               index == model.editing.presetPage.tabs.count {
                let width = Kit.width(of: otherHeading)
                if x + width > w - 10 { x = 10; y += 28 }
                otherHeading.frame = NSRect(x: x + 6, y: y + 5, width: width, height: 14)
                x += width + 12
            }
            let width = button.fitting.width
            if x + width > w - 10, x > 10 {
                x = 10
                y += 28
            }
            button.frame = NSRect(x: x, y: y, width: width, height: 24)
            x += width + 4
        }
        y += 30
        // What the tab draws.
        let noteWidth = min(Kit.width(of: layoutNote), w - 28)
        layoutNote.frame = NSRect(x: 14, y: y + 4, width: noteWidth, height: 16)
        var buttonX = noteWidth > 0 ? layoutNote.frame.maxX + 10 : 14
        for button in [copyFromAny, removeLayout] where !button.isHidden {
            let width = button.fitting.width
            button.frame = NSRect(x: buttonX, y: y, width: width, height: 24)
            buttonX += width + 8
        }
        y += 30
        // The sample along the bottom; the canvas between.
        let sampleY = bounds.height - 40
        sampleName.frame = NSRect(x: 14, y: sampleY + 5, width: Kit.width(of: sampleName), height: 16)
        let kindSize = sampleKind.fitting
        sampleKind.frame = NSRect(x: sampleName.frame.maxX + 8, y: sampleY + (26 - kindSize.height) / 2, width: kindSize.width, height: kindSize.height)
        let fieldX = sampleKind.frame.maxX + 10
        let sourceWidth = min(260, Kit.width(of: sampleSource))
        let fieldWidth = max(80, w - fieldX - sourceWidth - 28)
        sampleText.frame = NSRect(x: fieldX, y: sampleY, width: fieldWidth, height: 26)
        sampleMedia.frame = NSRect(x: fieldX, y: sampleY, width: min(320, fieldWidth), height: 26)
        let sourceX = (sampleText.isHidden ? sampleMedia.frame.maxX : sampleText.frame.maxX) + 10
        sampleSource.frame = NSRect(x: sourceX, y: sampleY + 5, width: max(0, w - sourceX - 14), height: 16)
        canvas.frame = NSRect(x: 0, y: y, width: w, height: max(0, sampleY - y - 6))
    }
}

/// Spec 11 §8 and G-32 — the Presets page's inspector: "the box's properties, its text style, the preset with Used by",
/// in three columns. The boxes themselves are in the page's list (PageListView).
@MainActor
final class PresetInspectorView: PanelView {
    private let model: ShowModel
    let notice = Kit.content(Kit.label(size: 11.5, weight: .medium))
    weak var host: ShowWindowView?
    // The preset and Used by.
    let presetColumn = FormColumn()
    let presetHeading = Kit.heading(Strings.text(.editPresetHeading))
    let number = EditField()
    let builtInNote = Kit.label(Strings.text(.editPresetBuiltIn), size: 11, color: Palette.faintText)
    let label = EditField()
    let usedHeading = Kit.heading(Strings.text(.editPresetUsedBy))
    let usedBy = Kit.label(size: 11.5, color: Palette.text)
    // The box's properties.
    let propertyColumn = FormColumn()
    let propertyHeading = Kit.heading(Strings.text(.editPresetBox))
    let selectNote = Kit.label(Strings.text(.editPresetSelectBox), size: 11.5, color: Palette.faintText)
    let binding = SegmentedView([Strings.text(.editPresetPixels), Strings.text(.editPresetField), Strings.text(.editPresetStatic)], small: true)
    let fieldName = EditField()
    let staticText = EditField()
    let variables = FlatButton(Strings.text(.editPresetVariables), style: .plain)
    /// Spec 11 §8, "Frame" (G-34) — the reference point the X and Y fields read.
    let anchor: AnchorPicker
    let frameX = EditField()
    let frameY = EditField()
    let frameW = EditField()
    let frameH = EditField()
    /// "X", "Y", "W" and "H" over the frame's fields, as percentages of the stack.
    let frameLetters: [NSTextField] = [StringKey.editPresetX, .editPresetY, .editPresetW, .editPresetH].map { key in
        let letter = Kit.label(Strings.text(key) + " %", size: 10, color: Palette.faintText)
        letter.setAccessibilityElement(false)
        return letter
    }
    let pixelFit = ChoicePopUp(label: Strings.text(.editPresetFit))
    let textFit = SegmentedView([Strings.text(.editPresetShrink), Strings.text(.editPresetMaxLines)], small: true)
    let fitNumber = EditField()
    /// The fit number's name: Min size while shrinking, Lines at most.
    private var fitNumberName: NSTextField?
    let transition = ChoicePopUp(label: Strings.text(.editPresetTransition))
    let transitionMs = EditField()
    let onVariable = ChoiceBox(Strings.text(.editPresetOnVariable))
    let fallback = ChoiceBox(Strings.text(.editPresetFallback))
    let offset = SegmentedView(["0", "+1", "+2", "+3"], small: true)
    let grade = ChoicePopUp(label: Strings.text(.editPresetGrade))
    // The text style.
    let styleColumn = FormColumn()
    let styleHeading = Kit.heading(Strings.text(.editPresetStyle))
    let noStyle = Kit.label(Strings.text(.editPresetNoStyle), size: 11.5, color: Palette.faintText)
    let fromStyle = Kit.label(size: 11.5, color: Palette.dimText)
    let applyStyle = FlatButton(Strings.text(.editPresetApplyStyle), style: .plain)
    let reapply = FlatButton(Strings.text(.editPresetReapply), style: .plain)
    let saveAsStyle = FlatButton(Strings.text(.editPresetSaveAsStyle), style: .plain)
    let font = FlatButton("", style: .plain)
    let size = EditField()
    let unit = SegmentedView([Strings.text(.editPresetPt), Strings.text(.editPresetPercent)], small: true)
    let weight = EditField()
    let color = FormColorWell(label: Strings.text(.editPresetColor))
    let align = SegmentedView([Strings.text(.editPresetLeft), Strings.text(.editPresetCenter), Strings.text(.editPresetRight)], small: true)
    let vertical = SegmentedView([Strings.text(.editPresetTop), Strings.text(.editPresetMiddle), Strings.text(.editPresetBottom)], small: true)
    let lineSpacing = EditField()
    let letterSpacing = EditField()
    let outlineSize = EditField()
    let outlineColor = FormColorWell(label: Strings.text(.editPresetOutline))
    let shadowX = EditField()
    let shadowY = EditField()
    let shadowBlur = EditField()
    let shadowColor = FormColorWell(label: Strings.text(.editPresetShadow))
    let allCaps = ChoiceBox(Strings.text(.editPresetAllCaps))
    private var fontsShown = 0
    /// The field committed last: outlined in red while the engine's refusal of it stands.
    private weak var lastField: EditField?

    static let fieldNames = ["body", "title", "copyright", "reference"]

    init(model: ShowModel) {
        self.model = model
        anchor = AnchorPicker(model: model)
        super.init(title: "")
        notice.isHidden = true
        addSubview(notice)
        buildPresetColumn()
        buildPropertyColumn()
        buildStyleColumn()
        for column in [propertyColumn, styleColumn, presetColumn] { addSubview(column.scroll) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// A field that sends a number, parsed; anything else is put back.
    private func numeric(_ field: EditField, _ label: String, _ send: @escaping (Double) -> Void) {
        field.setAccessibilityLabel(label)
        field.onCommit = { [weak self, weak field] text in
            guard let self, let field else { return }
            self.lastField = field
            if let value = FormNumber.value(text) { send(value) } else {
                field.putBack()
                self.refresh()
            }
        }
    }

    private func buildPresetColumn() {
        let c = presetColumn
        c.wide(presetHeading, height: 14)
        number.setAccessibilityLabel(Strings.text(.editPresetNumber))
        number.onCommit = { [weak self] text in
            guard let self else { return }
            self.lastField = self.number
            if let value = Int(text.trimmingCharacters(in: .whitespaces)) { self.model.editing.renumberPreset(to: value) } else { self.number.putBack() }
            self.refresh()
        }
        c.row(Strings.text(.editPresetNumber), [number], widths: [70], height: 26)
        builtInNote.maximumNumberOfLines = 2
        builtInNote.lineBreakMode = .byWordWrapping
        builtInNote.cell?.wraps = true
        c.wide(builtInNote, height: 30)
        label.setAccessibilityLabel(Strings.text(.editFieldLabel))
        label.onCommit = { [weak self] text in
            self?.lastField = self?.label
            self?.model.editing.setPreset("label", .string(text))
        }
        c.row(Strings.text(.editFieldLabel), [label], height: 26)
        c.wide(usedHeading, height: 14)
        usedBy.maximumNumberOfLines = 0
        usedBy.lineBreakMode = .byWordWrapping
        usedBy.cell?.wraps = true
        c.wide(usedBy, height: 18)
    }

    private func buildPropertyColumn() {
        let c = propertyColumn
        c.wide(propertyHeading, height: 14)
        selectNote.maximumNumberOfLines = 2
        selectNote.lineBreakMode = .byWordWrapping
        selectNote.cell?.wraps = true
        c.wide(selectNote, height: 30)
        binding.setAccessibilityLabel(Strings.text(.editPresetBinding))
        binding.onSelect = { [weak self] index in
            guard let self, let box = self.model.editing.selectedBox else { return }
            switch index {
            case 0: self.model.editing.setBinding(.pixels)
            case 1:
                if case .field = box.binding.kind { return }
                self.model.editing.setBinding(.field(name: "body"))
            default:
                if case .static = box.binding.kind { return }
                self.model.editing.setBinding(.static(text: ""))
            }
        }
        c.row(Strings.text(.editPresetBinding), [binding], height: 24)
        fieldName.setAccessibilityLabel(Strings.text(.editPresetFieldName))
        fieldName.onCommit = { [weak self] text in
            let name = text.trimmingCharacters(in: .whitespaces)
            self?.lastField = self?.fieldName
            guard !name.isEmpty else { return }
            self?.model.editing.setBinding(.field(name: name))
        }
        c.row(Strings.text(.editPresetFieldName), [fieldName], height: 26)
        staticText.setAccessibilityLabel(Strings.text(.editPresetStaticText))
        staticText.onCommit = { [weak self] text in
            self?.lastField = self?.staticText
            self?.model.editing.setBinding(.static(text: text))
        }
        // "Static text is a field with a Variables ▸ menu that inserts Spec 6 §5's names ..., sent on commit."
        variables.fontSize = 11.5
        variables.setAccessibilityLabel(Strings.text(.editPresetVariables))
        c.row(Strings.text(.editPresetStaticText), [staticText], height: 26)
        c.row("", [variables], widths: [110], height: 24)
        // "Frame: x, y, width and height as percentages of the stack".
        for (field, key, name) in [(frameX, "x", StringKey.editPresetX), (frameY, "y", .editPresetY), (frameW, "w", .editPresetW), (frameH, "h", .editPresetH)] {
            numeric(field, Strings.text(.editPresetFrame) + " " + Strings.text(name)) { [weak self] percent in
                guard let self, let index = self.model.editing.presetState.box, let box = self.model.editing.selectedBox else { return }
                let anchor = self.model.settings.boxAnchor
                let value = percent / 100
                let frame: Frame
                switch key {
                case "x": frame = LayoutCanvasMath.typed(box.frame, anchor: anchor, x: value)
                case "y": frame = LayoutCanvasMath.typed(box.frame, anchor: anchor, y: value)
                case "w": frame = LayoutCanvasMath.typed(box.frame, anchor: anchor, w: value)
                default: frame = LayoutCanvasMath.typed(box.frame, anchor: anchor, h: value)
                }
                self.model.editing.setFrame(LayoutCanvasMath.kept(frame), of: index)
            }
            field.placeholderString = Strings.text(name)
            field.toolTip = Strings.text(.editPresetFrame) + " " + Strings.text(name) + " %"
        }
        // The reference point, then the four fields with their letters over them.
        c.row(Strings.text(.editPresetAnchor), [anchor], widths: [AnchorPicker.size], height: AnchorPicker.size)
        c.row("", frameLetters, height: 12)
        c.row(Strings.text(.editPresetFrame), [frameX, frameY, frameW, frameH], height: 26)
        pixelFit.onChoose = { [weak self] tag in
            let fits: [PixelFit] = [.fill, .fit, .stretch, .crop]
            guard fits.indices.contains(tag) else { return }
            self?.model.editing.setBox("fit", .string(fits[tag].rawValue))
        }
        textFit.setAccessibilityLabel(Strings.text(.editPresetFit))
        textFit.onSelect = { [weak self] index in self?.model.editing.setBox("fit.policy", .string(index == 1 ? "maxLines" : "shrinkToFit")) }
        numeric(fitNumber, Strings.text(.editPresetFit)) { [weak self] value in
            guard let self, case .text(let fit)? = self.model.editing.selectedBox?.fit else { return }
            if fit.policy == .maxLines { self.model.editing.setBox("fit.maxLines", .number(max(1, value.rounded()))) } else {
                self.model.editing.setBox("fit.minSize", .number(max(1, value)))
            }
        }
        c.row(Strings.text(.editPresetFit), [pixelFit, textFit], height: 24)
        fitNumberName = c.row(Strings.text(.editPresetMinSize), [fitNumber], widths: [64], height: 24)
        transition.onChoose = { [weak self] tag in self?.model.editing.setBox("transition.ref", .number(Double(tag))) }
        transitionMs.setAccessibilityLabel(Strings.text(.editPresetTransition) + " " + Strings.text(.editPresetMs))
        transitionMs.onCommit = { [weak self] text in
            guard let self else { return }
            self.lastField = self.transitionMs
            let typed = text.trimmingCharacters(in: .whitespaces)
            if typed.isEmpty { self.model.editing.setBox("transition.ms", .null) } else if let ms = Int(typed), ms >= 0 {
                self.model.editing.setBox("transition.ms", .number(Double(ms)))
            } else {
                self.transitionMs.putBack()
                self.refresh()
            }
        }
        c.row(Strings.text(.editPresetTransition), [transition, transitionMs], widths: [nil, 60], height: 24)
        onVariable.onToggle = { [weak self] on in self?.model.editing.setBox("transitionOnVariableChange", .bool(on)) }
        c.row(nil, [onVariable], height: 20)
        fallback.onToggle = { [weak self] on in self?.model.editing.setBox("fallback", .bool(on)) }
        c.row(nil, [fallback], height: 20)
        offset.setAccessibilityLabel(Strings.text(.editPresetOffset))
        offset.onSelect = { [weak self] index in self?.model.editing.setBox("offset", .number(Double(index))) }
        c.row(Strings.text(.editPresetOffset), [offset], height: 24)
        grade.onChoose = { [weak self] tag in self?.model.editing.setBox("grade", tag == 0 ? .null : .number(Double(tag))) }
        c.row(Strings.text(.editPresetGrade), [grade], height: 24)
    }

    private func buildStyleColumn() {
        let c = styleColumn
        c.wide(styleHeading, height: 14)
        c.wide(noStyle, height: 18)
        c.wide(fromStyle, height: 16)
        applyStyle.fontSize = 11
        reapply.fontSize = 11
        reapply.onPress = { [weak model] in model?.editing.reapplyStyle() }
        saveAsStyle.fontSize = 11
        saveAsStyle.onPress = { [weak self] in self?.askStyleName() }
        c.row(nil, [applyStyle, reapply, saveAsStyle], widths: [nil, nil, nil], height: 24)
        font.fontSize = 12
        font.leading = true
        font.setAccessibilityLabel(Strings.text(.editPresetFont))
        c.row(Strings.text(.editPresetFont), [font], height: 24)
        numeric(size, Strings.text(.editPresetSize)) { [weak self] value in self?.model.editing.setStyle("size.value", .number(max(1, value))) }
        unit.setAccessibilityLabel(Strings.text(.editPresetSize))
        unit.onSelect = { [weak self] index in self?.model.editing.setStyle("size.unit", .string(index == 1 ? "percent" : "pt")) }
        c.row(Strings.text(.editPresetSize), [size, unit], widths: [56, nil], height: 24)
        numeric(weight, Strings.text(.editPresetWeight)) { [weak self] value in self?.model.editing.setStyle("weight", .number(min(1000, max(1, value.rounded())))) }
        color.onChoose = { [weak self] picked in self?.model.editing.setStyle("color", FormColor.value(picked)) }
        c.row(Strings.text(.editPresetWeight), [weight], widths: [64], height: 24)
        c.row(Strings.text(.editPresetColor), [color], widths: [44], height: 24)
        align.setAccessibilityLabel(Strings.text(.editPresetAlign))
        align.onSelect = { [weak self] index in self?.model.editing.setStyle("alignment", .string(["left", "center", "right"][min(2, max(0, index))])) }
        c.row(Strings.text(.editPresetAlign), [align], height: 24)
        vertical.setAccessibilityLabel(Strings.text(.editPresetVertical))
        vertical.onSelect = { [weak self] index in self?.model.editing.setStyle("verticalAlignment", .string(["top", "center", "bottom"][min(2, max(0, index))])) }
        c.row(Strings.text(.editPresetVertical), [vertical], height: 24)
        numeric(lineSpacing, Strings.text(.editPresetLineSpacing)) { [weak self] value in self?.model.editing.setStyle("lineSpacing", .number(max(0.1, value))) }
        c.row(Strings.text(.editPresetLineSpacing), [lineSpacing], widths: [64], height: 24)
        numeric(letterSpacing, Strings.text(.editPresetLetterSpacing)) { [weak self] value in self?.model.editing.setStyle("letterSpacing", .number(value)) }
        c.row(Strings.text(.editPresetLetterSpacing), [letterSpacing], widths: [64], height: 24)
        numeric(outlineSize, Strings.text(.editPresetOutline)) { [weak self] value in self?.model.editing.setStyle("outline.width", .number(max(0, value))) }
        outlineColor.onChoose = { [weak self] picked in self?.model.editing.setStyle("outline.color", FormColor.value(picked)) }
        c.row(Strings.text(.editPresetOutline), [outlineSize, outlineColor], widths: [56, 44], height: 24)
        numeric(shadowX, Strings.text(.editPresetShadow) + " X") { [weak self] value in self?.model.editing.setStyle("shadow.x", .number(value)) }
        numeric(shadowY, Strings.text(.editPresetShadow) + " Y") { [weak self] value in self?.model.editing.setStyle("shadow.y", .number(value)) }
        numeric(shadowBlur, Strings.text(.editPresetBlur)) { [weak self] value in self?.model.editing.setStyle("shadow.blur", .number(max(0, value))) }
        shadowColor.onChoose = { [weak self] picked in self?.model.editing.setStyle("shadow.color", FormColor.value(picked)) }
        shadowX.placeholderString = "X"
        shadowY.placeholderString = "Y"
        shadowBlur.placeholderString = Strings.text(.editPresetBlur)
        c.row(Strings.text(.editPresetShadow), [shadowX, shadowY, shadowBlur, shadowColor], widths: [nil, nil, nil, 44], height: 24)
        allCaps.onToggle = { [weak self] on in self?.model.editing.setStyle("allCaps", .bool(on)) }
        c.row(nil, [allCaps], height: 20)
    }

    /// "Save as Style… asks for a name".
    private func askStyleName() {
        let panel = PromptView(heading: Strings.text(.editPresetSaveAsStyle), width: 260)
        let field = panel.text(Strings.text(.editPresetStyleName), "")
        panel.onSave = { [weak model] in
            model?.editing.saveAsStyle(named: field.stringValue.trimmingCharacters(in: .whitespaces))
            return nil
        }
        panel.finish()
        host?.present(panel, at: saveAsStyle)
    }

    // MARK: - Showing the model

    func refresh() {
        let editing = model.editing
        let page = editing.presetPage
        let catalog = model.store.catalog
        let state = editing.presetState
        title.stringValue = page.preset.map { EditModel.name(of: $0) } ?? ""
        title.isHidden = page.preset == nil
        NoticeLine.show(editing.notice, in: notice, from: self)
        var refused = false
        if case .rejected? = editing.notice { refused = true }
        for field in [number, label, fieldName, staticText, frameX, frameY, frameW, frameH, fitNumber, transitionMs, size, weight, lineSpacing,
                      letterSpacing, outlineSize, shadowX, shadowY, shadowBlur] {
            field.isRefused = refused && field === lastField
        }
        // The preset and Used by.
        if let preset = page.preset {
            number.show(String(preset.number), placeholder: String(preset.number), subject: AnyHashable(preset.uuid))
            number.isEnabled = preset.number != 1
            builtInNote.isHidden = preset.number != 1
            label.show(preset.label, placeholder: Strings.text(.editPresetUntitled, preset.number), subject: AnyHashable(preset.uuid))
        }
        let uses = state.usedBy.map { use -> String in
            switch use.kind {
            case .channelDefault(let n): Strings.text(.editPresetUseChannel, n)
            case .stackDefault(let n): Strings.text(.editPresetUseStack, n)
            case .slot(let stack, let channel): Strings.text(.editPresetUseSlot, stack, channel)
            case .fallback(let stack, let channel): Strings.text(.editPresetUseFallback, stack, channel)
            }
        }
        usedBy.stringValue = uses.isEmpty ? Strings.text(.editPresetUsedNone) : uses.joined(separator: "\n")
        usedBy.textColor = uses.isEmpty ? Palette.faintText : Palette.text
        presetColumn.setHeight(CGFloat(max(1, uses.count)) * 17 + 2, of: usedBy)
        // Boxes.
        // The box.
        let box = editing.selectedBox
        refreshBox(box, catalog: catalog)
        refreshStyle(box, catalog: catalog, fonts: state.fonts)
        for column in [propertyColumn, styleColumn, presetColumn] { column.needsLayout = true }
        needsLayout = true
    }

    private func refreshBox(_ box: Box?, catalog: Catalog?) {
        selectNote.isHidden = box != nil
        let controls: [NSView] = [binding, fieldName, staticText, variables, frameX, frameY, frameW, frameH, pixelFit, textFit, fitNumber, transition,
                                  transitionMs, onVariable, fallback, offset, grade, anchor] + frameLetters
        for view in controls { view.isHidden = box == nil }
        guard let box else { return }
        let subject = AnyHashable("\(model.editing.presetNumber ?? 0)-\(model.editing.presetTab.string)-\(model.editing.presetState.box ?? -1)")
        switch box.binding.kind {
        case .pixels:
            binding.selected = 0
            fieldName.isHidden = true
            staticText.isHidden = true
            variables.isHidden = true
        case .field(let name):
            binding.selected = 1
            fieldName.show(name, subject: subject)
            staticText.isHidden = true
            variables.isHidden = true
        case .static(let text):
            binding.selected = 2
            fieldName.isHidden = true
            staticText.show(text, subject: subject)
            // "Static text is a field with a Variables ▸ menu that inserts Spec 6 §5's names ..., sent on commit."
            let menu = NSMenu()
            menu.autoenablesItems = false
            for name in EditPopovers.variableNames(catalog: catalog) {
                menu.addItem(ClosureMenuItem(title: name) { [weak self] in
                    guard let self else { return }
                    self.staticText.stringValue += name
                    self.staticText.sendAction(self.staticText.action, to: self.staticText.target)
                })
            }
            variables.dropMenu = menu
        }
        anchor.refresh()
        let at = LayoutCanvasMath.point(of: box.frame, at: model.settings.boxAnchor)
        for (field, value) in [(frameX, at.x), (frameY, at.y), (frameW, box.frame.w), (frameH, box.frame.h)] {
            field.show(FormNumber.text(value * 100), subject: subject)
        }
        switch box.fit {
        case .pixels(let fit):
            pixelFit.set([(Strings.text(.editPresetFill), 0), (Strings.text(.editPresetFitFit), 1), (Strings.text(.editPresetStretch), 2),
                          (Strings.text(.editPresetCrop), 3)], selected: [PixelFit.fill, .fit, .stretch, .crop].firstIndex(of: fit) ?? 1)
            textFit.isHidden = true
            fitNumber.isHidden = true
        case .text(let fit):
            pixelFit.isHidden = true
            textFit.selected = fit.policy == .maxLines ? 1 : 0
            fitNumber.show(fit.policy == .maxLines ? String(fit.maxLines) : FormNumber.text(fit.minSize), subject: subject)
            let name = Strings.text(fit.policy == .maxLines ? .editPresetMaxLines : .editPresetMinSize)
            fitNumberName?.stringValue = name
            fitNumber.setAccessibilityLabel(name)
        }
        // "cut or dissolve, the box transitions v1 draws".
        let transitions = (catalog?.transitions ?? []).filter { $0.type.appliesToText }.sorted { $0.number < $1.number }
        transition.set(transitions.map { (EditModeWording.numbered($0.number, $0.label), $0.number) }, selected: box.transition.ref)
        let own = transitions.first { $0.number == box.transition.ref }?.ms
        transitionMs.show(box.transition.ms.map(String.init) ?? "", placeholder: own.map(String.init) ?? Strings.text(.editPresetMs), subject: subject)
        onVariable.isHidden = !box.binding.isText
        onVariable.state = box.transitionOnVariableChange ? .on : .off
        fallback.state = box.fallback ? .on : .off
        // "0 to +3 ...; the schema's −2 and −1 show as v1.5."
        offset.selected = Box.drawnOffsets.contains(box.offset) ? box.offset : nil
        let grades = (catalog?.grades ?? []).sorted { $0.number < $1.number }
        grade.set([(Strings.text(.editStackPresetNone), 0)] + grades.map { (EditModeWording.numbered($0.number, $0.label), $0.number) }, selected: box.grade ?? 0)
    }

    private func refreshStyle(_ box: Box?, catalog: Catalog?, fonts: [FontFace]) {
        let style = box?.textStyle
        let isText = box?.binding.isText ?? false
        noStyle.isHidden = box == nil || isText
        let controls: [NSView] = [fromStyle, applyStyle, reapply, saveAsStyle, font, size, unit, weight, color, align, vertical, lineSpacing, letterSpacing,
                                  outlineSize, outlineColor, shadowX, shadowY, shadowBlur, shadowColor, allCaps]
        for view in controls { view.isHidden = !isText || style == nil }
        styleHeading.isHidden = box == nil
        guard isText, let style, let catalog else { return }
        let subject = AnyHashable("\(model.editing.presetNumber ?? 0)-\(model.editing.presetTab.string)-\(model.editing.presetState.box ?? -1)")
        // "The form says which style the box came from (`fromStyle`), and "changed" once its values differ."
        if let from = style.fromStyle {
            let numbered = catalog.textStyles.first { $0.number == from }
            let name = numbered.map { $0.label.isEmpty ? Strings.text(.editPresetStyleUntitled, $0.number) : "\($0.number) \($0.label)" }
                ?? Strings.text(.editPresetStyleUntitled, from)
            fromStyle.stringValue = Strings.text(PresetEdits.isChanged(style, catalog: catalog) ? .editPresetFromStyleChanged : .editPresetFromStyle, name)
        } else {
            fromStyle.stringValue = Strings.text(.editPresetFromNone)
        }
        reapply.isEnabled = style.fromStyle.map { from in catalog.textStyles.contains { $0.number == from } } ?? false
        let menu = NSMenu()
        menu.autoenablesItems = false
        for numbered in catalog.textStyles.sorted(by: { $0.number < $1.number }) {
            let name = numbered.label.isEmpty ? Strings.text(.editPresetStyleUntitled, numbered.number) : "\(numbered.number) \(numbered.label)"
            menu.addItem(ClosureMenuItem(title: name) { [weak model] in model?.editing.applyStyle(numbered.number) })
        }
        applyStyle.dropMenu = menu
        // The font: "from the `fonts` query's families and faces", each drawn in itself.
        if fonts.count != fontsShown || font.title != style.values.font {
            fontsShown = fonts.count
            font.title = style.values.font
            font.dropMenu = fontMenu(fonts, current: style.values.font)
        }
        let v = style.values
        size.show(FormNumber.text(v.size.value), subject: subject)
        unit.selected = v.size.unit == .percent ? 1 : 0
        weight.show(FormNumber.text(v.weight, places: 0), subject: subject)
        color.color = FormColor.ns(v.color)
        align.selected = [TextAlignment.left, .center, .right].firstIndex(of: v.alignment)
        vertical.selected = [VerticalAlignment.top, .center, .bottom].firstIndex(of: v.verticalAlignment)
        lineSpacing.show(FormNumber.text(v.lineSpacing), subject: subject)
        letterSpacing.show(FormNumber.text(v.letterSpacing), subject: subject)
        outlineSize.show(FormNumber.text(v.outline.width), subject: subject)
        outlineColor.color = FormColor.ns(v.outline.color)
        shadowX.show(FormNumber.text(v.shadow.x), subject: subject)
        shadowY.show(FormNumber.text(v.shadow.y), subject: subject)
        shadowBlur.show(FormNumber.text(v.shadow.blur), subject: subject)
        shadowColor.color = FormColor.ns(v.shadow.color)
        allCaps.state = v.allCaps ? .on : .off
    }

    /// The families, each with its faces drawn in themselves; the button's title is the box's font.
    private func fontMenu(_ fonts: [FontFace], current: String) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        var families: [(String, [FontFace])] = []
        for face in fonts {
            if families.last?.0 == face.family { families[families.count - 1].1.append(face) } else { families.append((face.family, [face])) }
        }
        for (family, faces) in families {
            let item = NSMenuItem(title: family, action: nil, keyEquivalent: "")
            let sub = NSMenu()
            for face in faces {
                let entry = ClosureMenuItem(title: face.name) { [weak model] in model?.editing.setStyle("font", .string(face.name)) }
                if let drawn = NSFont(name: face.name, size: 13) {
                    entry.attributedTitle = NSAttributedString(string: drawn.displayName ?? face.name, attributes: [.font: drawn])
                }
                if face.name == current { entry.state = .on }
                sub.addItem(entry)
            }
            item.submenu = sub
            menu.addItem(item)
        }
        return menu
    }

    override func layout() {
        super.layout()
        guard bounds.width > 120 else { return }
        let h = Self.headerHeight
        let titleRight = title.frame.maxX + 14
        notice.frame = NSRect(x: titleRight, y: (h - 15) / 2, width: max(0, bounds.width - titleRight - 14), height: 15)
        let column = floor(bounds.width / 3)
        for (index, form) in [propertyColumn, styleColumn, presetColumn].enumerated() {
            form.scroll.frame = NSRect(x: CGFloat(index) * column + 1, y: h + 2, width: column - 2, height: max(0, bounds.height - h - 4))
            form.place()
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        Palette.hairline.setFill()
        let column = floor(bounds.width / 3)
        for index in 1..<3 {
            NSRect(x: CGFloat(index) * column, y: Self.headerHeight, width: 1, height: bounds.height - Self.headerHeight).fill()
        }
    }
}
