// OApp — Spec 10 §6 and §7: what the pool's header and the cells say about imports and drops, and the selected item's details.

import Foundation
import OCore

/// The words for imports and drops, from the catalog.
@MainActor
public enum ImportWording {
    /// How far an import is, as the Mac's region writes a part of a whole: "42%".
    static func part(_ fraction: Double, locale: Locale) -> String {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .percent
        formatter.maximumFractionDigits = 0
        let clamped = min(1, max(0, fraction))
        return formatter.string(from: NSNumber(value: clamped)) ?? "\(Int(clamped * 100))%"
    }

    /// Why what waited on an import wasn't sent (Spec 10 §6, §7).
    public static func notSent(_ why: NotSent) -> String {
        switch why {
        case .cueGone: return Strings.text(.dropCueGone)
        case .cueChanged(let channel): return Strings.text(.dropCueChanged, channel)
        // "the cell then says so ("Not sent: channel 2 changed while importing")".
        case .channelChanged(let channel): return Strings.text(.dropChannelChanged, channel)
        // "so the cell says to drop the file again."
        case .engineEnded: return Strings.text(.dropEngineEnded)
        }
    }

    /// What a cue's cell or a strip's cell says about a drop.
    public static func note(_ note: DropNote, locale: Locale = .current) -> String {
        switch note {
        case .copying: return Strings.text(.dropCopying)
        case .importing(_, let progress):
            return progress.map { Strings.text(.dropImportingPart, part($0, locale: locale)) } ?? Strings.text(.dropImporting)
        // "A refusal shows its reason and writes nothing."
        case .refused(let code): return Strings.text(.dropRefused, EditWording.rejection(code: code))
        case .copyFailed(let message): return Strings.text(.dropCopyFailed, message)
        case .notSent(let why): return notSent(why)
        // "the cell says to drop them on the pool": the sentence alone says what to do.
        case .cannot(.dropOnThePool): return EditWording.reason(.dropOnThePool)
        case .cannot(let reason): return EditWording.notice(.notSent(reason))
        }
    }

    /// One row of the pool header's jobs: "each file's progress and outcome".
    public static func row(_ row: ImportRow, locale: Locale = .current) -> String {
        switch row.state {
        case .copying: return Strings.text(.importCopying, row.name)
        case .importing(let progress):
            return progress.map { Strings.text(.importImportingPart, row.name, part($0, locale: locale)) } ?? Strings.text(.importImporting, row.name)
        case .done(let known): return Strings.text(known ? .importKnown : .importImported, row.name)
        case .refused(let code): return Strings.text(.importRefused, row.name, EditWording.rejection(code: code))
        case .copyFailed(let message): return Strings.text(.importCopyFailed, row.name, message)
        case .engineAway: return Strings.text(.importEngineAway, row.name)
        case .notSent(let why): return Strings.text(.importNotSent, row.name, notSent(why))
        }
    }

    /// Spec 10 §7 — "showing the live red and "Goes live on 2 Foreground"
    /// meanwhile"; a file says "Goes live on 2 Foreground when imported".
    public static func goesLive(channel: Int, label: String, whenImported: Bool) -> String {
        Strings.text(whenImported ? .dropGoesLiveImported : .dropGoesLive, channel, label)
    }

    /// What a strip cell says while a drag is held over it, or nil when it would take nothing.
    public static func hover(_ plan: DropPlan, label: String) -> String? {
        switch plan {
        case .live(_, let channel): return goesLive(channel: channel, label: label, whenImported: false)
        case .importLive(_, let channel): return goesLive(channel: channel, label: label, whenImported: true)
        default: return nil
        }
    }

    /// Spec 10 §6, "Single click selects and shows the item's size,
    /// duration, codec, sound and alpha, and its defaults, in the header."
    public static func details(_ item: MediaItem, locale: Locale = .current) -> String {
        let entry = item.entry
        var parts = [MediaPool.name(of: entry)]
        // Pixels are written plain: 1920, never 1,920.
        if let width = entry.width, let height = entry.height { parts.append(Strings.text(.poolDetailsSize, String(width), String(height))) }
        if let duration = entry.durationMs { parts.append(TimeText.clock(ms: duration)) }
        if let codec = entry.codec, !codec.isEmpty { parts.append(codec) }
        if entry.hasAudio { parts.append(Strings.text(.poolDetailsSound)) }
        if entry.hasAlpha { parts.append(Strings.text(.poolDetailsAlpha)) }
        let defaults = entry.defaults
        if defaults.trimInMs != nil || defaults.trimOutMs != nil { parts.append(Strings.text(.poolDetailsTrim)) }
        if defaults.loop { parts.append(Strings.text(.poolDetailsLoop)) }
        if let gain = defaults.gain {
            let formatter = NumberFormatter()
            formatter.locale = locale
            formatter.maximumFractionDigits = 1
            formatter.positivePrefix = formatter.plusSign
            parts.append(Strings.text(.poolDetailsGain, formatter.string(from: NSNumber(value: gain)) ?? "\(gain)"))
        }
        if let grade = defaults.grade { parts.append(Strings.text(.poolDetailsGrade, grade)) }
        if let sync = defaults.syncOffsetMs { parts.append(Strings.text(.poolDetailsSync, sync)) }
        if let channel = defaults.defaultChannel { parts.append(Strings.text(.poolDetailsChannel, channel)) }
        return parts.joined(separator: " · ")
    }
}
