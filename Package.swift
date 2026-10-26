// swift-tools-version: 6.0
// Project O — Swift package manifest.
//
// Swift 6 language mode with strict concurrency (CLAUDE.md, code conventions).
// OCore (core/) is pure Swift, Foundation only, and must build on Linux.
// OEngine (engine/) is the macOS playback engine (Spec 4), filled in once the
// engine spike starts. The operator app in app/ is an Xcode project that depends
// on this package; it is not a package target.

import PackageDescription

let package = Package(
    name: "ProjectO",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "OCore", targets: ["OCore"]),
        .library(name: "OEngine", targets: ["OEngine"]),
    ],
    targets: [
        // Spec 1 (objects and format), Spec 2 (commands), Spec 3 (state and projection).
        // No Apple frameworks: tests/OCoreTests/ImportRuleTests.swift enforces it.
        .target(
            name: "OCore",
            path: "core"
        ),
        // Spec 4 (render pipeline). Metal, VideoToolbox, AVFoundation, CoreAudio,
        // CoreText, CoreGraphics and the DeckLink SDK live here and nowhere else.
        .target(
            name: "OEngine",
            dependencies: ["OCore"],
            path: "engine"
        ),
        .testTarget(
            name: "OCoreTests",
            dependencies: ["OCore"],
            path: "tests/OCoreTests"
        ),
    ]
)
