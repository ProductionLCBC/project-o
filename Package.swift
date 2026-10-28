// swift-tools-version: 6.0
// Project O — Swift package manifest.
//
// Swift 6 language mode with strict concurrency (CLAUDE.md, code conventions).
// OCore (core/) is pure Swift, Foundation only, and must build on Linux.
// OFormats (formats/OFormats) is the one place that touches the file system for
// the Spec 1 roots; it is Foundation only too and also builds on Linux.
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
        .library(name: "OFormats", targets: ["OFormats"]),
        .library(name: "OEngine", targets: ["OEngine"]),
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
        .testTarget(
            name: "OFormatsTests",
            dependencies: ["OCore", "OFormats"],
            path: "tests/OFormatsTests"
        ),
    ]
)
