// OApp — Spec 11 §5, what edit mode's model tells the Text page about what is live.

import Foundation
import OCore

extension EditModel {
    /// Spec 11 §5 — the live and the armed cue, and "Near the live cue": "The
    /// chunks of the three cues after the live cue, in playlist order, can
    /// show at once in a box at +1 to +3 ... While an output shows a box at +1
    /// to +3, they send when the caret leaves them ... while none does, they
    /// send while typing like every chunk and say nothing" (G-49).
    func textLive(list: List) -> TextDocument.Live {
        let live = model.store.live
        var result = TextDocument.Live(cue: nil, armed: live.armed?.cue, holdsBack: [])
        let uuid = list.uuid.uuidString.lowercased()
        // The list's cue is the live one only where it is live: in the live item, or fired from the library.
        if live.listUuid == uuid {
            if case .playlist(let playlist)? = source {
                if live.playlist == playlist, itemUuid == nil || live.item == itemUuid { result.cue = live.cue }
            } else if live.isLibraryList {
                result.cue = live.cue
            }
        }
        guard let catalog = model.store.catalog, !EditOnAir.lookaheadOutputs(catalog: catalog, dots: model.outputDots).isEmpty else { return result }
        var lists = model.store.lists
        lists[uuid] = ListDocument(list: list)
        result.holdsBack = EditOnAir.ahead(of: uuid, live: live, catalog: catalog, lists: lists)
        return result
    }
}
