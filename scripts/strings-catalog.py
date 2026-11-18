#!/usr/bin/env python3
"""Spec 10 §15 — writes app/Shell/Localizable.xcstrings from the table below.

The catalog is written by hand, as symbolic keys with their English and a
note for a translator; this script only gives it Xcode's own layout (sorted
keys, two-space indent, " : " between a key and its value) so a diff reads.
Each key here is a case of StringKey (app/Sources/OApp/Strings/Strings.swift);
tests/OAppTests/StringCatalogTests.swift fails when the two differ.

    python3 -I scripts/strings-catalog.py            # rewrite the catalog
    python3 -I scripts/strings-catalog.py --check    # exit 1 if it would change

An entry is (key, English, note). English is a string, or for a count a pair
(one, other): Spec 10 §15, "Counts use the catalog's plural variants".
"""
import json
import os
import sys

ENTRIES = [
    ("app.name", "Project O", "The app's name, as the main window's title shows it."),

    # The engine (Spec 10 §2)
    ("engine.starting", "Starting the engine…", "Shown while the app waits for the engine it started, up to fifteen seconds."),
    ("engine.connected", "Connected to the engine.", "The status line of the first build's window, once the engine has answered."),
    ("engine.stopped", "The engine stopped. Restarting…", "A banner across the window when the engine process ends. The app starts it again by itself."),
    ("engine.stopped.count", ("The engine has stopped %lld time. Restarting…", "The engine has stopped %lld times. Restarting…"),
     "The same banner from the third end in a row: how many times the engine has ended since it last ran. The console log's last lines show under it."),
    ("engine.notResponding", "The engine isn’t responding", "A banner when the engine hasn't answered for five seconds. The outputs may still be playing."),
    ("engine.wrongAPI", "This engine is version %@ and speaks another version of the API, so Project O can’t drive it.",
     "A banner when the engine running is from an incompatible build. %@ is the engine's version number."),
    ("engine.noSocket", "The engine hasn’t opened its connection.", "A banner when an engine was started and fifteen seconds passed without it becoming reachable."),
    ("engine.noHello", "An engine holds this Mac’s folder and isn’t answering.", "A banner when an engine process is running on this machine's root and says nothing."),
    ("engine.firstRunRefused", "The engine couldn’t set up a new library here.", "A banner when the engine refused a first run; the setup sheet opens again."),
    ("engine.anotherBuild", "The engine running is version %1$@ and this is Project O %2$@. Restart it when the screens can go black for a moment.",
     "A banner, with the Restart the engine button, for as long as the engine running is from another build than the app. %1$@ is the engine's version, %2$@ the app's."),
    ("engine.console.label", "The engine’s console log, last lines", "The VoiceOver label of the box that shows the engine's last console lines under a banner."),
    ("engine.restart", "Restart the engine", "A button on the banner. It ends the engine process and starts it again."),
    ("engine.restart.title", "Restart the engine?", "The title of the confirmation that the Restart the engine button opens."),
    ("engine.restart.body", "The screens go black for a moment.", "The confirmation's first sentence."),
    ("engine.restart.unsaved", ("%lld change isn’t saved yet and will be lost.", "%lld changes aren’t saved yet and will be lost."),
     "The confirmation's second sentence, only while changes are waiting to be saved."),
    ("engine.behindOutput", "Project O is behind output %lld. Press ⌃⌥⌘⎋ to take it off this screen.",
     "A note shown above an output for ten seconds when it covers the app's window. %lld is the output's number; ⌃⌥⌘⎋ is Control-Option-Command-Escape."),

    # Quitting (Spec 10 §2, choice U-2)
    ("quit.title", "Quit Project O? The outputs will stop.", "The question ⌘Q asks."),
    ("quit.unsaved", ("%lld change isn’t saved yet", "%lld changes aren’t saved yet"), "Added under the quit question while changes are waiting to be saved."),
    ("quit.quit", "Quit", "The quit dialog's button that stops the engine and the outputs, then quits."),
    ("quit.keepOutputs", "Keep outputs running", "The quit dialog's button that quits the app and leaves the engine and the outputs running."),
    ("quit.stopping", "Stopping the engine…", "Shown while the app waits, up to ten seconds, for the engine to stop."),
    ("quit.notSaved.title", "Some changes couldn’t be saved", "The title of what the app shows, before it quits, when the engine couldn't write every document."),
    ("quit.notSaved.body", ("The engine couldn’t write %lld document: %@", "The engine couldn’t write %lld documents: %@"),
     "%lld is how many documents; %@ is the list of their file names."),
    ("common.cancel", "Cancel", "A button that closes a dialog and does nothing."),
    ("common.ok", "OK", "A button that closes a message."),

    # First run (Spec 10 §13)
    ("firstRun.title", "Set up Project O", "The title of the sheet a new Mac shows before anything else."),
    ("firstRun.intro", "Project O keeps a library and this Mac’s own setup in two folders. Choose where they go.", "The setup sheet's first line."),
    ("firstRun.campus", "Campus name", "The label of the field for the campus's name."),
    ("firstRun.campus.placeholder", "The name of this campus", "Placeholder text in the empty campus name field."),
    ("firstRun.newLibrary", "Start a new library", "A choice on the setup sheet: make a new, empty library."),
    ("firstRun.existingLibrary", "Use a library that is already here", "A choice on the setup sheet: use a library folder that exists, such as one synced from central."),
    ("firstRun.folder", "Folder", "The label of the folder a new library and this Mac's setup go in."),
    ("firstRun.libraryFolder", "Library folder", "The label of the existing library's folder."),
    ("firstRun.machineFolder", "This Mac’s folder", "The label of the folder that holds this Mac's own setup."),
    ("firstRun.choose", "Choose…", "A button that opens a folder picker."),
    ("firstRun.start", "Start", "The setup sheet's button that saves the choices and starts the engine."),
    ("firstRun.problem.campus", "Enter the campus name.", "Shown on the setup sheet while the campus name is empty."),
    ("firstRun.problem.library.guarded", "The library can’t be in %@, which macOS guards. Choose a folder outside Desktop, Documents and Downloads.",
     "%@ is Desktop, Documents or Downloads."),
    ("firstRun.problem.machine.guarded", "This Mac’s folder can’t be in %@, which macOS guards. Choose a folder outside Desktop, Documents and Downloads.",
     "%@ is Desktop, Documents or Downloads."),
    ("firstRun.problem.library.otherVolume", "The library must be on this Mac’s startup disk.", "Shown when the library's folder is on an external drive or a share."),
    ("firstRun.problem.machine.otherVolume", "This Mac’s folder must be on its startup disk.", "Shown when the machine folder is on an external drive or a share."),
    ("firstRun.problem.library.notAbsolute", "Choose a folder for the library.", "Shown when no usable folder is chosen for the library."),
    ("firstRun.problem.machine.notAbsolute", "Choose a folder for this Mac.", "Shown when no usable folder is chosen for the machine."),
    ("firstRun.problem.socket", "That folder’s path is too long: the engine’s connection would need %lld bytes there, and macOS allows 103. Choose a folder with a shorter path.",
     "%lld is the length in bytes of the path the engine's socket would have."),
    ("firstRun.problem.noLibrary", "That folder holds no library: there is no library.json in it.", "Shown when the folder picked as an existing library is empty or isn't there."),
    ("firstRun.problem.noLibrary.found", "That folder holds no library: there is no library.json in it. It holds %@.",
     "%@ is a list of a few of the names found in the folder."),
    ("firstRun.problem.inside", "This Mac’s folder can’t be inside the library’s folder, which is synced.", "Shown when the machine folder is inside the existing library."),

    # Why something can't be done now (Spec 10 §1)
    ("unavailable.engineAway", "The engine is away.", "The reason shown on a disabled control while the engine isn't connected."),
    ("unavailable.locked", "The station is locked.", "The reason shown on a disabled control while the operator lock is on."),
    ("unavailable.readOnlyMasters", "Masters are read-only on this Mac.", "The reason shown on a disabled edit of the library on a machine that may not edit it."),

    # Menus (Spec 10 §4)
    ("menu.about", "About Project O", "The app menu's first item."),
    ("menu.quit", "Quit Project O", "The app menu's last item."),
    ("about.versions", "Project O %1$@ · engine %2$@", "In the About panel: %1$@ is the app's version, %2$@ the running engine's."),
    ("about.engineAway", "Project O %@ · the engine is away", "In the About panel while no engine is connected. %@ is the app's version."),
    ("unavailable.later", "Not in this build yet.", "The reason shown on a control that a later build of the app will switch on."),

    # The menu bar (Spec 10 §4)
    ("menu.settings", "Settings…", "App menu."),
    ("menu.lock", "Lock Station", "App menu: turns the operator lock on."),
    ("menu.file", "File", "A menu's title."),
    ("menu.newPlaylist", "New Playlist", "File menu."),
    ("menu.newList", "New List", "File menu."),
    ("menu.importMedia", "Import Media…", "File menu."),
    ("menu.takeSnapshot", "Take Snapshot", "File menu: saves a copy of the whole library now."),
    ("menu.restoreSnapshot", "Restore a Snapshot…", "File menu."),
    ("menu.edit", "Edit", "A menu's title."),
    ("menu.undo", "Undo", "Edit menu."),
    ("menu.redo", "Redo", "Edit menu."),
    ("menu.cut", "Cut", "Edit menu."),
    ("menu.copy", "Copy", "Edit menu."),
    ("menu.paste", "Paste", "Edit menu."),
    ("menu.selectAll", "Select All", "Edit menu."),
    ("menu.findInList", "Find in List", "Edit menu: puts the cursor in the grid's search field."),
    ("menu.view", "View", "A menu's title."),
    ("menu.multiviewer", "Multiviewer", "View menu: shows every stack's preview at once."),
    ("menu.showArchived", "Show Archived Playlists", "View menu."),
    ("menu.compactGrid", "Compact Grid", "View menu: drops the cue thumbnails."),
    ("menu.collapsePanel", "Collapse Panel", "View menu: folds the tabbed panel to its tab bar."),
    ("menu.resetLayout", "Reset Layout", "View menu: puts the window's layout back to its defaults."),
    ("menu.fullScreen", "Enter Full Screen", "View menu."),
    ("menu.go", "Go", "A menu's title."),
    ("menu.backToLive", "Back to Live", "Go menu, and a button in the top bar: shows what is live in the grid again."),
    ("menu.goToCue", "Go to Cue…", "Go menu: puts the cursor in the go-to field."),
    ("menu.holdAutoAdvance", "Hold Auto-Advance", "Go menu: stops the cue that is about to fire by itself."),
    ("menu.commandBar", "Command Bar", "Go menu."),
    ("menu.mode", "Mode", "A menu's title."),
    ("menu.show", "Show", "Mode menu, and a button in the top bar: the mode for running a service."),
    ("menu.editMode", "Edit", "Mode menu, and a button in the top bar: the mode for building cues."),
    ("menu.help", "Help", "A menu's title."),
    ("menu.keys", "Keys", "Help menu, and the label of the top bar's ? button: shows what each key does."),
    ("menu.releaseOutput", "Release Output from This Screen", "Help menu: takes the engine's output off the screen the app is on."),

    # The top bar (Spec 10 §8)
    ("top.position.cue", "%1$@ · %2$@ · %3$lld %4$@", "What is live: playlist, list, the cue's number and its label, as in \"Sunday · Great Is Thy Faithfulness · 3 Verse 2\"."),
    ("top.position.ready", "%@ · ready", "A playlist is loaded and no cue has been fired. %@ is the playlist's title."),
    ("top.position.library", "Library · %1$@ · %2$lld %3$@", "A list fired from the library is live: its title, the cue's number and label."),
    ("top.position.nothing", "Nothing live", "No playlist is loaded and no list was fired."),
    ("top.position.hint", "Nothing live · Click a cue, or choose Make Live", "As above, while a playlist is shown in the grid."),
    ("top.auto", "Auto in %@", "The countdown to a cue that will fire by itself. %@ is a clock, as in 0:08."),
    ("top.output.presenting", "%1$lld %2$@ · stack %3$lld", "One output: its number, its label and the stack it shows."),
    ("top.output.lost", "%1$lld %2$@ · lost", "An output whose device stopped taking frames."),
    ("top.output.released", "%1$lld %2$@ · released", "An output taken off its screen on purpose."),
    ("top.output.absent", "%1$lld %2$@ · absent", "An output whose device isn't connected."),
    ("top.output.blackout", "%@ · Blackout", "Added to an output's text while its stack is blacked out. %@ is that text."),
    ("top.tag.audioMuted", "Audio muted", "A tag in the top bar."),
    ("top.tag.audioLost", "Audio lost", "A tag in the top bar: an audio output has gone silent."),
    ("top.tag.popup", "Popup %lld", "A tag in the top bar while a popup message is up. %lld is its slot."),
    ("top.tag.engine", ("%lld engine notice", "%lld engine notices"), "A tag in the top bar counting the engine's standing warnings."),
    ("top.tag.saving", ("%lld change not saved yet", "%lld changes not saved yet"), "A tag in the top bar counting documents waiting to be written."),
    ("top.noOutputs", "No outputs", "In the top bar on a Mac with no output configured."),
    ("top.mirrored", "Screens are mirrored: the room sees this window", "In the top bar while macOS mirrors the screens."),
    ("top.remote", "Remote commands", "The label of the dot that lights while commands arrive from outside the app."),
    ("top.notActive", "Project O isn’t the active app: keys are going to %@. Click here to come back.", "Across the top bar while another app is in front. %@ is that app's name."),

    # The left column (Spec 10 §5)
    ("left.playlists", "Playlists", "The title of the playlists tree."),
    ("left.library", "Library", "The title of the library tree."),
    ("left.search", "Search the library", "The placeholder and label of the library's search field."),
    ("tag.archived", "archived", "A small tag on an archived playlist."),
    ("tag.local", "local", "A small tag on a list that is this Mac's own copy."),
    ("tag.missing", "missing", "A small tag on something whose file or list is gone."),
    ("tag.updated", "updated", "A small tag on a list that changed on disk since it was last fired."),
    ("tag.deleted", "deleted", "A small tag on a media item that was deleted and is still used."),
    ("tag.locked", "locked", "A small tag on a locked channel."),
    ("tag.unknownCommand", "unknown command", "A small tag on a cue that holds a command this build doesn't know."),
    ("tag.live", "live", "Read by VoiceOver on whatever is live."),
    ("menu.makeLive", "Make Live", "A playlist's menu: loads it, with no cue fired."),
    ("menu.showInLibrary", "Show in Library", "A playlist item's menu."),
    ("fire.renameToFire", "Rename to fire", "Why a playlist can't be fired: another has the same title."),
    ("fire.renumberToFire", "Renumber to fire", "Why a list can't be fired: another has the same number."),

    # The grid (Spec 10 §6)
    ("grid.browsing", "Browsing", "In the grid's header while it shows something that isn't live."),
    ("grid.lists", ("%lld list", "%lld lists"), "The grid's header for a playlist."),
    ("grid.cues", ("%lld cue", "%lld cues"), "The grid's header for a list, and each list's header."),
    ("grid.fromLibrary", "From the library: Next stops at its last cue", "The grid's header for a list opened from the library."),
    ("grid.search", "Find in list", "The placeholder and label of the grid's search field."),
    ("grid.view", "View", "A button that opens the grid's view options."),
    ("grid.view.chips", "Chips", "Grid view option."),
    ("grid.view.triggers", "Triggers", "Grid view option."),
    ("grid.view.notes", "Notes", "Grid view option."),
    ("grid.view.compact", "Compact", "Grid view option: no thumbnails."),
    ("grid.ccli", "CCLI %@", "A list header: the song's CCLI number."),
    ("grid.removed", "Removed: finishing", "On a list that was removed from the playlist while it is still live."),
    ("grid.empty", "Choose a playlist or a list.", "In the grid before anything is shown."),
    ("grid.more", "+%lld", "After the eighth channel chip: how many more channels there are."),
    ("grid.cue", "Cue %1$lld, %2$@", "VoiceOver: a cue's number and label."),
    ("grid.cue.unlabelled", "Cue %lld", "VoiceOver: a cue with no label."),
    ("trigger.go", "Go", "A cue that waits for the operator."),
    ("trigger.time", "+%@", "A cue that fires a time after the one before. %@ is the time, as in \"8 s\" or \"1:30\"."),
    ("trigger.advance", "adv %@", "A cue after which the next fires by itself. %@ is the time."),
    ("trigger.auto", "Auto %@", "On the cue about to fire by itself. %@ is a clock, as in 0:08."),
    ("time.seconds", "%@ s", "A number of seconds. %@ is the number, already formatted."),
    ("chip.new", "%1$lld %2$@: new", "VoiceOver and hover, a channel chip: the cue changes this channel. Number and label."),
    ("chip.held", "%1$lld %2$@: held", "A channel chip: the cue leaves this channel as it was."),
    ("chip.redundant", "%1$lld %2$@: redundant, it writes what is already there", "A channel chip: the cue's write changes nothing."),
    ("chip.clear", "%1$lld %2$@: cleared", "A channel chip: the cue empties this channel."),
    ("chip.attributes", "%1$@ · also writes %2$@", "A channel chip that also writes attributes. %1$@ is the chip's text, %2$@ a list of attributes."),
    ("attribute.grade", "grade", "A channel attribute, in a list."),
    ("attribute.transition", "transition", "A channel attribute, in a list."),
    ("attribute.audioTransition", "audio transition", "A channel attribute, in a list."),
    ("attribute.gain", "gain", "A channel attribute, in a list."),
    ("attribute.chase", "chase", "A channel attribute, in a list."),

    # The media pool (Spec 10 §6)
    ("pool.title", "Media", "The title of the media pool panel."),
    ("pool.search", "Search media", "The placeholder and label of the pool's search field."),
    ("pool.allMedia", "All Media", "The first row of the pool's folders."),
    ("pool.kind.all", "All", "The pool's kind filter."),
    ("pool.sort.name", "Name", "The pool's sort order."),
    ("pool.sort.date", "Date Added", "The pool's sort order."),
    ("pool.import", "Import…", "A button in the pool's header."),
    ("pool.usedInList", "Used in this list", "A filter in the pool's header."),
    ("pool.replaced", "Replaced", "A filter in the pool's header: items a newer file replaced."),
    ("pool.thisMac", "this Mac", "On a media item kept on this Mac only."),
    ("pool.recent", "Recently used", "The label of the strip of recently used media."),
    ("kind.video", "Video", "A kind of content."),
    ("kind.image", "Image", "A kind of content."),
    ("kind.audio", "Audio", "A kind of content."),
    ("kind.slide", "Slide", "A kind of content."),
    ("kind.text", "Text", "A kind of content."),
    ("kind.input", "Input", "A kind of content: a live video input."),
    ("kind.empty", "Empty", "A channel with nothing on it."),
    ("kind.media", "Media", "A kind of content, when the app can't tell more."),

    # The right column (Spec 10 §7)
    ("preview.stack", "Stack %1$lld %2$@", "A stack: its number and label."),
    ("preview.feeds", "feeds %@", "Under the preview: the outputs this stack is on. %@ is a list of outputs."),
    ("preview.only", "preview only", "Under the preview when no output shows this stack."),
    ("preview.blackout", "Blackout", "On a preview whose stack is blacked out."),
    ("preview.label", "Preview of stack %1$lld %2$@", "VoiceOver: the preview picture."),
    ("next.next", "Next", "The large button that fires the next cue."),
    ("next.last", "Last", "The button that goes back one cue."),
    ("next.goto", "Go to cue", "The placeholder and label of the field that takes a cue number."),
    ("next.hold", "Hold", "The button that stops the cue about to fire by itself."),
    ("why.endOfPlaylist", "End of the playlist", "Why Next did nothing."),
    ("why.startOfPlaylist", "Start of the playlist", "Why Last did nothing."),
    ("why.endOfLibraryList", "End of this song: it was fired from the library", "Why Next did nothing."),
    ("why.noCue", "No cue %1$lld in %2$@", "Why the go-to field did nothing. The number typed, and the list's title."),
    ("why.nothingLive", "Nothing is live", "Why a key or button did nothing."),
    ("why.pickUp", "Click a cue to pick up where you were", "Why Next did nothing after a restart that lost its place."),
    ("tab.transport", "Transport", "A tab of the right column's panel."),
    ("tab.clears", "Clears", "A tab of the right column's panel."),
    ("tab.macros", "Macros", "A tab of the right column's panel."),
    ("tab.popups", "Popups", "A tab of the right column's panel."),
    ("tab.collapse", "Collapse the panel", "The label of the panel's – button."),
    ("tab.expand", "Open the panel", "The label of the panel's + button."),
    ("transport.none", "No transport", "In the Transport tab when the selection has nothing to play."),
    ("transport.play", "Play", "A button."),
    ("transport.pause", "Pause", "A button."),
    ("transport.stop", "Stop", "A button."),
    ("transport.loop", "Loop", "What media does at its end."),
    ("transport.hold", "Hold", "What media does at its end: stays on its last frame."),
    ("transport.clear", "Clear", "A button, and what media does at its end."),
    ("transport.channels", ("%lld channel", "%lld channels"), "In the Transport tab with several channels selected."),
    ("transport.position", "%1$@ of %2$@", "A position in media: two clocks, as in \"0:12 of 1:00\"."),
    ("clears.clearAll", "Clear All", "A tile, and the strip's wide red button: empties every channel."),
    ("clears.blackoutStack", "Blackout Stack %lld", "A tile."),
    ("clears.blackoutAll", "Blackout All", "A tile."),
    ("clears.muteAllAudio", "Mute All Audio", "A tile."),
    ("clears.resetChannels", "Reset Channels", "A tile: puts every channel's attributes back to their defaults."),
    ("clears.clearPopups", "Clear Popups", "A tile, and a button beside Clear All."),
    ("macros.none", "No macros yet.", "In the Macros tab of a library with none."),
    ("macros.tile", "Macro %1$lld %2$@", "VoiceOver: a macro's number and label."),
    ("popup.slot", "Popup %lld", "A row of the Popups tab."),
    ("popup.empty", "nothing up", "In a popup's row while its slot is empty."),
    ("popup.draft", "Message for popup %lld", "The label of a popup row's text field."),
    ("popup.clearAfter", "Clear after", "The label of a popup row's time choice."),
    ("popup.stays", "Stays", "A popup that stays up until cleared."),
    ("popup.seconds", "%lld s", "A popup that clears itself after this many seconds."),
    ("popup.minutes", "%lld min", "A popup that clears itself after this many minutes."),
    ("popup.send", "Send", "A button."),
    ("timer.slot", "Timer %lld", "A row of the Popups tab."),
    ("timer.duration", "Duration for timer %lld", "The label of a timer row's field."),
    ("timer.down", "Down", "A timer that counts down."),
    ("timer.up", "Up", "A timer that counts up."),
    ("timer.set", "Set", "A button."),
    ("timer.start", "Start", "A button."),
    ("timer.reset", "Reset", "A button."),
    ("strip.clearSelected", "Clear Selected", "A button in the strip's header."),
    ("strip.all", "All", "A button in the strip's header: selects every channel."),
    ("strip.none", "None", "A button in the strip's header: selects no channel."),
    ("strip.view", "Channels shown", "The label of the strip's view menu."),
    ("strip.view.all", "All channels", "The strip's view menu."),
    ("strip.channel", "Channel %1$lld %2$@", "VoiceOver: a channel's number and label."),
    ("strip.select", "Select channel %lld", "The label of a channel's number badge."),
    ("strip.loops", "loops", "On media that loops."),
    ("strip.paused", "paused %@", "On paused media. %@ is the time left, as a clock."),
    ("strip.remaining", "−%@", "The time media has left. %@ is a clock."),
    ("strip.reset", "reset", "A mark on a channel whose attributes went back to their defaults."),
    ("strip.dot.showing", "Stack %1$lld %2$@: showing", "A stack dot on a channel."),
    ("strip.dot.muted", "Stack %1$lld %2$@: muted", "A stack dot on a channel."),
    ("strip.dot.absent", "Stack %1$lld %2$@: not in this stack", "A stack dot on a channel."),
    ("strip.from.cue", "from %1$@ · %2$@", "What put a channel's content there: a cue's label and its list's title."),
    ("strip.from.one", "from %@", "As above, when only one of the two is known."),
    ("strip.from.aCue", "from a cue", "As above, when neither is known."),
    ("strip.from.restored", "restored", "A channel's content came back at a restart."),
    ("strip.from.ui", "from the UI", "A channel's content was written from this app's buttons."),
    ("strip.from.key", "from a key", "Written by a key press."),
    ("strip.from.osc", "from OSC", "Written by an OSC message."),
    ("strip.from.macro", "from a macro", "Written by a macro."),
    ("strip.from.api", "from the API", "Written over the network API."),
    ("strip.from.other", "from %@", "Written by another source. %@ is its name."),
    ("meter.label", "Level of channel %lld", "VoiceOver: a channel's audio meter."),
    ("strip.lock", "Lock", "A channel's menu: keeps cues from writing to it."),
    ("strip.unlock", "Unlock", "A channel's menu."),
    ("strip.resetAttributes", "Reset Attributes", "A channel's menu: puts its grade, transition and gain back to their defaults."),
    ("strip.endBehaviour", "End Behaviour", "A channel's menu: what its media does at its end."),
    ("strip.grade", "Grade", "A channel's menu: its colour grade."),
    ("strip.grade.none", "None", "A channel's Grade menu: no grade."),
    ("strip.grade.numbered", "%1$lld %2$@", "A channel's Grade and Transition menus: an entry's number and label."),
    ("strip.transition", "Transition", "A channel's menu: how its content changes."),
    ("strip.selectOnly", "Select Only This Channel", "A channel's menu."),
    ("preview.picker", "Preview stack", "The label of the menu that picks which stack the preview shows."),

    # An output's details (Spec 10 §8), and the dividers (§4, §6)
    ("output.title", "Output %1$lld %2$@", "The title of an output's details: its number and label."),
    ("output.device", "Device", "A row of an output's details: the screen or port it uses."),
    ("output.format", "Format", "A row of an output's details."),
    ("output.format.value", "%1$@ × %2$@ · %3$@", "A video format: width, height (pixel counts, never grouped), and the rate with p or i, as in \"1920 × 1080 · 60p\"."),
    ("output.reference", "Reference", "A row of an output's details: its sync reference."),
    ("output.reference.locked", "locked", "An SDI output locked to its reference."),
    ("output.reference.freeRun", "free-running", "An SDI output running on its own clock."),
    ("output.reference.none", "none", "An SDI output with no reference."),
    ("output.state", "State", "A row of an output's details."),
    ("output.state.presenting", "presenting", "An output that is showing frames."),
    ("output.state.lost", "lost", "An output whose device stopped taking frames."),
    ("output.state.released", "released", "An output taken off its screen on purpose."),
    ("output.state.absent", "absent", "An output whose device isn't connected."),
    ("output.stack", "Stack", "A row of an output's details: the stack it shows, with a menu to switch it."),
    ("output.presented", "Presented", "A row of an output's details: frames shown since the engine started."),
    ("output.late", "Late", "A row of an output's details: frames shown late."),
    ("output.dropped", "Dropped", "A row of an output's details: frames dropped."),
    ("output.noCount", "not yet", "In an output's details before the engine has sent a count."),
    ("divider.left", "Width of the left column", "VoiceOver: the divider between the left column and the grid."),
    ("divider.right", "Width of the right column", "VoiceOver: the divider between the grid and the right column."),
    ("divider.pool", "Height of the media panel", "VoiceOver: the divider between the grid and the media panel."),
    ("divider.split", "Split between the playlists and the library", "VoiceOver: the divider in the left column."),

    # The first window (Spec 10 §13)
    ("first.output", "Output %1$lld is %2$@", "After first run: an output's number and its device."),
    ("first.defaults", "These defaults are yours to rename, number and extend.", "After first run, beside the list of outputs."),
    ("first.settings", "Settings ▸ Outputs", "A button after first run."),
    ("first.dismiss", "Dismiss", "A button that closes a note."),
]


def unit(value):
    return {"stringUnit": {"state": "translated", "value": value}}


def catalog():
    strings = {}
    for key, english, note in ENTRIES:
        if key in strings:
            raise SystemExit(f"{key} is in the table twice")
        if isinstance(english, tuple):
            one, other = english
            localization = {"variations": {"plural": {"one": unit(one), "other": unit(other)}}}
        else:
            localization = unit(english)
        strings[key] = {"comment": note, "extractionState": "manual", "localizations": {"en": localization}}
    return {"sourceLanguage": "en", "strings": strings, "version": "1.0"}


def main():
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    path = os.path.join(root, "app", "Shell", "Localizable.xcstrings")
    text = json.dumps(catalog(), ensure_ascii=False, indent=2, sort_keys=True, separators=(",", " : ")) + "\n"
    if "--check" in sys.argv[1:]:
        with open(path, encoding="utf-8") as existing:
            if existing.read() != text:
                raise SystemExit("app/Shell/Localizable.xcstrings is not what scripts/strings-catalog.py writes; run it")
        return
    with open(path, "w", encoding="utf-8") as out:
        out.write(text)
    print(f"wrote {len(ENTRIES)} strings to {path}")


if __name__ == "__main__":
    main()
