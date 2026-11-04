// OEngine — Spec 4 §11, "Mix graph per audio output device": the device seam,
// its software and Core Audio implementations, and the factories that open
// devices by key for the audio system (Area 16).

import Foundation
import AudioToolbox
import CoreAudio
import OCore
import Synchronization

/// The render callback: fill `frames` frames of interleaved float samples for
/// `channels` channels; `hostTimeNs` is when the first frame reaches the
/// device. Real-time: no locks, no allocation (Spec 4 §3).
public typealias AudioRenderCallback = @Sendable (_ output: UnsafeMutablePointer<Float>, _ frames: Int, _ hostTimeNs: Int64) -> Void

public enum AudioDeviceError: Error, Equatable {
    case noSuchDevice(String)
    case cannotOpen(String)
    case cannotStart(String)
}

/// Spec 4 §11 — "One Core Audio output unit (the HAL output AudioUnit) per
/// distinct device, each with its own render callback on Core Audio's
/// real-time thread." Spec 4 §16 — "The mix graph with a software device
/// produces sample-exact crossfades".
public protocol AudioDevice: AnyObject, Sendable {
    var name: String { get }
    var sampleRate: Double { get }
    var channelCount: Int { get }
    /// Now, on the clock the callback's host times use.
    var hostTimeNowNs: Int64 { get }
    var isRunning: Bool { get }
    func start(render: @escaping AudioRenderCallback) throws
    func stop()
}

/// Spec 4 §11 and §12 (Area 16) — where the audio system gets its devices:
/// one per key, where a key is a Core Audio device UID or `default` for the
/// system default device. The Core Audio factory opens HAL units and watches
/// the device list; the software factory hands out pullable devices and lets
/// a test mark keys absent.
public protocol AudioDeviceFactory: Sendable {
    func isPresent(key: String) -> Bool
    /// A device for `key` with `channelCount` interleaved channels, or nil when it is absent.
    func makeDevice(key: String, channelCount: Int) -> (any AudioDevice)?
    /// Spec 4 §12 — the silence stand-in: consumes at 48 kHz and plays nowhere.
    func makeSilenceDevice(name: String, channelCount: Int) -> PacedAudioDevice
    /// Spec 4 §12 — "Core Audio device notification": `handler` runs off the
    /// render path whenever the device list changes.
    func observeDeviceList(_ handler: @escaping @Sendable () -> Void)
    func stopObserving()
}

/// The key for an Audio Output's device (Spec 1 §3): the UID, `default` for
/// an empty one, `sdi:N` for an SDI output number.
public enum AudioDeviceKey {
    public static let defaultDevice = "default"

    public static func key(for output: AudioOutput) -> String {
        switch output.device {
        case .uid(let uid): return uid.isEmpty ? defaultDevice : uid
        case .sdiOutput(let number): return "sdi:\(number)"
        }
    }

    /// The Core Audio UID a key names; nil for the system default.
    public static func uid(for key: String) -> String? { key == defaultDevice ? nil : key }
}

/// Spec 4 §16 — the software device: the test pulls frames and gets what the
/// graph would have handed the hardware.
public final class SoftwareAudioDevice: AudioDevice, @unchecked Sendable {
    public let name: String
    public let sampleRate: Double
    public let channelCount: Int
    private let lock = NSLock()
    private var render: AudioRenderCallback?
    private var hostTimeNs: Int64 = 0

    /// `hostTimeNs` is where the device's clock starts; a real device's is far from zero.
    public init(name: String = "software", sampleRate: Double = 48_000, channelCount: Int = 2, hostTimeNs: Int64 = 0) {
        self.name = name
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.hostTimeNs = hostTimeNs
    }

    public func start(render: @escaping AudioRenderCallback) throws {
        lock.lock()
        self.render = render
        lock.unlock()
    }

    public func stop() {
        lock.lock()
        render = nil
        lock.unlock()
    }

    public var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return render != nil
    }

    /// Pull `frames` frames through the callback, interleaved.
    public func pull(frames: Int) -> [Float] {
        var out = [Float](repeating: 0, count: frames * channelCount)
        lock.lock()
        let render = self.render
        let at = hostTimeNs
        lock.unlock()
        guard let render else { return out }
        out.withUnsafeMutableBufferPointer { buffer in
            render(buffer.baseAddress!, frames, at)
        }
        lock.lock()
        hostTimeNs += Int64(Double(frames) / sampleRate * 1_000_000_000)
        lock.unlock()
        return out
    }

    /// The host time the next pulled frame will carry.
    public var nextHostTimeNs: Int64 {
        lock.lock()
        defer { lock.unlock() }
        return hostTimeNs
    }

    public var hostTimeNowNs: Int64 { nextHostTimeNs }
}

/// Spec 4 §16 — the software factory for the harness: a fresh pullable
/// device per key each time one is opened, keys a test can mark absent, and
/// manual silence stand-ins on a settable clock.
public final class SoftwareAudioDeviceFactory: AudioDeviceFactory, @unchecked Sendable {
    public let clock = SettableNanoClock(nowNs: 0)
    private let lock = NSLock()
    private var absentKeys: Set<String> = []
    private var made: [String: SoftwareAudioDevice] = [:]
    private var openedCount = 0

    public init() {}

    /// Keys that are not there: `makeDevice` returns nil and `isPresent` false.
    public var absent: Set<String> {
        get { lock.lock(); defer { lock.unlock() }; return absentKeys }
        set { lock.lock(); absentKeys = newValue; lock.unlock() }
    }

    /// How many devices were opened since the start.
    public var opened: Int { lock.lock(); defer { lock.unlock() }; return openedCount }

    /// The device last opened for `key`.
    public func device(_ key: String) -> SoftwareAudioDevice? {
        lock.lock()
        defer { lock.unlock() }
        return made[key]
    }

    public func isPresent(key: String) -> Bool { !absent.contains(key) }

    public func makeDevice(key: String, channelCount: Int) -> (any AudioDevice)? {
        lock.lock()
        defer { lock.unlock() }
        guard !absentKeys.contains(key) else { return nil }
        let device = SoftwareAudioDevice(name: key, channelCount: channelCount)
        made[key] = device
        openedCount += 1
        return device
    }

    public func makeSilenceDevice(name: String, channelCount: Int) -> PacedAudioDevice {
        let clock = self.clock
        return PacedAudioDevice(name: name, channelCount: channelCount, destination: nil, clock: { clock.nowNs }, threaded: false)
    }

    public func observeDeviceList(_ handler: @escaping @Sendable () -> Void) {}
    public func stopObserving() {}
}

/// Spec 4 §11 — the HAL output unit for one device, found by its Core Audio
/// UID (Spec 1 §3, Audio Output `device`); nil picks the system default.
public final class HALOutputDevice: AudioDevice, @unchecked Sendable {
    public let name: String
    public let sampleRate: Double
    public let channelCount: Int
    public let uid: String?
    private var unit: AudioUnit?
    private var callback: AudioRenderCallback?
    private var scratch: UnsafeMutablePointer<Float>?
    private var scratchFrames = 0
    private let running = Atomic<Bool>(false)

    public init(uid: String?, sampleRate: Double = 48_000, channelCount: Int = 2) {
        self.uid = uid
        self.name = uid ?? AudioDeviceKey.defaultDevice
        self.sampleRate = sampleRate
        self.channelCount = max(1, channelCount)
    }

    deinit {
        scratch?.deallocate()
    }

    /// The AudioDeviceID for a UID, or the default output device.
    public static func deviceID(forUID uid: String?) -> AudioDeviceID? {
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var device = AudioDeviceID(kAudioObjectUnknown)
        if let uid {
            var cfUID = uid as CFString
            var translate = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslateUIDToDevice, mScope: kAudioObjectPropertyScopeGlobal,
                                                       mElement: kAudioObjectPropertyElementMain)
            let status = withUnsafeMutablePointer(to: &cfUID) { pointer in
                AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &translate, UInt32(MemoryLayout<CFString>.size), pointer, &size, &device)
            }
            guard status == noErr, device != kAudioObjectUnknown else { return nil }
            return device
        }
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr, device != kAudioObjectUnknown else { return nil }
        return device
    }

    /// Every output device's UID, for settings and the fallback check.
    public static func availableUIDs() -> [String] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        var devices = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &devices) == noErr else { return [] }
        return devices.compactMap { device in
            var uidAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var uidSize = UInt32(MemoryLayout<CFString?>.size)
            var uid: Unmanaged<CFString>?
            guard AudioObjectGetPropertyData(device, &uidAddress, 0, nil, &uidSize, &uid) == noErr, let uid else { return nil }
            return uid.takeUnretainedValue() as String
        }
    }

    public var isRunning: Bool { running.load(ordering: .relaxed) }

    public func start(render: @escaping AudioRenderCallback) throws {
        guard !running.exchange(true, ordering: .acquiringAndReleasing) else { return }
        do {
            try open(render: render)
        } catch {
            running.store(false, ordering: .releasing)
            throw error
        }
    }

    private func open(render: @escaping AudioRenderCallback) throws {
        guard let deviceID = HALOutputDevice.deviceID(forUID: uid) else { throw AudioDeviceError.noSuchDevice(name) }
        var description = AudioComponentDescription(componentType: kAudioUnitType_Output, componentSubType: kAudioUnitSubType_HALOutput,
                                                    componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
        guard let component = AudioComponentFindNext(nil, &description) else { throw AudioDeviceError.cannotOpen("no HAL output component") }
        var unit: AudioUnit?
        guard AudioComponentInstanceNew(component, &unit) == noErr, let unit else { throw AudioDeviceError.cannotOpen("cannot instantiate the HAL output") }
        var device = deviceID
        guard AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &device, UInt32(MemoryLayout<AudioDeviceID>.size)) == noErr else {
            AudioComponentInstanceDispose(unit)
            throw AudioDeviceError.cannotOpen("cannot select \(name)")
        }
        var format = AudioStreamBasicDescription(mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
                                                 mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                                                 mBytesPerPacket: UInt32(4 * channelCount), mFramesPerPacket: 1, mBytesPerFrame: UInt32(4 * channelCount),
                                                 mChannelsPerFrame: UInt32(channelCount), mBitsPerChannel: 32, mReserved: 0)
        guard AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &format, UInt32(MemoryLayout<AudioStreamBasicDescription>.size)) == noErr else {
            AudioComponentInstanceDispose(unit)
            throw AudioDeviceError.cannotOpen("cannot set a \(channelCount)-channel stream format on \(name)")
        }
        callback = render
        scratchFrames = 4096
        if scratch == nil { scratch = UnsafeMutablePointer<Float>.allocate(capacity: scratchFrames * channelCount) }
        var input = AURenderCallbackStruct(inputProc: { context, _, timestamp, _, frames, bufferList in
            let device = Unmanaged<HALOutputDevice>.fromOpaque(context).takeUnretainedValue()
            device.render(frames: Int(frames), timestamp: timestamp.pointee, bufferList: bufferList)
            return noErr
        }, inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
        guard AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &input, UInt32(MemoryLayout<AURenderCallbackStruct>.size)) == noErr,
              AudioUnitInitialize(unit) == noErr, AudioOutputUnitStart(unit) == noErr else {
            AudioComponentInstanceDispose(unit)
            callback = nil
            throw AudioDeviceError.cannotStart(name)
        }
        self.unit = unit
    }

    private func render(frames: Int, timestamp: AudioTimeStamp, bufferList: UnsafeMutablePointer<AudioBufferList>?) {
        guard let callback, let scratch, let bufferList else { return }
        let count = min(frames, scratchFrames)
        let hostNs = Int64(Double(timestamp.mHostTime) * HALOutputDevice.hostTicksToNanoseconds)
        callback(scratch, count, hostNs)
        let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
        guard let first = buffers.first, let data = first.mData else { return }
        memcpy(data, scratch, min(Int(first.mDataByteSize), count * channelCount * 4))
    }

    static let hostTicksToNanoseconds: Double = {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        return Double(timebase.numer) / Double(timebase.denom)
    }()

    public var hostTimeNowNs: Int64 { Int64(Double(mach_absolute_time()) * HALOutputDevice.hostTicksToNanoseconds) }

    /// Stops the unit; `AudioOutputUnitStop` returns after the callback in
    /// flight has finished, so a swap never has two consumers on a ring.
    public func stop() {
        guard running.exchange(false, ordering: .acquiringAndReleasing) else { return }
        if let unit {
            AudioOutputUnitStop(unit)
            AudioUnitUninitialize(unit)
            AudioComponentInstanceDispose(unit)
        }
        unit = nil
        callback = nil
    }
}

/// Spec 4 §11 and §12 — the Core Audio factory: HAL units by UID, the
/// threaded silence stand-in, and the device-list listener ("Core Audio
/// device notification") on a utility queue.
public final class HALAudioDeviceFactory: AudioDeviceFactory, @unchecked Sendable {
    private let log: EngineLog?
    private let lock = NSLock()
    private var listener: AudioObjectPropertyListenerBlock?
    private static var devicesAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }

    public init(log: EngineLog? = nil) {
        self.log = log
    }

    public func isPresent(key: String) -> Bool {
        HALOutputDevice.deviceID(forUID: AudioDeviceKey.uid(for: key)) != nil
    }

    public func makeDevice(key: String, channelCount: Int) -> (any AudioDevice)? {
        guard isPresent(key: key) else { return nil }
        return HALOutputDevice(uid: AudioDeviceKey.uid(for: key), channelCount: channelCount)
    }

    public func makeSilenceDevice(name: String, channelCount: Int) -> PacedAudioDevice {
        PacedAudioDevice(name: name, channelCount: channelCount, destination: nil, threaded: true, log: log)
    }

    public func observeDeviceList(_ handler: @escaping @Sendable () -> Void) {
        stopObserving()
        let block: AudioObjectPropertyListenerBlock = { _, _ in handler() }
        var address = HALAudioDeviceFactory.devicesAddress
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.global(qos: .utility), block)
        lock.lock()
        listener = block
        lock.unlock()
    }

    public func stopObserving() {
        lock.lock()
        let block = listener
        listener = nil
        lock.unlock()
        guard let block else { return }
        var address = HALAudioDeviceFactory.devicesAddress
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.global(qos: .utility), block)
    }
}
