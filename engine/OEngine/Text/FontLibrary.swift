// OEngine — Spec 6 §4, fonts: the OFL fonts bundled with the engine, and the
// order in which a PostScript name finds its face.

import CoreText
import Foundation
import OCore

/// Spec 6 §4 — "Fonts (P14). The engine registers a set of OFL-licensed fonts
/// bundled with it. It registers them for its own process, at launch and
/// before the first raster, so a font such as DM Sans resolves at every campus
/// with nothing installed. Installed fonts resolve as before. If a bundled
/// font's PostScript name is also installed, the engine uses the installed
/// copy and logs the clash once (choice T-7). A missing font falls back to the
/// machine's `fallbackFont` and is recorded for pre-flight (Spec 4 §8)."
///
/// A name resolves to an installed face of exactly that PostScript name
/// first, then to a bundled face of that name, or of the usual name of a
/// bundled face's weight (`DMSans-Bold` for DM Sans' Bold instance, Adam's
/// answer of 2026-11-10), else to nothing, and the rasterizer falls back. Faces
/// come from their files' own descriptors, never from Core Text's lookup by
/// name, which prefers a font registered for the process over an installed
/// one: so a bundled face draws the same at every campus, and an installed one
/// wins whatever is registered. A bundled file whose names are installed is
/// not registered at all. Thread-safe: the raster and thumbnail queues share it.
public final class FontLibrary: @unchecked Sendable {
    /// Where a name's face came from.
    public enum Origin: Equatable, Sendable {
        case installed
        case bundled
    }

    /// Spec 6 §4 — the folder of fonts in the engine's resources ("The fonts and
    /// their licences sit together in the engine's resources").
    public static let bundledFolder: URL? = Bundle.module.url(forResource: "Fonts", withExtension: nil)

    /// The engine's own library of its bundled fonts, registered at launch.
    public static let shared = FontLibrary(folder: bundledFolder)

    /// The folder this library's bundled fonts come from.
    public let folder: URL?
    /// Every name a bundled face answers to: its PostScript name and its usual name.
    public let bundledNames: Set<String>

    private struct Face {
        var descriptor: CTFontDescriptor
        var file: URL
    }

    private let bundled: [String: Face]
    private let files: [URL]
    /// Lowercased names that count as installed, when a test says so; nil asks the machine.
    private let installedNames: Set<String>?
    private let lock = NSLock()
    private var resolved: [String: (CTFontDescriptor, Origin)?] = [:]
    /// Spec 1 §2 — the face a static font's name draws with at a weight, nil
    /// for the font itself, by name and weight.
    private var nearest: [String: CTFontDescriptor?] = [:]
    private var registered = false

    /// `installedNames` stands in for what the machine has installed, for
    /// tests; nil, the default, asks Core Text.
    public init(folder: URL?, installedNames: Set<String>? = nil) {
        self.folder = folder?.standardizedFileURL
        self.installedNames = installedNames.map { Set($0.map { $0.lowercased() }) }
        let extensions: Set<String> = ["ttf", "otf", "ttc", "otc"]
        let contents = folder.flatMap { try? FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil) } ?? []
        files = contents.filter { extensions.contains($0.pathExtension.lowercased()) }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        var faces: [String: Face] = [:]
        var names: Set<String> = []
        for file in files {
            for descriptor in (CTFontManagerCreateFontDescriptorsFromURL(file as CFURL) as? [CTFontDescriptor]) ?? [] {
                for name in FontLibrary.names(of: descriptor) where faces[name.lowercased()] == nil {
                    faces[name.lowercased()] = Face(descriptor: descriptor, file: file)
                    names.insert(name)
                }
            }
        }
        bundled = faces
        bundledNames = names
    }

    /// A face's PostScript name, then the usual name of its weight: its
    /// family and style without spaces, as static fonts are named.
    static func names(of descriptor: CTFontDescriptor) -> [String] {
        var names: [String] = []
        if let postScript = CTFontDescriptorCopyAttribute(descriptor, kCTFontNameAttribute) as? String { names.append(postScript) }
        if let family = CTFontDescriptorCopyAttribute(descriptor, kCTFontFamilyNameAttribute) as? String,
           let style = CTFontDescriptorCopyAttribute(descriptor, kCTFontStyleNameAttribute) as? String {
            names.append(family.replacingOccurrences(of: " ", with: "") + "-" + style.replacingOccurrences(of: " ", with: ""))
        }
        return names
    }

    // MARK: - Resolving

    /// Spec 6 §4 — the face a style's PostScript name draws with, and where it
    /// came from: installed, then bundled; nil when it is neither.
    public func descriptor(named name: String) -> (descriptor: CTFontDescriptor, origin: Origin)? {
        let key = name.lowercased()
        lock.lock()
        if let known = resolved[key] {
            lock.unlock()
            return known
        }
        lock.unlock()
        var found: (CTFontDescriptor, Origin)?
        if let installed = installedDescriptor(name) {
            found = (installed, .installed)
        } else if let face = bundled[key] {
            found = (face.descriptor, .bundled)
        }
        lock.lock()
        resolved[key] = found
        lock.unlock()
        return found
    }

    /// Spec 6 §4 — the font for a name at a pixel size, or nil when the name
    /// is neither installed nor bundled.
    public func font(named name: String, size: Double) -> CTFont? {
        descriptor(named: name).map { CTFontCreateWithFontDescriptor($0.descriptor, size, nil) }
    }

    /// Where a name's face comes from, or nil when it is neither installed nor bundled.
    public func origin(of name: String) -> Origin? {
        descriptor(named: name)?.origin
    }

    /// An installed face of exactly `name`, never one of this library's files.
    private func installedDescriptor(_ name: String) -> CTFontDescriptor? {
        if let installedNames, !installedNames.contains(name.lowercased()) { return nil }
        let request = CTFontDescriptorCreateWithAttributes([kCTFontNameAttribute: name] as CFDictionary)
        let mandatory = Set([kCTFontNameAttribute as String]) as CFSet
        let matches = (CTFontDescriptorCreateMatchingFontDescriptors(request, mandatory) as? [CTFontDescriptor]) ?? []
        if let exact = matches.first(where: { descriptor in
            !isBundled(CTFontDescriptorCopyAttribute(descriptor, kCTFontURLAttribute) as? URL)
                && (CTFontDescriptorCopyAttribute(descriptor, kCTFontNameAttribute) as? String)?.caseInsensitiveCompare(name) == .orderedSame
        }) {
            return exact
        }
        // Core Text's own reading of the name, as before Spec 6: accepted when it is that face and not one of ours.
        let font = CTFontCreateWithName(name as CFString, 12, nil)
        guard (CTFontCopyPostScriptName(font) as String).caseInsensitiveCompare(name) == .orderedSame,
              !isBundled(CTFontCopyAttribute(font, kCTFontURLAttribute) as? URL) else { return nil }
        return CTFontCopyFontDescriptor(font)
    }

    private func isBundled(_ url: URL?) -> Bool {
        guard let folder, let path = url?.standardizedFileURL.path else { return false }
        return path.hasPrefix(folder.path + "/")
    }

    // MARK: - Weight (Spec 1 §2)

    /// Spec 1 §2 — "weight is the wght axis when the font is variable and the
    /// nearest instance when it is not": for a static `font`, the face of its
    /// family nearest `weight`, among the static faces installed or bundled
    /// with its slant and width (a condensed face stays condensed, an italic
    /// italic). A face's weight is its OS/2 weight class, or Core Text's
    /// weight trait on that scale when it has none. A tie keeps `font`, then
    /// takes the lighter face, then the first name. Variable fonts' instances
    /// are never chosen: their weight is an axis.
    public func nearestFace(to font: CTFont, weight: Double, size: Double) -> CTFont {
        let name = CTFontCopyPostScriptName(font) as String
        let key = name.lowercased() + "|" + String(Int(weight.rounded()))
        lock.lock()
        let known = nearest[key]
        lock.unlock()
        if let known {
            return known.map { CTFontCreateWithFontDescriptor($0, size, nil) } ?? font
        }
        let chosen = nearestDescriptor(to: font, name: name, weight: weight)
        lock.lock()
        nearest[key] = .some(chosen)
        lock.unlock()
        return chosen.map { CTFontCreateWithFontDescriptor($0, size, nil) } ?? font
    }

    private func nearestDescriptor(to font: CTFont, name: String, weight: Double) -> CTFontDescriptor? {
        let own = FontLibrary.weightClass(of: font)
        guard abs(Double(own) - weight) > 0.5 else { return nil }
        let family = CTFontCopyFamilyName(font) as String
        let italic = CTFontGetSymbolicTraits(font).contains(.traitItalic)
        let width = FontLibrary.widthTrait(of: font)
        var candidates: [(name: String, weight: Int, descriptor: CTFontDescriptor?)] = [(name, own, nil)]
        var seen: Set<String> = [name.lowercased()]
        let request = CTFontDescriptorCreateWithAttributes([kCTFontFamilyNameAttribute: family] as CFDictionary)
        let mandatory = Set([kCTFontFamilyNameAttribute as String]) as CFSet
        let installed = (CTFontDescriptorCreateMatchingFontDescriptors(request, mandatory) as? [CTFontDescriptor]) ?? []
        let bundledFaces = bundled.values.map(\.descriptor).filter {
            (CTFontDescriptorCopyAttribute($0, kCTFontFamilyNameAttribute) as? String) == family
        }
        for descriptor in installed + bundledFaces {
            guard let faceName = CTFontDescriptorCopyAttribute(descriptor, kCTFontNameAttribute) as? String,
                  seen.insert(faceName.lowercased()).inserted else { continue }
            // Only what counts as installed (a test may say), and the bundled faces.
            let ours = isBundled(CTFontDescriptorCopyAttribute(descriptor, kCTFontURLAttribute) as? URL)
            if !ours, let installedNames, !installedNames.contains(faceName.lowercased()) { continue }
            let face = CTFontCreateWithFontDescriptor(descriptor, 12, nil)
            guard ((CTFontCopyVariationAxes(face) as? [Any]) ?? []).isEmpty,
                  CTFontGetSymbolicTraits(face).contains(.traitItalic) == italic,
                  abs(FontLibrary.widthTrait(of: face) - width) < 0.05 else { continue }
            candidates.append((faceName, FontLibrary.weightClass(of: face), descriptor))
        }
        let best = candidates.min { a, b in
            let da = abs(Double(a.weight) - weight)
            let db = abs(Double(b.weight) - weight)
            if da != db { return da < db }
            if (a.descriptor == nil) != (b.descriptor == nil) { return a.descriptor == nil }
            if a.weight != b.weight { return a.weight < b.weight }
            return a.name < b.name
        }
        return best?.descriptor
    }

    /// A face's weight on the 100–900 scale: the OS/2 table's weight class
    /// (1 to 9 read as hundreds), or Core Text's weight trait mapped to it.
    static func weightClass(of font: CTFont) -> Int {
        if let table = CTFontCopyTable(font, CTFontTableTag(kCTFontTableOS2), []) as Data?, table.count >= 6 {
            let value = Int(table[table.startIndex + 4]) << 8 | Int(table[table.startIndex + 5])
            if value >= 1, value <= 9 { return value * 100 }
            if value >= 1, value <= 1000 { return value }
        }
        let trait = ((CTFontCopyTraits(font) as NSDictionary)[kCTFontWeightTrait] as? NSNumber)?.doubleValue ?? 0
        let scale: [(trait: Double, weight: Double)] = [(-0.8, 100), (-0.6, 200), (-0.4, 300), (0, 400), (0.23, 500), (0.3, 600),
                                                        (0.4, 700), (0.56, 800), (0.62, 900)]
        guard let first = scale.first, let last = scale.last else { return 400 }
        if trait <= first.trait { return Int(first.weight) }
        if trait >= last.trait { return Int(last.weight) }
        for (low, high) in zip(scale, scale.dropFirst()) where trait <= high.trait {
            let t = (trait - low.trait) / (high.trait - low.trait)
            return Int((low.weight + t * (high.weight - low.weight)).rounded())
        }
        return 400
    }

    /// Core Text's width trait: 0 for regular width, below for condensed.
    static func widthTrait(of font: CTFont) -> Double {
        ((CTFontCopyTraits(font) as NSDictionary)[kCTFontWidthTrait] as? NSNumber)?.doubleValue ?? 0
    }

    // MARK: - Registering

    /// Whether `register(log:)` has run.
    public var isRegistered: Bool {
        lock.lock()
        defer { lock.unlock() }
        return registered
    }

    /// Spec 6 §4 — "It registers them for its own process, at launch and
    /// before the first raster ... If a bundled font's PostScript name is also
    /// installed, the engine uses the installed copy and logs the clash once."
    /// A file with any installed name is not registered, so Core Text's own
    /// lookups find the installed copy too. Runs once; later calls do nothing.
    public func register(log: EngineLog?) {
        lock.lock()
        if registered {
            lock.unlock()
            return
        }
        registered = true
        lock.unlock()
        var count = 0
        for file in files {
            let descriptors = (CTFontManagerCreateFontDescriptorsFromURL(file as CFURL) as? [CTFontDescriptor]) ?? []
            let postScript = descriptors.compactMap { CTFontDescriptorCopyAttribute($0, kCTFontNameAttribute) as? String }
            if let clash = postScript.first(where: { installedDescriptor($0) != nil }) {
                log?.warning("font \(clash) is installed and bundled with the engine; the installed copy is used (\(file.lastPathComponent) is not registered)")
                continue
            }
            var error: Unmanaged<CFError>?
            if CTFontManagerRegisterFontsForURL(file as CFURL, .process, &error) {
                count += 1
            } else if let failure = error?.takeRetainedValue(), CFErrorGetCode(failure) != CTFontManagerError.alreadyRegistered.rawValue {
                log?.error("font file \(file.lastPathComponent) could not be registered: \(CFErrorCopyDescription(failure) as String? ?? "unknown")")
            } else {
                count += 1
            }
        }
        log?.info("fonts: \(count) bundled font file(s) registered for the engine")
    }
}
