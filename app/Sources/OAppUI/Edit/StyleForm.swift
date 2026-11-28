// OAppUI — Spec 11 §8, "The text style", and §9, "Text styles": the style form, which the preset inspector shows for a
// box's own style and the Objects page for a numbered one.

import AppKit
import OApp
import OCore

/// The style form: font, size, weight, color, alignment, spacing, outline, shadow and all caps, each change one edit
/// of one field (`textStyle.FIELD` of a box, or `edit textstyle N FIELD VALUE`). Its rows go into the page's column.
@MainActor
final class StyleForm {
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
    /// One field's edit: its name within the style, and its value.
    var onSet: ((String, JSONValue) -> Void)?
    /// A field was committed: the page outlines it in red while the engine's refusal of it stands (Spec 11 §2).
    var onCommit: ((EditField) -> Void)?
    /// A field's text didn't read as a number: the page shows the model's value again.
    var onPutBack: (() -> Void)?
    private var fontsShown = 0

    /// Every control the form shows, to hide or show together.
    var controls: [NSView] {
        [font, size, unit, weight, color, align, vertical, lineSpacing, letterSpacing, outlineSize, outlineColor, shadowX, shadowY, shadowBlur,
         shadowColor, allCaps]
    }

    var fields: [EditField] { [size, weight, lineSpacing, letterSpacing, outlineSize, shadowX, shadowY, shadowBlur] }

    init() {
        numeric(size, Strings.text(.editPresetSize)) { [weak self] value in self?.onSet?("size.value", .number(max(1, value))) }
        unit.setAccessibilityLabel(Strings.text(.editPresetSize))
        unit.onSelect = { [weak self] index in self?.onSet?("size.unit", .string(index == 1 ? "percent" : "pt")) }
        numeric(weight, Strings.text(.editPresetWeight)) { [weak self] value in self?.onSet?("weight", .number(min(1000, max(1, value.rounded())))) }
        color.onChoose = { [weak self] picked in self?.onSet?("color", FormColor.value(picked)) }
        align.setAccessibilityLabel(Strings.text(.editPresetAlign))
        align.onSelect = { [weak self] index in self?.onSet?("alignment", .string(["left", "center", "right"][min(2, max(0, index))])) }
        vertical.setAccessibilityLabel(Strings.text(.editPresetVertical))
        vertical.onSelect = { [weak self] index in self?.onSet?("verticalAlignment", .string(["top", "center", "bottom"][min(2, max(0, index))])) }
        numeric(lineSpacing, Strings.text(.editPresetLineSpacing)) { [weak self] value in self?.onSet?("lineSpacing", .number(max(0.1, value))) }
        numeric(letterSpacing, Strings.text(.editPresetLetterSpacing)) { [weak self] value in self?.onSet?("letterSpacing", .number(value)) }
        numeric(outlineSize, Strings.text(.editPresetOutline)) { [weak self] value in self?.onSet?("outline.width", .number(max(0, value))) }
        outlineColor.onChoose = { [weak self] picked in self?.onSet?("outline.color", FormColor.value(picked)) }
        numeric(shadowX, Strings.text(.editPresetShadow) + " X") { [weak self] value in self?.onSet?("shadow.x", .number(value)) }
        numeric(shadowY, Strings.text(.editPresetShadow) + " Y") { [weak self] value in self?.onSet?("shadow.y", .number(value)) }
        numeric(shadowBlur, Strings.text(.editPresetBlur)) { [weak self] value in self?.onSet?("shadow.blur", .number(max(0, value))) }
        shadowColor.onChoose = { [weak self] picked in self?.onSet?("shadow.color", FormColor.value(picked)) }
        shadowX.placeholderString = "X"
        shadowY.placeholderString = "Y"
        shadowBlur.placeholderString = Strings.text(.editPresetBlur)
        allCaps.onToggle = { [weak self] on in self?.onSet?("allCaps", .bool(on)) }
        font.fontSize = 12
        font.leading = true
        font.setAccessibilityLabel(Strings.text(.editPresetFont))
    }

    /// A field that sends a number, parsed; anything else is put back.
    private func numeric(_ field: EditField, _ label: String, _ send: @escaping (Double) -> Void) {
        field.setAccessibilityLabel(label)
        field.onCommit = { [weak self, weak field] text in
            guard let self, let field else { return }
            self.onCommit?(field)
            if let value = FormNumber.value(text) { send(value) } else {
                field.putBack()
                self.onPutBack?()
            }
        }
    }

    /// The form's rows, in the page's column.
    func addRows(to c: FormColumn) {
        c.row(Strings.text(.editPresetFont), [font], height: 24)
        c.row(Strings.text(.editPresetSize), [size, unit], widths: [56, nil], height: 24)
        c.row(Strings.text(.editPresetWeight), [weight], widths: [64], height: 24)
        c.row(Strings.text(.editPresetColor), [color], widths: [44], height: 24)
        c.row(Strings.text(.editPresetAlign), [align], height: 24)
        c.row(Strings.text(.editPresetVertical), [vertical], height: 24)
        c.row(Strings.text(.editPresetLineSpacing), [lineSpacing], widths: [64], height: 24)
        c.row(Strings.text(.editPresetLetterSpacing), [letterSpacing], widths: [64], height: 24)
        c.row(Strings.text(.editPresetOutline), [outlineSize, outlineColor], widths: [56, 44], height: 24)
        c.row(Strings.text(.editPresetShadow), [shadowX, shadowY, shadowBlur, shadowColor], widths: [nil, nil, nil, 44], height: 24)
        c.row(nil, [allCaps], height: 20)
    }

    func setHidden(_ hidden: Bool) {
        for view in controls { view.isHidden = hidden }
    }

    /// The style's values; `subject` names what the fields edit, so a field keeps its text while it has the focus.
    func show(_ v: TextStyleValues, subject: AnyHashable, fonts: [FontFace]) {
        // The font: "from the `fonts` query's families and faces", each drawn in itself.
        if fonts.count != fontsShown || font.title != v.font {
            fontsShown = fonts.count
            font.title = v.font
            font.dropMenu = fontMenu(fonts, current: v.font)
        }
        size.show(FormNumber.text(v.size.value), subject: subject)
        unit.selected = v.size.unit == .percent ? 1 : 0
        weight.show(FormNumber.text(v.weight, places: 0), subject: subject)
        color.show(FormColor.ns(v.color))
        align.selected = [TextAlignment.left, .center, .right].firstIndex(of: v.alignment)
        vertical.selected = [VerticalAlignment.top, .center, .bottom].firstIndex(of: v.verticalAlignment)
        lineSpacing.show(FormNumber.text(v.lineSpacing), subject: subject)
        letterSpacing.show(FormNumber.text(v.letterSpacing), subject: subject)
        outlineSize.show(FormNumber.text(v.outline.width), subject: subject)
        outlineColor.show(FormColor.ns(v.outline.color))
        shadowX.show(FormNumber.text(v.shadow.x), subject: subject)
        shadowY.show(FormNumber.text(v.shadow.y), subject: subject)
        shadowBlur.show(FormNumber.text(v.shadow.blur), subject: subject)
        shadowColor.show(FormColor.ns(v.shadow.color))
        allCaps.state = v.allCaps ? .on : .off
    }

    /// The families, each with its faces drawn in themselves; the button's title is the style's font.
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
                let entry = ClosureMenuItem(title: face.name) { [weak self] in self?.onSet?("font", .string(face.name)) }
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
}
