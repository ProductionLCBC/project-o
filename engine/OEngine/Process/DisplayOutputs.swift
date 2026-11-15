// OEngine — Spec 10 §2, the display outputs and the screens they wait for.

import AppKit
import Foundation
import OCore

/// Spec 10 §2 — "A display output whose screen isn't there stays `absent` and
/// opens when a screen with its id appears; it never falls back to another
/// screen." Spec 10 §9 — `releaseScreen` "takes every output off the named
/// screen for the rest of the run". One place watches the Mac's screens and
/// gives each display sink the screen `OutputPlacement` says is its own, at
/// launch and at every change of screens.
@MainActor
public final class DisplayOutputs {
    private let sinks: [Int: DisplaySink]
    private let outputs: [Output]
    private let devices: SystemDevices
    private let log: EngineLog
    /// The screens released this run, by uuid in capitals: from `--released` and from `releaseScreen`.
    public private(set) var released: Set<String>
    private var observer: NSObjectProtocol?
    /// Called on the main actor after the screens changed and the sinks were placed.
    public var onChange: (() -> Void)?

    public init(sinks: [DisplaySink], outputs: [Output], devices: SystemDevices, released: Set<String> = [], log: EngineLog) {
        self.sinks = Dictionary(sinks.map { ($0.output, $0) }, uniquingKeysWith: { first, _ in first })
        self.outputs = outputs
        self.devices = devices
        self.released = Set(released.map { $0.uppercased() })
        self.log = log
    }

    /// Reads the screens and gives each sink its own, or none; a sink whose
    /// screen was released is closed for the rest of the run.
    public func reconcile() {
        devices.refreshScreens()
        let places = OutputPlacement.places(outputs: outputs, screens: devices.keptScreens, released: released)
        for number in sinks.keys.sorted() {
            guard let sink = sinks[number] else { continue }
            switch places[number] ?? .absent {
            case .screen(let uuid):
                sink.place(on: SystemDevices.screen(uuid: uuid))
            case .absent:
                sink.place(on: nil)
            case .released:
                if sink.currentState.phase != .released { sink.release() }
            }
        }
    }

    /// Reconciles again at every change of screens, until `stopWatching()`.
    public func watch() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.reconcile()
                self?.onChange?()
            }
        }
    }

    public func stopWatching() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
    }

    /// Spec 10 §9 — "the engine closes those outputs' windows, reports them
    /// `released`": every display output on the screen with this uuid, now
    /// and for the rest of the run. The outputs released, in number order.
    @discardableResult
    public func release(screen uuid: String) -> [Int] {
        released.insert(uuid.uppercased())
        reconcile()
        let numbers = OutputPlacement.outputs(onScreen: uuid, of: outputs)
        log.info("released screen \(uuid.uppercased()): outputs \(numbers)")
        return numbers
    }
}
