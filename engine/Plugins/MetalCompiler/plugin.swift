// OEngine build tooling — Spec 4 §14: "Shaders live in one .metal file per pass
// with function constants for variants, never string-assembled at runtime."
//
// The command-line `swift build` ignores .metal files, so this build tool
// plugin compiles every .metal file of the target with Xcode's `metal` driver
// into one `default.metallib`, which SwiftPM then bundles as a resource of the
// target. The engine loads it with `MTLDevice.makeLibrary(URL:)` from
// `Bundle.module`. The clang module cache is kept inside the plugin's work
// directory because the build sandbox forbids the default location.

import Foundation
import PackagePlugin

@main
struct MetalCompiler: BuildToolPlugin {
    func createBuildCommands(context: PluginContext, target: Target) async throws -> [Command] {
        guard let sources = target as? SourceModuleTarget else { return [] }
        let metalFiles = sources.sourceFiles.filter { $0.url.pathExtension == "metal" }.map(\.url)
        guard !metalFiles.isEmpty else { return [] }
        let output = context.pluginWorkDirectoryURL.appendingPathComponent("default.metallib")
        let moduleCache = context.pluginWorkDirectoryURL.appendingPathComponent("ModuleCache")
        var arguments = [
            "-sdk", "macosx", "metal",
            "-fmodules-cache-path=\(moduleCache.path)",
            "-std=metal3.1",
            "-Wall", "-Werror",
            "-o", output.path,
        ]
        arguments.append(contentsOf: metalFiles.map(\.path))
        return [
            .buildCommand(
                displayName: "Compiling Metal shaders for \(target.name)",
                executable: URL(fileURLWithPath: "/usr/bin/xcrun"),
                arguments: arguments,
                inputFiles: metalFiles,
                outputFiles: [output])
        ]
    }
}
