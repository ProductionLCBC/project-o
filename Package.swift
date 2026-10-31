// swift-tools-version: 6.0
// Project O — Swift package manifest.
//
// Swift 6 language mode with strict concurrency (CLAUDE.md, code conventions).
// OCore (core/) is pure Swift, Foundation only, and must build on Linux.
// OFormats (formats/OFormats) is the one place that touches the file system for
// the Spec 1 roots; it is Foundation only too and also builds on Linux.
// OEngine (engine/OEngine) is the macOS playback engine (Spec 4), with the
// headless process in engine/Process and the DeckLink module in engine/ODeckLink.
// The engine targets exist only on macOS, so the Linux CI job keeps proving
// OCore alone (CLAUDE.md, "Commands"). The operator app in app/ is an Xcode
// project that depends on this package; it is not a package target.
//
// The deployment target is macOS 15: the engine's lock-free hand-offs use the
// Swift `Synchronization` module (Spec 4 §3, Area 4 plan decision 2).

import PackageDescription
import Foundation

let package = Package(
    name: "ProjectO",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(name: "OCore", targets: ["OCore"]),
        .library(name: "OFormats", targets: ["OFormats"]),
    ],
    targets: [
        // Spec 1 (objects and format), Spec 2 (commands), Spec 3 (state and projection).
        // No Apple frameworks: tests/OCoreTests/ImportRuleTests.swift enforces it.
        .target(
            name: "OCore",
            path: "core"
        ),
        // Spec 1 §5 at the file boundary: reads a root into bytes, executes a
        // write plan with temp file, fsync and rename, hashes media files. The
        // JSON schemas live beside it in formats/schemas.
        .target(
            name: "OFormats",
            dependencies: ["OCore"],
            path: "formats/OFormats"
        ),
        .testTarget(
            name: "OCoreTests",
            dependencies: ["OCore"],
            path: "tests/OCoreTests"
        ),
        .testTarget(
            name: "OFormatsTests",
            dependencies: ["OCore", "OFormats"],
            path: "tests/OFormatsTests"
        ),
    ],
    cxxLanguageStandard: .cxx17
)

#if os(macOS)
// Spec 4 §14 — the DeckLink SDK is wrapped by a small Objective-C++ module, the
// only place C++ is allowed. The SDK is not redistributable and lives in vendor/
// (vendor/README.md); when it is absent the module builds its stub, which
// reports the card as unavailable, so the rest of the engine still builds.
let deckLinkHeader = Context.packageDirectory + "/vendor/DeckLinkSDK/Mac/include/DeckLinkAPI.h"
let deckLinkSDKPresent = FileManager.default.fileExists(atPath: deckLinkHeader)

package.products += [
    .library(name: "OEngine", targets: ["OEngine"]),
    .executable(name: "oengine", targets: ["OEngineProcess"]),
]
package.targets += [
    // Spec 4 §14 — shaders live in one .metal file per pass. The command-line
    // build does not compile Metal by itself, so this plugin runs Xcode's
    // `metal` compiler over the engine's shader files into one metallib in
    // the module's resource bundle.
    .plugin(
        name: "MetalCompiler",
        capability: .buildTool(),
        path: "engine/Plugins/MetalCompiler"
    ),
    .target(
        name: "ODeckLink",
        path: "engine/ODeckLink",
        exclude: deckLinkSDKPresent ? ["ODeckLinkStub.c"] : ["ODeckLink.mm"],
        cxxSettings: deckLinkSDKPresent
            ? [.headerSearchPath("../../vendor/DeckLinkSDK/Mac/include"), .define("ODL_HAVE_SDK", to: "1")]
            : [],
        linkerSettings: [.linkedFramework("CoreFoundation")]
    ),
    // Spec 4 (render pipeline). Metal, VideoToolbox, AVFoundation, CoreAudio,
    // CoreText, CoreGraphics and the DeckLink SDK live here and nowhere else.
    .target(
        name: "OEngine",
        dependencies: ["OCore", "OFormats", "ODeckLink"],
        path: "engine/OEngine",
        plugins: ["MetalCompiler"]
    ),
    // Spec 4 §15 — the headless OEngine process driven over OSC, the product
    // `oengine`. The target and its folder are not called oengine because the
    // default file system is case-insensitive and they would collide with
    // OEngine on disk and in the build folder.
    .executableTarget(
        name: "OEngineProcess",
        dependencies: ["OEngine", "OCore", "OFormats"],
        path: "engine/Process"
    ),
    .testTarget(
        name: "OEngineTests",
        dependencies: ["OEngine", "OCore", "OFormats"],
        path: "tests/OEngineTests"
    ),
]
#endif
