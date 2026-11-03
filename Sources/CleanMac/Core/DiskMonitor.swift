import Foundation

@MainActor
final class DiskMonitor: ObservableObject {
    static let shared = DiskMonitor()

    @Published private(set) var status = VolumeStatus(freeBytes: 0, totalBytes: 0, availableForImportantUsage: nil)
    @Published private(set) var pressure: DiskPressure = .normal
    @Published private(set) var sessionActive = true
    /// Share of non-idle CPU since the previous sample. Nil until two samples exist.
    @Published private(set) var cpuLoad: Double?
    /// Recent CPU fractions, oldest first. About a minute at the two-second sample.
    @Published private(set) var cpuHistory: [Double] = []
    @Published private(set) var memory: MemorySample?
    /// Nil when the GPU driver does not publish utilization.
    @Published private(set) var gpuLoad: Double?

    private var timer: Timer?
    private var meterTimer: Timer?
    private var cpuReader = CPULoadReader()
    private var started = false
    private let historyLimit = 36

    func start() {
        guard !started else { return }
        started = true
        refresh()
        let timer = Timer(timeInterval: 120, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        _ = cpuReader.percentage()
        sampleMeters()
        let meterTimer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sampleMeters() }
        }
        RunLoop.main.add(meterTimer, forMode: .common)
        self.meterTimer = meterTimer
    }

    private func sampleMeters() {
        guard sessionActive else { return }
        let settings = AppSettings.shared
        if settings.showCPUMeter, let load = cpuReader.percentage() {
            cpuLoad = load
            cpuHistory.append(load)
            if cpuHistory.count > historyLimit {
                cpuHistory.removeFirst(cpuHistory.count - historyLimit)
            }
        }
        if settings.showMemoryMeter {
            memory = MemoryReader.sample()
        }
        if settings.showGPUMeter {
            gpuLoad = GPULoadReader.percentage()
        }
    }

    func refresh() {
        guard sessionActive else { return }
        let thresholds = AppSettings.shared.pressureThresholds
        Task.detached(priority: .utility) {
            let status = VolumeReader.read()
            await MainActor.run {
                guard let status, self.sessionActive else { return }
                let previous = self.pressure
                self.status = status
                let next = thresholds.pressure(freeBytes: status.freeBytes, previous: previous)
                self.pressure = next
                NotificationCoordinator.shared.consider(previous: previous, next: next, freeBytes: status.freeBytes)
            }
        }
    }

    func setSessionActive(_ active: Bool) {
        sessionActive = active
        if active {
            _ = cpuReader.percentage()
            cpuLoad = nil
            cpuHistory = []
            refresh()
        }
    }
}

@MainActor
final class NotificationCoordinator {
    static let shared = NotificationCoordinator()

    private var lastNotifiedPressure: DiskPressure = .normal
    private var lastNotifiedAt: Date?

    func consider(previous: DiskPressure, next: DiskPressure, freeBytes: Int64) {
        let settings = AppSettings.shared
        if next < lastNotifiedPressure {
            lastNotifiedPressure = next
        }
        guard settings.notificationsEnabled, DiskMonitor.shared.sessionActive else { return }
        if let snooze = settings.notificationSnoozeUntil, snooze > Date() { return }
        guard next > previous, next >= .low, next > lastNotifiedPressure else { return }
        lastNotifiedPressure = next
        lastNotifiedAt = Date()
        settings.postPressureNotification(pressure: next, freeBytes: freeBytes)
    }

    func rememberCurrentPressure() {
        lastNotifiedPressure = DiskMonitor.shared.pressure
        lastNotifiedAt = Date()
    }
}
