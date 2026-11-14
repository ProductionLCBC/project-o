// OEngine — Spec 8 §6, the Trash: where `media delete` moves an item's files, and where `media undelete` finds them.

import Foundation
import OFormats

/// Spec 8 §6 — why a move to or from the Trash failed.
public enum MediaTrashFailure: Error, Equatable, Sendable {
    /// "A file on a volume with no Trash is refused with `noTrash`".
    case noTrash
    /// "if the Trash has been emptied, the undo fails with `conflict`": the
    /// file is no longer where the Trash put it.
    case gone
    /// A file appeared at the path being put back to: nothing moved, and the
    /// caller numbers the name again ("It never overwrites a file").
    case taken
    /// Anything else macOS refused, with its words for the engine log.
    case failed(String)
}

/// Spec 8 §11 — "Free space, the watcher's events, the Trash and the clock
/// are seams, so the tests run without real volumes or waits."
public protocol MediaTrash: Sendable {
    /// Spec 8 §6 — "The worker moves the item's file ... to the Trash": the
    /// absolute URL the Trash gave it.
    func trash(_ url: URL) -> Result<URL, MediaTrashFailure>
    /// Spec 8 §6 — `media undelete` "moves the files back to where they came
    /// from". Never over a file: the caller names a path nothing holds.
    func putBack(_ trashed: URL, to url: URL) -> Result<Void, MediaTrashFailure>
}

/// Spec 8 §6 — this Mac's Trash, through the Finder's own call: a file on the
/// startup volume goes to the user's Trash, under a name the Trash picks.
/// Putting it back is a rename on the same volume, which needs no access to
/// the Trash folder's listing.
public struct SystemTrash: MediaTrash {
    public init() {}

    public func trash(_ url: URL) -> Result<URL, MediaTrashFailure> {
        var resulting: NSURL?
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
        } catch let error as CocoaError where error.code == .featureUnsupported {
            return .failure(.noTrash)
        } catch {
            return .failure(.failed(String(describing: error)))
        }
        guard let trashed = resulting as URL? else { return .failure(.failed("the Trash gave no path for \(url.path)")) }
        return .success(trashed)
    }

    public func putBack(_ trashed: URL, to url: URL) -> Result<Void, MediaTrashFailure> {
        var info = stat()
        guard lstat(trashed.path, &info) == 0 else {
            let code = errno
            return code == ENOENT ? .failure(.gone) : .failure(.failed("\(trashed.path): \(String(cString: strerror(code)))"))
        }
        // A rename that never replaces a file: one that appeared at the path meanwhile is `taken`.
        switch LocalFiles.moveMedia(trashed, to: url) {
        case .moved: return .success(())
        case .taken: return .failure(.taken)
        case .failed(let why): return .failure(.failed("\(trashed.path) → \(url.path): \(why)"))
        }
    }
}
