import Foundation

struct ToolProbe: Equatable {
    var exitCode: Int32
    var output: String
    var timedOut: Bool = false
}

enum ToolOutput {
    static func lastAbsolutePath(in output: String) -> String? {
        let lines = output.split(whereSeparator: \.isNewline).map { line in
            String(line).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        for line in lines.reversed() {
            if line.hasPrefix("/") && !line.contains("..") && !line.contains("\0") && !line.contains(" ") {
                return line
            }
        }
        return nil
    }
}

struct PnpmChoice: Equatable {
    var tool: URL?
    var store: URL?
    var problem: String?
    var ignoredBrokenCandidate: Bool
}

enum CategoryRules {
    static let telegramCacheNames = ["cache", "media_cache"]
    static let telegramMacChannels = ["stable", "appstore", "beta", "alpha"]

    /// The category itself says whether it is safe to offer. A running app stays out of «Рекомендовані»: its cache is cleanable only after the user confirms closing it.
    static func recommends(included: Bool, cleanable: Bool, appRunning: Bool, excepted: Bool) -> Bool {
        cleanable && !appRunning && !excepted && included
    }

    /// JVM crash artifacts dropped in the home directory by PhpStorm, IDEA, WebStorm and other JetBrains IDEs.
    /// Only the file name is checked. The caller still has to prove the file is a direct child of this user's home.
    static func isIDECrashDump(_ name: String) -> Bool {
        guard !name.isEmpty, !name.contains("/"), !name.contains("\0"), name != ".", name != ".." else { return false }
        if name.hasPrefix("java_error_in_"), name.hasSuffix(".log") || name.hasSuffix(".hprof") { return true }
        if name.hasPrefix("hs_err_pid"), name.hasSuffix(".log") { return true }
        if name.hasPrefix("replay_pid"), name.hasSuffix(".log") { return true }
        return false
    }

    static func allowsBulkClean(id: String, cleanable: Bool) -> Bool {
        cleanable && id != "trash"
    }

    static func isTelegramUserDataDirectory(_ name: String) -> Bool {
        if name == "user_data" { return true }
        guard name.hasPrefix("user_data#") else { return false }
        let suffix = name.dropFirst("user_data#".count)
        return !suffix.isEmpty && suffix.allSatisfy(\.isNumber)
    }

    static func isTelegramMacMediaCache(relative: String) -> Bool {
        let parts = relative.split(separator: "/").map(String.init)
        guard parts.count == 4 else { return false }
        guard telegramMacChannels.contains(parts[0]) else { return false }
        let account = parts[1]
        guard account.hasPrefix("account-") else { return false }
        let suffix = account.dropFirst("account-".count)
        guard !suffix.isEmpty, suffix.allSatisfy(\.isNumber) else { return false }
        return parts[2] == "postbox" && parts[3] == "media"
    }

    static func choosePnpm(home: URL, probes: [(tool: URL, probe: ToolProbe)], directoryExists: (URL) -> Bool) -> PnpmChoice {
        let guarder = PathGuard(home: home)
        var ignoredBroken = false
        var lastProblem = "Команда pnpm не працює. Перевстановіть pnpm і оновіть список. Каталог store не змінювався."
        guard !probes.isEmpty else {
            return PnpmChoice(tool: nil, store: nil, problem: nil, ignoredBrokenCandidate: false)
        }
        for item in probes {
            let path = ToolOutput.lastAbsolutePath(in: item.probe.output)
            let store = path.map { URL(fileURLWithPath: $0, isDirectory: true) }
            let vetted: URL? = store.flatMap { candidate in
                guard item.probe.exitCode == 0, !item.probe.timedOut, directoryExists(candidate) else { return nil }
                guard case let .allowed(resolved) = guarder.vetDirectory(candidate) else { return nil }
                return resolved
            }
            if let vetted {
                return PnpmChoice(tool: item.tool, store: vetted, problem: nil, ignoredBrokenCandidate: ignoredBroken)
            }
            ignoredBroken = true
            lastProblem = "Команда pnpm не працює (\(item.tool.lastPathComponent)). Перевстановіть pnpm і оновіть список. Store не змінювався."
        }
        return PnpmChoice(tool: nil, store: nil, problem: lastProblem, ignoredBrokenCandidate: ignoredBroken)
    }

    static func acceptCacheDirectory(output: String, home: URL, directoryExists: (URL) -> Bool) -> URL? {
        guard let path = ToolOutput.lastAbsolutePath(in: output) else { return nil }
        let url = URL(fileURLWithPath: path, isDirectory: true)
        guard directoryExists(url) else { return nil }
        guard case let .allowed(resolved) = PathGuard(home: home).vetDirectory(url) else { return nil }
        return resolved
    }

    enum HomebrewPlan: Equatable {
        case hidden
        case viewOnly(String)
        case trashCache(URL, note: String)
        case cleanup(brew: URL, cache: URL?)
    }

    /// `brew cleanup` with no extra flags. Anything else, including prune or uninstall, is rejected.
    static func isExactBrewCleanup(executable: URL, arguments: [String]) -> Bool {
        executable.lastPathComponent == "brew" && arguments == ["cleanup"]
    }

    /// The invoked file must be exactly `<prefix>/bin/brew` for a real directory the user owns.
    /// The resolved target has to stay inside `/opt/homebrew` or `/usr/local`.
    static func brewLivesInOwnedPrefix(_ executable: URL, uid: uid_t) -> Bool {
        guard uid != 0 else { return false }
        let invoked = executable.standardizedFileURL
        for raw in ["/opt/homebrew", "/usr/local"] {
            let prefix = URL(fileURLWithPath: raw, isDirectory: true).standardizedFileURL
            var info = stat()
            guard lstat(prefix.path, &info) == 0 else { continue }
            guard (info.st_mode & S_IFMT) == S_IFDIR, info.st_uid == uid else { continue }
            let resolvedPrefix = prefix.resolvingSymlinksInPath().standardizedFileURL
            guard resolvedPrefix.path == prefix.path else { continue }
            guard invoked.path == prefix.appendingPathComponent("bin/brew").standardizedFileURL.path else { continue }
            let resolvedExec = executable.resolvingSymlinksInPath().standardizedFileURL
            guard resolvedExec.path == prefix.path || resolvedExec.path.hasPrefix(prefix.path + "/") else { continue }
            return true
        }
        return false
    }

    static func homebrewPlan(cache: URL?, prefix: URL?, home: URL, ownerUID: uid_t?, currentUID: uid_t, cacheIsDirectory: Bool, brew: URL? = nil) -> HomebrewPlan {
        let guarder = PathGuard(home: home)
        let allowedCache: URL?
        if let cache, cacheIsDirectory {
            guard case let .allowed(resolved) = guarder.vetDirectory(cache) else {
                return .viewOnly(L10n.t("homebrew.outside"))
            }
            guard let ownerUID, ownerUID == currentUID else {
                return .viewOnly(L10n.t("homebrew.owner"))
            }
            allowedCache = resolved
        } else {
            allowedCache = nil
        }
        if let brew, isExactBrewCleanup(executable: brew, arguments: ["cleanup"]), brewLivesInOwnedPrefix(brew, uid: currentUID) {
            return .cleanup(brew: brew, cache: allowedCache)
        }
        guard let allowedCache else { return .hidden }
        let prefixIsPersonal = prefix.map { guarder.isInsideHome($0) } ?? false
        let note = prefixIsPersonal
            ? L10n.t("homebrew.personal")
            : L10n.t("homebrew.shared")
        return .trashCache(allowedCache, note: note)
    }

    /// Relative paths under ~/Library/Caches that are not already claimed by a dedicated category.
    static func unclaimedCachePaths(topLevel: [String], nested: [String: [String]], claimed: Set<String>, excludedNames: Set<String>, excludedPrefixes: [String]) -> [String] {
        func excluded(_ name: String) -> Bool {
            excludedNames.contains(name) || excludedPrefixes.contains { name.hasPrefix($0) }
        }
        var results: [String] = []
        for name in topLevel.sorted() where !excluded(name) {
            let nestedNames = nested[name] ?? []
            let claimedInside = claimed.contains { $0 == name || $0.hasPrefix(name + "/") }
            if !claimedInside {
                if !claimed.contains(name) {
                    results.append(name)
                }
                continue
            }
            if claimed.contains(name) { continue }
            let children = nestedNames.isEmpty ? [] : nestedNames
            if children.isEmpty { continue }
            for child in children.sorted() where !excluded(child) {
                let relative = "\(name)/\(child)"
                if claimed.contains(relative) { continue }
                if claimed.contains(where: { $0.hasPrefix(relative + "/") }) { continue }
                results.append(relative)
            }
        }
        return results
    }
}
