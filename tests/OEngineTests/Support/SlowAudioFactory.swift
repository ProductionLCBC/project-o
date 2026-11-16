import Foundation
import OCore
@testable import OEngine
import protocol OEngine.AudioDevice   // the engine's, not Core Audio's type of the same name

/// A factory whose devices open only when the test lets them: a HAL device
/// can take seconds to start (fourteen, on the dev Mac on 2026-11-16, for the
/// first open of a virtual device). Everything else is the software factory's.
final class SlowAudioFactory: AudioDeviceFactory, @unchecked Sendable {
    let inner = SoftwareAudioDeviceFactory()
    /// Signalled each time a device starts to open.
    let opening = DispatchSemaphore(value: 0)
    /// Signalled by the test to let one open finish.
    let gate = DispatchSemaphore(value: 0)

    func isPresent(key: String) -> Bool { inner.isPresent(key: key) }

    func makeDevice(key: String, channelCount: Int) -> (any AudioDevice)? {
        opening.signal()
        gate.wait()
        return inner.makeDevice(key: key, channelCount: channelCount)
    }

    func makeSilenceDevice(name: String, channelCount: Int) -> PacedAudioDevice { inner.makeSilenceDevice(name: name, channelCount: channelCount) }
    func observeDeviceList(_ handler: @escaping @Sendable () -> Void) { inner.observeDeviceList(handler) }
    func stopObserving() { inner.stopObserving() }
}

/// What `promptly`'s thread hands back.
final class PromptBox<T>: @unchecked Sendable {
    let lock = NSLock()
    var value: T?
}

/// Runs `work` on a thread of its own and gives its result, or nil when it
/// hasn't answered in `seconds`: for calls that must never wait on something slow.
func promptly<T>(_ seconds: TimeInterval = 2, _ work: @escaping @Sendable () -> T) -> T? {
    let box = PromptBox<T>()
    let done = DispatchSemaphore(value: 0)
    let thread = Thread {
        let value = work()
        box.lock.lock()
        box.value = value
        box.lock.unlock()
        done.signal()
    }
    thread.start()
    guard done.wait(timeout: .now() + seconds) == .success else { return nil }
    box.lock.lock()
    defer { box.lock.unlock() }
    return box.value
}
