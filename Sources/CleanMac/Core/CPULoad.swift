import Darwin

/// Two samples of host CPU ticks. The first call only remembers the baseline.
struct CPULoadReader {
    private var previous: (user: UInt32, system: UInt32, idle: UInt32, nice: UInt32)?

    mutating func percentage() -> Double? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { pointer -> kern_return_t in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard status == KERN_SUCCESS else { return nil }
        let ticks = info.cpu_ticks
        let current = (user: ticks.0, system: ticks.1, idle: ticks.2, nice: ticks.3)
        defer { previous = current }
        guard let previous else { return nil }
        let user = current.user &- previous.user
        let system = current.system &- previous.system
        let idle = current.idle &- previous.idle
        let nice = current.nice &- previous.nice
        let total = UInt64(user) + UInt64(system) + UInt64(idle) + UInt64(nice)
        guard total > 0 else { return 0 }
        return Double(UInt64(user) + UInt64(system) + UInt64(nice)) / Double(total)
    }
}
