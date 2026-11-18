// OApp — Spec 10 §15, every string the app shows, by its key in the string catalog.

import Foundation

/// Spec 10 §15, "Localization" — "Every string shown is in the app's string
/// catalog, English only in v1, and built from whole sentences with
/// placeholders rather than pieces joined in code, so another language can
/// reorder them. Counts use the catalog's plural variants".
///
/// A case is a key of `app/Shell/Localizable.xcstrings`, where its English
/// and a note for a translator live; `StringCatalogTests` fails when a key
/// is in one and not the other. Nothing in the app shows text that didn't
/// come through `Strings.text`, apart from what the operator and the library
/// wrote themselves.
public enum StringKey: String, CaseIterable, Sendable {
    case appName = "app.name"

    // The engine (Spec 10 §2)
    case engineStarting = "engine.starting"
    case engineConnected = "engine.connected"
    case engineStopped = "engine.stopped"
    case engineStoppedCount = "engine.stopped.count"
    case engineNotResponding = "engine.notResponding"
    case engineWrongAPI = "engine.wrongAPI"
    case engineNoSocket = "engine.noSocket"
    case engineNoHello = "engine.noHello"
    case engineFirstRunRefused = "engine.firstRunRefused"
    case engineAnotherBuild = "engine.anotherBuild"
    case engineConsoleLabel = "engine.console.label"
    case engineRestart = "engine.restart"
    case engineRestartTitle = "engine.restart.title"
    case engineRestartBody = "engine.restart.body"
    case engineRestartUnsaved = "engine.restart.unsaved"
    case engineBehindOutput = "engine.behindOutput"

    // Quitting (Spec 10 §2, choice U-2)
    case quitTitle = "quit.title"
    case quitUnsaved = "quit.unsaved"
    case quitQuit = "quit.quit"
    case quitKeepOutputs = "quit.keepOutputs"
    case quitStopping = "quit.stopping"
    case quitNotSavedTitle = "quit.notSaved.title"
    case quitNotSavedBody = "quit.notSaved.body"
    case cancel = "common.cancel"
    case ok = "common.ok"

    // First run (Spec 10 §13)
    case firstRunTitle = "firstRun.title"
    case firstRunIntro = "firstRun.intro"
    case firstRunCampus = "firstRun.campus"
    case firstRunCampusPlaceholder = "firstRun.campus.placeholder"
    case firstRunNewLibrary = "firstRun.newLibrary"
    case firstRunExistingLibrary = "firstRun.existingLibrary"
    case firstRunFolder = "firstRun.folder"
    case firstRunLibraryFolder = "firstRun.libraryFolder"
    case firstRunMachineFolder = "firstRun.machineFolder"
    case firstRunChoose = "firstRun.choose"
    case firstRunStart = "firstRun.start"
    case firstRunProblemCampus = "firstRun.problem.campus"
    case firstRunProblemLibraryGuarded = "firstRun.problem.library.guarded"
    case firstRunProblemMachineGuarded = "firstRun.problem.machine.guarded"
    case firstRunProblemLibraryOtherVolume = "firstRun.problem.library.otherVolume"
    case firstRunProblemMachineOtherVolume = "firstRun.problem.machine.otherVolume"
    case firstRunProblemLibraryNotAbsolute = "firstRun.problem.library.notAbsolute"
    case firstRunProblemMachineNotAbsolute = "firstRun.problem.machine.notAbsolute"
    case firstRunProblemSocket = "firstRun.problem.socket"
    case firstRunProblemNoLibrary = "firstRun.problem.noLibrary"
    case firstRunProblemNoLibraryFound = "firstRun.problem.noLibrary.found"
    case firstRunProblemInside = "firstRun.problem.inside"

    // Why something can't be done now (Spec 10 §1)
    case unavailableEngineAway = "unavailable.engineAway"
    case unavailableLocked = "unavailable.locked"
    case unavailableReadOnlyMasters = "unavailable.readOnlyMasters"

    // Menus (Spec 10 §4)
    case menuAbout = "menu.about"
    case menuQuit = "menu.quit"
    case aboutVersions = "about.versions"
    case aboutEngineAway = "about.engineAway"

    // The window's regions (Spec 10 §4-§8, §13)
    case outputTitle = "output.title"
    case outputDevice = "output.device"
    case outputFormat = "output.format"
    case outputFormatValue = "output.format.value"
    case outputReference = "output.reference"
    case outputReferenceLocked = "output.reference.locked"
    case outputReferenceFreeRun = "output.reference.freeRun"
    case outputReferenceNone = "output.reference.none"
    case outputState = "output.state"
    case outputStatePresenting = "output.state.presenting"
    case outputStateLost = "output.state.lost"
    case outputStateReleased = "output.state.released"
    case outputStateAbsent = "output.state.absent"
    case outputStack = "output.stack"
    case outputPresented = "output.presented"
    case outputLate = "output.late"
    case outputDropped = "output.dropped"
    case outputNoCount = "output.noCount"
    case dividerLeft = "divider.left"
    case dividerRight = "divider.right"
    case dividerPool = "divider.pool"
    case dividerSplit = "divider.split"

    // The window's regions (Spec 10 §4-§8, §13)
    case stripLock = "strip.lock"
    case stripUnlock = "strip.unlock"
    case stripResetAttributes = "strip.resetAttributes"
    case stripEndBehaviour = "strip.endBehaviour"
    case stripGrade = "strip.grade"
    case stripGradeNone = "strip.grade.none"
    case stripGradeNumbered = "strip.grade.numbered"
    case stripTransition = "strip.transition"
    case stripSelectOnly = "strip.selectOnly"
    case previewPicker = "preview.picker"

    // The window's regions (Spec 10 §4-§8, §13)
    case unavailableLater = "unavailable.later"
    case menuSettings = "menu.settings"
    case menuLock = "menu.lock"
    case menuFile = "menu.file"
    case menuNewPlaylist = "menu.newPlaylist"
    case menuNewList = "menu.newList"
    case menuImportMedia = "menu.importMedia"
    case menuTakeSnapshot = "menu.takeSnapshot"
    case menuRestoreSnapshot = "menu.restoreSnapshot"
    case menuEdit = "menu.edit"
    case menuUndo = "menu.undo"
    case menuRedo = "menu.redo"
    case menuCut = "menu.cut"
    case menuCopy = "menu.copy"
    case menuPaste = "menu.paste"
    case menuSelectAll = "menu.selectAll"
    case menuFindInList = "menu.findInList"
    case menuView = "menu.view"
    case menuMultiviewer = "menu.multiviewer"
    case menuShowArchived = "menu.showArchived"
    case menuCompactGrid = "menu.compactGrid"
    case menuCollapsePanel = "menu.collapsePanel"
    case menuResetLayout = "menu.resetLayout"
    case menuFullScreen = "menu.fullScreen"
    case menuGo = "menu.go"
    case menuBackToLive = "menu.backToLive"
    case menuGoToCue = "menu.goToCue"
    case menuHoldAutoAdvance = "menu.holdAutoAdvance"
    case menuCommandBar = "menu.commandBar"
    case menuMode = "menu.mode"
    case menuShow = "menu.show"
    case menuEditMode = "menu.editMode"
    case menuHelp = "menu.help"
    case menuKeys = "menu.keys"
    case menuReleaseOutput = "menu.releaseOutput"
    case topPositionCue = "top.position.cue"
    case topPositionReady = "top.position.ready"
    case topPositionLibrary = "top.position.library"
    case topPositionNothing = "top.position.nothing"
    case topPositionHint = "top.position.hint"
    case topAuto = "top.auto"
    case topOutputPresenting = "top.output.presenting"
    case topOutputLost = "top.output.lost"
    case topOutputReleased = "top.output.released"
    case topOutputAbsent = "top.output.absent"
    case topOutputBlackout = "top.output.blackout"
    case topTagAudioMuted = "top.tag.audioMuted"
    case topTagAudioLost = "top.tag.audioLost"
    case topTagPopup = "top.tag.popup"
    case topTagEngine = "top.tag.engine"
    case topTagSaving = "top.tag.saving"
    case topNoOutputs = "top.noOutputs"
    case topMirrored = "top.mirrored"
    case topRemote = "top.remote"
    case topNotActive = "top.notActive"
    case leftPlaylists = "left.playlists"
    case leftLibrary = "left.library"
    case leftSearch = "left.search"
    case tagArchived = "tag.archived"
    case tagLocal = "tag.local"
    case tagMissing = "tag.missing"
    case tagUpdated = "tag.updated"
    case tagDeleted = "tag.deleted"
    case tagLocked = "tag.locked"
    case tagUnknownCommand = "tag.unknownCommand"
    case tagLive = "tag.live"
    case menuMakeLive = "menu.makeLive"
    case menuShowInLibrary = "menu.showInLibrary"
    case fireRenameToFire = "fire.renameToFire"
    case fireRenumberToFire = "fire.renumberToFire"
    case gridBrowsing = "grid.browsing"
    case gridLists = "grid.lists"
    case gridCues = "grid.cues"
    case gridFromLibrary = "grid.fromLibrary"
    case gridSearch = "grid.search"
    case gridView = "grid.view"
    case gridViewChips = "grid.view.chips"
    case gridViewTriggers = "grid.view.triggers"
    case gridViewNotes = "grid.view.notes"
    case gridViewCompact = "grid.view.compact"
    case gridCcli = "grid.ccli"
    case gridRemoved = "grid.removed"
    case gridEmpty = "grid.empty"
    case gridMore = "grid.more"
    case gridCue = "grid.cue"
    case gridCueUnlabelled = "grid.cue.unlabelled"
    case triggerGo = "trigger.go"
    case triggerTime = "trigger.time"
    case triggerAdvance = "trigger.advance"
    case triggerAuto = "trigger.auto"
    case timeSeconds = "time.seconds"
    case chipNew = "chip.new"
    case chipHeld = "chip.held"
    case chipRedundant = "chip.redundant"
    case chipClear = "chip.clear"
    case chipAttributes = "chip.attributes"
    case attributeGrade = "attribute.grade"
    case attributeTransition = "attribute.transition"
    case attributeAudioTransition = "attribute.audioTransition"
    case attributeGain = "attribute.gain"
    case attributeChase = "attribute.chase"
    case poolTitle = "pool.title"
    case poolSearch = "pool.search"
    case poolAllMedia = "pool.allMedia"
    case poolKindAll = "pool.kind.all"
    case poolSortName = "pool.sort.name"
    case poolSortDate = "pool.sort.date"
    case poolImport = "pool.import"
    case poolUsedInList = "pool.usedInList"
    case poolReplaced = "pool.replaced"
    case poolThisMac = "pool.thisMac"
    case poolRecent = "pool.recent"
    case kindVideo = "kind.video"
    case kindImage = "kind.image"
    case kindAudio = "kind.audio"
    case kindSlide = "kind.slide"
    case kindText = "kind.text"
    case kindInput = "kind.input"
    case kindEmpty = "kind.empty"
    case kindMedia = "kind.media"
    case previewStack = "preview.stack"
    case previewFeeds = "preview.feeds"
    case previewOnly = "preview.only"
    case previewBlackout = "preview.blackout"
    case previewLabel = "preview.label"
    case nextNext = "next.next"
    case nextLast = "next.last"
    case nextGoto = "next.goto"
    case nextHold = "next.hold"
    case whyEndOfPlaylist = "why.endOfPlaylist"
    case whyStartOfPlaylist = "why.startOfPlaylist"
    case whyEndOfLibraryList = "why.endOfLibraryList"
    case whyNoCue = "why.noCue"
    case whyNothingLive = "why.nothingLive"
    case whyPickUp = "why.pickUp"
    case tabTransport = "tab.transport"
    case tabClears = "tab.clears"
    case tabMacros = "tab.macros"
    case tabPopups = "tab.popups"
    case tabCollapse = "tab.collapse"
    case tabExpand = "tab.expand"
    case transportNone = "transport.none"
    case transportPlay = "transport.play"
    case transportPause = "transport.pause"
    case transportStop = "transport.stop"
    case transportLoop = "transport.loop"
    case transportHold = "transport.hold"
    case transportClear = "transport.clear"
    case transportChannels = "transport.channels"
    case transportPosition = "transport.position"
    case clearsClearAll = "clears.clearAll"
    case clearsBlackoutStack = "clears.blackoutStack"
    case clearsBlackoutAll = "clears.blackoutAll"
    case clearsMuteAllAudio = "clears.muteAllAudio"
    case clearsResetChannels = "clears.resetChannels"
    case clearsClearPopups = "clears.clearPopups"
    case macrosNone = "macros.none"
    case macrosTile = "macros.tile"
    case popupSlot = "popup.slot"
    case popupEmpty = "popup.empty"
    case popupDraft = "popup.draft"
    case popupClearAfter = "popup.clearAfter"
    case popupStays = "popup.stays"
    case popupSeconds = "popup.seconds"
    case popupMinutes = "popup.minutes"
    case popupSend = "popup.send"
    case timerSlot = "timer.slot"
    case timerDuration = "timer.duration"
    case timerDown = "timer.down"
    case timerUp = "timer.up"
    case timerSet = "timer.set"
    case timerStart = "timer.start"
    case timerReset = "timer.reset"
    case stripClearSelected = "strip.clearSelected"
    case stripAll = "strip.all"
    case stripNone = "strip.none"
    case stripView = "strip.view"
    case stripViewAll = "strip.view.all"
    case stripChannel = "strip.channel"
    case stripSelect = "strip.select"
    case stripLoops = "strip.loops"
    case stripPaused = "strip.paused"
    case stripRemaining = "strip.remaining"
    case stripReset = "strip.reset"
    case stripDotShowing = "strip.dot.showing"
    case stripDotMuted = "strip.dot.muted"
    case stripDotAbsent = "strip.dot.absent"
    case stripFromCue = "strip.from.cue"
    case stripFromOne = "strip.from.one"
    case stripFromACue = "strip.from.aCue"
    case stripFromRestored = "strip.from.restored"
    case stripFromUi = "strip.from.ui"
    case stripFromKey = "strip.from.key"
    case stripFromOsc = "strip.from.osc"
    case stripFromMacro = "strip.from.macro"
    case stripFromApi = "strip.from.api"
    case stripFromOther = "strip.from.other"
    case meterLabel = "meter.label"
    case firstOutput = "first.output"
    case firstDefaults = "first.defaults"
    case firstSettings = "first.settings"
    case firstDismiss = "first.dismiss"
}

/// The table the keys are looked up in, and what is done to a string on its
/// way out. On the main thread, like everything that shows text.
@MainActor
public enum Strings {
    /// Where a key's format comes from: the count picks a plural variant
    /// where the key has them. The app reads its bundle's compiled catalog;
    /// a test reads the catalog file itself, since under `swift test` no
    /// bundle of the app's exists.
    public static var lookup: (_ key: String, _ count: Int?) -> String? = { key, _ in
        let found = Bundle.main.localizedString(forKey: key, value: "\u{0}", table: nil)
        return found == "\u{0}" ? nil : found
    }

    /// Spec 10 §18 — "under the accented pseudolanguage and one 40% longer,
    /// nothing is clipped": a transform every string passes through (Area 13
    /// reading: both pseudolanguages are the app's own, applied here).
    public static var transform: ((String) -> String)?

    /// The string for `key`, its placeholders filled in order. A key the
    /// table doesn't hold shows as the key itself, which a test catches and
    /// an operator can at least report.
    public static func text(_ key: StringKey, _ arguments: CVarArg...) -> String {
        format(key, count: nil, arguments)
    }

    /// The string for a key with plural variants, chosen by `count`, which
    /// is also its first placeholder: "3 changes aren't saved yet".
    public static func counted(_ key: StringKey, _ count: Int, _ arguments: CVarArg...) -> String {
        format(key, count: count, [count] + arguments)
    }

    private static func format(_ key: StringKey, count: Int?, _ arguments: [CVarArg]) -> String {
        let format = lookup(key.rawValue, count) ?? key.rawValue
        let text = arguments.isEmpty ? format : String(format: format, locale: Locale.current, arguments: arguments)
        return transform?(text) ?? text
    }
}

/// Spec 10 §18 — the two pseudolanguages the clipping test lays the window
/// out under.
public enum Pseudolanguage {
    /// Every letter that has one takes an accent, so a string that didn't
    /// come from the table stands out as plain, and tall marks test line
    /// heights.
    public static func accented(_ text: String) -> String {
        let pairs: [Character: Character] = ["a": "á", "e": "é", "i": "í", "o": "ó", "u": "ú", "A": "Á", "E": "É", "I": "Í", "O": "Ó", "U": "Ú",
                                             "c": "ç", "n": "ñ", "y": "ý", "C": "Ç", "N": "Ñ", "Y": "Ý"]
        return String(text.map { pairs[$0] ?? $0 })
    }

    /// "one 40% longer": the string with two fifths of its length again,
    /// padded with a letter that never appears in the app's own strings.
    public static func longer(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        return text + String(repeating: "~", count: Int((Double(text.count) * 0.4).rounded(.up)))
    }
}
