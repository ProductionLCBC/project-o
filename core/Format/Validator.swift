// OCore — Spec 1 §8, the reference checks and the report.

import Foundation

/// How serious a report line is: hard failures are errors, broken references
/// warnings ("nothing refuses to load because of it"), skipped files info.
public enum IssueSeverity: String, Equatable, Sendable {
    case error, warning, info
}

/// Spec 1 §8 — what a report line is about.
public enum IssueCode: String, Equatable, Sendable {
    // Hard failures (§8) and skipped files (§5).
    case malformedJSON, schemaTooNew, schemaTooOld, unreadableDocument, ignoredFile
    // References to numbers that do not exist (§8).
    case missingChannel, missingPreset, missingTextStyle, missingGrade, missingTransition, missingAudioTransition
    case missingMacro, missingList, missingStack, missingOutput, missingAudioOutput, missingInput, missingBuiltIn
    // Numbers and slots (§8, §9, §3).
    case duplicateNumber, duplicateSlot, slotOutOfRange
    // Media (§7, §8) and fonts (§7).
    case unknownMedia, missingMedia, fontNotInstalled
    // Commands (§6, Spec 2 §7, Spec 2 §5).
    case unknownCommand, invalidCommand, guardOnCue, macroCycle
    // Playlists (§3).
    case playlistNameClash
}

/// One line of the report.
public struct ValidationIssue: Equatable, Sendable {
    public var severity: IssueSeverity
    public var code: IssueCode
    public var file: String?
    public var subject: String
    public var message: String

    public init(severity: IssueSeverity, code: IssueCode, file: String? = nil, subject: String, message: String) {
        self.severity = severity
        self.code = code
        self.file = file
        self.subject = subject
        self.message = message
    }

    public var line: String {
        "[\(severity.rawValue)] \(code.rawValue) \(subject): \(message)" + (file.map { " (\($0))" } ?? "")
    }
}

/// Spec 1 §8 — "Reference checks run on load and produce one report, which
/// is also what the pre-flight command reads". Lines are deduplicated, so one
/// broken reference is one line.
public struct ValidationReport: Equatable, Sendable {
    public var issues: [ValidationIssue]

    public init(issues: [ValidationIssue] = []) {
        self.issues = issues
    }

    public var isClean: Bool { issues.isEmpty }
    public var lines: [String] { issues.map(\.line) }

    public func issues(_ code: IssueCode) -> [ValidationIssue] {
        issues.filter { $0.code == code }
    }

    mutating func add(_ severity: IssueSeverity, _ code: IssueCode, file: String? = nil, subject: String, message: String) {
        let issue = ValidationIssue(severity: severity, code: code, file: file, subject: subject, message: message)
        if !issues.contains(issue) { issues.append(issue) }
    }

    mutating func add(_ failure: DocumentFailure) {
        let code: IssueCode
        switch failure {
        case .malformedJSON: code = .malformedJSON
        case .schemaTooNew: code = .schemaTooNew
        case .schemaTooOld: code = .schemaTooOld
        case .notADocument, .unreadable: code = .unreadableDocument
        }
        add(.error, code, file: failure.path, subject: failure.path, message: failure.message)
    }
}

/// What the validator can only learn from outside the roots: which media
/// files exist (Spec 1 §7, missing state) and which fonts are installed.
/// Nil means unknown, and that check is skipped.
public struct ValidationEnvironment: Sendable {
    public var existingMediaPaths: Set<String>?
    public var installedFonts: Set<String>?

    public init(existingMediaPaths: Set<String>? = nil, installedFonts: Set<String>? = nil) {
        self.existingMediaPaths = existingMediaPaths
        self.installedFonts = installedFonts
    }
}

/// Spec 1 §8 — "references to numbers that do not exist (a cue writing a
/// deleted channel, a slot naming a missing preset), duplicate channels in a
/// stack, duplicate numbers within a type, media ids with no path, and fonts
/// not installed." Plus §6's command flags, Spec 2 §5's macro cycles and
/// §3's playlist names. A library validates alone; with a machine, the
/// references that "meet by number" are checked too.
public enum Validator {
    public static func validate(library: Library, machine: Machine?, environment: ValidationEnvironment = ValidationEnvironment()) -> ValidationReport {
        var report = ValidationReport()
        var v = Checks(library: library, machine: machine, environment: environment, report: report)
        v.run()
        report = v.report
        return report
    }

    /// Spec 1 §9 — the stack rule the loader enforces, and §3's slot ranges.
    static func checkStacks(_ machine: Machine, into report: inout ValidationReport, file: String?) {
        for stack in machine.stacks {
            for index in stack.duplicateSlotIndices {
                let slot = stack.slots[index]
                report.add(.warning, .duplicateSlot, file: file, subject: "stack \(stack.number) slot \(index + 1)",
                           message: "channel \(slot.channel) appears again at offset \(slot.offset); the slot is empty at use")
            }
            for (index, slot) in stack.slots.enumerated() where !slot.isInRange {
                report.add(.warning, .slotOutOfRange, file: file, subject: "stack \(stack.number) slot \(index + 1)",
                           message: "offset \(slot.offset) must be -2 to +3 and opacity \(slot.opacity) 0 to 1")
            }
        }
    }
}

/// The checks, run in document order so the report reads like the roots.
struct Checks {
    let library: Library
    let machine: Machine?
    let environment: ValidationEnvironment
    var report: ValidationReport

    mutating func warn(_ code: IssueCode, _ subject: String, _ message: String) {
        report.add(.warning, code, subject: subject, message: message)
    }

    mutating func run() {
        duplicateNumbers()
        builtIns()
        channels()
        presets()
        for list in library.lists { commands(of: list, local: false) }
        for macro in library.macros { commands(of: macro) }
        indexDefaults(library.mediaIndex.entries)
        if let machine {
            for list in machine.localLists { commands(of: list, local: true) }
            for macro in machine.macros { commands(of: macro) }
            indexDefaults(machine.mediaLocal.entries)
            stacks(machine)
            outputs(machine)
            audioOutputs(machine)
            settings(machine)
            keys(machine)
            playlists(machine)
        }
        macroCycles()
        media()
        fonts()
    }

    // MARK: - Lookups

    func has(_ type: NumberedType, _ number: Int) -> Bool {
        switch type {
        case .channel: return library.channel(number) != nil
        case .preset: return number == 1 || library.preset(number) != nil
        case .textStyle: return library.textStyle(number) != nil
        case .grade: return library.grade(number) != nil
        case .transition: return library.transition(number) != nil
        case .audioTransition: return library.audioTransition(number) != nil
        case .macro: return library.macro(number) != nil || machine?.macro(number) != nil
        case .list: return library.list(number: number) != nil
        case .stack: return machine?.stack(number) != nil
        case .output: return machine?.output(number) != nil
        case .audioOutput: return machine?.audioOutput(number) != nil
        case .input: return machine?.input(number) != nil
        }
    }

    /// Machine-level references are checked only with a machine in hand.
    func checkable(_ type: NumberedType) -> Bool {
        switch type {
        case .stack, .output, .audioOutput, .input: return machine != nil
        default: return true
        }
    }

    static func code(for type: NumberedType) -> IssueCode {
        switch type {
        case .channel: return .missingChannel
        case .preset: return .missingPreset
        case .textStyle: return .missingTextStyle
        case .grade: return .missingGrade
        case .transition: return .missingTransition
        case .audioTransition: return .missingAudioTransition
        case .macro: return .missingMacro
        case .list: return .missingList
        case .stack: return .missingStack
        case .output: return .missingOutput
        case .audioOutput: return .missingAudioOutput
        case .input: return .missingInput
        }
    }

    mutating func reference(_ type: NumberedType, _ number: Int, from subject: String) {
        guard checkable(type), !has(type, number) else { return }
        warn(Checks.code(for: type), subject, "\(type.displayName) \(number) does not exist")
    }

    // MARK: - Numbers and built-ins

    mutating func duplicateNumbers() {
        func check<T>(_ type: NumberedType, _ objects: [T], _ number: (T) -> Int) {
            var seen: Set<Int> = []
            for object in objects where !seen.insert(number(object)).inserted {
                warn(.duplicateNumber, "\(type.displayName) \(number(object))", "more than one \(type.displayName) has this number; the first is used")
            }
        }
        check(.channel, library.channels, \.number)
        check(.textStyle, library.textStyles, \.number)
        check(.grade, library.grades, \.number)
        check(.transition, library.transitions, \.number)
        check(.audioTransition, library.audioTransitions, \.number)
        check(.preset, library.presets, \.number)
        check(.macro, library.macros + (machine?.macros ?? []), \.number)
        check(.list, library.lists, \.number)
        if let machine {
            check(.stack, machine.stacks, \.number)
            check(.output, machine.outputs, \.number)
            check(.audioOutput, machine.audioOutputs, \.number)
            check(.input, machine.inputs, \.number)
        }
    }

    /// Spec 1 §2 — "Preset 1 is built in"; "Transitions 1–3 ship built in".
    mutating func builtIns() {
        if library.preset(1) == nil {
            warn(.missingBuiltIn, "preset 1", "the built-in default preset is not on disk; the app's copy is used")
        }
        for n in 1...3 where library.transition(n) == nil {
            warn(.missingBuiltIn, "transition \(n)", "built-in transition \(n) is not on disk")
        }
    }

    // MARK: - Objects

    mutating func channels() {
        for channel in library.channels {
            let subject = "channel \(channel.number)"
            reference(.preset, channel.defaultPreset, from: subject)
            reference(.transition, channel.defaults.transition, from: subject)
            reference(.audioTransition, channel.defaults.audioTransition, from: subject)
            for output in channel.audioOutputs { reference(.audioOutput, output, from: subject) }
        }
    }

    mutating func presets() {
        for preset in library.presets {
            for key in preset.layouts.keys.sorted() {
                guard let layout = preset.layouts[key] else { continue }
                if case .stack(let n) = key { reference(.stack, n, from: "preset \(preset.number) layout \(key.string)") }
                for (index, box) in layout.boxes.enumerated() {
                    let subject = "preset \(preset.number) layout \(key.string) box \(index + 1)"
                    if let style = box.textStyle?.fromStyle { reference(.textStyle, style, from: subject) }
                    reference(.transition, box.transition.ref, from: subject)
                    if let grade = box.grade { reference(.grade, grade, from: subject) }
                }
            }
        }
    }

    mutating func indexDefaults(_ entries: [MediaEntry]) {
        for entry in entries {
            if let grade = entry.defaults.grade { reference(.grade, grade, from: "media \(entry.id)") }
            if let channel = entry.defaults.defaultChannel { reference(.channel, channel, from: "media \(entry.id)") }
        }
    }

    mutating func stacks(_ machine: Machine) {
        Validator.checkStacks(machine, into: &report, file: nil)
        for stack in machine.stacks {
            if let preset = stack.defaultPreset { reference(.preset, preset, from: "stack \(stack.number)") }
            for (index, slot) in stack.slots.enumerated() {
                let subject = "stack \(stack.number) slot \(index + 1)"
                reference(.channel, slot.channel, from: subject)
                if let preset = slot.preset { reference(.preset, preset, from: subject) }
            }
        }
    }

    mutating func outputs(_ machine: Machine) {
        for output in machine.outputs {
            let subject = "output \(output.number)"
            reference(.stack, output.defaultStack, from: subject)
            if let partner = output.keyFillPartner { reference(.output, partner, from: subject) }
            reference(.transition, output.transitions.switch, from: subject)
            reference(.transition, output.transitions.blackout, from: subject)
        }
    }

    mutating func audioOutputs(_ machine: Machine) {
        for audio in machine.audioOutputs {
            if case .sdiOutput(let n) = audio.device { reference(.output, n, from: "audio output \(audio.number)") }
        }
    }

    mutating func settings(_ machine: Machine) {
        reference(.stack, machine.settings.thumbnailStack, from: "machine thumbnailStack")
        if let m = machine.settings.startupMacro { reference(.macro, m, from: "machine startupMacro") }
        if let m = machine.settings.shutdownMacro { reference(.macro, m, from: "machine shutdownMacro") }
    }

    mutating func keys(_ machine: Machine) {
        for (index, binding) in machine.keys.enumerated() {
            command(binding.command, guard: nil, subject: "key binding \(index + 1)", commandSubject: "key binding \(index + 1)", onCue: false)
        }
    }

    mutating func playlists(_ machine: Machine) {
        var names: Set<String> = []
        for playlist in machine.playlists {
            let name = "playlist \(playlist.title)" + (playlist.serviceDate.map { " " + $0 } ?? "")
            if !names.insert(playlist.nameKey).inserted {
                warn(.playlistNameClash, name, "another playlist has this title and date; names are unique per machine")
            }
            for (index, item) in playlist.items.enumerated() {
                switch item.kind {
                case .header: break
                case .linked(let list): reference(.list, list, from: "\(name) item \(index + 1)")
                case .local(let uuid):
                    if machine.localList(uuid: uuid) == nil, library.list(uuid: uuid) == nil {
                        warn(.missingList, "\(name) item \(index + 1)", "local copy \(uuid.uuidString.lowercased()) is not in lists-local")
                    }
                }
            }
        }
    }

    // MARK: - Commands (Spec 1 §6)

    mutating func commands(of list: List, local: Bool) {
        for (c, cue) in list.cues.enumerated() {
            let subject = (local ? "local " : "") + "list \(list.number) cue \(c + 1)"
            for (i, entry) in cue.commands.enumerated() {
                command(entry.command, guard: entry.when, subject: subject, commandSubject: "\(subject) command \(i + 1)", onCue: true)
            }
        }
    }

    mutating func commands(of macro: Macro) {
        for (i, entry) in macro.commands.enumerated() {
            command(entry.command, guard: entry.when, subject: "macro \(macro.number)", commandSubject: "macro \(macro.number) command \(i + 1)", onCue: false)
        }
    }

    mutating func command(_ command: Command, guard condition: Guard?, subject: String, commandSubject: String, onCue: Bool) {
        if case .unknown(let cmd, _) = command {
            warn(.unknownCommand, commandSubject, "\(cmd) is not in the vocabulary; kept as written")
            return
        }
        if case .invalid(let cmd, _) = command {
            warn(.invalidCommand, commandSubject, "\(cmd): " + (command.invalidReason ?? "bad parameters") + "; kept as written")
            return
        }
        if onCue, condition != nil {
            warn(.guardOnCue, commandSubject, "a guard on a cue command is reserved and ignored in v1")
        }
        for type in NumberedType.allCases {
            command.forEachReference(of: type) { number in reference(type, number, from: subject) }
            condition?.forEachReference(of: type) { number in reference(type, number, from: subject) }
        }
        if let ref = command.mediaRef, MediaResolver.resolve(ref, library: library, machine: machine) == nil {
            warn(.unknownMedia, subject, "\(ref) is in neither media index")
        }
    }

    /// Spec 2 §5 — "A macro can call another macro; depth is capped at 8 and
    /// cycles are rejected at save." One line per cycle, naming it.
    mutating func macroCycles() {
        let macros = (library.macros + (machine?.macros ?? [])).sorted { $0.number < $1.number }
        var calls: [Int: [Int]] = [:]
        for macro in macros where calls[macro.number] == nil {
            var called: [Int] = []
            for entry in macro.commands { entry.command.forEachReference(of: .macro) { called.append($0) } }
            calls[macro.number] = called
        }
        var reported: Set<Int> = []
        for macro in macros where !reported.contains(macro.number) {
            var path = [macro.number]
            if let cycle = Checks.findCycle(from: macro.number, calls: calls, path: &path) {
                reported.formUnion(cycle)
                warn(.macroCycle, "macro \(macro.number)", "macros call each other in a loop: " + cycle.map { "macro \($0)" }.joined(separator: " → "))
            }
        }
    }

    static func findCycle(from start: Int, calls: [Int: [Int]], path: inout [Int]) -> [Int]? {
        guard let current = path.last else { return nil }
        for next in calls[current] ?? [] {
            if next == start { return path + [start] }
            if path.contains(next) { continue }
            path.append(next)
            if let cycle = findCycle(from: start, calls: calls, path: &path) { return cycle }
            path.removeLast()
        }
        return nil
    }

    // MARK: - Media and fonts

    /// Spec 1 §7 — "an id whose path no longer exists ... is listed by pre-flight."
    mutating func media() {
        guard let existing = environment.existingMediaPaths else { return }
        for id in MediaResolver.missingIds(library: library, machine: machine, existingPaths: existing).sorted() {
            let path = MediaResolver.resolve(id, library: library, machine: machine)?.path ?? ""
            warn(.missingMedia, id, "\(path) is not in the media root")
        }
    }

    /// Spec 1 §7 — "v1 references fonts by PostScript name and uses whatever
    /// is installed, with the machine's fallback font substituting and the
    /// substitution reported."
    mutating func fonts() {
        guard let installed = environment.installedFonts else { return }
        var used: [String] = library.textStyles.map(\.values.font)
        for preset in library.presets {
            for key in preset.layouts.keys.sorted() {
                for box in preset.layouts[key]?.boxes ?? [] {
                    if let font = box.textStyle?.values.font { used.append(font) }
                }
            }
        }
        if let fallback = machine?.settings.fallbackFont { used.append(fallback) }
        var seen: Set<String> = []
        for font in used where !installed.contains(font) && seen.insert(font).inserted {
            warn(.fontNotInstalled, font, "not installed on this machine; the fallback font substitutes")
        }
    }
}
