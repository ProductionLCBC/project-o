// OCore — Spec 10 §13, first run: the library and the machine a fresh install starts with.

import Foundation

/// Spec 10 §13 — "The engine writes the defaults (C1: the app never writes in
/// the roots)." What it writes is worked out here, from plain values: the
/// campus name, the Mac's time zone, the path between the roots and a list
/// of the devices the Mac has. Nothing here reads a clock, a file or a
/// device, so the table of §13 is tested as a table.
///
/// The uuids come from the caller: Spec 1 §4 — "Machines and libraries each
/// have a `uuid`, generated on first run and never changed." Area 19 reading:
/// the built-in objects keep the uuids the fixtures give them, as Preset 1's
/// is in code (Spec 6 §9); everything else gets a new one.
public enum FirstRun {
    // MARK: - The library

    /// Spec 10 §13 — "the first-run library: Spec 6 §9's channels 1 to 3,
    /// Presets 1 and 2 and text styles 1 and 2; Spec 1 §2's built-in
    /// transitions 1 to 3 (cut, dissolve, fade through a color); audio
    /// transitions 1 to 3 (cut, crossfade, fade through silence); all with
    /// the fixture library's values (Spec 1 §10); empty grades and macros; an
    /// empty media index". The folders (`media/` with `imports/` and
    /// `fonts/`) are the writer's.
    public static func library(name: String, uuid: () -> UUID) -> Library {
        Library(channels: channels(uuid: uuid), transitions: transitions, audioTransitions: audioTransitions,
                info: LibraryInfo(uuid: uuid(), name: name), textStyles: textStyles(uuid: uuid),
                presets: [Preset.builtInDefault, clockPreset(uuid: uuid)])
    }

    /// Area 19 reading, Adam's answer of 2026-11-15 — the first-run library is named for its campus.
    public static func libraryName(campus: String) -> String {
        campus.isEmpty ? "Library" : campus + " Library"
    }

    /// Spec 6 §9 — "1 Background (`usualContent` media); 2 Foreground (text);
    /// 3 Clock (`usualContent` any, default preset 2). All three are routed
    /// to audio output 1". Spec 1 §9 gives every one `renderSize` `largest`;
    /// Spec 10 §13 names channel 2's as the one value that isn't the
    /// fixture's, whose channel 2 is a fixed 1920 by 1080.
    static func channels(uuid: () -> UUID) -> [Channel] {
        [
            Channel(number: 1, label: "Background", decoderCap: 2, uuid: uuid(), defaultPreset: 1, audioOutputs: [1], renderSize: .largest, usualContent: .media),
            Channel(number: 2, label: "Foreground", decoderCap: 2, uuid: uuid(), defaultPreset: 1, audioOutputs: [1], renderSize: .largest, usualContent: .text),
            Channel(number: 3, label: "Clock", decoderCap: 2, uuid: uuid(), defaultPreset: 2, audioOutputs: [1], renderSize: .largest, usualContent: .any),
        ]
    }

    private static func fixed(_ text: String) -> UUID {
        UUID(uuidString: text) ?? UUID()
    }

    /// Spec 1 §2 — "Transitions 1–3 ship built in": cut, dissolve, fade through a color.
    static let transitions: [Transition] = [
        Transition(number: 1, type: .cut, ms: 0, label: "Cut", uuid: fixed("7a110000-0000-4000-8000-000000000001"), easing: .linear, builtIn: true),
        Transition(number: 2, type: .dissolve, ms: 500, label: "Dissolve", uuid: fixed("7a110000-0000-4000-8000-000000000002"), easing: .easeInOut, builtIn: true),
        Transition(number: 3, type: .fadeThroughColor, ms: 1000, label: "Fade through black", uuid: fixed("7a110000-0000-4000-8000-000000000003"),
                   easing: .easeInOut, color: Color(r: 0, g: 0, b: 0, a: 1), builtIn: true),
    ]

    /// Spec 10 §13 — "audio transitions 1 to 3 (cut, crossfade, fade through silence)".
    static let audioTransitions: [AudioTransition] = [
        AudioTransition(number: 1, type: .cut, ms: 0, offsetMs: 0, label: "Cut", uuid: fixed("a0d10000-0000-4000-8000-000000000001"), easing: .linear),
        AudioTransition(number: 2, type: .crossfade, ms: 500, offsetMs: 0, label: "Crossfade", uuid: fixed("a0d10000-0000-4000-8000-000000000002"), easing: .easeInOut),
        AudioTransition(number: 3, type: .fadeThroughSilence, ms: 800, offsetMs: -200, label: "Fade through silence",
                        uuid: fixed("a0d10000-0000-4000-8000-000000000003"), easing: .easeOut),
    ]

    /// Text style 2's values, which the Clock preset's box copies (Spec 1 §2: "Applying one copies its values").
    private static let caption = TextStyleValues(font: "HelveticaNeue-Medium", size: TextSize(value: 4.5, unit: .percent), weight: 500, color: .white,
                                                 alignment: .left, verticalAlignment: .center, lineSpacing: 1.2, letterSpacing: 0.5,
                                                 outline: Outline(width: 1, color: Color(r: 0, g: 0, b: 0, a: 1)),
                                                 shadow: Shadow(x: 0, y: 0, blur: 0, color: Color(r: 0, g: 0, b: 0, a: 0)),
                                                 allCaps: true, variations: ["wdth": 110, "wght": 500])

    /// Spec 6 §9 — "1 Body and 2 Caption, as in the fixtures, each with `verticalAlignment` `center`".
    static func textStyles(uuid: () -> UUID) -> [TextStyle] {
        let body = TextStyleValues(font: "HelveticaNeue-Bold", size: TextSize(value: 72, unit: .pt), weight: 700, color: .white,
                                   alignment: .center, verticalAlignment: .center, lineSpacing: 1.1, letterSpacing: 0,
                                   outline: Outline(width: 0, color: Color(r: 0, g: 0, b: 0, a: 1)),
                                   shadow: Shadow(x: 0, y: 2, blur: 8, color: Color(r: 0, g: 0, b: 0, a: 0.6)))
        return [TextStyle(number: 1, label: "Body", uuid: uuid(), values: body), TextStyle(number: 2, label: "Caption", uuid: uuid(), values: caption)]
    }

    /// Spec 6 §9 — "Preset 2, Clock: `\"*\"`: one static `[Time]` box in the top right corner".
    static func clockPreset(uuid: () -> UUID) -> Preset {
        var style = caption
        style.alignment = .right
        return Preset(number: 2, label: "Clock", uuid: uuid(), layouts: [
            .any: Layout(boxes: [
                Box(binding: .static(text: "[Time]"), frame: Frame(x: 0.69, y: 0.01, w: 0.28, h: 0.09),
                    fit: .text(TextFit(policy: .shrinkToFit, maxLines: 1, minSize: 12)),
                    textStyle: BoxTextStyle(values: style, fromStyle: 2), transition: BoxTransition(ref: 1)),
            ]),
        ])
    }

    // MARK: - The machine

    /// What the machine side is made from.
    public struct MachineRequest: Equatable, Sendable {
        /// "the campus name from `--campus`".
        public var campus: String
        /// "the Mac's time zone", as its identifier ("America/New_York").
        public var timeZone: String
        /// "`mediaRoot` the path from the machine root to the library root's `media/`".
        public var mediaRoot: String
        /// The ports, screens and audio devices the Mac has now.
        public var devices: DetectedDevices
        /// The screen "holding the app's window" (`display:<uuid>`), which
        /// never becomes an output; nil when the app named none.
        public var operatorScreen: String?

        public init(campus: String, timeZone: String, mediaRoot: String = "../library/media", devices: DetectedDevices = DetectedDevices(),
                    operatorScreen: String? = nil) {
            self.campus = campus
            self.timeZone = timeZone
            self.mediaRoot = mediaRoot
            self.devices = devices
            self.operatorScreen = operatorScreen
        }
    }

    /// Spec 10 §13 — the table of documents a machine root without
    /// `machine.json` gets: the settings, the outputs, their stacks, the
    /// audio outputs and §9's keys; "`inputs.json` and `clocks.json` empty,
    /// no playlists, no macros".
    public static func machine(_ request: MachineRequest, uuid: () -> UUID) -> Machine {
        // "A new uuid, the campus name from `--campus`, and Spec 1 §9's values, with the Mac's time zone, `libraryMode`
        // `writable` (choice U-10, E-2), `dropChannels` as Spec 8 §8 has them, and `mediaRoot`".
        let settings = MachineSettings(uuid: uuid(), campusName: request.campus, libraryMode: .writable, mediaRoot: request.mediaRoot,
                                       dropChannels: .firstRun, timeZone: request.timeZone)
        let outputs = outputs(devices: request.devices, operatorScreen: request.operatorScreen, uuid: uuid)
        return Machine(stacks: stacks(for: outputs, uuid: uuid), outputs: outputs, settings: settings,
                       audioOutputs: audioOutputs(devices: request.devices, outputs: outputs, uuid: uuid), keys: keys)
    }

    /// Spec 10 §13, "Which screens become outputs" (S3) — "Every DeckLink
    /// output port, then every screen except the one holding the app's
    /// window, numbered in that order: ports in the order the driver lists
    /// them, then screens left to right, top to bottom where two share a left
    /// edge. So output 1 is the main look. Labels are the devices' names. A
    /// screen's output takes its current mode, progressive and full range. A
    /// DeckLink port starts at 1920 by 1080, progressive, limited range,
    /// free-running, in the displays' rate family: 60 beside 60 Hz screens,
    /// 59.94 beside 59.94 Hz screens or with no screen output (choice U-11,
    /// Spec 4 §2). Every output's switch transition is 1 (cut) and its
    /// blackout transition 2 (dissolve) ... A Mac with one screen and no card
    /// gets no outputs, and neither does one whose screens are mirrored".
    ///
    /// Area 19 readings: with screens of both rate families the ports take
    /// the family of the first screen output; and when the app named its
    /// screen and that screen isn't among the Mac's, no screen becomes an
    /// output, since any of them might be the one the app's window is on.
    public static func outputs(devices: DetectedDevices, operatorScreen: String?, uuid: () -> UUID) -> [Output] {
        let own = operatorScreen.flatMap(DetectedScreen.uuid(ofDevice:))
        var screens = devices.screens.sorted { ($0.frame.x, $0.frame.y) < ($1.frame.x, $1.frame.y) }
        if let own {
            let known = screens.contains { $0.uuid == own }
            screens = known ? screens.filter { $0.uuid != own } : []
        }
        // "60 beside 60 Hz screens, 59.94 beside 59.94 Hz screens or with no screen output".
        let fractional = screens.first.map(\.mode.rate.isFractional) ?? true
        let portRate = fractional ? FrameRate(num: 60_000, den: 1001) : FrameRate(num: 60, den: 1)
        let transitions = OutputTransitions(switch: 1, blackout: 2)
        var outputs: [Output] = []
        // Output 1 is on stack 1; "output N's being stack N + 1" from the second on.
        func stack(_ number: Int) -> Int { number == 1 ? 1 : number + 1 }
        for port in devices.ports {
            let number = outputs.count + 1
            outputs.append(Output(number: number, defaultStack: stack(number), transitions: transitions, label: port.name, uuid: uuid(), kind: .sdi,
                                  device: port.device, format: VideoFormat(width: 1920, height: 1080, rate: portRate, interlaced: false),
                                  colorRange: .limited, genlock: .freeRun))
        }
        for screen in screens {
            let number = outputs.count + 1
            var format = screen.mode
            format.interlaced = false
            outputs.append(Output(number: number, defaultStack: stack(number), transitions: transitions, label: screen.name, uuid: uuid(), kind: .display,
                                  device: screen.device, format: format, colorRange: .full))
        }
        return outputs
    }

    /// Spec 10 §13 — "Stack 1, Main (channels 1 and 2), output 1's default;
    /// stack 2, Confidence (channels 2 and 3), on no output; then one stack
    /// per further output with channels 1 and 2, output N's being stack N +
    /// 1, labeled like its output (Spec 6 §9)".
    public static func stacks(for outputs: [Output], uuid: () -> UUID) -> [Stack] {
        var stacks = [
            Stack(number: 1, slots: [StackSlot(channel: 1), StackSlot(channel: 2)], label: "Main", uuid: uuid()),
            Stack(number: 2, slots: [StackSlot(channel: 2), StackSlot(channel: 3)], label: "Confidence", uuid: uuid()),
        ]
        for output in outputs where output.number >= 2 {
            stacks.append(Stack(number: output.number + 1, slots: [StackSlot(channel: 1), StackSlot(channel: 2)], label: output.label, uuid: uuid()))
        }
        return stacks
    }

    /// Spec 10 §13 — "Audio output 1, the system's default output device at
    /// first run, by its UID, with its first two channels; then one per
    /// DeckLink output's embedded audio, which no channel feeds until someone
    /// routes one".
    ///
    /// Area 19 readings: a Mac with no default output device gets no audio
    /// output 1, and the embedded ones keep their numbers from 2, so the
    /// channels, which are routed to audio output 1, feed none of them; the
    /// labels are the device's name and the port's name with "embedded".
    public static func audioOutputs(devices: DetectedDevices, outputs: [Output], uuid: () -> UUID) -> [AudioOutput] {
        var audio: [AudioOutput] = []
        if let device = devices.audio.first(where: \.isDefault) {
            let channels = device.channels == 1 ? [0] : [0, 1]
            audio.append(AudioOutput(number: 1, label: device.name, uuid: uuid(), kind: .device, device: .uid(device.uid), channels: channels))
        }
        var number = 2
        for output in outputs where output.kind == .sdi {
            audio.append(AudioOutput(number: number, label: output.label + " embedded", uuid: uuid(), kind: .sdiEmbedded,
                                     device: .sdiOutput(output.number), channels: [0, 1]))
            number += 1
        }
        return audio
    }

    /// Spec 10 §9, Defaults (R1) — "Space and → send `next`, ← sends
    /// `previous`, and ⇧⎋ sends `system clearall`. No per-channel clear keys
    /// ship, and section jumps ship unbound".
    public static let keys: [KeyBinding] = [
        KeyBinding(device: "keyboard", key: "space", command: .next),
        KeyBinding(device: "keyboard", key: "right", command: .next),
        KeyBinding(device: "keyboard", key: "left", command: .previous),
        KeyBinding(device: "keyboard", key: "shift+escape", command: .systemClearAll),
    ]
}
