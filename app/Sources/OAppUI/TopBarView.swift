// OAppUI — Spec 10 §8, the top bar.

import AppKit
import OApp
import OCore

/// Spec 10 §8 — "Status, with a few buttons, the same in show and edit
/// mode ... The buttons are Show and Edit, Back to Live, the output dots,
/// the tags, and ?, each opening or doing what it says; nothing else in the
/// bar is a control".
@MainActor
final class TopBarView: Surface {
    /// Spec 10 §4 — "Top bar ... 38 points high".
    static let height: CGFloat = 38

    private let model: ShowModel
    let show = FlatButton(style: .bare)
    let edit = FlatButton(style: .bare)
    private let liveDot = DotView()
    let position = Kit.content(Kit.label(size: 13, weight: .medium))
    let backToLive = FlatButton(style: .amber)
    let countdown = Kit.label(size: 13, weight: .semibold, mono: true)
    private var outputs: [(button: FlatButton, dot: DotView)] = []
    private var tags: [TagView] = []
    let note = Kit.label(size: 12)
    private let remote = DotView()
    let time = Kit.label(size: 12, mono: true)
    let keys = FlatButton(style: .bare)
    /// "While another app is active, the whole bar says ...".
    let notActive = Kit.content(Kit.label(size: 13, weight: .medium))
    /// The other app's name while this one isn't active; nil while it is.
    var activeElsewhere: String? { didSet { refresh() } }
    /// Opens an output's details, with its Stack ▸ menu.
    var onOutput: ((OutputDot, NSView) -> Void)?
    var onPopupTag: (() -> Void)?

    init(model: ShowModel) {
        self.model = model
        super.init(frame: .zero)
        fill = Palette.panel
        show.title = Strings.text(.menuShow)
        show.isOn = true
        edit.title = Strings.text(.menuEditMode)
        // Edit mode is Area 14's.
        edit.isEnabled = false
        edit.reason = Strings.text(.unavailableLater)
        liveDot.color = Palette.live
        backToLive.title = Strings.text(.menuBackToLive)
        backToLive.onPress = { [weak model] in model?.backToLive() }
        countdown.textColor = Palette.browsing
        countdown.alignment = .center
        note.textColor = Palette.dimText
        remote.color = Palette.selection
        remote.setAccessibilityElement(true)
        remote.setAccessibilityRole(.image)
        time.textColor = Palette.dimText
        keys.title = "?"
        keys.setAccessibilityLabel(Strings.text(.menuKeys))
        // The keys overlay comes with the keys' stage.
        keys.isEnabled = false
        keys.reason = Strings.text(.unavailableLater)
        notActive.alignment = .center
        notActive.textColor = Palette.browsing
        for view in [show, edit, liveDot, position, backToLive, countdown, note, remote, time, keys, notActive] as [NSView] { addSubview(view) }
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// The time of day, in the system's short format (Area 13 reading).
    static func clockText(_ date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter.string(from: date)
    }

    func refresh() {
        let inactive = activeElsewhere != nil
        notActive.stringValue = activeElsewhere.map { Strings.text(.topNotActive, $0) } ?? ""
        notActive.isHidden = !inactive
        let browsing = model.isBrowsing
        // "the top bar, the grid's edge and Back to Live turn amber".
        fill = browsing ? Palette.browsing.withAlphaComponent(0.10).blended(withFraction: 0.86, of: Palette.panel) : Palette.panel
        position.stringValue = ShowWording.position(model.livePosition)
        liveDot.isHidden = !model.store.live.isSomethingLive || inactive
        backToLive.isHidden = !browsing || inactive
        if let ms = model.countdownMs {
            countdown.stringValue = ShowWording.countdown(ms: ms)
            countdown.isHidden = inactive
        } else {
            countdown.stringValue = ""
            countdown.isHidden = true
        }
        time.stringValue = Self.clockText()
        remote.isHollow = !model.isRemoteLit
        remote.setAccessibilityLabel(Strings.text(.topRemote))

        // One dot an output.
        let dots = model.outputDots
        while outputs.count > dots.count {
            let last = outputs.removeLast()
            last.button.removeFromSuperview()
        }
        while outputs.count < dots.count {
            let button = FlatButton(style: .bare)
            let dot = DotView()
            button.addSubview(dot)
            addSubview(button)
            outputs.append((button, dot))
        }
        for (index, dot) in dots.enumerated() {
            let (button, mark) = outputs[index]
            // The text carries the state in words; the dot's shape says it again, so colour is never the only signal.
            button.title = "    " + ShowWording.output(dot)
            button.setAccessibilityLabel(ShowWording.output(dot))
            mark.color = dot.state == .presenting ? Palette.outputting : Palette.live
            mark.isHollow = dot.state != .presenting || dot.isBlackedOut
            mark.isSquare = dot.state != .presenting
            button.onPress = { [weak self, weak button] in
                guard let self, let button else { return }
                self.onOutput?(dot, button)
            }
            button.isHidden = inactive
        }
        if let outputsNote = OutputsNote.make(outputs: model.store.catalog?.outputs ?? [], screensAreMirrored: Self.screensAreMirrored),
           model.store.catalog != nil {
            note.stringValue = ShowWording.note(outputsNote)
            note.isHidden = inactive
        } else {
            note.stringValue = ""
            note.isHidden = true
        }

        tags.forEach { $0.removeFromSuperview() }
        tags = model.tags.map { tag in
            let style: TagView.Style
            switch tag {
            case .audioLost: style = .red
            case .audioMuted, .saving, .engine: style = .amber
            case .popup: style = .quiet
            }
            let view = TagView(ShowWording.tag(tag), style: style)
            view.isHidden = inactive
            addSubview(view)
            return view
        }
        for view in [show, edit, position, time, keys, remote] as [NSView] { view.isHidden = inactive }
        if !inactive { liveDot.isHidden = !model.store.live.isSomethingLive }
        needsLayout = true
    }

    /// Spec 10 §13 — a Mac "whose screens are mirrored, which macOS reports as one screen".
    static var screensAreMirrored: Bool {
        NSScreen.screens.contains { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return false }
            return CGDisplayIsInMirrorSet(CGDirectDisplayID(number.uint32Value)) != 0
        }
    }

    override func layout() {
        super.layout()
        let h = bounds.height
        notActive.frame = NSRect(x: 12, y: (h - 18) / 2, width: bounds.width - 24, height: 18)
        var x: CGFloat = 10
        for button in [show, edit] {
            let size = button.fitting
            button.frame = NSRect(x: x, y: (h - 26) / 2, width: size.width, height: 26)
            x += size.width + 2
        }
        x += 12
        liveDot.frame = NSRect(x: x, y: (h - 10) / 2, width: 10, height: 10)
        if !liveDot.isHidden { x += 18 }
        // From the right.
        var right = bounds.width - 10
        keys.frame = NSRect(x: right - 26, y: (h - 26) / 2, width: 26, height: 26)
        right -= 34
        let timeWidth = Kit.width(of: time)
        time.frame = NSRect(x: right - timeWidth, y: (h - 16) / 2, width: timeWidth, height: 16)
        right -= timeWidth + 12
        remote.frame = NSRect(x: right - 9, y: (h - 9) / 2, width: 9, height: 9)
        right -= 21
        for tag in tags.reversed() {
            let size = tag.fitting
            tag.frame = NSRect(x: right - size.width, y: (h - size.height) / 2, width: size.width, height: size.height)
            right -= size.width + 6
        }
        if !note.isHidden {
            let width = Kit.width(of: note)
            note.frame = NSRect(x: right - width, y: (h - 16) / 2, width: width, height: 16)
            right -= width + 10
        }
        for (button, dot) in outputs.reversed() {
            let size = button.fitting
            button.frame = NSRect(x: right - size.width, y: (h - 26) / 2, width: size.width, height: 26)
            dot.frame = NSRect(x: 9, y: 8, width: 10, height: 10)
            right -= size.width + 2
        }
        // The middle: the position at the left, Back to Live after it, the countdown centred in what is left.
        let positionWidth = min(Kit.width(of: position), max(80, right - x - 20))
        position.frame = NSRect(x: x, y: (h - 17) / 2, width: positionWidth, height: 17)
        x += positionWidth + 12
        if !backToLive.isHidden {
            let size = backToLive.fitting
            backToLive.frame = NSRect(x: x, y: (h - 24) / 2, width: size.width, height: 24)
            x += size.width + 12
        }
        let countdownWidth = Kit.width(of: countdown)
        let centred = (bounds.width - countdownWidth) / 2
        countdown.frame = NSRect(x: max(x, min(centred, right - countdownWidth - 8)), y: (h - 17) / 2, width: countdownWidth, height: 17)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        Palette.hairline.setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
    }

    override func mouseDown(with event: NSEvent) {
        // "Click here to come back."
        if activeElsewhere != nil { NSApplication.shared.activate(ignoringOtherApps: true) } else { super.mouseDown(with: event) }
    }

    /// What the bar shows, for a test.
    var shownOutputs: [String] { outputs.map { $0.button.accessibilityLabel() ?? "" } }
    var shownTags: [String] { tags.map(\.text) }
}
