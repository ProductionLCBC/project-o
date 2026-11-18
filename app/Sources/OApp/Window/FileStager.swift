// OApp — Spec 8 §3, "Staged": the app's copy of a dropped file into its staging folder.

import Foundation

/// Spec 8 §3 — "A file dropped from outside both folders is first copied by
/// the app into its staging folder, `~/Library/Application Support/Project
/// O/Staging/`, outside both roots, and imported from there; on the same
/// volume the copy is a clone, which takes no time or space. The engine
/// never reads a dropped file where it lies, since that may be a place macOS
/// guards (§2)."
///
/// The copy runs off the main thread and answers on it. Each drop is copied
/// into a folder of its own under the staging folder, so two files of one
/// name never meet there (Area 13 reading); the engine removes a staged file
/// once its import is done and empties the folder at launch.
public final class FileStager: MediaStager {
    public let staging: URL
    /// The folders the engine reads in place: the library and machine roots and the media root.
    private let roots: @MainActor () -> [URL]

    public init(staging: URL, roots: @escaping @MainActor () -> [URL]) {
        self.staging = staging
        self.roots = roots
    }

    /// "`~/Library/Application Support/Project O/Staging/`".
    public static var standardFolder: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Project O/Staging", isDirectory: true)
    }

    /// Whether `url` lies under `folder`, by the paths as written.
    static func isInside(_ url: URL, _ folder: URL) -> Bool {
        url.standardizedFileURL.path.hasPrefix(folder.standardizedFileURL.path + "/")
    }

    @MainActor
    public func stage(_ path: String, done: @escaping @MainActor (Result<String, StagingError>) -> Void) {
        let source = URL(fileURLWithPath: path).standardizedFileURL
        // Only "a file dropped from outside both folders" is copied: one inside them is imported where it lies
        // (Spec 8 §3: "Already in the media root: indexed where it is").
        if roots().contains(where: { Self.isInside(source, $0) }) { return done(.success(source.path)) }
        let staging = self.staging
        DispatchQueue.global(qos: .userInitiated).async {
            let result: Result<String, StagingError>
            do {
                let folder = staging.appendingPathComponent(UUID().uuidString, isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let copy = folder.appendingPathComponent(source.lastPathComponent)
                try FileManager.default.copyItem(at: source, to: copy)
                result = .success(copy.path)
            } catch {
                result = .failure(StagingError(error.localizedDescription))
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { done(result) } }
        }
    }
}
