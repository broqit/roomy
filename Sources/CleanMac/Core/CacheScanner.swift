import Foundation

enum AccessState: Equatable {
    case unknown
    case full
    case partial
    case denied
}

enum ChildDisposition: Equatable {
    case cleanable
    case blocked(String)
    case viewOnly(String)
}

struct MeasuredChild: Equatable, Identifiable {
    var name: String
    var bytes: Int64
    var modified: Date?
    var disposition: ChildDisposition
    /// A delete handle. A runtime UUID or a relative path under the Android system-images folder. Never a raw absolute path.
    var actionToken: String? = nil
    var id: String { actionToken ?? name }
}

struct ScanResult: Equatable {
    var bytes: Int64?
    var cleanableBytes: Int64
    var access: AccessState
    var children: [MeasuredChild]
    var oldest: Date?
    var skippedSymlinks: Int
    /// Extra sentence from a probe, such as a Docker breakdown or why the probe failed.
    var note: String? = nil

    static let unknown = ScanResult(bytes: nil, cleanableBytes: 0, access: .unknown, children: [], oldest: nil, skippedSymlinks: 0)

    var hasCleanableChild: Bool {
        children.contains { if case .cleanable = $0.disposition { return true }; return false }
    }
}

enum CacheScanner {
    static func scan(_ category: CacheCategory, environment: UserEnvironment) async -> ScanResult {
        let uid = environment.uid
        let blockedApp = await MainActor.run {
            RunningApps.firstRunning(of: category.blockingApps, uid: uid)?.name
        }
        let runningChildren = await MainActor.run { () -> Set<String> in
            guard category.blocksMatchingBundleChildren else { return [] }
            return Set(category.roots.map(\.lastPathComponent).filter { RunningApps.isRunning(bundleID: $0, uid: uid) })
        }
        return await Task.detached(priority: .utility) {
            measure(category, home: environment.home, blockedApp: blockedApp, runningChildren: runningChildren)
        }.value
    }

    private static func measure(_ category: CacheCategory, home: URL, blockedApp: String?, runningChildren: Set<String>) -> ScanResult {
        if category.usageProbe == .dockerSystemDF {
            return DockerUsage.measure(home: home)
        }
        if category.usageProbe == .deviceImages {
            return DeviceImages.measure(category, home: home)
        }
        if category.roots.isEmpty {
            return .unknown
        }
        let guarder = PathGuard(home: home)
        var total: Int64 = 0
        var counted = false
        var denied = false
        var partial = false
        var skipped = 0
        var oldest: Date?
        var children: [MeasuredChild] = []
        let splitRoots = category.roots.count > 1 || category.childFilter == .namedFiles

        for root in category.roots {
            if Task.isCancelled { break }
            if splitRoots {
                let walk = walk(url: root, limit: root)
                if walk.denied, walk.bytes == 0 {
                    denied = true
                    continue
                }
                counted = true
                total += walk.bytes
                partial = partial || walk.partial
                oldest = earliest(oldest, walk.oldest)
                children.append(MeasuredChild(
                    name: displayName(root),
                    bytes: walk.bytes,
                    modified: walk.oldest,
                    disposition: disposition(for: root.lastPathComponent, category: category, blockedApp: blockedApp, runningChildren: runningChildren)
                ))
                continue
            }

            let listing = guarder.listChildren(of: root)
            skipped += listing.skippedSymlinks
            if listing.root == nil || listing.rejection != nil {
                denied = true
                continue
            }
            if listing.accessDenied { denied = true }
            if listing.children.isEmpty { counted = true }
            for child in listing.children {
                if Task.isCancelled { break }
                let name = child.lastPathComponent
                if category.isExcluded(childName: name) { continue }
                let walk = walk(url: child, limit: child)
                if walk.denied, walk.bytes == 0 {
                    partial = true
                    continue
                }
                counted = true
                total += walk.bytes
                partial = partial || walk.partial
                oldest = earliest(oldest, walk.oldest)
                children.append(MeasuredChild(
                    name: name,
                    bytes: walk.bytes,
                    modified: walk.oldest,
                    disposition: disposition(for: name, category: category, blockedApp: blockedApp, runningChildren: runningChildren)
                ))
            }
        }

        let access: AccessState
        if !counted && (denied || partial) {
            access = .denied
        } else if partial || (denied && counted) {
            access = .partial
        } else {
            access = .full
        }
        let bytes: Int64? = access == .denied ? nil : total
        let cleanableBytes = cleanableByteCount(
            methodIsCommand: category.method.isCommand,
            revealOnly: category.method.isRevealOnly,
            unrecognized: category.childFilter == .unrecognized,
            total: total,
            children: children
        )
        return ScanResult(
            bytes: bytes,
            cleanableBytes: cleanableBytes,
            access: access,
            children: Array(children.sorted { $0.bytes > $1.bytes }.prefix(6)),
            oldest: oldest,
            skippedSymlinks: skipped
        )
    }

    /// Bytes that can go away once a running app is closed. View-only rows, including unrecognized folders, stay out.
    static func cleanableByteCount(methodIsCommand: Bool, revealOnly: Bool, unrecognized: Bool, total: Int64, children: [MeasuredChild]) -> Int64 {
        if methodIsCommand { return total }
        if revealOnly || unrecognized { return 0 }
        return children.reduce(Int64(0)) { sum, child in
            switch child.disposition {
            case .cleanable, .blocked:
                return sum + child.bytes
            case .viewOnly:
                return sum
            }
        }
    }

    private static func disposition(for name: String, category: CacheCategory, blockedApp: String?, runningChildren: Set<String>) -> ChildDisposition {
        if let blockedApp { return .blocked(blockedApp) }
        if runningChildren.contains(name) { return .blocked(name) }
        switch category.childFilter {
        case .everything, .identifiedApplications, .namedFiles:
            return .cleanable
        case .unrecognized:
            return .viewOnly("Власника не визначено — лише перегляд")
        }
    }

    private static func displayName(_ root: URL) -> String {
        let parent = root.deletingLastPathComponent().lastPathComponent
        let name = root.lastPathComponent
        if parent == "Caches" || parent == "cache" || parent == "media_cache" || parent.isEmpty {
            return name
        }
        return "\(parent)/\(name)"
    }

    private struct Walk {
        var bytes: Int64
        var oldest: Date?
        var partial: Bool
        var denied: Bool
    }

    /// Symlinks are not followed and do not contribute size.
    static func walk(url: URL, limit: URL) -> (bytes: Int64, oldest: Date?, partial: Bool, denied: Bool) {
        let result = walkTree(url: url, limit: limit)
        return (result.bytes, result.oldest, result.partial, result.denied)
    }

    private static func walkTree(url: URL, limit: URL) -> Walk {
        let keys: Set<URLResourceKey> = [
            .isSymbolicLinkKey, .isDirectoryKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .contentModificationDateKey,
        ]
        guard let values = try? url.resourceValues(forKeys: keys) else {
            return Walk(bytes: 0, oldest: nil, partial: false, denied: true)
        }
        if values.isSymbolicLink == true {
            return Walk(bytes: 0, oldest: nil, partial: false, denied: false)
        }
        let limitPath = limit.resolvingSymlinksInPath().standardizedFileURL.path
        guard values.isDirectory == true else {
            return Walk(
                bytes: Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0),
                oldest: values.contentModificationDate,
                partial: false,
                denied: false
            )
        }

        var total: Int64 = 0
        var oldest = values.contentModificationDate
        var partial = false
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: Array(keys),
            options: [],
            errorHandler: { _, error in
                if isPermission(error) { partial = true }
                return true
            }
        ) else {
            return Walk(bytes: 0, oldest: oldest, partial: false, denied: true)
        }

        var counter = 0
        for case let fileURL as URL in enumerator {
            counter += 1
            if counter % 4096 == 0, Task.isCancelled { break }
            guard let fileValues = try? fileURL.resourceValues(forKeys: keys) else { continue }
            if fileValues.isSymbolicLink == true {
                enumerator.skipDescendants()
                continue
            }
            let resolved = fileURL.resolvingSymlinksInPath().standardizedFileURL.path
            if resolved != limitPath && !resolved.hasPrefix(limitPath + "/") {
                enumerator.skipDescendants()
                continue
            }
            oldest = earliest(oldest, fileValues.contentModificationDate)
            if fileValues.isDirectory == true { continue }
            total += Int64(fileValues.totalFileAllocatedSize ?? fileValues.fileAllocatedSize ?? 0)
        }
        return Walk(bytes: total, oldest: oldest, partial: partial, denied: false)
    }

    private static func earliest(_ lhs: Date?, _ rhs: Date?) -> Date? {
        switch (lhs, rhs) {
        case let (left?, right?): return min(left, right)
        case let (left?, nil): return left
        case let (nil, right?): return right
        case (nil, nil): return nil
        }
    }

    private static func isPermission(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain, nsError.code == NSFileReadNoPermissionError { return true }
        if nsError.domain == NSPOSIXErrorDomain, [Int(EPERM), Int(EACCES)].contains(nsError.code) { return true }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError,
           underlying.domain == NSPOSIXErrorDomain, [Int(EPERM), Int(EACCES)].contains(underlying.code) {
            return true
        }
        return false
    }
}
