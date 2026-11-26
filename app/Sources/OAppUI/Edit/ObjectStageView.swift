// OAppUI — Spec 11 §9 as corrected 2026-11-25 (G-37): the Objects page's stage, the rest of the workspace's width given
// to the selected object's preview: a grade beside the item without it, a transition played, an audio transition's
// lanes, a text style's sample, a macro's commands.

import AppKit
import CoreText
import OApp
import OCore

/// Spec 11 §9 — "gives the rest of its width to the object's preview, the stage".
@MainActor
final class ObjectStageView: NSView {
    private let model: ShowModel
    weak var host: ShowWindowView? { didSet { commands.host = host } }
    var machineRoot: URL?
    let heading = Kit.heading("")
    // The pickers over the pictures: a grade's item, or a transition's two.
    let firstName = Kit.label(size: 11.5, color: Palette.dimText)
    /// "it opens the media chooser" (Spec 11 §2, G-42): the item's name, and a press opens it.
    let firstPicker = FlatButton("", style: .plain)
    let secondName = Kit.label(Strings.text(.editObjectTo), size: 11.5, color: Palette.dimText)
    let secondPicker = FlatButton("", style: .plain)
    // Grades: "the item through the grade beside the same item without it".
    let graded = NSImageView()
    let ungraded = NSImageView()
    let gradedCaption = Kit.label(size: 11, color: Palette.dimText)
    let ungradedCaption = Kit.label(Strings.text(.editObjectPreviewUngraded), size: 11, color: Palette.dimText)
    let note = Kit.label(size: 12, color: Palette.faintText)
    // Transitions: "Play, a loop switch and a scrub bar over the easing curve".
    let player = TransitionPlayerView()
    let play = FlatButton(Strings.text(.editObjectPlay), style: .plain)
    let loop = ChoiceBox(Strings.text(.editObjectLoop))
    let curve = EasingCurveView()
    // Audio transitions: the lanes.
    let lanes = AudioLanesView()
    // Text styles: the sample.
    let sampleField = EditField()
    let sample = StyleSampleView()
    // Macros: the commands.
    let commands: MacroCommandsView
    /// While playing: when the run started, on the system's clock.
    private var started: TimeInterval?
    private var timer: Timer?
    private var shown: [ObjectIdentifier: String] = [:]
    /// Before and after a transition, the stage holds each picture this long, so the change reads.
    static let holdMs = 500.0

    override var isFlipped: Bool { true }

    init(model: ShowModel) {
        self.model = model
        commands = MacroCommandsView(model: model)
        super.init(frame: .zero)
        for picker in [firstPicker, secondPicker] {
            picker.fontSize = 12
            picker.leading = true
            picker.chevron = true
        }
        firstPicker.onPress = { [weak self] in self?.choose(first: true) }
        secondPicker.onPress = { [weak self] in self?.choose(first: false) }
        firstPicker.setAccessibilityLabel(Strings.text(.editObjectPreviewItem))
        secondPicker.setAccessibilityLabel(Strings.text(.editObjectTo))
        for image in [graded, ungraded] {
            image.imageScaling = .scaleProportionallyUpOrDown
            image.setAccessibilityElement(false)
            // A dark well, so the picture's place reads before the engine has drawn it.
            image.wantsLayer = true
            image.layer?.backgroundColor = NSColor.black.cgColor
            image.layer?.borderColor = Palette.hairline.cgColor
            image.layer?.borderWidth = 1
        }
        for caption in [gradedCaption, ungradedCaption, note] { caption.alignment = .center }
        note.maximumNumberOfLines = 2
        play.onPress = { [weak self] in self?.togglePlay() }
        loop.onToggle = { _ in }
        curve.onScrub = { [weak self] t in self?.scrub(to: t) }
        sampleField.setAccessibilityLabel(Strings.text(.editObjectSample))
        sampleField.placeholderString = Strings.text(.editObjectSample)
        sampleField.onCommit = { [weak model] text in model?.editing.setStyleSample(text) }
        for view in [heading, firstName, firstPicker, secondName, secondPicker, graded, ungraded, gradedCaption, ungradedCaption, note, player, play,
                     loop, curve, lanes, sampleField, sample, commands] as [NSView] { addSubview(view) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// The chooser for a grade's item, or a transition's first or second (whose black is its first tile).
    func chooser(first: Bool) -> (PromptView, MediaPickerView)? {
        let editing = model.editing
        if editing.selectedGrade != nil {
            return MediaChooser.panel(model: model, machineRoot: machineRoot, selected: editing.gradeMedia, kinds: [.video, .image]) { [weak model] id in
                if let id { model?.editing.setGradeMedia(id) }
            }
        }
        guard editing.selectedTransition != nil else { return nil }
        let media = editing.transitionMedia
        return MediaChooser.panel(model: model, machineRoot: machineRoot, selected: first ? media.from : media.to, kinds: [.video, .image],
                                  extra: Strings.text(.editObjectBlack)) { [weak model] id in
            if first { model?.editing.setTransitionMedia(from: id) } else { model?.editing.setTransitionMedia(to: id) }
        }
    }

    private func choose(first: Bool) {
        guard let (panel, _) = chooser(first: first) else { return }
        host?.present(panel, at: first ? firstPicker : secondPicker)
    }

    /// An item's name, or black.
    private func named(_ id: String?) -> String {
        id.flatMap { id in model.store.media.first { $0.id == id } }.map { MediaPool.name(of: $0.entry) } ?? Strings.text(.editObjectBlack)
    }

    /// An engine picture in an image view, read again only when its file changes.
    private func show(_ picture: PreviewPicture, in view: NSImageView) -> NSImage? {
        let key = ObjectIdentifier(view)
        guard picture.file != shown[key] else { return view.image }
        shown[key] = picture.file
        guard let file = picture.file, let root = machineRoot else {
            view.image = nil
            return nil
        }
        view.image = PictureStore.shared.picture(at: root.appendingPathComponent(file)) { [weak self, weak view] image in
            view?.image = image
            self?.refresh()
        }
        return view.image
    }

    // MARK: - Showing the model

    func refresh() {
        let editing = model.editing
        let all: [NSView] = [firstName, firstPicker, secondName, secondPicker, graded, ungraded, gradedCaption, ungradedCaption, note, player, play,
                             loop, curve, lanes, sampleField, sample, commands]
        // What shows this time; each view is shown or hidden only when that changes, since hiding a field that has the
        // keys takes them from it (the sample's text lost its selection at every redraw, Adam, 2026-11-26).
        var showing: [NSView] = []
        defer {
            for view in all {
                let hidden = !showing.contains { $0 === view }
                if view.isHidden != hidden { view.isHidden = hidden }
            }
        }
        heading.isHidden = editing.selectedObject == nil
        let choices = editing.gradeMediaChoices
        if let grade = editing.selectedGrade {
            Kit.setHeading(heading, Strings.text(.editPreview))
            if choices.isEmpty {
                note.stringValue = Strings.text(.editObjectPreviewNoMedia)
                showing.append(note)
            } else {
                firstName.stringValue = Strings.text(.editObjectPreviewItem)
                firstPicker.title = named(editing.gradeMedia)
                gradedCaption.stringValue = Strings.text(.editObjectPreviewGraded, grade.number)
                showing += [firstName, firstPicker, graded, ungraded, gradedCaption, ungradedCaption]
                _ = show(editing.objectState.graded, in: graded)
                _ = show(editing.objectState.ungraded, in: ungraded)
            }
            stop()
        } else if let transition = editing.selectedTransition {
            Kit.setHeading(heading, Strings.text(.editPreview))
            let media = editing.transitionMedia
            firstName.stringValue = Strings.text(.editObjectFrom)
            firstPicker.title = named(media.from)
            secondPicker.title = named(media.to)
            showing += [firstName, firstPicker, secondName, secondPicker, player, play, loop, curve]
            player.from = show(editing.objectState.fromPicture, in: player.fromView)
            player.to = show(editing.objectState.toPicture, in: player.toView)
            player.color = transition.color.map(FormColor.ns) ?? .black
            curve.show(easing: transition.easing, ms: transition.ms)
            if started == nil { setProgress(curve.playhead ?? 0) }
        } else if let audio = editing.selectedAudioTransition {
            Kit.setHeading(heading, Strings.text(.editPreview))
            lanes.transition = audio
            showing += [lanes, play, loop]
        } else if let style = editing.selectedTextStyle {
            Kit.setHeading(heading, Strings.text(.editPreview))
            sampleField.show(editing.objectState.styleSample ?? "", placeholder: editing.styleSampleText, subject: AnyHashable("style-\(style.number)"))
            sample.values = style.values
            sample.text = editing.styleSampleText
            sample.stackSize = editing.canvasSize
            showing += [sampleField, sample]
            stop()
        } else if editing.selectedMacro != nil {
            Kit.setHeading(heading, Strings.text(.editObjectMacroHeading))
            showing.append(commands)
            commands.refresh()
            stop()
        } else {
            stop()
        }
        play.title = Strings.text(started == nil ? .editObjectPlay : .editObjectStop)
        needsLayout = true
    }

    // MARK: - Playing (Spec 11 §9, "Play, a loop switch and a scrub bar")

    /// The length of one run: the hold, the change, the hold.
    private var runMs: Double {
        let editing = model.editing
        if let transition = editing.selectedTransition { return Self.holdMs * 2 + Double(transition.ms) }
        if editing.selectedAudioTransition != nil { return lanes.span.upperBound - lanes.span.lowerBound }
        return 0
    }

    private func togglePlay() {
        if started != nil {
            stop()
        } else {
            started = ProcessInfo.processInfo.systemUptime
            timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
        }
        play.title = Strings.text(started == nil ? .editObjectPlay : .editObjectStop)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        started = nil
        lanes.playhead = nil
        play.title = Strings.text(.editObjectPlay)
    }

    /// One step of a run: where it is, at the system's clock.
    func tick() {
        guard let started else { return }
        let total = max(1, runMs)
        var elapsed = (ProcessInfo.processInfo.systemUptime - started) * 1000
        if elapsed > total {
            guard loop.state == .on else {
                show(elapsed: total)
                return stop()
            }
            elapsed = elapsed.truncatingRemainder(dividingBy: total)
        }
        show(elapsed: elapsed)
    }

    /// The stage at a time into the run.
    func show(elapsed: Double) {
        let editing = model.editing
        if let transition = editing.selectedTransition {
            let t = transition.ms > 0 ? (elapsed - Self.holdMs) / Double(transition.ms) : (elapsed >= Self.holdMs ? 1 : 0)
            setProgress(min(1, max(0, t)))
        } else if editing.selectedAudioTransition != nil {
            lanes.playhead = lanes.span.lowerBound + elapsed
        }
    }

    private func setProgress(_ t: Double) {
        guard let transition = model.editing.selectedTransition else { return }
        curve.playhead = t
        player.mix = TransitionMix.weights(transition.type, easing: transition.easing, at: t)
    }

    private func scrub(to t: Double) {
        stop()
        setProgress(t)
    }

    // MARK: - Layout

    override func layout() {
        super.layout()
        guard bounds.width > 120 else { return }
        let pad: CGFloat = 16
        let inner = max(0, bounds.width - 2 * pad)
        heading.frame = NSRect(x: pad, y: 14, width: inner, height: 14)
        var y: CGFloat = 36
        // The pickers' row.
        if !firstPicker.isHidden {
            let nameWidth = Kit.width(of: firstName) + 6
            firstName.frame = NSRect(x: pad, y: y + 4, width: nameWidth, height: 16)
            let pickerWidth = min(280, (inner - nameWidth * 2 - 24) / (secondPicker.isHidden ? 1 : 2))
            firstPicker.frame = NSRect(x: pad + nameWidth, y: y, width: pickerWidth, height: 24)
            if !secondPicker.isHidden {
                let x = firstPicker.frame.maxX + 16
                let secondWidth = Kit.width(of: secondName) + 6
                secondName.frame = NSRect(x: x, y: y + 4, width: secondWidth, height: 16)
                secondPicker.frame = NSRect(x: x + secondWidth, y: y, width: pickerWidth, height: 24)
            }
            y += 34
        }
        let room = max(0, bounds.height - y - pad)
        if !graded.isHidden {
            // Two pictures side by side, each 16 by 9, a caption under each.
            let half = (inner - 12) / 2
            let height = min(half * 9 / 16, max(0, room - 22))
            graded.frame = NSRect(x: pad, y: y, width: half, height: height)
            ungraded.frame = NSRect(x: pad + half + 12, y: y, width: half, height: height)
            gradedCaption.frame = NSRect(x: graded.frame.minX, y: graded.frame.maxY + 4, width: half, height: 15)
            ungradedCaption.frame = NSRect(x: ungraded.frame.minX, y: ungraded.frame.maxY + 4, width: half, height: 15)
            let scale = window?.backingScaleFactor ?? 2
            if half > 0 { model.editing.gradeWidth(Int((half * scale).rounded())) }
        }
        if !player.isHidden {
            // The picture as large as fits over the controls and the curve.
            let below: CGFloat = 34 + 110
            let height = min(inner * 9 / 16, max(60, room - below))
            let width = height * 16 / 9
            player.frame = NSRect(x: pad + (inner - width) / 2, y: y, width: width, height: height)
            let scale = window?.backingScaleFactor ?? 2
            model.editing.gradeWidth(Int((width * scale).rounded()))
            y = player.frame.maxY + 10
            let playWidth = max(80, play.fitting.width + 8)
            play.frame = NSRect(x: pad, y: y, width: playWidth, height: 24)
            loop.frame = NSRect(x: play.frame.maxX + 12, y: y + 2, width: loop.fittingSize.width + 4, height: 20)
            y += 34
            curve.frame = NSRect(x: pad, y: y, width: inner, height: min(170, max(60, bounds.height - y - pad)))
        }
        if !lanes.isHidden {
            let playWidth = max(80, play.fitting.width + 8)
            play.frame = NSRect(x: pad, y: y, width: playWidth, height: 24)
            loop.frame = NSRect(x: play.frame.maxX + 12, y: y + 2, width: loop.fittingSize.width + 4, height: 20)
            y += 34
            lanes.frame = NSRect(x: pad, y: y, width: inner, height: min(320, max(120, bounds.height - y - pad)))
        }
        if !sample.isHidden {
            sampleField.frame = NSRect(x: pad, y: y, width: min(inner, 520), height: 26)
            y += 36
            let roomLeft = max(0, bounds.height - y - pad)
            let aspect = CGFloat(sample.stackSize.width) / CGFloat(max(1, sample.stackSize.height))
            let height = min(inner / aspect, roomLeft)
            sample.frame = NSRect(x: pad + (inner - height * aspect) / 2, y: y, width: height * aspect, height: height)
        }
        if !commands.isHidden {
            commands.frame = NSRect(x: pad, y: y - 2, width: inner, height: max(commands.wantedHeight, bounds.height - y - pad))
        }
        if !note.isHidden { note.frame = NSRect(x: pad, y: bounds.height / 2 - 18, width: inner, height: 36) }
    }
}

/// Spec 11 §9 — a transition played on the stage: the two engine pictures mixed "as Spec 4 §7 says the channel pass does",
/// by the weights `TransitionMix` gives, over black.
@MainActor
final class TransitionPlayerView: NSView {
    /// Hold the pictures as the engine drew them; the player draws them mixed.
    let fromView = NSImageView()
    let toView = NSImageView()
    var from: NSImage? { didSet { needsDisplay = true } }
    var to: NSImage? { didSet { needsDisplay = true } }
    var color = NSColor.black { didSet { needsDisplay = true } }
    var mix: (outgoing: Double, color: Double, incoming: Double) = (1, 0, 0) { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel(Strings.text(.editPreview))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill()
        bounds.fill()
        // Each part added over black by its weight, so the three make the frame.
        func draw(_ image: NSImage?, _ weight: Double) {
            guard let image, weight > 0 else { return }
            image.draw(in: bounds, from: .zero, operation: .plusLighter, fraction: CGFloat(weight), respectFlipped: true, hints: nil)
        }
        draw(from, mix.outgoing)
        if mix.color > 0 {
            color.withAlphaComponent(CGFloat(mix.color)).setFill()
            bounds.fill(using: .plusLighter)
        }
        draw(to, mix.incoming)
        Palette.hairline.setStroke()
        NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5)).stroke()
    }
}

/// Spec 11 §9 — "The stage draws the outgoing and incoming gains over time on two lanes, with the trigger and the
/// picture's cut marked, as Spec 4 §11 applies them, and Play runs a playhead across them."
@MainActor
final class AudioLanesView: NSView {
    var transition: AudioTransition? { didSet { needsDisplay = true; refreshSpoken() } }
    /// Where the playhead is, in ms from the trigger; nil when not playing.
    var playhead: Double? { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    private func refreshSpoken() {
        guard let t = transition else { return }
        setAccessibilityLabel(Strings.text(.editObjectPreviewCurve, EditModeWording.audioTransitionType(t.type), SecondsText.text(ms: t.ms) + " s"))
    }

    /// The time the lanes show, in ms from the trigger: a little before it to a little after the last change.
    var span: ClosedRange<Double> {
        guard let t = transition else { return 0...1000 }
        let starts = AudioFade.starts(t)
        let end = Double(max(starts.sound + t.ms, starts.picture))
        let margin = max(200, end * 0.15)
        return -margin...(end + margin)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let t = transition, bounds.width > 40 else { return }
        let left: CGFloat = 92
        let plot = NSRect(x: left, y: 8, width: bounds.width - left - 8, height: bounds.height - 30)
        let span = self.span
        func x(_ ms: Double) -> CGFloat { plot.minX + plot.width * CGFloat((ms - span.lowerBound) / (span.upperBound - span.lowerBound)) }
        let laneHeight = (plot.height - 12) / 2
        let lanes = [(Strings.text(.editObjectLaneOut), plot.minY), (Strings.text(.editObjectLaneIn), plot.minY + laneHeight + 12)]
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: Palette.dimText]
        for (index, (name, top)) in lanes.enumerated() {
            let lane = NSRect(x: plot.minX, y: top, width: plot.width, height: laneHeight)
            Palette.well.setFill()
            NSBezierPath(roundedRect: lane, xRadius: 4, yRadius: 4).fill()
            (name as NSString).draw(at: NSPoint(x: 0, y: lane.midY - 7), withAttributes: attributes)
            let path = NSBezierPath()
            let steps = 160
            for step in 0...steps {
                let ms = span.lowerBound + (span.upperBound - span.lowerBound) * Double(step) / Double(steps)
                let gains = AudioFade.gains(t, at: ms)
                let gain = index == 0 ? gains.outgoing : gains.incoming
                let point = NSPoint(x: x(ms), y: lane.maxY - 3 - (lane.height - 6) * CGFloat(gain))
                if step == 0 { path.move(to: point) } else { path.line(to: point) }
            }
            path.lineWidth = 2
            Palette.selection.setStroke()
            path.stroke()
        }
        // The trigger and the picture's change.
        let starts = AudioFade.starts(t)
        var marks = [(0.0, Strings.text(.editObjectTrigger), Palette.dimText)]
        // A J cut moves the picture's change after the trigger.
        if starts.picture > 0 { marks.append((Double(starts.picture), Strings.text(.editObjectPicture), Palette.browsing)) }
        for (ms, word, color) in marks {
            let line = NSBezierPath()
            line.move(to: NSPoint(x: x(ms), y: plot.minY))
            line.line(to: NSPoint(x: x(ms), y: plot.maxY))
            line.setLineDash([3, 3], count: 2, phase: 0)
            color.setStroke()
            line.stroke()
            let label = NSAttributedString(string: word, attributes: [.font: NSFont.systemFont(ofSize: 10.5), .foregroundColor: color])
            label.draw(at: NSPoint(x: x(ms) + 3, y: plot.maxY + 4))
        }
        if let playhead {
            Palette.live.setFill()
            NSRect(x: x(playhead) - 1, y: plot.minY, width: 2, height: plot.height).fill()
        }
    }
}

/// Spec 11 §9 — "The stage draws a sample in the style on the shape of the thumbnail stack": the app's drawing with the
/// same fonts, an approximation of the engine's raster, scaled from the stack's size to the stage.
@MainActor
final class StyleSampleView: NSView {
    var values: TextStyleValues? { didSet { needsDisplay = true } }
    var text = "" { didSet { needsDisplay = true; setAccessibilityLabel(text) } }
    var stackSize: (width: Int, height: Int) = (1920, 1080) { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// The sample as attributed text at a scale from the stack's pixels to the view's points.
    func attributed(scale: CGFloat) -> NSAttributedString? {
        guard let v = values else { return nil }
        let points = v.size.unit == .percent ? CGFloat(v.size.value) / 100 * CGFloat(stackSize.height) : CGFloat(v.size.value)
        let size = max(1, points * scale)
        var font = NSFont(name: v.font, size: size) ?? NSFont.systemFont(ofSize: size)
        // The weight on a variable face's 'wght' axis.
        let wght = 0x7767_6874
        if let axes = CTFontCopyVariationAxes(font as CTFont) as? [[String: Any]],
           axes.contains(where: { ($0[kCTFontVariationAxisIdentifierKey as String] as? Int) == wght }) {
            let descriptor = font.fontDescriptor.addingAttributes([.init(rawValue: kCTFontVariationAttribute as String): [wght: v.weight]])
            font = NSFont(descriptor: descriptor, size: size) ?? font
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = [TextAlignment.left: NSTextAlignment.left, .center: .center, .right: .right][v.alignment] ?? .center
        paragraph.lineHeightMultiple = CGFloat(v.lineSpacing)
        var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: FormColor.ns(v.color), .paragraphStyle: paragraph,
                                                         .kern: CGFloat(v.letterSpacing) * scale]
        if v.outline.width > 0, v.outline.color.a > 0 {
            attributes[.strokeColor] = FormColor.ns(v.outline.color)
            attributes[.strokeWidth] = -CGFloat(v.outline.width) * scale / size * 100
        }
        if v.shadow.color.a > 0 {
            let shadow = NSShadow()
            shadow.shadowColor = FormColor.ns(v.shadow.color)
            shadow.shadowOffset = NSSize(width: CGFloat(v.shadow.x) * scale, height: -CGFloat(v.shadow.y) * scale)
            shadow.shadowBlurRadius = CGFloat(v.shadow.blur) * scale
            attributes[.shadow] = shadow
        }
        return NSAttributedString(string: v.allCaps ? text.uppercased() : text, attributes: attributes)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill()
        bounds.fill()
        Palette.hairline.setStroke()
        NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5)).stroke()
        let scale = bounds.height / CGFloat(max(1, stackSize.height))
        guard let values, let string = attributed(scale: scale) else { return }
        let box = bounds.insetBy(dx: bounds.width * 0.05, dy: bounds.height * 0.05)
        let needed = string.boundingRect(with: NSSize(width: box.width, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading])
        let height = min(box.height, ceil(needed.height))
        let y: CGFloat
        switch values.verticalAlignment {
        case .top: y = box.minY
        case .center: y = box.midY - height / 2
        case .bottom: y = box.maxY - height
        }
        string.draw(with: NSRect(x: box.minX, y: y, width: box.width, height: height), options: [.usesLineFragmentOrigin, .usesFontLeading])
    }
}
