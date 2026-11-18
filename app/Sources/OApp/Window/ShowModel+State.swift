// OApp — Spec 10 §14: the last state's banner and what it offers, the snapshots, and what the engine and saving tags list.

import Foundation
import OCore

extension ShowModel {
    // MARK: - The last state (Spec 10 §14)

    /// The banner for this run's last state, or nil.
    public var restoreBanner: RestoreBanner? {
        guard store.isConnected, store.hasState else { return nil }
        return RestoreBanner.make(engine: store.engine, dismissedRun: settings.dismissedRestoreRun, lastSeen: lastSeen, catalog: store.catalog, live: store.live)
    }

    /// "Dismissed, it stays away for that run (§4)": the run is kept in `view.json`.
    public func dismissRestoreBanner() {
        guard !store.engine.run.isEmpty else { return }
        change { $0.dismissedRestoreRun = self.store.engine.run }
    }

    /// "Set Timers Again, which sets each timer to its last value from the
    /// `timers` topic and starts those that were running." Offered once: the
    /// timers are then the engine's again.
    @discardableResult
    public func setTimersAgain() -> Bool {
        guard case .setAgain(let timers)? = restoreBanner?.timers else { return false }
        guard send(Edits.setTimersAgain(timers)) else { return false }
        lastSeen?.timers = []
        changed([.grid])
        return true
    }

    /// "Fire 3 Verse 2 again", as an ordinary fire. Offered once.
    @discardableResult
    public func fireAgain() -> Bool {
        guard let sending = restoreBanner?.fireAgain?.sending, send(sending) else { return false }
        lastSeen?.live = LiveStatus()
        changed([.grid])
        return true
    }

    // MARK: - Snapshots (Spec 10 §14)

    /// File ▸ Take Snapshot (`system snapshot`), which the lock leaves working (§12).
    public func takeSnapshot() {
        edit(Edits.takeSnapshot(), at: .top) { [weak self] outcome in
            if outcome.kind == .ok { self?.say(.snapshotTaken, at: .top) }
        }
    }

    /// Why Restore a Snapshot… can't be opened now: the lock disables "the restore pickers" (§12).
    public var cannotRestore: CannotEdit? { cannotEditMachine.map(CannotEdit.unavailable) }

    /// "Restore a Snapshot… ... opens the snapshots from the `snapshots`
    /// query, newest first". Hands back the snapshots, and this machine's
    /// uuid so the sheet can say which another machine took.
    public func snapshots(then show: @escaping @MainActor (_ snapshots: [SnapshotSummary]) -> Void) {
        ask(.query("snapshots", [:])) { answer in
            show(answer.map(SnapshotSummary.all) ?? [])
        }
    }

    /// "Restore asks ... Then `system restore snapshot "ID"`, which runs on
    /// the engine's worker, so the sheet shows it working until its result.
    /// A refusal is shown with its reason in plain words". `began` runs once
    /// the operator said yes and the command went; `ended` with nil when the
    /// engine applied it, or with its refusal.
    public func restore(_ snapshot: SnapshotSummary, began: @escaping @MainActor () -> Void, ended: @escaping @MainActor (EngineRejection?) -> Void) {
        if let cannot = cannotRestore { return say(.notSent(cannot), at: .top) }
        let question = Confirmation.restoreSnapshot(takenAt: EditWording.when(snapshot.takenAt), mastersReadOnly: store.catalog?.mastersAreReadOnly == true)
        ask(question) { [weak self] in
            guard let self, self.store.cannotSend == nil, let transmit = self.transmit, let request = Edits.restore(snapshot: snapshot.id).request else {
                return ended(EngineRejection(code: "", message: ""))
            }
            began()
            transmit(request) { reply in
                guard let outcome = reply?.outcome else { return ended(EngineRejection(code: "", message: "")) }
                ended(outcome.kind == .rejected ? outcome.rejection ?? EngineRejection(code: "", message: "") : nil)
            }
        }
    }

    // MARK: - The tags' lists (Spec 10 §14)

    /// What a click on the saving tag lists.
    public var savingDetails: SavingDetails { SavingDetails(store.saving) }
}
