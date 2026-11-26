// OApp — Spec 10 §15, the window's models put into words, every one from the string catalog.

import Foundation
import OCore

/// Spec 10 §15 — "Every string shown is in the app's string catalog ... and
/// built from whole sentences with placeholders rather than pieces joined in
/// code". The models say what is so; this says it in words, for the views
/// and for VoiceOver alike.
@MainActor
public enum ShowWording {
    // MARK: The top bar (Spec 10 §8)

    public static func position(_ position: LivePosition) -> String {
        switch position {
        case .cue(let playlist, let list, let number, let label): return Strings.text(.topPositionCue, playlist, list, number, label)
        case .ready(let playlist): return Strings.text(.topPositionReady, playlist)
        case .library(let list, let number, let label): return Strings.text(.topPositionLibrary, list, number, label)
        case .nothing: return Strings.text(.topPositionNothing)
        }
    }

    /// "1 Main · stack 1", "1 Main · lost", and "· Blackout" for a blacked-out stack.
    public static func output(_ dot: OutputDot) -> String {
        let text: String
        switch dot.state {
        case .presenting: text = Strings.text(.topOutputPresenting, dot.number, dot.label, dot.stack)
        case .lost: text = Strings.text(.topOutputLost, dot.number, dot.label)
        case .released: text = Strings.text(.topOutputReleased, dot.number, dot.label)
        case .absent: text = Strings.text(.topOutputAbsent, dot.number, dot.label)
        }
        return dot.isBlackedOut ? Strings.text(.topOutputBlackout, text) : text
    }

    public static func tag(_ tag: TopBarTag) -> String {
        switch tag {
        case .audioMuted: return Strings.text(.topTagAudioMuted)
        case .audioLost: return Strings.text(.topTagAudioLost)
        case .popup(let slot): return Strings.text(.topTagPopup, slot)
        case .engine(let badges): return Strings.counted(.topTagEngine, badges)
        case .saving(let tag): return StateWording.tag(tag)
        }
    }

    public static func note(_ note: OutputsNote) -> String {
        Strings.text(note == .mirrored ? .topMirrored : .topNoOutputs)
    }

    /// "Auto in 0:08".
    public static func countdown(ms: Int) -> String {
        Strings.text(.topAuto, TimeText.clock(ms: ms, roundUp: true))
    }

    // MARK: The grid (Spec 10 §6)

    public static func refusal(_ refusal: FireRefusal) -> String {
        Strings.text(refusal == .renameToFire ? .fireRenameToFire : .fireRenumberToFire)
    }

    /// A span for a trigger: "8 s", "2.5 s", and a clock from a minute, "1:30".
    public static func span(ms: Int, locale: Locale = .current) -> String {
        if let seconds = TimeText.shortSeconds(ms: ms, locale: locale) { return Strings.text(.timeSeconds, seconds) }
        return TimeText.clock(ms: ms)
    }

    /// The label line's trigger: "Go", "+8 s" for Time, "adv 12 s" for
    /// advance-after, and on the armed cue "Auto 0:08". A cue with a time
    /// and an advance shows both (Area 13 reading).
    public static func trigger(_ cell: CueCell, armedMs: Int? = nil, locale: Locale = .current) -> String {
        if cell.isArmed, let armedMs { return Strings.text(.triggerAuto, TimeText.clock(ms: armedMs, roundUp: true)) }
        var parts: [String] = []
        switch cell.trigger {
        case .go: if cell.advanceAfterMs == nil { parts.append(Strings.text(.triggerGo)) }
        case .time(let ms): parts.append(Strings.text(.triggerTime, span(ms: ms, locale: locale)))
        case .timecode(let code): parts.append(code)
        }
        if let advance = cell.advanceAfterMs { parts.append(Strings.text(.triggerAdvance, span(ms: advance, locale: locale))) }
        return parts.joined(separator: " · ")
    }

    public static func attribute(_ attribute: ChannelAttribute) -> String {
        switch attribute {
        case .grade: return Strings.text(.attributeGrade)
        case .transition: return Strings.text(.attributeTransition)
        case .audioTransition: return Strings.text(.attributeAudioTransition)
        case .gain: return Strings.text(.attributeGain)
        case .chase: return Strings.text(.attributeChase)
        }
    }

    /// A chip, for its hover and for VoiceOver: "2 Foreground: new", with the attributes it also writes.
    public static func chip(_ chip: CueChip, label: String) -> String {
        let key: StringKey
        switch chip.state {
        case .new: key = .chipNew
        case .held: key = .chipHeld
        case .redundant: key = .chipRedundant
        case .clear: key = .chipClear
        }
        let text = Strings.text(key, chip.channel, label)
        guard !chip.attributes.isEmpty else { return text }
        var seen: [ChannelAttribute] = []
        var names: [String] = []
        for write in chip.attributes where !seen.contains(write.attribute) {
            seen.append(write.attribute)
            names.append(attribute(write.attribute))
        }
        return Strings.text(.chipAttributes, text, ListFormatter.localizedString(byJoining: names))
    }

    /// A cue, for VoiceOver: "Cue 3, Verse 2", and that it is live.
    public static func cue(_ cell: CueCell) -> String {
        let text = cell.label.isEmpty ? Strings.text(.gridCueUnlabelled, cell.number) : Strings.text(.gridCue, cell.number, cell.label)
        return cell.isLive ? text + ", " + Strings.text(.tagLive) : text
    }

    /// The grid header's count: "3 lists" for a playlist, "4 cues" for a list.
    public static func count(_ model: GridModel) -> String {
        if let lists = model.listCount { return Strings.counted(.gridLists, lists) }
        if let cues = model.cueCount { return Strings.counted(.gridCues, cues) }
        return ""
    }

    /// A playlist's date as the tree shows it: month and day by the
    /// system's formatter, with the year when it isn't this year's (Area 13
    /// reading). Nil for no date, or one that doesn't read.
    public static func serviceDate(_ stored: String?, now: Date = Date(), locale: Locale = .current) -> String? {
        guard let stored else { return nil }
        let parts = stored.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        guard let date = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 12)) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate(calendar.component(.year, from: now) == parts[0] ? "MMMd" : "yMMMd")
        return formatter.string(from: date)
    }

    // MARK: The right column (Spec 10 §7)

    public static func why(_ reason: WhyNothing) -> String {
        switch reason {
        case .endOfPlaylist: return Strings.text(.whyEndOfPlaylist)
        case .startOfPlaylist: return Strings.text(.whyStartOfPlaylist)
        case .endOfLibraryList: return Strings.text(.whyEndOfLibraryList)
        case .noCue(let number, let title): return Strings.text(.whyNoCue, number, title)
        case .nothingLive: return Strings.text(.whyNothingLive)
        case .pickUp: return Strings.text(.whyPickUp)
        }
    }

    public static func tile(_ kind: ClearsTile.Kind) -> String {
        switch kind {
        case .clearAll: return Strings.text(.clearsClearAll)
        case .blackoutStack(let stack): return Strings.text(.clearsBlackoutStack, stack)
        case .blackoutAll: return Strings.text(.clearsBlackoutAll)
        case .muteAllAudio: return Strings.text(.clearsMuteAllAudio)
        case .resetChannels: return Strings.text(.clearsResetChannels)
        case .clearPopups: return Strings.text(.clearsClearPopups)
        }
    }

    /// "stays, 15 s, 30 s, 1 min, 2 min, 5 min".
    public static func clearAfter(_ seconds: Int?) -> String {
        guard let seconds else { return Strings.text(.popupStays) }
        return seconds < 60 ? Strings.text(.popupSeconds, seconds) : Strings.text(.popupMinutes, seconds / 60)
    }

    public static func kind(_ kind: StripCell.Kind) -> String {
        switch kind {
        case .empty: return Strings.text(.kindEmpty)
        case .text: return Strings.text(.kindText)
        case .video: return Strings.text(.kindVideo)
        case .image: return Strings.text(.kindImage)
        case .audio: return Strings.text(.kindAudio)
        case .slide: return Strings.text(.kindSlide)
        case .input: return Strings.text(.kindInput)
        case .other: return Strings.text(.kindMedia)
        }
    }

    public static func kind(_ kind: MediaKind) -> String {
        switch kind {
        case .video: return Strings.text(.kindVideo)
        case .image: return Strings.text(.kindImage)
        case .audio, .audioSet: return Strings.text(.kindAudio)
        case .slide, .template: return Strings.text(.kindSlide)
        }
    }

    /// "the remaining time on timed media ("loops", or "paused 1:23")".
    public static func remaining(_ remaining: StripCell.Remaining) -> String {
        switch remaining {
        case .counting(let ms): return Strings.text(.stripRemaining, TimeText.clock(ms: ms, roundUp: true))
        case .loops: return Strings.text(.stripLoops)
        case .paused(let ms): return Strings.text(.stripPaused, TimeText.clock(ms: ms, roundUp: true))
        }
    }

    /// "from Verse 2 · Great Is Thy Faithfulness", "restored", or the source.
    public static func origin(_ origin: StripCell.Origin) -> String {
        switch origin {
        case .cue(let label?, let list?): return Strings.text(.stripFromCue, label, list)
        case .cue(let label?, nil): return Strings.text(.stripFromOne, label)
        case .cue(nil, let list?): return Strings.text(.stripFromOne, list)
        case .cue(nil, nil): return Strings.text(.stripFromACue)
        case .restored: return Strings.text(.stripFromRestored)
        case .source("ui"): return Strings.text(.stripFromUi)
        case .source("key"): return Strings.text(.stripFromKey)
        case .source("osc"): return Strings.text(.stripFromOsc)
        case .source("macro"): return Strings.text(.stripFromMacro)
        case .source("api"): return Strings.text(.stripFromApi)
        case .source(let name): return Strings.text(.stripFromOther, name)
        }
    }

    /// "Stack 2 Confidence: showing".
    public static func dot(_ dot: StackDot) -> String {
        switch dot.state {
        case .showing: return Strings.text(.stripDotShowing, dot.stack, dot.label)
        case .muted: return Strings.text(.stripDotMuted, dot.stack, dot.label)
        case .absent: return Strings.text(.stripDotAbsent, dot.stack, dot.label)
        }
    }

    public static func unavailable(_ reason: Unavailable?) -> String? {
        reason.map(UnavailableWording.sentence)
    }

    // MARK: An output's details (Spec 10 §8)

    /// A video format: "1920 × 1080 · 60p", or "· 59.94i" for an interlaced
    /// one, named by its fields a second as a video engineer names it.
    public static func format(_ format: VideoFormat, locale: Locale = .current) -> String {
        let frames = Double(format.rate.num) / Double(max(1, format.rate.den))
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        formatter.maximumFractionDigits = 2
        let rate = formatter.string(from: NSNumber(value: format.interlaced ? frames * 2 : frames)) ?? ""
        // A pixel size is a name, not a quantity: "1920", never "1,920".
        return Strings.text(.outputFormatValue, String(format.width), String(format.height), rate + (format.interlaced ? "i" : "p"))
    }

    /// An SDI output's reference in a word; nil for an output with none to speak of.
    public static func reference(_ reference: String?) -> String? {
        switch reference {
        case "locked": return Strings.text(.outputReferenceLocked)
        case "freeRun": return Strings.text(.outputReferenceFreeRun)
        case "none": return Strings.text(.outputReferenceNone)
        default: return nil
        }
    }

    public static func state(_ state: OutputDot.State) -> String {
        switch state {
        case .presenting: return Strings.text(.outputStatePresenting)
        case .lost: return Strings.text(.outputStateLost)
        case .released: return Strings.text(.outputStateReleased)
        case .absent: return Strings.text(.outputStateAbsent)
        }
    }

    /// A count of frames, grouped as the system does; "not yet" before the engine has sent one.
    public static func frames(_ count: Int?, locale: Locale = .current) -> String {
        guard let count else { return Strings.text(.outputNoCount) }
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: count)) ?? "\(count)"
    }

    /// The rows of an output's details, each a name and its value, in the spec's order.
    public static func rows(_ details: OutputDetails, locale: Locale = .current) -> [(name: String, value: String)] {
        var rows: [(String, String)] = [(Strings.text(.outputDevice), details.device), (Strings.text(.outputFormat), format(details.format, locale: locale))]
        if let reference = reference(details.reference) { rows.append((Strings.text(.outputReference), reference)) }
        var state = self.state(details.state)
        if details.isBlackedOut { state = Strings.text(.topOutputBlackout, state) }
        rows.append((Strings.text(.outputState), state))
        rows.append((Strings.text(.outputPresented), frames(details.presented, locale: locale)))
        rows.append((Strings.text(.outputLate), frames(details.late, locale: locale)))
        rows.append((Strings.text(.outputDropped), frames(details.dropped, locale: locale)))
        return rows
    }
}
