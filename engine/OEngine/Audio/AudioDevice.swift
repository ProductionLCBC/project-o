// OEngine — Spec 4 §11, "Mix graph per audio output device": the device seam
// and its two implementations, a software device for the harness and the
// Core Audio HAL output unit.

import Foundation
import AudioToolbox
import CoreAudio
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
    func start(render: @escaping AudioRenderCallback) throws
    func stop()
}

/// Spec 4 §16 — the software device: the test pulls frames and gets what the
/// graph would have handed the hardware.
public final class SoftwareAudioDevice: AudioDevice, @unchecked Sendable {
    public let name = "software"
    public let sampleRate: Double
    public let channelCount: Int
    private var render: AudioRenderCallback?
    private var hostTimeNs: Int64 = 0

    public init(sampleRate: Double = 48_000, channelCount: Int = 2) {
        self.sampleRate = sampleRate
        self.channelCount = channelCount
    }

    public func start(render: @escaping AudioRenderCallback) throws {
        self.render = render
    }

    public func stop() {
        render = nil
    }

    /// Pull `frames` frames through the callback, interleaved.
    public func pull(frames: Int) -> [Float] {
        var out = [Float](repeating: 0, count: frames * channelCount)
        guard let render else { return out }
        out.withUnsafeMutableBufferPointer { buffer in
            render(buffer.baseAddress!, frames, hostTimeNs)
        }
        hostTimeNs += Int64(Double(frames) / sampleRate * 1_000_000_000)
        return out
    }

    /// The host time the next pulled frame will carry.
    public var nextHostTimeNs: Int64 { hostTimeNs }
    public var hostTimeNowNs: Int64 { hostTimeNs }
}

/// Spec 4 §11 — the HAL output unit for one device, found by its Core Audio
/// UID (Spec 1 §3, Audio Output `device`); nil picks the system default.
/// Spec 4 §12 — "Audio device vanishes: Switch to the Audio Output's
/// configured fallback device if one is set; otherwise drop that output's
/// audio (silence, with a badge) rather than guessing".
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
    private let underrunCount = Atomic<Int64>(0)
    public var onDeviceLost: (@Sendable () -> Void)?

    public init(uid: String?, sampleRate: Double = 48_000, channelCount: Int = 2) {
        self.uid = uid
        self.name = uid ?? "default"
        self.sampleRate = sampleRate
        self.channelCount = channelCount
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

    public func start(render: @escaping AudioRenderCallback) throws {
        guard !running.exchange(true, ordering: .acquiringAndReleasing) else { return }
        guard let deviceID = HALOutputDevice.deviceID(forUID: uid) else {
            running.store(false, ordering: .releasing)
            throw AudioDeviceError.noSuchDevice(name)
        }
        var description = AudioComponentDescription(componentType: kAudioUnitType_Output, componentSubType: kAudioUnitSubType_HALOutput,
                                                    componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
        guard let component = AudioComponentFindNext(nil, &description) else { throw AudioDeviceError.cannotOpen("no HAL output component") }
        var unit: AudioUnit?
        guard AudioComponentInstanceNew(component, &unit) == noErr, let unit else { throw AudioDeviceError.cannotOpen("cannot instantiate the HAL output") }
        var device = deviceID
        guard AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &device, UInt32(MemoryLayout<AudioDeviceID>.size)) == noErr else {
            throw AudioDeviceError.cannotOpen("cannot select \(name)")
        }
        var format = AudioStreamBasicDescription(mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
                                                 mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                                                 mBytesPerPacket: UInt32(4 * channelCount), mFramesPerPacket: 1, mBytesPerFrame: UInt32(4 * channelCount),
                                                 mChannelsPerFrame: UInt32(channelCount), mBitsPerChannel: 32, mReserved: 0)
        guard AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &format, UInt32(MemoryLayout<AudioStreamBasicDescription>.size)) == noErr else {
            throw AudioDeviceError.cannotOpen("cannot set the stream format on \(name)")
        }
        callback = render
        scratchFrames = 4096
        scratch = UnsafeMutablePointer<Float>.allocate(capacity: scratchFrames * channelCount)
        var input = AURenderCallbackStruct(inputProc: { context, _, timestamp, _, frames, bufferList in
            let device = Unmanaged<HALOutputDevice>.fromOpaque(context).takeUnretainedValue()
            device.render(frames: Int(frames), timestamp: timestamp.pointee, bufferList: bufferList)
            return noErr
        }, inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
        guard AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &input, UInt32(MemoryLayout<AURenderCallbackStruct>.size)) == noErr,
              AudioUnitInitialize(unit) == noErr, AudioOutputUnitStart(unit) == noErr else {
            throw AudioDeviceError.cannotStart(name)
        }
        self.unit = unit
        installDeviceListener()
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

    /// Spec 4 §12 — "Core Audio device notification".
    private func installDeviceListener() {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.global(qos: .utility)) { [weak self] _, _ in
            guard let self, self.running.load(ordering: .relaxed) else { return }
            if HALOutputDevice.deviceID(forUID: self.uid) == nil { self.onDeviceLost?() }
        }
    }

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
