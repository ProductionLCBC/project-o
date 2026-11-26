// OAppUI — Spec 10 §2, the banner across the window that says where the app stands with the engine.

import AppKit
import OApp

/// Spec 10 §2 — "a banner across the window says "The engine stopped.
/// Restarting…"", "the banner says "The engine isn't responding" and offers
/// "Restart the engine"", and "shows the console log's last lines". The
/// wording is `EngineBanner`'s; this draws it.
@MainActor
final class BannerView: NSView {
    private let label = NSTextField(labelWithString: "")
    private let restart = NSButton(title: "", target: nil, action: nil)
    private let console = NSTextField(wrappingLabelWithString: "")
    private let stack = NSStackView()
    /// Called when the operator presses Restart the engine; the confirmation is the caller's to ask.
    var onRestart: (() -> Void)?
    private(set) var banner: EngineBanner?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.textColor = Palette.text
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        restart.bezelStyle = .rounded
        restart.target = self
        restart.action = #selector(pressedRestart)
        console.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        console.textColor = Palette.dimText
        console.isSelectable = true
        console.maximumNumberOfLines = 20
        let row = NSStackView(views: [label, NSView(), restart])
        row.orientation = .horizontal
        row.alignment = .centerY
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 14, bottom: 8, right: 14)
        stack.addArrangedSubview(row)
        stack.addArrangedSubview(console)
        row.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28).isActive = true
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
                                     stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor)])
        show(nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    /// Shows a banner, or with nil takes it away.
    func show(_ banner: EngineBanner?) {
        self.banner = banner
        isHidden = banner == nil
        guard let banner else { return }
        label.stringValue = banner.text
        restart.title = Strings.text(.engineRestart)
        restart.isHidden = !banner.offersRestart
        console.stringValue = banner.console.joined(separator: "\n")
        console.isHidden = banner.console.isEmpty
        // Spec 10 §4 — red for errors, amber for warnings; the sentence says it too, so color is never the only signal (§15).
        switch banner.tone {
        case .failure: layer?.backgroundColor = Palette.live.withAlphaComponent(0.28).cgColor
        case .notice: layer?.backgroundColor = Palette.browsing.withAlphaComponent(0.22).cgColor
        case .working: layer?.backgroundColor = Palette.panel.cgColor
        }
        // Spec 10 §15 — "Every control has a label and its state".
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(banner.text)
        console.setAccessibilityLabel(Strings.text(.engineConsoleLabel))
        restart.setAccessibilityLabel(restart.title)
    }

    /// What the banner shows, for a test and for VoiceOver's own reading.
    var shownText: String { label.stringValue }
    var shownConsole: String { console.stringValue }
    var offersRestart: Bool { !restart.isHidden && !isHidden }

    @objc private func pressedRestart() {
        onRestart?()
    }

    /// Presses Restart the engine as a click would.
    func pressRestart() {
        guard offersRestart else { return }
        pressedRestart()
    }
}
