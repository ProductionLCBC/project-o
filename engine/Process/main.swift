// oengine — Spec 4 §15: "a headless OEngine process driven over OSC, with the
// fixture library from Spec 1 on disk". The subcommands arrive with the engine;
// this is the entry point.

import Foundation
import OEngine

// Line-buffered output even into a pipe, so a captured soak log is complete up to the last line.
setlinebuf(stdout)
let status = OEngineCommandLine.run(arguments: Array(CommandLine.arguments.dropFirst()))
exit(status)
