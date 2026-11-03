import Foundation

enum CleanError: LocalizedError, Equatable {
    case appRunning(String)
    case accessDenied
    case viewOnly
    case busy
    case toolFailed(tool: String)
    case timedOut(tool: String)
    case unsafePath

    var errorDescription: String? { message }

    var message: String {
        switch self {
        case let .appRunning(name):
            return L10n.f("error.appStill", name)
        case .accessDenied:
            return L10n.t("error.access")
        case .viewOnly:
            return L10n.t("error.view")
        case .busy:
            return L10n.t("error.busy")
        case let .toolFailed(tool):
            return L10n.f("error.tool", tool)
        case let .timedOut(tool):
            return L10n.f("error.timeout", tool)
        case .unsafePath:
            return L10n.t("error.unsafe")
        }
    }
}

struct CategoryOutcome: Equatable {
    var before: ScanResult
    var after: ScanResult
    var trashedBytes: Int64
    var failedItems: Int
    var skipped: [String]
    var failure: String?
    var irreversible: Bool

    var cacheReduction: Int64 {
        guard let before = before.bytes, let after = after.bytes else { return 0 }
        return max(0, before - after)
    }
}

enum CleanLock {
    static func withLock<T>(home: URL, _ body: () async -> T) async -> T? {
        let directory = home.appendingPathComponent("Library/Application Support/CleanMac", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent("clean.lock")
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: Data())
            }
            let handle = try FileHandle(forUpdating: url)
            guard flock(handle.fileDescriptor, LOCK_EX | LOCK_NB) == 0 else {
                try? handle.close()
                return nil
            }
            let value = await body()
            flock(handle.fileDescriptor, LOCK_UN)
            try? handle.close()
            return value
        } catch {
            return nil
        }
    }
}

enum CacheCleaner {
    static func clean(_ category: CacheCategory, environment: UserEnvironment, quitRunningApps: Bool = false) async -> CategoryOutcome {
        let locked = await CleanLock.withLock(home: environment.home) {
            await cleanUnlocked(category, environment: environment, quitRunningApps: quitRunningApps)
        }
        if let locked { return locked }
        let before = await CacheScanner.scan(category, environment: environment)
        return CategoryOutcome(before: before, after: before, trashedBytes: 0, failedItems: 0, skipped: [], failure: CleanError.busy.message, irreversible: false)
    }

    private static func cleanUnlocked(_ category: CacheCategory, environment: UserEnvironment, quitRunningApps: Bool) async -> CategoryOutcome {
        let before = await CacheScanner.scan(category, environment: environment)
        if category.method.isRevealOnly || category.toolProblem != nil {
            let message = category.toolProblem ?? CleanError.viewOnly.message
            return CategoryOutcome(before: before, after: before, trashedBytes: 0, failedItems: 0, skipped: [], failure: message, irreversible: false)
        }
        if before.access == .denied, !category.method.isCommand {
            let message = CleanError.accessDenied.message
            return CategoryOutcome(before: before, after: before, trashedBytes: 0, failedItems: 0, skipped: [], failure: message, irreversible: false)
        }
        if quitRunningApps {
            if let failure = await closeRunningApps(category, environment: environment) {
                return CategoryOutcome(before: before, after: before, trashedBytes: 0, failedItems: 0, skipped: [], failure: failure, irreversible: false)
            }
        } else {
            let runningApp = await MainActor.run {
                RunningApps.firstRunning(of: category.blockingApps, uid: environment.uid)
            }
            if let app = runningApp {
                return CategoryOutcome(before: before, after: before, trashedBytes: 0, failedItems: 0, skipped: [], failure: L10n.f("error.leftRunning", app.name), irreversible: false)
            }
        }

        switch category.method {
        case let .command(executable, arguments, _, scope):
            let failure = await runCommand(executable: executable, arguments: arguments, scope: scope, home: environment.home)
            let after = await CacheScanner.scan(category, environment: environment)
            return CategoryOutcome(before: before, after: after, trashedBytes: 0, failedItems: failure == nil ? 0 : 1, skipped: [], failure: failure, irreversible: true)
        case .trashContents:
            let runningRoots = await MainActor.run {
                Set(category.roots.map(\.lastPathComponent).filter { RunningApps.isRunning(bundleID: $0, uid: environment.uid) })
            }
            let trash = await Task.detached(priority: .userInitiated) {
                trashChildren(of: category, environment: environment, runningRoots: runningRoots)
            }.value
            let after = await CacheScanner.scan(category, environment: environment)
            return CategoryOutcome(before: before, after: after, trashedBytes: trash.bytes, failedItems: trash.failures, skipped: trash.skipped, failure: nil, irreversible: false)
        case .revealOnly:
            return CategoryOutcome(before: before, after: before, trashedBytes: 0, failedItems: 0, skipped: [], failure: CleanError.viewOnly.message, irreversible: false)
        }
    }

    static func deleteChild(_ category: CacheCategory, token: String, environment: UserEnvironment) async -> CategoryOutcome {
        let before = await CacheScanner.scan(category, environment: environment)
        let failure: String?
        let irreversible: Bool
        if category.id == "xcode-runtimes" {
            irreversible = true
            failure = await Task.detached(priority: .userInitiated) {
                DeviceImages.deleteRuntime(token: token, home: environment.home)
            }.value
        } else if category.id == "android-images" {
            irreversible = false
            failure = await Task.detached(priority: .userInitiated) {
                DeviceImages.deleteAndroidImage(token: token, home: environment.home)
            }.value
        } else {
            irreversible = false
            failure = L10n.t("error.view")
        }
        let after = await CacheScanner.scan(category, environment: environment)
        let childBytes = before.children.first { $0.actionToken?.caseInsensitiveCompare(token) == .orderedSame }?.bytes ?? 0
        return CategoryOutcome(
            before: before,
            after: after,
            trashedBytes: failure == nil && !irreversible ? childBytes : 0,
            failedItems: failure == nil ? 0 : 1,
            skipped: [],
            failure: failure,
            irreversible: irreversible && failure == nil
        )
    }

    /// Closes apps that hold this cache. A category-level app that will not quit cancels the whole clean.
    /// Per-folder apps that stay open are left for `trashChildren` to skip.
    private static func closeRunningApps(_ category: CacheCategory, environment: UserEnvironment) async -> String? {
        var ids = category.blockingApps.map(\.bundleID)
        if category.blocksMatchingBundleChildren {
            ids.append(contentsOf: category.roots.map(\.lastPathComponent))
        }
        guard !ids.isEmpty else { return nil }
        let attempt = await AppQuitter.quit(bundleIDs: ids, uid: environment.uid)
        if attempt.terminatedAny {
            try? await Task.sleep(for: .milliseconds(300))
        }
        let failed = Set(attempt.failedBundleIDs)
        if let app = category.blockingApps.first(where: { failed.contains($0.bundleID) }) {
            return CleanError.appRunning(app.name).message
        }
        return nil
    }

    private static func runCommand(executable: URL, arguments: [String], scope: URL, home: URL) async -> String? {
        let guarder = PathGuard(home: home)
        guard case .allowed = guarder.vetDirectory(scope) else { return CleanError.unsafePath.message }
        for argument in arguments where argument.hasPrefix("/") {
            let url = URL(fileURLWithPath: argument, isDirectory: true)
            if guarder.isInsideHome(url) { continue }
            return CleanError.unsafePath.message
        }
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            return CleanError.toolFailed(tool: executable.lastPathComponent).message
        }
        let result = await Task.detached(priority: .userInitiated) {
            ToolRunner.run(executable, arguments, home: home, timeout: 180)
        }.value
        if result.timedOut { return CleanError.timedOut(tool: executable.lastPathComponent).message }
        if result.exitCode != 0 { return CleanError.toolFailed(tool: executable.lastPathComponent).message }
        return nil
    }

    private static func trashChildren(of category: CacheCategory, environment: UserEnvironment, runningRoots: Set<String>) -> (bytes: Int64, failures: Int, skipped: [String]) {
        let guarder = PathGuard(home: environment.home)
        var bytes: Int64 = 0
        var failures = 0
        var skipped: [String] = []
        if category.childFilter == .unrecognized {
            return (0, 0, ["лише перегляд"])
        }
        if category.childFilter == .namedFiles {
            return trashNamedFiles(of: category, guarder: guarder)
        }
        for root in category.roots {
            if runningRoots.contains(root.lastPathComponent) {
                skipped.append("\(root.lastPathComponent) запущено")
                continue
            }
            let listing = guarder.listChildren(of: root)
            guard let resolvedRoot = listing.root else {
                skipped.append("шлях недоступний")
                continue
            }
            for child in listing.children {
                let name = child.lastPathComponent
                if category.isExcluded(childName: name) { continue }
                guard case let .allowed(safe) = guarder.revalidate(child, asChildOf: resolvedRoot, expected: child) else {
                    skipped.append(name)
                    continue
                }
                let size = CacheScanner.walk(url: safe, limit: safe).bytes
                do {
                    try FileManager.default.trashItem(at: safe, resultingItemURL: nil)
                    bytes += size
                } catch {
                    failures += 1
                }
            }
        }
        return (bytes, failures, skipped)
    }

    /// Trash only files whose names still match the crash-dump allowlist and whose parent is still this user's home.
    private static func trashNamedFiles(of category: CacheCategory, guarder: PathGuard) -> (bytes: Int64, failures: Int, skipped: [String]) {
        var bytes: Int64 = 0
        var failures = 0
        var skipped: [String] = []
        for root in category.roots {
            guard case let .allowed(safe) = guarder.vetHomeFile(root, nameAllowed: CategoryRules.isIDECrashDump) else {
                skipped.append(root.lastPathComponent)
                continue
            }
            let size = CacheScanner.walk(url: safe, limit: safe).bytes
            do {
                try FileManager.default.trashItem(at: safe, resultingItemURL: nil)
                bytes += size
            } catch {
                failures += 1
            }
        }
        return (bytes, failures, skipped)
    }
}
