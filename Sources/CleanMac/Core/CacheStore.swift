import AppKit
import Combine
import Foundation

struct CacheItem: Identifiable {
    var category: CacheCategory
    var result: ScanResult
    var runningApp: String?
    /// Apps Roomy will close before cleaning this row. Empty when nothing is running.
    var appsToQuit: [String] = []

    var id: String { category.id }

    var isCleanable: Bool {
        if category.method.isRevealOnly || category.toolProblem != nil { return false }
        if result.access == .denied { return false }
        return result.cleanableBytes > 0
    }
}

struct PendingClean: Equatable {
    var ids: [String]
    var appsToQuit: [String]
    /// When set, confirmation deletes this one image instead of the whole category.
    var childToken: String? = nil
    var childTitle: String? = nil
}

struct Banner: Equatable {
    var message: String
    var isError: Bool
}

@MainActor
final class CacheStore: ObservableObject {
    static let shared = CacheStore()

    @Published private(set) var items: [CacheItem] = []
    @Published private(set) var isScanning = false
    @Published private(set) var scanIncomplete = false
    @Published private(set) var cleaningIDs: Set<String> = []
    @Published var selection: Set<String> = []
    @Published var pendingClean: PendingClean?
    @Published var banner: Banner?
    @Published var highlightedID: String?
    @Published private(set) var lastScanDate: Date?
    @Published private(set) var lastReport: CleanReport?
    @Published private(set) var scannedCount = 0
    @Published private(set) var plannedCount = 0
    @Published private(set) var sessionActive = true

    let cleanupFinished = PassthroughSubject<String, Never>()

    private var scanTask: Task<Void, Never>?
    private var bannerTask: Task<Void, Never>?
    private let environment = UserEnvironment.current()

    var totalKnownBytes: Int64 {
        items.reduce(0) { $0 + ($1.result.bytes ?? 0) }
    }

    var totalsComplete: Bool {
        !items.isEmpty && items.allSatisfy { $0.result.access == .full && $0.result.bytes != nil } && !scanIncomplete && !isScanning
    }

    var hasScannedAnything: Bool { items.contains { $0.result.bytes != nil } }
    var isCleaning: Bool { !cleaningIDs.isEmpty }
    var needsFullDiskAccess: Bool { items.contains { $0.result.access == .denied || $0.result.access == .partial } }

    var sortedItems: [CacheItem] {
        items.sorted { lhs, rhs in
            let left = lhs.result.bytes ?? -1
            let right = rhs.result.bytes ?? -1
            if left != right { return left > right }
            return lhs.category.name.localizedCaseInsensitiveCompare(rhs.category.name) == .orderedAscending
        }
    }

    var selectedCleanableIDs: [String] {
        sortedItems.filter { selection.contains($0.id) && $0.isCleanable && CategoryRules.allowsBulkClean(id: $0.id, cleanable: true) }.map(\.id)
    }

    func suggestionInput(now: Date = Date()) -> SuggestionInput {
        SuggestionInput(
            pressure: DiskMonitor.shared.pressure,
            freeBytes: DiskMonitor.shared.status.freeBytes,
            items: items.map {
                SuggestionItem(
                    id: $0.id,
                    name: $0.category.name,
                    bytes: $0.result.bytes,
                    accessDenied: $0.result.access == .denied,
                    partial: $0.result.access == .partial,
                    blockedApp: $0.runningApp,
                    toolProblem: $0.category.toolProblem,
                    recommend: CategoryRules.recommends(included: $0.category.includeInRecommendations, cleanable: $0.isCleanable, appRunning: !$0.appsToQuit.isEmpty, excepted: AppSettings.shared.excludedSuggestions.contains($0.id)),
                    viewOnly: $0.category.method.isRevealOnly
                )
            },
            scanDate: lastScanDate,
            now: now,
            lastReport: lastReport
        )
    }

    func pauseForInactiveSession() {
        sessionActive = false
        scanTask?.cancel()
        isScanning = false
    }

    func resumeSession() {
        sessionActive = true
    }

    func refreshIfStale(maxAge: TimeInterval = 600) {
        guard sessionActive, !isScanning, !isCleaning else { return }
        if let lastScanDate, Date().timeIntervalSince(lastScanDate) < maxAge {
            updateRunningApps()
            return
        }
        refresh()
    }

    func refresh() {
        guard sessionActive, !isCleaning else { return }
        scanTask?.cancel()
        isScanning = true
        scanIncomplete = false
        scannedCount = 0
        let generation = UUID()
        scanTask = Task { [weak self] in
            guard let self else { return }
            let categories = await CategoryCatalog.detect(environment: self.environment)
            guard !Task.isCancelled else { return }
            let previous = Dictionary(uniqueKeysWithValues: self.items.map { ($0.id, $0.result) })
            self.items = categories.map { category in
                CacheItem(category: category, result: previous[category.id] ?? .unknown, runningApp: nil)
            }
            self.selection.formIntersection(categories.map(\.id))
            self.updateRunningApps()
            self.plannedCount = categories.count
            await self.scan(categories, generation: generation)
        }
    }

    func cancelScan() {
        scanTask?.cancel()
        isScanning = false
        scanIncomplete = true
        showBanner(L10n.t("scan.stopped"), isError: true)
    }

    func updateRunningApps() {
        for index in items.indices {
            let names = appsThatMustQuit(items[index].category)
            items[index].appsToQuit = names
            items[index].runningApp = names.first
        }
    }

    func selectRecommended() {
        let excepted = AppSettings.shared.excludedSuggestions
        selection = Set(items.compactMap { item in
            CategoryRules.recommends(included: item.category.includeInRecommendations, cleanable: item.isCleanable, appRunning: !item.appsToQuit.isEmpty, excepted: excepted.contains(item.id)) ? item.id : nil
        })
    }

    func requestClean(ids: [String]) {
        updateRunningApps()
        let targets = items.filter { ids.contains($0.id) && $0.isCleanable && CategoryRules.allowsBulkClean(id: $0.id, cleanable: true) }
        guard !targets.isEmpty else { return }
        pendingClean = PendingClean(ids: targets.map(\.id), appsToQuit: combinedQuitNames(targets))
    }

    func cancelPendingClean() {
        pendingClean = nil
    }

    func requestDeleteImage(categoryID: String, token: String, title: String) {
        guard items.contains(where: { $0.id == categoryID }) else { return }
        pendingClean = PendingClean(ids: [categoryID], appsToQuit: [], childToken: token, childTitle: title)
    }

    func confirmPendingClean() {
        guard let pendingClean else { return }
        if pendingClean.childToken != nil {
            let request = pendingClean
            self.pendingClean = nil
            Task { await deleteImage(request) }
            return
        }
        updateRunningApps()
        let targets = items.filter { pendingClean.ids.contains($0.id) }
        let now = combinedQuitNames(targets)
        if Set(now) != Set(pendingClean.appsToQuit) {
            self.pendingClean = PendingClean(ids: pendingClean.ids, appsToQuit: now)
            return
        }
        self.pendingClean = nil
        Task { await clean(ids: pendingClean.ids) }
    }

    private func appsThatMustQuit(_ category: CacheCategory) -> [String] {
        var apps = category.blockingApps
        if category.blocksMatchingBundleChildren {
            let known = Set(apps.map(\.bundleID))
            for root in category.roots where !known.contains(root.lastPathComponent) {
                apps.append(BlockingApp(bundleID: root.lastPathComponent, name: root.lastPathComponent))
            }
        }
        var seen = Set<String>()
        return RunningApps.matches(of: apps, uid: environment.uid).compactMap { match in
            seen.insert(match.name).inserted ? match.name : nil
        }
    }

    private func combinedQuitNames(_ items: [CacheItem]) -> [String] {
        var seen = Set<String>()
        return items.flatMap(\.appsToQuit).filter { seen.insert($0).inserted }
    }

    func deleteImage(_ request: PendingClean) async {
        guard let id = request.ids.first, let token = request.childToken,
              let category = items.first(where: { $0.id == id })?.category else { return }
        cleaningIDs.insert(id)
        let outcome = await CacheCleaner.deleteChild(category, token: token, environment: environment)
        if let index = items.firstIndex(where: { $0.id == id }) {
            items[index].result = outcome.after
        }
        cleaningIDs.remove(id)
        let report = CleanReport(
            trashedBytes: outcome.trashedBytes,
            cacheReductionBytes: outcome.cacheReduction,
            irreversible: outcome.irreversible,
            freeBefore: 0,
            freeAfter: 0,
            failures: outcome.failure.map { [$0] } ?? [],
            skipped: outcome.skipped,
            categoryNames: [category.name]
        )
        lastReport = report
        showBanner(ResultCopy.details(report), isError: outcome.failure != nil)
        cleanupFinished.send(ResultCopy.toast(report))
    }

    func clean(ids: [String]) async {
        let targets = items.filter { ids.contains($0.id) && $0.isCleanable }
        guard !targets.isEmpty else { return }
        cleaningIDs.formUnion(targets.map(\.id))
        let freeBefore = await Task.detached(priority: .utility) { VolumeReader.read()?.freeBytes ?? 0 }.value
        var trashed: Int64 = 0
        var reduction: Int64 = 0
        var irreversible = false
        var failures: [String] = []
        var skipped: [String] = []

        for item in targets {
            guard let category = items.first(where: { $0.id == item.id })?.category else { continue }
            let outcome = await CacheCleaner.clean(category, environment: environment, quitRunningApps: true)
            trashed += outcome.trashedBytes
            reduction += outcome.cacheReduction
            irreversible = irreversible || outcome.irreversible
            if let failure = outcome.failure {
                failures.append("\(category.name): \(failure)")
            }
            if outcome.failedItems > 0 {
                failures.append("\(category.name): не вдалося прибрати \(outcome.failedItems)")
            }
            skipped.append(contentsOf: outcome.skipped.map { "\(category.name): \($0)" })
            if let index = items.firstIndex(where: { $0.id == category.id }) {
                items[index].result = outcome.after
            }
            cleaningIDs.remove(category.id)
            selection.remove(category.id)
        }

        let freeAfter = await Task.detached(priority: .utility) { VolumeReader.read()?.freeBytes ?? 0 }.value
        DiskMonitor.shared.refresh()
        updateRunningApps()
        let names = targets.map(\.category.name)
        let report = CleanReport(
            trashedBytes: trashed,
            cacheReductionBytes: reduction,
            irreversible: irreversible,
            freeBefore: freeBefore,
            freeAfter: freeAfter,
            failures: failures,
            skipped: Array(skipped.prefix(6)),
            categoryNames: names
        )
        lastReport = report
        HistoryStore.shared.append(HistoryEntry(
            id: UUID(),
            date: Date(),
            categoryIDs: targets.map(\.id),
            categoryNames: names,
            action: irreversible && trashed > 0 ? "mixed" : (irreversible ? "command" : "trash"),
            cacheReductionBytes: reduction,
            trashedBytes: trashed,
            irreversible: irreversible,
            freeBefore: freeBefore,
            freeAfter: freeAfter,
            failures: failures,
            skipped: Array(skipped.prefix(6))
        ))
        let message = ResultCopy.details(report)
        showBanner(message, isError: !failures.isEmpty)
        cleanupFinished.send(ResultCopy.toast(report))
        lastScanDate = Date()
    }

    func item(_ id: String) -> CacheItem? {
        items.first { $0.id == id }
    }

    private func scan(_ categories: [CacheCategory], generation: UUID) async {
        let deferred = categories.filter { $0.usageProbe != nil }
        let immediate = categories.filter { $0.usageProbe == nil }
        await scanConcurrently(immediate, limit: 3)
        guard !Task.isCancelled else {
            isScanning = false
            scanIncomplete = true
            return
        }
        await scanConcurrently(deferred, limit: 1)
        guard !Task.isCancelled else {
            isScanning = false
            scanIncomplete = true
            return
        }
        _ = generation
        lastScanDate = Date()
        isScanning = false
        scanIncomplete = false
    }

    /// `docker system df` takes long enough to starve the rest of the list, so probes run after the file walks.
    private func scanConcurrently(_ categories: [CacheCategory], limit: Int) async {
        guard !categories.isEmpty else { return }
        let environment = environment
        await withTaskGroup(of: (String, ScanResult).self) { group in
            var next = min(limit, categories.count)
            for category in categories.prefix(next) {
                group.addTask { [environment] in
                    (category.id, await CacheScanner.scan(category, environment: environment))
                }
            }
            while let (id, result) = await group.next() {
                if Task.isCancelled { break }
                apply(result, to: id)
                scannedCount += 1
                if next < categories.count {
                    let category = categories[next]
                    next += 1
                    group.addTask { [environment] in
                        (category.id, await CacheScanner.scan(category, environment: environment))
                    }
                }
            }
        }
    }

    private func apply(_ result: ScanResult, to id: String) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].result = result
    }

    private func showBanner(_ message: String, isError: Bool) {
        banner = Banner(message: message, isError: isError)
        bannerTask?.cancel()
        bannerTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(isError ? 10 : 6))
            guard !Task.isCancelled else { return }
            self?.banner = nil
        }
    }
}
