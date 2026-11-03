import Foundation

enum DiskPressure: Int, Comparable, Codable, CaseIterable {
    case normal = 0
    case low = 1
    case critical = 2
    case urgent = 3

    static func < (lhs: DiskPressure, rhs: DiskPressure) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var title: String {
        switch self {
        case .normal: return L10n.t("pressure.normal")
        case .low: return L10n.t("pressure.low")
        case .critical: return L10n.t("pressure.critical")
        case .urgent: return L10n.t("pressure.urgent")
        }
    }
}

struct PressureThresholds: Equatable, Codable {
    var lowBytes: Int64
    var criticalBytes: Int64
    var urgentBytes: Int64
    var hysteresisBytes: Int64

    static let `default` = PressureThresholds(
        lowBytes: 20_000_000_000,
        criticalBytes: 10_000_000_000,
        urgentBytes: 5_000_000_000,
        hysteresisBytes: 1_000_000_000
    )

    func normalized() -> PressureThresholds {
        let hysteresis = max(0, hysteresisBytes)
        var levels = [max(1, urgentBytes), max(1, criticalBytes), max(1, lowBytes)].sorted()
        if levels[0] == levels[1] { levels[1] += 1 }
        if levels[1] == levels[2] { levels[2] += 1 }
        return PressureThresholds(
            lowBytes: levels[2],
            criticalBytes: levels[1],
            urgentBytes: levels[0],
            hysteresisBytes: hysteresis
        )
    }

    /// Worsening applies immediately. Recovery waits until the freed space clears the threshold plus hysteresis.
    func pressure(freeBytes: Int64, previous: DiskPressure) -> DiskPressure {
        let thresholds = normalized()
        let immediate = thresholds.immediate(freeBytes)
        guard immediate < previous else { return immediate }
        var state = previous
        while state > immediate {
            let exitAt = thresholds.entryThreshold(state) + thresholds.hysteresisBytes
            if freeBytes >= exitAt {
                state = DiskPressure(rawValue: state.rawValue - 1) ?? .normal
            } else {
                break
            }
        }
        return state
    }

    private func immediate(_ freeBytes: Int64) -> DiskPressure {
        if freeBytes < urgentBytes { return .urgent }
        if freeBytes < criticalBytes { return .critical }
        if freeBytes < lowBytes { return .low }
        return .normal
    }

    private func entryThreshold(_ state: DiskPressure) -> Int64 {
        switch state {
        case .urgent: return urgentBytes
        case .critical: return criticalBytes
        case .low: return lowBytes
        case .normal: return Int64.max
        }
    }
}

struct VolumeStatus: Equatable {
    var freeBytes: Int64
    var totalBytes: Int64
    var availableForImportantUsage: Int64?
}

enum VolumeReader {
    static func read(volume: URL = URL(fileURLWithPath: "/", isDirectory: true)) -> VolumeStatus? {
        let keys: Set<URLResourceKey> = [
            .volumeAvailableCapacityKey,
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
        ]
        guard let values = try? volume.resourceValues(forKeys: keys),
              let free = values.volumeAvailableCapacity,
              let total = values.volumeTotalCapacity else { return nil }
        return VolumeStatus(
            freeBytes: Int64(free),
            totalBytes: Int64(total),
            availableForImportantUsage: values.volumeAvailableCapacityForImportantUsage
        )
    }
}
