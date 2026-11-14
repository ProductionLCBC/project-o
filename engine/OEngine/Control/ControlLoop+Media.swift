// OEngine — Spec 8 §2–§4 and §7, the control thread's side of the media worker.

import Foundation
import OCore
import OFormats

extension ControlLoop {
    // MARK: - Attaching the worker (Spec 8 §4, at launch)

    /// Spec 8 §4 — the media worker: "The engine walks the media root and
    /// `machine/media/` at launch". Called once, before the engine starts.
    /// The first build then prunes ("Only the launch walk prunes, before
    /// anything can be undone") before any queued group runs, and Staging is
    /// emptied ("empties the folder at launch", Spec 8 §3).
    public func attachMedia(_ worker: MediaWorker) {
        mediaWorker = worker
        mediaLaunchPending = true
        if let refused = media.refused {
            log.warning("the media root \(refused.path) \(refused.problem.description), where media may not live (Spec 8 §2): nothing there is read, and library media shows missing")
        }
        worker.adopt(mediaSnapshot)
        worker.emptyStaging()
        worker.requestWalk()
        // Spec 8 §5 — posters and tiles missing since the last run, after the launch walk.
        worker.requestPosters()
    }

    /// What the worker reads: the indexes, the mode, the import folder, the cache and the missing set.
    var mediaSnapshot: MediaWorker.Snapshot {
        MediaWorker.Snapshot(library: library.mediaIndex, machine: machine.mediaLocal,
                             libraryWritable: machine.settings.libraryMode == .writable,
                             importFolder: machine.settings.defaultImportFolder, cache: mediaCache, missing: missing, files: mediaFiles)
    }

    var libraryWritable: Bool { machine.settings.libraryMode == .writable }

    // MARK: - What the worker found, through the one queue (Spec 8 §2)

    /// Spec 8 §2 — "The index changes an import job or the walk makes later
    /// aren't commands: they reach the control thread through the one queue
    /// (Spec 5 §2), bump the library revision and send the `library` event
    /// with cause `media`, but they aren't in the command log and never join
    /// the undo stack ... Operator lock doesn't stop them ... The engine log
    /// records them, by id (Spec 9 §2)."
    func absorbMedia(now: MonotonicTime) {
        guard let worker = mediaWorker else { return }
        if mediaLaunchPending {
            mediaLaunchPending = false
            pruneAtLaunch(worker, now: now)
        }
        for report in worker.takeReports() {
            switch report {
            case .listed(let listing): applyListing(listing)
            case .walked(let findings): applyWalk(findings, worker: worker, now: now)
            case .event(let fields): mediaEvent(fields)
            case .copied(let job, let file, let copied): applyCopied(copied, job: job, file: file, worker: worker, now: now)
            case .decided(let job, let file, let outcome): done(job: job, file: file, outcome)
            case .inPlace(let job, let file, let location): waitingInPlace.append((job, file, location))
            case .posters(let made, let removed): applyPosters(made, removed: removed, now: now)
            case .tiles(let names): mediaTiles = names
            }
        }
    }

    /// Spec 8 §4 — "Only the launch walk prunes, before anything can be
    /// undone: replaced entries whose file is gone and that nothing on this
    /// machine names, with their posters. Their mappings stay".
    func pruneAtLaunch(_ worker: MediaWorker, now: MonotonicTime) {
        let named = MediaReferences.named(library: library, machine: machine)
        let files = mediaFiles
        let result = MediaLaunch.prune(library: library.mediaIndex, machine: machine.mediaLocal, libraryWritable: libraryWritable,
                                       state: { files[$0] ?? .absent }, named: named)
        guard !result.changes.isEmpty else { return }
        let before = (library: library, machine: machine)
        library.mediaIndex = result.library
        machine.mediaLocal = result.machine
        indexesChanged(result.changes, before: before, now: now)
        worker.removePosters(result.posters, tilesOf: result.changes.map(\.id))
        if !result.posters.isEmpty {
            posterFiles.subtract(result.posters)
            posterFilesChanged = true
        }
    }

    /// Spec 8 §4 — the walk's first look: a file that went is missing at
    /// once; one that changed counts present until the walk hashes it
    /// (Adam's answer of 2026-11-11), unless the cache or its entry's own size
    /// and date say what it holds.
    func applyListing(_ listing: MediaListing) {
        let named = MediaLaunch.locations(library: library.mediaIndex, machine: machine.mediaLocal)
        var states = mediaFiles
        for location in states.keys where listing.folders.contains(location.folder) && listing.files[location] == nil {
            states[location] = .absent
        }
        for (location, stat) in listing.files {
            if let hash = mediaCache.hash(at: location, size: stat.size, modified: stat.modified) {
                states[location] = .holds(hash)
            } else if let entry = named[location]?.first(where: { $0.size == stat.size && $0.modified == stat.modified }) {
                states[location] = .holds(entry.id)
            } else if case .holds? = states[location] {
                states[location] = .unhashed
            } else if states[location] == nil || states[location] == .absent {
                states[location] = .unhashed
            }
        }
        if states != mediaFiles {
            mediaFiles = states
            mediaFilesChanged = true
        }
        // Spec 8 §5 — "a change under `.posters/` makes it look again".
        var posters = posterFiles.filter { !listing.folders.contains($0.folder) }
        posters.formUnion(listing.posters)
        if posters != posterFiles {
            posterFiles = posters
            posterFilesChanged = true
        }
    }

    /// Spec 8 §4 — the walk's rules against the indexes as they are now, and
    /// presence from what it found.
    func applyWalk(_ findings: MediaFindings, worker: MediaWorker, now: MonotonicTime) {
        let before = (library: library, machine: machine)
        let missingBefore = missing
        let result = MediaWalk.plan(MediaWalk.Input(library: library.mediaIndex, machine: machine.mediaLocal, libraryWritable: libraryWritable,
                                                    found: findings.found, folders: findings.folders,
                                                    overrideTargets: findings.overrideTargets, cache: mediaCache, now: variables.timestamp()))
        library.mediaIndex = result.library
        machine.mediaLocal = result.machine
        var states = mediaFiles
        for location in states.keys where findings.folders.contains(location.folder) && findings.found[location] == nil {
            states[location] = .absent
        }
        for (location, found) in findings.found { states[location] = found.state }
        if states != mediaFiles {
            mediaFiles = states
            mediaFilesChanged = true
        }
        if result.cache != mediaCache {
            mediaCache = result.cache
            worker.persist(mediaCache)
        }
        indexesChanged(result.changes, before: before, now: now)
        // Spec 8 §4 — reported, and "the reference report lists" kinds v1 doesn't take: once a run in the engine log.
        for note in result.notes where mediaNotesLogged.insert(note).inserted {
            log.info("media: " + note.text)
        }
        // Spec 8 §3 — files imported where they lie take their outcome from this walk.
        var waiting: [(job: String, file: String, location: MediaLocation)] = []
        for item in waitingInPlace {
            guard findings.folders.contains(item.location.folder),
                  let outcome = MediaImport.inPlaceOutcome(at: item.location, found: findings.found[item.location],
                                                           before: (before.library.mediaIndex, before.machine.mediaLocal),
                                                           presentBefore: { !missingBefore.contains($0) }, walk: result,
                                                           libraryWritable: libraryWritable) else {
                waiting.append(item)
                continue
            }
            done(job: item.job, file: item.file, outcome)
        }
        waitingInPlace = waiting
    }

    /// Spec 8 §3, step 5 — a copied file joins the index.
    func applyCopied(_ copied: MediaImport.Copied, job: String, file: String, worker: MediaWorker, now: MonotonicTime) {
        let before = (library: library, machine: machine)
        var index = library.mediaIndex
        var local = machine.mediaLocal
        let missingNow = missing
        let (outcome, changes) = MediaImport.apply(copied, library: &index, machine: &local, libraryWritable: libraryWritable,
                                                   presence: { missingNow.contains($0) ? .missing : .ok }, now: variables.timestamp())
        library.mediaIndex = index
        machine.mediaLocal = local
        mediaFiles[copied.location] = .holds(copied.file.id)
        mediaFilesChanged = true
        if let poster = copied.poster, let location = MediaLocation(copied.location.folder, poster) {
            posterFiles.insert(location)
            posterFilesChanged = true
        }
        mediaCache = MediaCache(records: mediaCache.records + [MediaCacheRecord(location: copied.location, size: copied.file.size,
                                                                                modified: copied.file.modified, hash: copied.file.id)],
                                extra: mediaCache.extra)
        worker.persist(mediaCache)
        indexesChanged(changes, before: before, now: now)
        done(job: job, file: file, outcome)
    }

    /// Spec 8 §5 — posters the worker made join their entries ("The entry's
    /// `poster` holds that path ...; it's null until extracted, and when
    /// extraction fails, which is reported"), as index changes with cause
    /// `media`; the poster files follow.
    func applyPosters(_ made: [MediaPosters.Made], removed: [MediaLocation], now: MonotonicTime) {
        let before = (library: library, machine: machine)
        var index = library.mediaIndex
        var local = machine.mediaLocal
        let changes = MediaPosters.apply(made, library: &index, machine: &local, libraryWritable: libraryWritable)
        library.mediaIndex = index
        machine.mediaLocal = local
        indexesChanged(changes, before: before, now: now)
        var posters = posterFiles.subtracting(removed)
        for m in made {
            if let path = m.path, let location = MediaLocation(MediaPosters.folder(of: m.tier), path) { posters.insert(location) }
        }
        if posters != posterFiles {
            posterFiles = posters
            posterFilesChanged = true
        }
    }

    /// Spec 8 §2 — an index change that isn't a command: the revision, the
    /// `library` event with cause `media`, the writer, and the engine log.
    func indexesChanged(_ changes: [MediaIndexChange], before: (library: Library, machine: Machine), now: MonotonicTime) {
        guard !changes.isEmpty else { return }
        lastRootsChanged = true
        documents?.noteEdits(before: before, library: library, machine: machine, executed: [], now: now)
        revision += 1
        lastLibraryEvents.append(LibraryEvent(rev: revision, cause: .media, changed: LibraryChange.merged(changes.flatMap(\.libraryChanges)),
                                              seq: commandLog.lastSeq))
        for change in changes { log.info(change.logText) }
    }

    // MARK: - The media topic (Spec 8 §7)

    /// Spec 8 §7 — one `media` event: "an event carries the `seq` of the log
    /// line that caused it, or of the last line logged before it" (Spec 2 §9).
    func mediaEvent(_ fields: [String: JSONValue]) {
        var members = fields
        members["type"] = .string("event")
        members["topic"] = .string("media")
        members["seq"] = .number(Double(commandLog.lastSeq))
        lastMediaEvents.append(.object(members))
    }

    /// Spec 8 §7 — "a final outcome per file": `imported`, `known` or
    /// `refused`, a refusal with its `reason`.
    func done(job: String, file: String, _ outcome: MediaImportOutcome) {
        var fields: [String: JSONValue] = ["job": .string(job), "op": .string("import"), "file": .string(file),
                                           "state": .string("done"), "outcome": .string(outcome.word)]
        switch outcome {
        case .imported(let id), .known(let id):
            fields["id"] = .string(id)
        case .refused(let reason, let detail):
            fields["reason"] = .string(reason.rawValue)
            if let detail { fields["format"] = .string(detail) }
            log.info("media import of \(file) refused: \(reason.rawValue)" + (detail.map { " (\($0))" } ?? ""))
        }
        mediaEvent(fields)
    }

    // MARK: - Commands (Spec 8 §2)

    /// Spec 8 §2 and §3 — the engine's say on a media command it runs: "A
    /// `media import` sent from elsewhere names its own PATH; one the engine
    /// can't read is rejected with `unreadable`", and a PATH where media may
    /// not live (Spec 8 §2) is never touched; "The result is `ok` with a
    /// `job` id once PATH is readable". `media rebuild` always runs.
    func prepareMedia(_ command: MediaCommand, source: CommandSource) -> Result<String?, Rejection> {
        guard case .importFile(let path) = command else { return .success(nil) }
        if let places = media.places, let problem = places.problem(with: URL(fileURLWithPath: path).standardizedFileURL.path) {
            return .failure(Rejection(reason: .unreadable, message: "\"\(path)\" \(problem.description), where the engine doesn't read"))
        }
        guard FileManager.default.isReadableFile(atPath: path) else {
            return .failure(Rejection(reason: .unreadable, message: "the engine can't read \"\(path)\""))
        }
        return .success(Self.newJob())
    }

    /// Spec 8 §7 — a job id, `j-` and eight hex characters, as `"j-3c1d9a20"`.
    static func newJob() -> String {
        let hex = String(UInt32.random(in: .min ... .max), radix: 16)
        return "j-" + String(repeating: "0", count: 8 - hex.count) + hex
    }

    /// Spec 8 §3 and §4 — an applied `media import` starts its job, and an
    /// applied `media rebuild` walks the media folders now.
    func startMediaWork(_ command: MediaCommand, job: String?) {
        switch command {
        case .importFile(let path):
            guard let job else { return }
            guard let worker = mediaWorker else {
                log.warning("media import \(job): no media worker runs here, so nothing is imported")
                return
            }
            worker.importPath(job: job, path: path)
        case .rebuild:
            mediaWorker?.requestWalk()
        default:
            break
        }
    }

    // MARK: - Missing state (Spec 8 §2, §7, §9)

    /// Spec 8 §2 — "Missing state is worked out this way per location, again
    /// after every walk and whenever either index reloads"; Spec 8 §7 — the
    /// `media` topic "carries changes in an item's missing state, which
    /// aren't index changes", one event per item. The worker then reads what
    /// was applied.
    func refreshMedia() {
        guard lastRootsChanged || mediaFilesChanged || posterFilesChanged else { return }
        let files = mediaFiles
        let next = MediaResolver.missingIds(library: library, machine: machine, state: { files[$0] ?? .absent })
        if next != missing {
            var items = Set(library.mediaIndex.entries.map(\.id))
            items.formUnion(machine.mediaLocal.entries.map(\.id))
            for id in next.symmetricDifference(missing).intersection(items).sorted() {
                mediaEvent(["op": .string("missing"), "id": .string(id), "missing": .bool(next.contains(id))])
            }
            missing = next
            mediaFilesChanged = true
        }
        // Spec 8 §5 — "a change under `.posters/` makes it look again", and so does a change in the media,
        // an image being its own poster.
        if posterFilesChanged || mediaFilesChanged { posters.postersChanged() }
        mediaWorker?.adopt(mediaSnapshot)
        // Spec 8 §5 — posters "by the walk when one is missing, and after an edit changes
        // `defaults.trimInMs`", and tiles "made again when missing": a pass over what was just adopted.
        mediaWorker?.requestPosters()
    }
}
