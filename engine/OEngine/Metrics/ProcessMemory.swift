// OEngine — Spec 4 §13, "memory in use, as the process footprint ... beside
// the resident size, and its parts".

import Foundation
import Darwin

/// Spec 4 §13 — the process-level memory figures of the minute record: the
/// resident size (what the record carried before the correction of
/// 2026-11-03, kept for older readers), the kernel's `phys_footprint` ("which
/// counts the GPU-owned textures and heaps and leaves out purgeable cache
/// memory"), and "the malloc zones' live and allocated bytes with the
/// purgeable zone on its own", so cache growth and allocator fragmentation
/// show as themselves. Read on the recorder's thread once a minute; never on
/// the render thread, since the zone statistics take the allocator's locks.
public struct ProcessMemory: Equatable, Sendable {
    public var residentBytes: Int64
    public var footprintBytes: Int64
    /// The graphics-tagged part of the footprint: the GPU-owned textures,
    /// heaps and drawables, which swing by tens of megabytes between minutes
    /// as the driver's pools come and go, so §13 judges the footprint less
    /// this part and the resource table's texture bytes say what the engine
    /// itself holds.
    public var graphicsFootprintBytes: Int64
    public var heapLiveBytes: Int64
    public var heapAllocatedBytes: Int64
    public var purgeableLiveBytes: Int64

    public init(residentBytes: Int64 = 0, footprintBytes: Int64 = 0, graphicsFootprintBytes: Int64 = 0, heapLiveBytes: Int64 = 0,
                heapAllocatedBytes: Int64 = 0, purgeableLiveBytes: Int64 = 0) {
        self.residentBytes = residentBytes
        self.footprintBytes = footprintBytes
        self.graphicsFootprintBytes = graphicsFootprintBytes
        self.heapLiveBytes = heapLiveBytes
        self.heapAllocatedBytes = heapAllocatedBytes
        self.purgeableLiveBytes = purgeableLiveBytes
    }

    /// Every figure, read now.
    public static func current() -> ProcessMemory {
        let zones = mallocZones()
        let footprints = footprint()
        return ProcessMemory(residentBytes: residentSize(), footprintBytes: footprints.total, graphicsFootprintBytes: footprints.graphics,
                             heapLiveBytes: zones.live, heapAllocatedBytes: zones.allocated, purgeableLiveBytes: zones.purgeableLive)
    }

    /// The resident size, as `ri_resident_size`: it counts purgeable cache
    /// pages the kernel reclaims at will and misses the GPU-owned memory,
    /// which is why §13 no longer judges it when the footprint is there.
    public static func residentSize() -> Int64 {
        var usage = rusage_info_current()
        let result = withUnsafeMutablePointer(to: &usage) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rebound in
                proc_pid_rusage(getpid(), RUSAGE_INFO_CURRENT, rebound)
            }
        }
        return result == 0 ? Int64(usage.ri_resident_size) : 0
    }

    /// The kernel's `phys_footprint`, the figure Apple's `footprint` tool and
    /// the memory limit hold a process to, and its graphics-tagged part (the
    /// ledger the tool shows as "(graphics)", mapped or not, compressed or
    /// not).
    public static func footprint() -> (total: Int64, graphics: Int64) {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(task_self_trap(), task_flavor_t(TASK_VM_INFO), rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else { return (0, 0) }
        let graphics = Int64(info.ledger_tag_graphics_footprint) + Int64(info.ledger_tag_graphics_footprint_compressed)
        return (Int64(info.phys_footprint), graphics)
    }

    /// The malloc zones summed, with the purgeable zone (CoreGraphics' and
    /// CoreText's cache memory, volatile to the kernel) on its own: `live` is
    /// what is in use, `allocated` what the zones hold from the kernel, so a
    /// rising `allocated` over a flat `live` is fragmentation.
    public static func mallocZones() -> (live: Int64, allocated: Int64, purgeableLive: Int64) {
        var addresses: UnsafeMutablePointer<vm_address_t>?
        var count: UInt32 = 0
        guard malloc_get_all_zones(task_self_trap(), nil, &addresses, &count) == KERN_SUCCESS, let addresses else { return (0, 0, 0) }
        var live: Int64 = 0
        var allocated: Int64 = 0
        var purgeable: Int64 = 0
        for index in 0..<Int(count) {
            guard let zone = UnsafeMutablePointer<malloc_zone_t>(bitPattern: UInt(addresses[index])) else { continue }
            var stats = malloc_statistics_t()
            malloc_zone_statistics(zone, &stats)
            let name = malloc_get_zone_name(zone).map { String(cString: $0) } ?? ""
            if name.hasPrefix("DefaultPurgeableMallocZone") {
                purgeable += Int64(stats.size_in_use)
            } else {
                live += Int64(stats.size_in_use)
                allocated += Int64(stats.size_allocated)
            }
        }
        return (live, allocated, purgeable)
    }
}
