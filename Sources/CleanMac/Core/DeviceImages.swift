import Foundation

/// Simulator runtimes and Android system images. Each image is removed on its own, never as a bulk clean.
enum DeviceImages {
    struct Image: Equatable {
        var token: String
        var name: String
        var bytes: Int64
        var deletable: Bool
    }

    static func measure(_ category: CacheCategory, home: URL) -> ScanResult {
        let images = category.id == "xcode-runtimes" ? xcodeImages(home: home) : androidImages(home: home)
        let children = images.map { image in
            MeasuredChild(
                name: image.name,
                bytes: image.bytes,
                modified: nil,
                disposition: image.deletable ? .cleanable : .viewOnly(L10n.t("images.kept")),
                actionToken: image.deletable ? image.token : nil
            )
        }
        let total = images.reduce(Int64(0)) { $0 + $1.bytes }
        return ScanResult(
            bytes: total,
            cleanableBytes: 0,
            access: .full,
            children: children.sorted { $0.bytes > $1.bytes },
            oldest: nil,
            skippedSymlinks: 0,
            note: images.isEmpty ? L10n.t("images.empty") : nil
        )
    }

    static func xcodeImages(home: URL) -> [Image] {
        guard let xcrun = ToolLocator.find("xcrun", home: home) else { return [] }
        let result = ToolRunner.run(xcrun, ["simctl", "runtime", "list", "-j"], home: home, timeout: 40)
        guard result.exitCode == 0, !result.timedOut else { return [] }
        return parseRuntimes(Data(result.output.utf8))
    }

    static func parseRuntimes(_ data: Data) -> [Image] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        var images: [Image] = []
        for (key, value) in object {
            guard let row = value as? [String: Any] else { continue }
            let identifier = (row["identifier"] as? String) ?? key
            guard isRuntimeIdentifier(identifier) else { continue }
            let version = row["version"] as? String ?? ""
            let build = row["build"] as? String ?? ""
            let platform = platformName(row["platformIdentifier"] as? String)
            var name = platform
            if !version.isEmpty { name += " \(version)" }
            if !build.isEmpty { name += " (\(build))" }
            images.append(Image(
                token: identifier,
                name: name,
                bytes: int64(row["sizeBytes"]),
                deletable: row["deletable"] as? Bool ?? false
            ))
        }
        return images.sorted { lhs, rhs in
            if lhs.bytes != rhs.bytes { return lhs.bytes > rhs.bytes }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    /// Only a UUID that simctl itself reported. Never a path and never `all`.
    static func isRuntimeIdentifier(_ value: String) -> Bool {
        value.range(
            of: #"^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$"#,
            options: .regularExpression
        ) != nil
    }

    static func deleteRuntime(token: String, home: URL) -> String? {
        guard isRuntimeIdentifier(token) else { return L10n.t("error.unsafe") }
        guard let match = xcodeImages(home: home).first(where: {
            $0.token.caseInsensitiveCompare(token) == .orderedSame && $0.deletable
        }) else {
            return L10n.t("images.xcode.gone")
        }
        guard let xcrun = ToolLocator.find("xcrun", home: home) else { return L10n.t("images.xcode.missing") }
        let result = ToolRunner.run(xcrun, ["simctl", "runtime", "delete", match.token], home: home, timeout: 180)
        if result.timedOut { return L10n.f("error.timeout", "xcrun") }
        if result.exitCode != 0 { return L10n.f("error.tool", "xcrun") }
        return nil
    }

    static func androidImages(home: URL) -> [Image] {
        let root = home.appendingPathComponent("Library/Android/sdk/system-images", isDirectory: true)
        let guarder = PathGuard(home: home)
        guard case let .allowed(safeRoot) = guarder.vetDirectory(root) else { return [] }
        var images: [Image] = []
        for api in guarder.listChildren(of: safeRoot).children where isDirectory(api) {
            for tag in guarder.listChildren(of: api).children where isDirectory(tag) {
                let abis = guarder.listChildren(of: tag).children.filter(isDirectory)
                let leaves = abis.isEmpty ? [tag] : abis
                for leaf in leaves {
                    let relative = relativePath(of: leaf, under: safeRoot)
                    guard isAndroidRelativePath(relative) else { continue }
                    let walk = CacheScanner.walk(url: leaf, limit: leaf)
                    images.append(Image(
                        token: relative,
                        name: androidTitle(relative),
                        bytes: walk.bytes,
                        deletable: true
                    ))
                }
            }
        }
        return images.sorted { $0.bytes > $1.bytes }
    }

    static func isAndroidRelativePath(_ value: String) -> Bool {
        let parts = value.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard (2...3).contains(parts.count) else { return false }
        return parts.allSatisfy { part in
            !part.isEmpty && part != "." && part != ".." && !part.hasPrefix(".")
                && !part.contains("\0") && !part.contains("/") && !part.contains("\\")
        }
    }

    static func deleteAndroidImage(token: String, home: URL) -> String? {
        guard let target = androidTarget(token: token, home: home) else { return L10n.t("error.unsafe") }
        let walk = CacheScanner.walk(url: target, limit: target)
        do {
            try FileManager.default.trashItem(at: target, resultingItemURL: nil)
            _ = walk
            return nil
        } catch {
            return L10n.t("images.android.busy")
        }
    }

    static func androidTarget(token: String, home: URL) -> URL? {
        guard isAndroidRelativePath(token) else { return nil }
        let root = home.appendingPathComponent("Library/Android/sdk/system-images", isDirectory: true)
        let guarder = PathGuard(home: home)
        guard case let .allowed(safeRoot) = guarder.vetDirectory(root) else { return nil }
        let target = token.split(separator: "/").reduce(safeRoot) { $0.appendingPathComponent(String($1), isDirectory: true) }
        guard case let .allowed(safe) = guarder.vetDirectory(target) else { return nil }
        let rootPath = safeRoot.resolvingSymlinksInPath().standardizedFileURL.path
        let path = safe.resolvingSymlinksInPath().standardizedFileURL.path
        guard path != rootPath, path.hasPrefix(rootPath + "/") else { return nil }
        return safe
    }

    private static func relativePath(of url: URL, under root: URL) -> String {
        let rootPath = root.resolvingSymlinksInPath().standardizedFileURL.path
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        guard path.hasPrefix(rootPath + "/") else { return "" }
        return String(path.dropFirst(rootPath.count + 1))
    }

    private static func androidTitle(_ relative: String) -> String {
        let parts = relative.split(separator: "/").map(String.init)
        let api = parts.first.map { $0.hasPrefix("android-") ? "Android \($0.dropFirst("android-".count))" : $0 } ?? relative
        return ([api] + parts.dropFirst()).joined(separator: " · ")
    }

    private static func platformName(_ identifier: String?) -> String {
        switch identifier {
        case "com.apple.platform.iphonesimulator": return "iOS"
        case "com.apple.platform.watchsimulator": return "watchOS"
        case "com.apple.platform.appletvsimulator": return "tvOS"
        case "com.apple.platform.xrsimulator": return "visionOS"
        default: return "Simulator"
        }
    }

    private static func int64(_ value: Any?) -> Int64 {
        if let number = value as? NSNumber { return number.int64Value }
        if let number = value as? Int64 { return number }
        if let number = value as? Int { return Int64(number) }
        return 0
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}
