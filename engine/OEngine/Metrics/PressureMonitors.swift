// OEngine — Spec 4 §12, the three conditions "detected elsewhere and never on
// the render thread": memory pressure, which "shrinks the text and thumbnail
// caches and never touches decoder pools during playback", and thermal
// throttling, which "is logged from the process thermal state so a rising GPU
// time has an explanation, and changes nothing". (The third, a full disk,
// belongs to the log and saving area.)

import Foundation
import Dispatch

/// Spec 4 §12 — the system's memory-pressure levels, as the minute record and
/// the live summary carry them (Spec 4 §13).
public enum MemoryPressureLevel: String, Codable, Sendable {
    case normal
    case warning
    case critical
}

/// Spec 4 §12 — a cache memory pressure may shrink: it evicts down to a
/// ceiling below its cap, keeping what the last plans used, and restores the
/// cap when the pressure passes. The text cache (Spec 4 §8) and the thumbnail
/// cache (Spec 4 §10) conform.
public protocol ShrinkableCache: AnyObject, Sendable {
    var name: String { get }
    /// The cache's full byte cap.
    var maximumBytes: Int { get }
    /// Evict down to `bytes` now and hold the cache there; nil restores the cap.
    func setPressureCeiling(_ bytes: Int?)
}

/// Spec 4 §12 — how far the caches shrink per level: a warning halves the cap,
/// critical pressure quarters it, normal restores it (Area 5 reading).
public enum CachePressurePolicy {
    public static func ceilingFraction(for level: MemoryPressureLevel) -> Double? {
        switch level {
        case .normal: return nil
        case .warning: return 0.5
        case .critical: return 0.25
        }
    }

    public static func ceiling(for level: MemoryPressureLevel, cap: Int) -> Int? {
        ceilingFraction(for: level).map { max(1, Int(Double(cap) * $0)) }
    }
}

/// Spec 4 §12 — "memory pressure (the system notification) shrinks the text
/// and thumbnail caches and never touches decoder pools during playback". The
/// system's memory-pressure source lands on a utility queue, never the render
/// thread; `apply` is the whole response, so the harness drives it directly.
public final class MemoryPressureMonitor: @unchecked Sendable {
    private let lock = NSLock()
    private var registered: [any ShrinkableCache]
    private var current = MemoryPressureLevel.normal
    private var changeCount = 0
    private let log: EngineLog
    private let queue = DispatchQueue(label: "o.engine.pressure", qos: .utility)
    private var source: DispatchSourceMemoryPressure?

    public init(caches: [any ShrinkableCache] = [], log: EngineLog) {
        registered = caches
        self.log = log
    }

    /// The caches that answer to pressure.
    public var caches: [any ShrinkableCache] {
        lock.lock()
        defer { lock.unlock() }
        return registered
    }

    /// A cache built after the engine (the thumbnail cache) joins here; it
    /// takes the current level at once.
    public func add(_ cache: any ShrinkableCache) {
        lock.lock()
        registered.append(cache)
        let level = current
        lock.unlock()
        cache.setPressureCeiling(CachePressurePolicy.ceiling(for: level, cap: cache.maximumBytes))
    }

    public var level: MemoryPressureLevel {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    /// How many times the level changed since start (Spec 4 §13, a note for the record).
    public var changes: Int {
        lock.lock()
        defer { lock.unlock() }
        return changeCount
    }

    /// Spec 4 §12 — the response to a level: every cache shrinks to the
    /// policy's ceiling or gets its cap back, and the change is logged.
    public func apply(_ level: MemoryPressureLevel) {
        lock.lock()
        let previous = current
        current = level
        if level != previous { changeCount += 1 }
        let caches = registered
        lock.unlock()
        guard level != previous else { return }
        for cache in caches {
            cache.setPressureCeiling(CachePressurePolicy.ceiling(for: level, cap: cache.maximumBytes))
        }
        let names = caches.map(\.name).joined(separator: ", ")
        switch level {
        case .normal:
            log.info("memory pressure \(previous.rawValue) -> normal; caches restored to their caps (\(names))")
        case .warning, .critical:
            log.warning("memory pressure \(previous.rawValue) -> \(level.rawValue); caches shrunk (\(names)); decoder pools untouched")
        }
    }

    /// Listen to the system's memory-pressure source.
    public func start() {
        lock.lock()
        defer { lock.unlock() }
        guard source == nil else { return }
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: queue)
        source.setEventHandler { [weak self, weak source] in
            guard let self, let source else { return }
            let event = source.data
            let level: MemoryPressureLevel = event.contains(.critical) ? .critical : (event.contains(.warning) ? .warning : .normal)
            self.apply(level)
        }
        source.activate()
        self.source = source
    }

    public func stop() {
        lock.lock()
        defer { lock.unlock() }
        source?.cancel()
        source = nil
    }
}

/// Spec 4 §12 — the process thermal state, as the minute record and the live
/// summary carry it (Spec 4 §13).
public enum ThermalLevel: String, Codable, Sendable {
    case nominal
    case fair
    case serious
    case critical
    case unknown

    public init(_ state: ProcessInfo.ThermalState) {
        switch state {
        case .nominal: self = .nominal
        case .fair: self = .fair
        case .serious: self = .serious
        case .critical: self = .critical
        @unknown default: self = .unknown
        }
    }
}

/// Spec 4 §12 — "thermal throttling is logged from the process thermal state
/// so a rising GPU time has an explanation, and changes nothing." The state
/// is read at start and on every change notification; `observe` is the whole
/// response, so the harness feeds it states directly.
public final class ThermalMonitor: @unchecked Sendable {
    private let lock = NSLock()
    private var current: ThermalLevel
    private var changeCount = 0
    private let log: EngineLog
    private let read: @Sendable () -> ThermalLevel
    private var observer: NSObjectProtocol?

    public init(log: EngineLog, read: @escaping @Sendable () -> ThermalLevel = { ThermalLevel(ProcessInfo.processInfo.thermalState) }) {
        self.log = log
        self.read = read
        current = read()
    }

    public var level: ThermalLevel {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    /// How many times the state changed since start.
    public var changes: Int {
        lock.lock()
        defer { lock.unlock() }
        return changeCount
    }

    /// A state reading: logged when it differs from the last, and nothing else.
    public func observe(_ level: ThermalLevel) {
        lock.lock()
        let previous = current
        guard level != previous else {
            lock.unlock()
            return
        }
        current = level
        changeCount += 1
        lock.unlock()
        switch level {
        case .nominal, .fair:
            log.info("thermal state \(previous.rawValue) -> \(level.rawValue)")
        case .serious, .critical, .unknown:
            log.warning("thermal state \(previous.rawValue) -> \(level.rawValue); a rising GPU time has its explanation")
        }
    }

    /// Follow the process's thermal state notifications.
    public func start() {
        lock.lock()
        defer { lock.unlock() }
        guard observer == nil else { return }
        let read = self.read
        observer = NotificationCenter.default.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: nil) { [weak self] _ in
            self?.observe(read())
        }
    }

    public func stop() {
        lock.lock()
        defer { lock.unlock() }
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
    }
}
