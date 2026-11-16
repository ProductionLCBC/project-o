// OEngine — Spec 10 §2, when the Mac started.

import Darwin
import Foundation

/// Spec 10 §2, "What a relaunch brings back" — a launch is a relaunch "when
/// the run before it ended without a stop in this boot of the Mac:
/// `state/last.json` says `clean: false` and was written after the Mac
/// started." This is when the Mac started, as the kernel has it.
public enum BootTime {
    /// The wall-clock moment of the boot, in milliseconds since 1970, or nil
    /// when the kernel doesn't say. It is a wall-clock stamp, like the one in
    /// `last.json`, so the two compare as they are.
    public static func wallMilliseconds() -> Int64? {
        var name = [CTL_KERN, KERN_BOOTTIME]
        var booted = timeval()
        var size = MemoryLayout<timeval>.stride
        guard sysctl(&name, u_int(name.count), &booted, &size, nil, 0) == 0, booted.tv_sec > 0 else { return nil }
        return Int64(booted.tv_sec) * 1000 + Int64(booted.tv_usec) / 1000
    }
}
