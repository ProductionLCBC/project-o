// OAppUI — Spec 10 §13, the first-run sheet.

import AppKit
import SwiftUI
import OApp
import OCore

/// Spec 10 §13, "The roots" — what the sheet holds while the operator fills
/// it in, and the problems `FirstRunCheck` finds with it.
@MainActor
final class FirstRunModel: ObservableObject {
    enum Mode: Hashable {
        case new
        case existing
    }

    @Published var campus = ""
    @Published var mode = Mode.new
    @Published var folder: URL
    @Published var library: URL?
    @Published var machine: URL

    private let places: MediaPlaces
    private let contents: (URL) -> [String]?

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser, places: MediaPlaces? = nil,
         contents: @escaping (URL) -> [String]? = { try? FileManager.default.contentsOfDirectory(atPath: $0.path) }) {
        folder = FirstRunChoice.defaultFolder(home: home)
        machine = FirstRunChoice.defaultMachineRoot(home: home)
        self.places = places ?? MediaPlaces(home: home.path, isOnStartupVolume: FirstRunModel.isOnStartupVolume)
        self.contents = contents
    }

    /// The choice as it stands, or nil while an existing library's folder hasn't been picked.
    var choice: FirstRunChoice? {
        switch mode {
        case .new: return FirstRunChoice(campus: campus, place: .new(folder: folder))
        case .existing: return library.map { FirstRunChoice(campus: campus, place: .existing(library: $0, machine: machine)) }
        }
    }

    var problems: [FirstRunProblem] {
        guard let choice else {
            // No folder is picked for the library yet: that, and the campus name if it is missing too.
            let campusMissing = campus.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            return (campusMissing ? [.campusMissing] : []) + [.libraryPlace(.notAbsolute)]
        }
        return FirstRunCheck.problems(with: choice, places: places, contents: contents)
    }

    var sentences: [String] {
        problems.map(FirstRunWording.sentence)
    }

    /// Spec 8 §2 — whether a path is on the startup volume: its nearest
    /// folder that exists is on the volume the system started from.
    nonisolated static func isOnStartupVolume(_ path: String) -> Bool {
        var url = URL(fileURLWithPath: path)
        while !FileManager.default.fileExists(atPath: url.path), url.path != "/" { url.deleteLastPathComponent() }
        let volume = try? url.resourceValues(forKeys: [.volumeURLKey]).volume
        let startup = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeURLKey]).volume
        guard let volume, let startup else { return false }
        return volume.standardizedFileURL.path == startup.standardizedFileURL.path
    }
}

/// Spec 10 §13 — "a sheet asks for the campus name and where to keep the
/// library, with `~/Project O/` as the default ... The sheet can instead use
/// a library that is already there". A simple panel, so SwiftUI (Spec 10 §1).
struct FirstRunSheet: View {
    @ObservedObject var model: FirstRunModel
    var start: (FirstRunChoice) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(Strings.text(.firstRunTitle)).font(.title2.weight(.semibold))
            Text(Strings.text(.firstRunIntro)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            LabeledContent(Strings.text(.firstRunCampus)) {
                TextField(Strings.text(.firstRunCampusPlaceholder), text: $model.campus)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel(Strings.text(.firstRunCampus))
            }
            Picker("", selection: $model.mode) {
                Text(Strings.text(.firstRunNewLibrary)).tag(FirstRunModel.Mode.new)
                Text(Strings.text(.firstRunExistingLibrary)).tag(FirstRunModel.Mode.existing)
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            if model.mode == .new {
                folderRow(.firstRunFolder, model.folder) { model.folder = $0 }
            } else {
                folderRow(.firstRunLibraryFolder, model.library) { model.library = $0 }
                folderRow(.firstRunMachineFolder, model.machine) { model.machine = $0 }
            }
            ForEach(model.sentences, id: \.self) { sentence in
                Label(sentence, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button(Strings.text(.firstRunStart)) {
                    if let choice = model.choice { start(choice) }
                }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.problems.isEmpty)
            }
        }
        .padding(22)
        .frame(width: 560)
    }

    private func folderRow(_ label: StringKey, _ url: URL?, set: @escaping (URL) -> Void) -> some View {
        LabeledContent(Strings.text(label)) {
            HStack {
                Text(url?.path ?? "").lineLimit(1).truncationMode(.middle).frame(maxWidth: .infinity, alignment: .leading)
                Button(Strings.text(.firstRunChoose)) {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    panel.canCreateDirectories = true
                    panel.directoryURL = url
                    // Spec 10 §4 — "every confirmation and file dialog is a sheet on the main window": this one on
                    // the first-run sheet, which is itself a sheet there.
                    let picked: (NSApplication.ModalResponse) -> Void = { response in
                        if response == .OK, let folder = panel.url { set(folder) }
                    }
                    if let window = NSApplication.shared.keyWindow {
                        panel.beginSheetModal(for: window, completionHandler: picked)
                    } else {
                        panel.begin(completionHandler: picked)
                    }
                }
                .accessibilityLabel("\(Strings.text(label)): \(Strings.text(.firstRunChoose))")
            }
        }
    }
}
