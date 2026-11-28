// OApp — Spec 11 §8, the preset editor's selection, its picture, its Used by, the fonts and the sample, and its edits.

import Foundation
import OCore

/// A face the engine draws, from the `fonts` query (Spec 10 §3).
public struct FontFace: Equatable, Sendable {
    public var name: String
    public var family: String
    public var bundled: Bool
}

/// Spec 11 §8, "Used by" — one thing that refers to the preset, from `uses`.
public struct PresetUse: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// "the channels that default to it".
        case channelDefault(Int)
        /// "the stacks that default to it".
        case stackDefault(Int)
        /// "the slots that name it".
        case slot(stack: Int, channel: Int)
        /// "and the slots that reach it by fallback (Spec 6 §2)".
        case fallback(stack: Int, channel: Int)
    }

    public var kind: Kind
}

/// Spec 11 §8 — what the Presets page keeps between redraws.
public struct PresetEditorState: Equatable, Sendable {
    /// The selected box, by its place in the layout's `boxes`.
    public var box: Int?
    /// "the `*` layout at the size of the stack its picker names (the thumbnail stack at first)".
    public var canvasStack: Int?
    public var sample = LayoutSample()
    /// The text the sample's own field holds when it was changed there; it replaces the body.
    public var sampleText: String?
    /// The engine's picture of the layout, and what it reported.
    public var picture = PreviewPicture()
    public var overflow: [LayoutOverflow] = []
    /// "A box whose font fell back says so": the box's place and the font that wasn't found.
    public var fallbackFonts: [Int: String] = [:]
    public var usedBy: [PresetUse] = []
    public var fonts: [FontFace] = []
    var pixels = 0
    var asked = 0
    var subject: [String: JSONValue]?
    var usesFor: Int?
    var usesAsked = 0
    var fontsAsked = false

    public init() {}
}

extension EditModel {
    // MARK: - The selection (Spec 11 §8)

    /// The preset the page edits: the one chosen last, else the first.
    public var presetNumber: Int? {
        let presets = model.store.catalog?.presets.map(\.number).sorted() ?? []
        if let chosen = model.settings.editPreset, presets.contains(chosen) { return chosen }
        return presets.first
    }

    /// The layout tab: a stack's number, or nil for `*`.
    public var presetTab: LayoutKey { model.settings.editLayout.map { .stack($0) } ?? .any }

    public var presetPage: PresetPage {
        guard let catalog = model.store.catalog else { return PresetPage() }
        return PresetPage.make(catalog: catalog, preset: presetNumber, tab: presetTab, dots: model.outputDots)
    }

    /// The stack the canvas is drawn at: the tab's own, or for `*` the picker's, the thumbnail stack at first.
    public var canvasStack: Int? {
        let stacks = model.store.catalog?.stacks.map(\.number).sorted() ?? []
        if case .stack(let number) = presetTab, stacks.contains(number) { return number }
        if let chosen = presetState.canvasStack, stacks.contains(chosen) { return chosen }
        if let thumbnail = model.store.catalog?.settings?.thumbnailStack, stacks.contains(thumbnail) { return thumbnail }
        return stacks.first
    }

    /// Spec 11 §3 — "A stack's size is that of the output showing it, else of an output whose default stack it is,
    /// else 1920 by 1080": the canvas's pixels, which a nudge moves by.
    public var canvasSize: (width: Int, height: Int) {
        guard let stack = canvasStack, let outputs = model.store.catalog?.outputs.sorted(by: { $0.number < $1.number }) else { return (1920, 1080) }
        let showing = model.outputDots.filter { $0.stack == stack && $0.state != .absent }.map(\.number)
        let output = outputs.first { showing.contains($0.number) } ?? outputs.first { $0.defaultStack == stack }
        guard let format = output?.format, format.width > 0, format.height > 0 else { return (1920, 1080) }
        return (format.width, format.height)
    }

    /// The box the properties show, when the tab's layout is its own.
    public var selectedBox: Box? {
        let page = presetPage
        guard page.ownsLayout, let index = presetState.box, let boxes = page.layout?.boxes, boxes.indices.contains(index) else { return nil }
        return boxes[index]
    }

    func presetsOpened() {
        presetState.box = nil
        presetState.subject = nil
        askFonts()
        askLayout()
        askPresetUses()
    }

    public func selectPreset(_ number: Int) {
        guard number != presetNumber || model.settings.editPreset == nil else { return }
        model.settings.editPreset = number
        presetState.box = nil
        model.changed([.edit])
        askLayout()
        askPresetUses()
    }

    public func selectTab(_ key: LayoutKey) {
        switch key {
        case .any: model.settings.editLayout = nil
        case .stack(let number): model.settings.editLayout = number
        }
        presetState.box = nil
        model.changed([.edit])
        askLayout()
    }

    /// "A click selects a box, and so does a row of the box list".
    public func selectBox(_ index: Int?) {
        guard index != presetState.box else { return }
        presetState.box = index
        model.changed([.edit])
    }

    public func setCanvasStack(_ number: Int) {
        presetState.canvasStack = number
        model.changed([.edit])
        askLayout()
    }

    /// The canvas's width in pixels: the render is asked for at it.
    public func canvasWidth(_ pixels: Int) {
        let pixels = min(1920, max(160, pixels))
        guard pixels != presetState.pixels else { return }
        presetState.pixels = pixels
        askLayout()
    }

    // MARK: - The sample (Spec 11 §8, "The sample")

    public func setSample(kind: LayoutSample.Kind) {
        presetState.sample.kind = kind
        model.changed([.edit])
        askLayout()
    }

    /// "Either can be changed in the sample's own field"; empty puts the cue's or the built-in text back.
    public func setSampleText(_ text: String) {
        presetState.sampleText = text.isEmpty ? nil : text
        model.changed([.edit])
        askLayout()
    }

    /// A pool item, or nil for the engine's test pattern.
    public func setSampleMedia(_ id: String?) {
        presetState.sample.media = id
        presetState.sample.kind = .media
        model.changed([.edit])
        askLayout()
    }

    /// The sample as it is drawn: "the fields of the cue selected in the Cues page when it writes text, with that cue
    /// as the sample's `listUuid` and `cue` ...; else a built-in sample"; for media, "the engine's test pattern at
    /// first ..., or a pool item chosen after it".
    public var layoutSample: LayoutSample {
        var sample = presetState.sample
        sample.fields = nil
        sample.next = []
        sample.listUuid = nil
        sample.cue = nil
        if sample.kind == .text, let found = cueText() {
            sample.fields = found.fields
            sample.next = found.next
            sample.listUuid = listUuid
            sample.isLocal = found.isLocal
            sample.cue = found.cue
        }
        if let text = presetState.sampleText {
            var fields = sample.fields ?? LayoutSample.builtIn(verse: 0)
            fields["body"] = text
            sample.fields = fields
            if sample.next.isEmpty { sample.next = (1...3).map { LayoutSample.builtIn(verse: $0) } }
        }
        return sample
    }

    /// The selected cue's text write and the next cues', when the Cues page's cue writes text.
    private func cueText() -> (fields: [String: String], next: [[String: String]], cue: String, isLocal: Bool)? {
        guard let list, let listUuid, let uuid = selection.lead ?? selection.first(in: grid.headers.map(\.uuid)),
              let index = list.cues.firstIndex(where: { $0.uuid.uuidString.lowercased() == uuid }) else { return nil }
        func text(of cue: Cue) -> [String: String]? {
            for line in cue.commands.reversed() {
                if case .channelWrite(let write) = line.command, case .text(let fields) = write.content { return fields }
            }
            return nil
        }
        guard let fields = text(of: list.cues[index]) else { return nil }
        let next = list.cues[(index + 1)...].prefix(3).compactMap { text(of: $0) }
        let isLocal = model.store.lists[listUuid]?.local ?? model.store.catalog?.list(uuid: listUuid)?.local ?? false
        return (fields, next, uuid, isLocal)
    }

    // MARK: - What the page asks of the engine (Spec 11 §3)

    /// "`render` with `subject.kind` `layout` and the sample (§3), asked for again after each edit".
    func askLayout(again: Bool = false) {
        guard model.mode == .edit, page == .presets, presetState.pixels > 0, let preset = presetNumber else { return }
        let tab = presetPage.tab
        var subject: [String: JSONValue] = ["kind": .string("layout"), "preset": .number(Double(preset)), "sample": layoutSample.value]
        switch tab {
        case .any:
            subject["layout"] = .string("*")
            guard let stack = canvasStack else { return }
            subject["stack"] = .number(Double(stack))
        case .stack(let number):
            subject["layout"] = .number(Double(number))
        }
        let request: [String: JSONValue] = ["canvas": .string("layout"), "subject": .object(subject), "width": .number(Double(presetState.pixels))]
        guard again || request != presetState.subject else { return }
        presetState.subject = request
        presetState.asked += 1
        let asked = presetState.asked
        model.ask(.query("render", request)) { [weak self] answer in
            guard let self, asked == self.presetState.asked, let answer, answer["superseded"] != .bool(true),
                  let file = answer["file"]?.stringValue else { return }
            self.presetState.picture = PreviewPicture(file: file, width: answer["width"]?.intValue, height: answer["height"]?.intValue,
                                                      isMissing: answer["missing"] == .bool(true))
            self.presetState.overflow = (answer["overflow"]?.arrayValue ?? []).compactMap { value in
                guard let o = value.objectValue, let box = o["box"]?.intValue else { return nil }
                return LayoutOverflow(box: box, offset: o["offset"]?.intValue ?? 0, linesCut: o["linesCut"]?.intValue ?? 0)
            }
            var fallback: [Int: String] = [:]
            for value in answer["fallbackFonts"]?.arrayValue ?? [] {
                if let o = value.objectValue, let box = o["box"]?.intValue { fallback[box] = o["font"]?.stringValue ?? "" }
            }
            self.presetState.fallbackFonts = fallback
            self.model.changed([.edit])
        }
    }

    /// "Used by, from `uses` (§3)".
    func askPresetUses(again: Bool = false) {
        guard model.mode == .edit, page == .presets, let preset = presetNumber, again || presetState.usesFor != preset else { return }
        presetState.usesFor = preset
        presetState.usesAsked += 1
        let asked = presetState.usesAsked
        model.ask(.query("uses", ["object": .string("preset"), "preset": .number(Double(preset))])) { [weak self] answer in
            guard let self, asked == self.presetState.usesAsked, let answer else { return }
            var used: [PresetUse] = []
            for value in answer["uses"]?.objectValue?["channels"]?.arrayValue ?? [] {
                if let entry = value.objectValue, let channel = entry["channel"]?.intValue { used.append(PresetUse(kind: .channelDefault(channel))) }
            }
            for value in answer["uses"]?.objectValue?["stacks"]?.arrayValue ?? [] {
                guard let entry = value.objectValue, let stack = entry["stack"]?.intValue else { continue }
                if let slot = entry["slot"]?.intValue {
                    used.append(PresetUse(kind: entry["fallback"] == .bool(true) ? .fallback(stack: stack, channel: slot) : .slot(stack: stack, channel: slot)))
                } else {
                    used.append(PresetUse(kind: .stackDefault(stack)))
                }
            }
            self.presetState.usedBy = used
            self.model.changed([.edit])
        }
    }

    /// "font, from the `fonts` query's families and faces, the engine's installed and bundled fonts".
    func askFonts(again: Bool = false) {
        guard again || !presetState.fontsAsked else { return }
        presetState.fontsAsked = true
        model.ask(.query("fonts", [:])) { [weak self] answer in
            guard let self, let answer else {
                self?.presetState.fontsAsked = false
                return
            }
            self.presetState.fonts = (answer["fonts"]?.arrayValue ?? []).compactMap { value in
                guard let o = value.objectValue, let name = o["name"]?.stringValue else { return nil }
                return FontFace(name: name, family: o["family"]?.stringValue ?? name, bundled: o["bundled"] == .bool(true))
            }
            self.model.changed([.edit])
        }
    }

    // MARK: - The layout tabs (Spec 11 §8, "Layouts")

    /// "Copy from \*, which sets `layouts.S` to a copy of the `*` layout".
    public func copyLayoutFromAny() {
        guard let preset = presetPage.preset, case .stack(let stack) = presetTab else { return }
        _ = send(PresetEdits.copyFromAny(preset: preset, stack: stack))
    }

    /// "Remove This Stack's Layout (`edit preset P unset layouts.S`), asking first."
    public func removeStackLayout() {
        guard let preset = presetNumber, case .stack(let stack) = presetTab, presetPage.ownsLayout else { return }
        model.ask(.removeLayout(preset: preset, stack: stack)) { [weak self] in
            _ = self?.send(PresetEdits.removeLayout(preset: preset, stack: stack))
        }
    }

    // MARK: - The boxes (Spec 11 §8, "Boxes" and "The selected box's properties")

    /// The preset, the layout's key and the box's place an edit of the selected box needs; nil while nothing is editable.
    private var boxTarget: (preset: Int, layout: String, index: Int, box: Box)? {
        let page = presetPage
        guard let preset = page.preset?.number, page.ownsLayout, let index = presetState.box, let boxes = page.layout?.boxes,
              boxes.indices.contains(index) else { return nil }
        return (preset, page.path, index, boxes[index])
    }

    public func setBox(_ field: String, _ value: JSONValue) {
        guard let target = boxTarget else { return }
        _ = send(PresetEdits.setBox(preset: target.preset, layout: target.layout, index: target.index, field, value))
    }

    /// "when the drag or the nudge ends, one `edit.set` of the box's `frame`".
    public func setFrame(_ frame: Frame, of index: Int) {
        let page = presetPage
        guard let preset = page.preset?.number, page.ownsLayout else { return }
        presetState.box = index
        _ = send(PresetEdits.frame(preset: preset, layout: page.path, index: index, frame))
    }

    public func setBinding(_ kind: Binding.Kind) {
        guard let target = boxTarget else { return }
        let style1 = model.store.catalog?.textStyles.first { $0.number == 1 }
        _ = send(PresetEdits.binding(preset: target.preset, layout: target.layout, index: target.index, box: target.box, to: kind, style1: style1))
    }

    /// "Add Box ▸ Pixels, Field ▸ ... or Static Text inserts a box at the top"; the new box is selected.
    public func addBox(_ kind: Binding.Kind) {
        let page = presetPage
        guard let preset = page.preset?.number, page.ownsLayout else { return }
        let count = page.layout?.boxes.count ?? 0
        let style1 = model.store.catalog?.textStyles.first { $0.number == 1 }
        _ = send(PresetEdits.insertBox(preset: preset, layout: page.path, at: count, PresetEdits.newBox(kind, style1: style1))) { [weak self] outcome in
            guard outcome.kind == .ok else { return }
            self?.selectBox(count)
        }
    }

    /// "a row's menu also has Duplicate, which inserts a copy above it".
    public func duplicateBox(_ index: Int) {
        let page = presetPage
        guard let preset = page.preset?.number, page.ownsLayout, let boxes = page.layout?.boxes, boxes.indices.contains(index) else { return }
        _ = send(PresetEdits.insertBox(preset: preset, layout: page.path, at: index + 1, boxes[index])) { [weak self] outcome in
            guard outcome.kind == .ok else { return }
            self?.selectBox(index + 1)
        }
    }

    /// "and Remove (`edit.remove`), which Delete does with the canvas or the list focused".
    public func removeBox(_ index: Int) {
        let page = presetPage
        guard let preset = page.preset?.number, page.ownsLayout, let boxes = page.layout?.boxes, boxes.indices.contains(index) else { return }
        presetState.box = nil
        _ = send(PresetEdits.removeBox(preset: preset, layout: page.path, index: index))
    }

    /// "Rows drag to reorder ..., and Move Up and Move Down in a row's menu do the same by keyboard": up is toward the top.
    public func moveBox(_ index: Int, up: Bool) {
        moveBox(index, to: index + (up ? 1 : -1))
    }

    public func moveBox(_ index: Int, to target: Int) {
        let page = presetPage
        guard let preset = page.preset?.number, page.ownsLayout, let count = page.layout?.boxes.count,
              (0..<count).contains(index), (0..<count).contains(target), index != target else { return }
        presetState.box = target
        _ = send(PresetEdits.moveBox(preset: preset, layout: page.path, from: index, to: target))
    }

    // MARK: - The text style (Spec 11 §8, "The text style")

    public func setStyle(_ field: String, _ value: JSONValue) {
        guard let target = boxTarget, target.box.binding.isText else { return }
        _ = send(PresetEdits.style(preset: target.preset, layout: target.layout, index: target.index, field, value))
    }

    /// "Apply Style ▸ copies a numbered style's value into the box and sets `fromStyle`"; Re-apply is the same with the
    /// style the box came from.
    public func applyStyle(_ number: Int) {
        guard let target = boxTarget, let style = model.store.catalog?.textStyles.first(where: { $0.number == number }) else { return }
        _ = send(PresetEdits.apply(preset: target.preset, layout: target.layout, index: target.index, style: style))
    }

    public func reapplyStyle() {
        guard let from = boxTarget?.box.textStyle?.fromStyle else { return }
        applyStyle(from)
    }

    /// "Save as Style… asks for a name and sends one group ...; a number taken meanwhile fails the group, and the app
    /// tries the next."
    public func saveAsStyle(named label: String, tries: Int = 3) {
        guard let target = boxTarget, let values = target.box.textStyle?.values, let catalog = model.store.catalog else { return }
        let number = PresetEdits.nextStyleNumber(catalog: catalog) + (3 - tries)
        _ = send(PresetEdits.saveAsStyle(preset: target.preset, layout: target.layout, index: target.index, values: values, number: number, label: label)) { [weak self] outcome in
            guard outcome.kind != .ok, tries > 1 else { return }
            self?.saveAsStyle(named: label, tries: tries - 1)
        }
    }

    // MARK: - The preset (Spec 11 §8, "The preset")

    public func setPreset(_ path: String, _ value: JSONValue) {
        guard let preset = presetNumber else { return }
        _ = send(PresetEdits.set(preset: preset, path, value))
    }

    public func newPreset() {
        _ = send(PresetEdits.create()) { [weak self] outcome in
            guard let number = outcome.applied.first?.command.objectValue?["preset"]?.intValue else { return }
            self?.selectPreset(number)
        }
    }

    /// "Duplicate (`edit preset P duplicate`, ..., opening the copy)".
    public func duplicatePreset() {
        guard let preset = presetNumber else { return }
        _ = send(PresetEdits.duplicate(preset: preset)) { [weak self] outcome in
            guard let number = outcome.applied.first?.command.objectValue?["preset"]?.intValue, number != preset else { return }
            self?.selectPreset(number)
        }
    }

    /// "Preset 1 can be edited but not deleted, renumbered or swapped (Spec 5 §6)."
    public var presetIsBuiltIn: Bool { presetNumber == 1 }

    public func renumberPreset(to number: Int) {
        guard let preset = presetNumber, !presetIsBuiltIn, number >= 1, number != preset, number != 1 else { return }
        let taken = model.store.catalog?.presets.contains { $0.number == number } ?? false
        _ = send(PresetEdits.renumber(preset: preset, to: number, swap: taken)) { [weak self] outcome in
            guard outcome.kind == .ok else { return }
            self?.selectPreset(number)
        }
    }

    /// "Delete, which asks first, with the counts from `uses`".
    public func deletePreset() {
        guard let preset = presetPage.preset, !presetIsBuiltIn else { return }
        deleteAsking("preset", preset.number, name: Self.name(of: preset), always: true, PresetEdits.delete(preset: preset.number))
    }

    public static func name(of preset: Preset) -> String {
        preset.label.isEmpty ? Strings.text(.editPresetUntitled, preset.number) : "\(preset.number) \(preset.label)"
    }
}
