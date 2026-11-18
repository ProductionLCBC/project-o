// OAppUI — Spec 10 §5, §6 and §7, drags: what goes on the pasteboard, and the mark a target shows.

import AppKit
import OApp

extension NSPasteboard.PasteboardType {
    /// The app's own drags: a playlist item, a library list or folder, a pool tile.
    static let projectO = NSPasteboard.PasteboardType("org.lcbc.projecto.drag")
}

/// Where a drag would land on a row: on it, or on the line above or below it.
enum DropMark: Equatable {
    case none
    case onto
    case above
    case below
}

/// The app's drags on the pasteboard. A drag from the Finder is read as its files.
@MainActor
enum Dragging {
    /// The types a target of the app's own drags registers for.
    static let own: [NSPasteboard.PasteboardType] = [.projectO]
    /// With the Finder's files as well (Spec 10 §6, §7; choice U-8).
    static let withFiles: [NSPasteboard.PasteboardType] = [.projectO, .fileURL]

    static func item(for payload: DragPayload) -> NSPasteboardItem {
        let item = NSPasteboardItem()
        item.setString(payload.text, forType: .projectO)
        return item
    }

    /// What a pasteboard carries: one of the app's own drags, or files.
    static func payload(from pasteboard: NSPasteboard) -> DragPayload? {
        if let text = pasteboard.pasteboardItems?.compactMap({ $0.string(forType: .projectO) }).first { return DragPayload(text: text) }
        let urls = (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        return urls.isEmpty ? nil : .files(urls.map(\.path))
    }

    /// Starts a drag of `view`'s picture carrying `payload`.
    static func begin(_ payload: DragPayload, from view: NSView & NSDraggingSource, event: NSEvent) {
        let item = NSDraggingItem(pasteboardWriter: self.item(for: payload))
        var picture: NSImage?
        if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let image = NSImage(size: view.bounds.size)
            image.addRepresentation(bitmap)
            picture = image
        }
        item.setDraggingFrame(view.bounds, contents: picture)
        view.beginDraggingSession(with: [item], event: event, source: view)
    }
}
