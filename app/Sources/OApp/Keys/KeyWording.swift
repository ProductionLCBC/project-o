// OApp — Spec 10 §9 and §15, the keys in words: a key as it is drawn, a command's plain name, the overlay.

import Foundation
import OCore

/// Spec 10 §15, "Localization" — "A command's plain name, in the keys
/// overlay and elsewhere, comes from a table of one sentence with
/// placeholders per command object (Spec 2 §3), and a command without one
/// shows its canonical text. Keys are drawn as the current keyboard layout
/// labels them, though matched by position (§9)."
@MainActor
public enum KeyWording {
    // MARK: A key

    /// A key as it is drawn: its modifiers as the Mac's signs, then the key.
    /// `layout` says what the current keyboard layout prints on the key at a
    /// position; a key it has nothing for is drawn by its US name.
    public static func key(_ name: KeyName, layout: (UInt16) -> String? = { _ in nil }) -> String {
        let label = keyLabel(name.key, layout: layout)
        guard !name.isPlain else { return label }
        let modifiers = (name.ctrl ? Strings.text(.keyCtrl) : "") + (name.alt ? Strings.text(.keyAlt) : "") + (name.shift ? Strings.text(.keyShift) : "")
        return Strings.text(.keyChord, modifiers, label)
    }

    private static let named: [String: StringKey] = [
        "space": .keySpace, "return": .keyReturn, "escape": .keyEscape, "tab": .keyTab, "delete": .keyDelete, "forwarddelete": .keyForwardDelete,
        "left": .keyLeft, "right": .keyRight, "up": .keyUp, "down": .keyDown, "home": .keyHome, "end": .keyEnd, "pageup": .keyPageUp,
        "pagedown": .keyPageDown, "padenter": .keyPadEnter,
    ]

    private static let padSigns: [String: String] = ["padplus": "+", "padminus": "−", "padstar": "*", "padslash": "/", "paddot": ".", "padequals": "="]

    private static func keyLabel(_ key: String, layout: (UInt16) -> String?) -> String {
        if let named = named[key] { return Strings.text(named) }
        if key.count > 1, key.hasPrefix("f"), let number = Int(key.dropFirst()) { return Strings.text(.keyFunction, number) }
        if let sign = padSigns[key] { return Strings.text(.keyPad, sign) }
        if key.hasPrefix("pad") { return Strings.text(.keyPad, String(key.dropFirst(3))) }
        // A letter, a digit or a punctuation key: what the layout prints there, as a keycap shows it.
        let printed = KeyPositions.code(of: key).flatMap(layout).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
        return (printed.isEmpty ? key : printed).uppercased()
    }

    // MARK: A command's plain name

    /// The command's sentence from the table, or its canonical text when
    /// the table has none for it: every form with a duration, a rider or a
    /// guard, the edits and the media commands (Area 13 reading: a plain
    /// name never says less than the command does).
    public static func plain(_ command: Command) -> String {
        sentence(command) ?? CommandText.print(command) ?? command.cmd
    }

    private static func sentence(_ command: Command) -> String? {
        switch command {
        case .next: return Strings.text(.commandNext)
        case .previous: return Strings.text(.commandPrevious)
        case .cue(let cue, _): return Strings.text(.commandCue, cue)
        case .itemCue(let item, let cue, _): return Strings.text(.commandItemCue, item, cue)
        case .itemSection(let item, let section): return Strings.text(.commandItemSection, item, section)
        case .listCue(let list, let cue, _): return Strings.text(.commandListCue, list, cue)
        case .playlistLoad(let title): return Strings.text(.commandPlaylist, title)
        case .disarm: return Strings.text(.commandDisarm)
        case .systemClearAll: return Strings.text(.commandClearAll)
        case .systemPreflight: return Strings.text(.commandPreflight)
        case .systemSnapshot: return Strings.text(.commandSnapshot)
        case .channelClear(let channel): return target(channel, .commandChannelClear, all: .commandChannelClearAll)
        case .channelReset(let channel): return target(channel, .commandChannelReset, all: .commandChannelResetAll)
        case .channelTransport(let channel, let mode):
            switch mode {
            case .play: return target(channel, .commandChannelPlay, all: .commandChannelPlayAll)
            case .pause: return target(channel, .commandChannelPause, all: .commandChannelPauseAll)
            case .stop: return target(channel, .commandChannelStop, all: .commandChannelStopAll)
            }
        case .channelEndBehavior(.number(let channel), let mode):
            switch mode {
            case .loop: return Strings.text(.commandChannelEndLoop, channel)
            case .hold: return Strings.text(.commandChannelEndHold, channel)
            case .clear: return Strings.text(.commandChannelEndClear, channel)
            }
        case .channelLock(let channel, let locked):
            return locked ? target(channel, .commandChannelLock, all: .commandChannelLockAll) : target(channel, .commandChannelUnlock, all: .commandChannelUnlockAll)
        case .channelFreeze(.number(let channel), let state):
            return Strings.text(state == .on ? .commandChannelFreezeOn : state == .off ? .commandChannelFreezeOff : .commandChannelFreezeToggle, channel)
        case .channelGrade(.number(let channel), let grade, nil):
            return grade == 0 ? Strings.text(.commandChannelGradeNone, channel) : Strings.text(.commandChannelGrade, channel, grade)
        case .channelTransition(.number(let channel), let transition, nil): return Strings.text(.commandChannelTransition, channel, transition)
        case .channelAudioTransition(.number(let channel), let transition, nil): return Strings.text(.commandChannelAudioTransition, channel, transition)
        case .outputStack(let output, let stack): return Strings.text(.commandOutputStack, output, stack)
        case .stackBlackout(let stack, let state):
            switch state {
            case .on: return target(stack, .commandStackBlackoutOn, all: .commandStackBlackoutAllOn)
            case .off: return target(stack, .commandStackBlackoutOff, all: .commandStackBlackoutAllOff)
            case .toggle: return target(stack, .commandStackBlackoutToggle, all: .commandStackBlackoutAllToggle)
            }
        case .stackMute(let stack, let channel, let state):
            return Strings.text(state == .on ? .commandStackMuteOn : state == .off ? .commandStackMuteOff : .commandStackMuteToggle, stack, channel)
        case .timerStart(let timer): return Strings.text(.commandTimerStart, timer)
        case .timerPause(let timer): return Strings.text(.commandTimerPause, timer)
        case .timerReset(let timer): return Strings.text(.commandTimerReset, timer)
        case .popupSet(let popup, let text, nil): return Strings.text(.commandPopupSet, popup, text)
        case .popupClear(let popup): return Strings.text(.commandPopupClear, popup)
        case .audioMute(let audio, let state):
            switch state {
            case .on: return target(audio, .commandAudioMuteOn, all: .commandAudioMuteAllOn)
            case .off: return target(audio, .commandAudioMuteOff, all: .commandAudioMuteAllOff)
            case .toggle: return target(audio, .commandAudioMuteToggle, all: .commandAudioMuteAllToggle)
            }
        case .macro(let macro): return Strings.text(.commandMacro, macro)
        case .undo: return Strings.text(.commandUndo)
        case .redo: return Strings.text(.commandRedo)
        default: return nil
        }
    }

    private static func target(_ target: Target, _ one: StringKey, all: StringKey) -> String {
        switch target {
        case .number(let number): return Strings.text(one, number)
        case .all: return Strings.text(all)
        }
    }

    // MARK: Fields (Spec 10 §8)

    /// "while a text field has the focus, what its keys do".
    public static func hint(_ hint: FieldKind.Hint) -> String {
        switch hint {
        case .commandReturnSaves: return Strings.text(.hintCommandReturnSaves)
        case .textEditor: return Strings.text(.hintTextEditor)
        case .returnSaves: return Strings.text(.hintReturnSaves)
        case .typing: return Strings.text(.hintTyping)
        }
    }

    // MARK: The table's safeguards (Spec 10 §9)

    public static func missing(_ missing: BindingTable.Missing) -> String {
        switch missing {
        case .next: return Strings.text(.keysWarnNext)
        case .clearAll: return Strings.text(.keysWarnClearAll)
        }
    }

    public static func ignored(_ row: BindingTable.Ignored) -> String {
        switch row.reason {
        case .notAKeyName: return Strings.text(.keysIgnoredNotAKeyName, row.key)
        case .reserved: return Strings.text(.keysIgnoredReserved, row.key)
        case .repeated: return Strings.text(.keysIgnoredRepeated, row.key)
        }
    }

    // MARK: The command bar (Spec 10 §9)

    /// What the bar shows beside itself for the last command sent, or nil with nothing sent yet.
    public static func outcome(of bar: CommandBar) -> String? {
        guard let outcome = bar.outcome else { return nil }
        let command = bar.last ?? ""
        switch outcome {
        case .sent: return Strings.text(.commandBarOutcomeSent, command)
        case .result(.ok): return Strings.text(.commandBarOutcomeOk, command)
        case .result(.noop): return Strings.text(.commandBarOutcomeNoop, command)
        case .result(.blocked): return Strings.text(.commandBarOutcomeBlocked, command)
        case .result(.steppedOn): return Strings.text(.commandBarOutcomeSteppedOn, command)
        case .result(.rejected): return Strings.text(.commandBarOutcomeRejected, command, "")
        case .rejected(let why): return Strings.text(.commandBarOutcomeRejected, command, why)
        case .engineAway: return Strings.text(.commandBarOutcomeEngineAway)
        }
    }
}

/// Spec 10 §9, "The keys overlay" — "lists every binding as its key, drawn
/// as the current keyboard layout labels it, and its command's plain name
/// (§15), then the fixed keys and ⌥-double-click (§6). It names `system
/// clearall` "Clear all channels (popups stay)" and says that in v1 undo
/// changes the library, never the screens."
public struct KeysOverlay: Equatable, Sendable {
    /// A key and what it does.
    public struct Row: Equatable, Sendable {
        public var key: String
        public var what: String

        public init(key: String, what: String) {
            self.key = key
            self.what = what
        }
    }

    /// The keyboard's bindings, in the file's order.
    public var bindings: [Row]
    /// The fixed keys, the app's view actions, digit entry and ⌥-double-click.
    public var fixed: [Row]
    /// "the keys overlay warn[s] when nothing is bound to `next` or to `system clearall`".
    public var warnings: [String]
    /// The rows of `keys.json` the app leaves out, each with why.
    public var ignored: [String]
    /// What the overlay says besides: undo, an open menu, and ⌃⌥⌘⎋ when the system wouldn't register it.
    public var notes: [String]

    /// The overlay for a table. `releaseKeyRegistered` is whether the
    /// system took ⌃⌥⌘⎋ as a hot key: when it didn't, the key works only
    /// while the app is active, and the overlay says so (Area 13 reading).
    @MainActor
    public static func make(table: BindingTable, releaseKeyRegistered: Bool, layout: (UInt16) -> String? = { _ in nil }) -> KeysOverlay {
        let bindings = table.rows.map { Row(key: KeyWording.key($0.key, layout: layout), what: KeyWording.plain($0.binding.command)) }
        let fixed = [
            Row(key: Strings.text(.keysFixedReleaseKey), what: Strings.text(.keysFixedRelease)),
            Row(key: Strings.text(.keyEscape), what: Strings.text(.keysFixedEscape)),
            Row(key: Strings.text(.keysFixedDigitsKey), what: Strings.text(.keysFixedDigits)),
            Row(key: Strings.text(.keysFixedBackToLiveKey), what: Strings.text(.menuBackToLive)),
            Row(key: Strings.text(.keysFixedMultiviewerKey), what: Strings.text(.menuMultiviewer)),
            Row(key: Strings.text(.keysFixedShowKey), what: Strings.text(.menuShow)),
            Row(key: Strings.text(.keysFixedEditKey), what: Strings.text(.menuEditMode)),
            Row(key: Strings.text(.keysFixedOptionDoubleClickKey), what: Strings.text(.keysFixedOptionDoubleClick)),
        ]
        var notes = [Strings.text(.keysNoteUndo), Strings.text(.keysNoteMenu)]
        if !releaseKeyRegistered { notes.append(Strings.text(.keysNoteReleaseUnregistered)) }
        return KeysOverlay(bindings: bindings, fixed: fixed, warnings: table.missing.map(KeyWording.missing), ignored: table.ignored.map(KeyWording.ignored),
                           notes: notes)
    }
}
