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
