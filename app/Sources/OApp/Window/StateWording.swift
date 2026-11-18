// OApp — Spec 10 §14: the words of the saving tag, the engine tag's list, the last state's banner and the snapshots sheet.

import Foundation
import OCore

/// Spec 10 §14, in the catalog's words.
@MainActor
public enum StateWording {
    // MARK: The saving tag

    /// "amber "Unsaved (3)" ..., amber "Disk low", and red "Disk full: changes not saved"".
    public static func tag(_ tag: SavingTag) -> String {
        switch tag {
        case .unsaved(let count): return Strings.text(.savingTagUnsaved, count)
        case .diskLow: return Strings.text(.savingTagDiskLow)
        case .diskFull: return Strings.text(.savingTagDiskFull)
        }
    }

    /// "A click lists what is waiting": a line for the documents, one for
    /// the disk when it isn't well, one for the log when it is in memory.
    public static func saving(_ details: SavingDetails) -> [String] {
        var lines = [details.waiting > 0 ? Strings.counted(.topTagSaving, details.waiting) : Strings.text(.savingWritten)]
        switch details.disk {
        case "low": lines.append(Strings.text(.savingDiskLow))
        case "full": lines.append(Strings.text(.savingDiskFull))
        default: break
        }
        if details.logInMemory { lines.append(Strings.text(.savingLogMemory)) }
        return lines
    }

    // MARK: The engine tag

    /// "The engine tag lists the standing badges in plain words".
    public static func badge(_ badge: EngineStatus.Badge) -> String {
        switch badge.kind {
        case "thermal": return Strings.text(.badgeThermal)
        case "memory": return Strings.text(.badgeMemory)
        case "watchdog": return Strings.text(.badgeWatchdog)
        case "gpu": return Strings.text(.badgeGpu)
        case "clock": return Strings.text(.badgeClock)
        case "keychain": return Strings.text(.badgeKeychain)
        default: return Strings.text(.badgeOther, badge.kind)
        }
    }

    // MARK: The last state

    /// The time of day in an ISO date, as the Mac's region writes one: "09:41". Nil when the date doesn't read.
    static func timeOfDay(_ iso: String?, locale: Locale, timeZone: TimeZone) -> String? {
        guard let iso else { return nil }
        let parser = ISO8601DateFormatter()
        var date = parser.date(from: iso)
        if date == nil {
            parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            date = parser.date(from: iso)
        }
        guard let date else { return nil }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private static func left(_ item: RestoreBanner.Left) -> String {
        switch (item.kind, item.why) {
        case ("channel", "missing"): return Strings.text(.restoreLeftChannelMissing, item.number)
        case ("channel", _): return Strings.text(.restoreLeftChannelGone, item.number)
        case ("output", _): return Strings.text(.restoreLeftOutputGone, item.number)
        case ("stack", _): return Strings.text(.restoreLeftStackGone, item.number)
        case ("popup", _): return Strings.text(.restoreLeftPopupClearing, item.number)
        default: return Strings.text(.restoreLeftOther)
        }
    }

    /// The banner's sentences: what happened, "what didn't come back", and
    /// "that timers came back unset"; or why nothing was put back.
    public static func banner(_ banner: RestoreBanner, locale: Locale = .current, timeZone: TimeZone = .current) -> [String] {
        switch banner.kind {
        case .restored(let writtenAt, let left):
            var sentences: [String]
            if let time = timeOfDay(writtenAt, locale: locale, timeZone: timeZone) {
                sentences = [Strings.text(.restoreRestoredAt, time)]
            } else {
                sentences = [Strings.text(.restoreRestored)]
            }
            var said: Set<String> = []
            for item in left {
                let sentence = self.left(item)
                if said.insert(sentence).inserted { sentences.append(sentence) }
            }
            if banner.timers != .none { sentences.append(Strings.text(.restoreTimersUnset)) }
            return sentences
        case .skipped(let reason):
            switch reason {
            case "clean": return [Strings.text(.restoreSkippedClean)]
            case "old": return [Strings.text(.restoreSkippedOld)]
            case "restoredBefore": return [Strings.text(.restoreSkippedRestoredBefore)]
            default: return [Strings.text(.restoreSkippedOther)]
            }
        }
    }

    /// "Fire 3 Verse 2 again".
    public static func fireAgain(_ fire: RestoreBanner.FireAgain) -> String {
        Strings.text(.restoreFireAgain, fire.number, fire.label)
    }

    // MARK: Snapshots

    private static func reason(_ reason: String) -> String {
        switch reason {
        case "launch": return Strings.text(.snapshotsReasonLaunch)
        case "playlist": return Strings.text(.snapshotsReasonPlaylist)
        case "timer": return Strings.text(.snapshotsReasonTimer)
        case "command": return Strings.text(.snapshotsReasonCommand)
        case "restore": return Strings.text(.snapshotsReasonRestore)
        default: return Strings.text(.snapshotsReasonOther)
        }
    }

    /// A snapshot's row: "each with its time, its reason and its size, and
    /// the campus and machine when another machine took it."
    public static func snapshot(_ snapshot: SnapshotSummary, thisMachine: String?, locale: Locale = .current, timeZone: TimeZone = .current) -> (title: String, detail: String) {
        let sizes = ByteCountFormatter()
        sizes.countStyle = .file
        let size = sizes.string(fromByteCount: Int64(snapshot.bytes))
        let title = EditWording.when(snapshot.takenAt, locale: locale, timeZone: timeZone)
        let own = snapshot.machine.isEmpty || thisMachine.map { $0.caseInsensitiveCompare(snapshot.machine) == .orderedSame } ?? true
        if own { return (title, Strings.text(.snapshotsDetail, reason(snapshot.reason), size)) }
        return (title, Strings.text(.snapshotsDetailOther, reason(snapshot.reason), size, snapshot.campus, String(snapshot.machine.prefix(8))))
    }

    /// "A refusal is shown with its reason in plain words: the renumbered
    /// objects for `conflict`, the channel on air for `onAir`, the disk for
    /// `diskFull`." The app's sentence for the code, then the engine's own
    /// words, which name the objects (Area 13 reading).
    public static func refusal(_ rejection: EngineRejection) -> String {
        let sentence = rejection.code.isEmpty ? UnavailableWording.sentence(for: .engineAway) : EditWording.rejection(code: rejection.code)
        return rejection.message.isEmpty ? Strings.text(.snapshotsRefused, sentence) : Strings.text(.snapshotsRefusedDetail, sentence, rejection.message)
    }
}
