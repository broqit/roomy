import Darwin
import Foundation
import IOKit

struct MemorySample: Equatable {
    var usedBytes: Int64
    var physicalBytes: Int64
    /// Share of physical memory that Activity Monitor counts as used: app, wired, and compressed.
    var fraction: Double
}

enum MemoryReader {
    static func sample() -> MemorySample? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &stats) { pointer -> kern_return_t in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard status == KERN_SUCCESS else { return nil }
        var pageSize: vm_size_t = 0
        guard host_page_size(mach_host_self(), &pageSize) == KERN_SUCCESS, pageSize > 0 else { return nil }
        let usedPages = UInt64(stats.internal_page_count) + UInt64(stats.compressor_page_count) + UInt64(stats.wire_count)
        let physical = ProcessInfo.processInfo.physicalMemory
        guard physical > 0 else { return nil }
        let used = min(usedPages * UInt64(pageSize), physical)
        return MemorySample(usedBytes: Int64(used), physicalBytes: Int64(physical), fraction: Double(used) / Double(physical))
    }
}

/// GPU activity from the accelerator's performance statistics. Nil when the driver does not publish a utilization key.
enum GPULoadReader {
    private static let keys = ["Device Utilization %", "GPU Activity(%)", "Renderer Utilization %"]

    static func percentage() -> Double? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }
        var best: Double?
        while true {
            let service = IOIteratorNext(iterator)
            if service == 0 { break }
            defer { IOObjectRelease(service) }
            if let value = utilization(service) {
                best = max(best ?? 0, value)
            }
        }
        return best
    }

    private static func utilization(_ service: io_registry_entry_t) -> Double? {
        guard let property = IORegistryEntryCreateCFProperty(service, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue(),
              let statistics = property as? [String: Any] else { return nil }
        for key in keys {
            guard let raw = (statistics[key] as? NSNumber)?.doubleValue else { continue }
            let fraction = raw > 1 ? raw / 100 : raw
            if fraction >= 0, fraction <= 1 { return fraction }
        }
        return nil
    }
}
