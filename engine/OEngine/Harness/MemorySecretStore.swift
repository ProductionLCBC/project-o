// OEngine — the harness's stand-in for the Keychain (Spec 4 §14, Spec 10 §12).

import Foundation

/// A Keychain in memory, for the tests: what it holds, whether it can be
/// read or written, and a gate that holds a read the way a system prompt
/// nobody has answered does.
public final class MemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: Data] = [:]
    private var refusal: String?
    private var writable = true
    private var gate: DispatchSemaphore?
    private var readCount = 0
    private var writeCount = 0

    public init(_ items: [String: Data] = [:]) {
        self.items = items
    }

    /// Every read answers `unreadable` with this text until it is nil again.
    public var unreadable: String? {
        get { lock.lock(); defer { lock.unlock() }; return refusal }
        set { lock.lock(); refusal = newValue; lock.unlock() }
    }

    /// Whether a write succeeds.
    public var acceptsWrites: Bool {
        get { lock.lock(); defer { lock.unlock() }; return writable }
        set { lock.lock(); writable = newValue; lock.unlock() }
    }

    public var reads: Int { lock.lock(); defer { lock.unlock() }; return readCount }
    public var writes: Int { lock.lock(); defer { lock.unlock() }; return writeCount }

    public func item(_ account: String) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return items[account]
    }

    /// From now on a read waits, as on a prompt, until `answerPrompt`.
    public func holdReads() {
        lock.lock()
        gate = DispatchSemaphore(value: 0)
        lock.unlock()
    }

    /// Lets the held read go on, and every read after it.
    public func answerPrompt() {
        lock.lock()
        let held = gate
        gate = nil
        lock.unlock()
        held?.signal()
    }

    public func read(account: String) -> SecretRead {
        lock.lock()
        let held = gate
        lock.unlock()
        held?.wait()
        held?.signal()   // whoever else waits on the same prompt goes on too
        lock.lock()
        defer { lock.unlock() }
        readCount += 1
        if let refusal { return .unreadable(refusal) }
        guard let data = items[account] else { return .missing }
        return .found(data)
    }

    public func write(_ value: Data, account: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        writeCount += 1
        guard writable else { return false }
        items[account] = value
        return true
    }
}
