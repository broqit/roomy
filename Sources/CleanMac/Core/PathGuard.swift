import Foundation

enum PathRejection: Equatable {
    case outsideHome
    case symlink
    case notDirectory
    case notDirectChild
    case missing
    case ambiguous
}

enum PathVerdict: Equatable {
    case allowed(URL)
    case rejected(PathRejection)
}

struct DirectoryListing: Equatable {
    var root: URL?
    var children: [URL]
    var skippedSymlinks: Int
    var accessDenied: Bool
    var rejection: PathRejection?
}

/// Allows only real (non-symlink) items inside one user's resolved home directory.
struct PathGuard {
    let home: URL
    private let fileManager = FileManager.default

    init(home: URL) {
        self.home = home.resolvingSymlinksInPath().standardizedFileURL
    }

    func vetDirectory(_ url: URL) -> PathVerdict {
        guard fileManager.fileExists(atPath: url.path) else { return .rejected(.missing) }
        if isSymlink(url) { return .rejected(.symlink) }
        let resolved = resolve(url)
        guard isInsideHome(resolved) else { return .rejected(.outsideHome) }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: resolved.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return .rejected(.notDirectory)
        }
        guard ancestorsStayInsideHome(resolved) else { return .rejected(.symlink) }
        return .allowed(resolved)
    }

    func listChildren(of root: URL) -> DirectoryListing {
        guard case let .allowed(resolvedRoot) = vetDirectory(root) else {
            let rejection: PathRejection
            if case let .rejected(reason) = vetDirectory(root) {
                rejection = reason
            } else {
                rejection = .ambiguous
            }
            let denied = rejection == .missing ? false : isPermissionDenied(root)
            return DirectoryListing(root: nil, children: [], skippedSymlinks: 0, accessDenied: denied || rejection == .outsideHome, rejection: rejection)
        }

        let names: [String]
        do {
            names = try fileManager.contentsOfDirectory(atPath: resolvedRoot.path)
        } catch {
            return DirectoryListing(root: resolvedRoot, children: [], skippedSymlinks: 0, accessDenied: isPermissionError(error), rejection: nil)
        }

        var children: [URL] = []
        var skipped = 0
        for name in names.sorted() {
            guard isSafeName(name) else {
                skipped += 1
                continue
            }
            let child = resolvedRoot.appendingPathComponent(name)
            if isSymlink(child) {
                skipped += 1
                continue
            }
            let resolvedChild = resolve(child)
            guard resolvedChild.deletingLastPathComponent().path == resolvedRoot.path else {
                skipped += 1
                continue
            }
            guard isInsideHome(resolvedChild) else {
                skipped += 1
                continue
            }
            guard ancestorsStayInsideHome(resolvedChild) else {
                skipped += 1
                continue
            }
            children.append(resolvedChild)
        }
        return DirectoryListing(root: resolvedRoot, children: children, skippedSymlinks: skipped, accessDenied: false, rejection: nil)
    }

    /// A regular file that is a direct child of this user's home. Used for IDE crash dumps, never for a directory.
    func vetHomeFile(_ url: URL, nameAllowed: (String) -> Bool) -> PathVerdict {
        let name = url.lastPathComponent
        guard nameAllowed(name) else { return .rejected(.ambiguous) }
        guard fileManager.fileExists(atPath: url.path) else { return .rejected(.missing) }
        if isSymlink(url) { return .rejected(.symlink) }
        let resolved = resolve(url)
        guard resolved.deletingLastPathComponent().path == home.path else { return .rejected(.notDirectChild) }
        guard isInsideHome(resolved), ancestorsStayInsideHome(resolved) else { return .rejected(.symlink) }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: resolved.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            return .rejected(.notDirectory)
        }
        return .allowed(resolved)
    }

    /// Call immediately before trash or before trusting a command root. `expected` is the path from the last listing.
    func revalidate(_ url: URL, asChildOf root: URL, expected: URL) -> PathVerdict {
        guard case let .allowed(resolvedRoot) = vetDirectory(root) else { return .rejected(.ambiguous) }
        if isSymlink(url) { return .rejected(.symlink) }
        let resolved = resolve(url)
        guard resolved.path == expected.resolvingSymlinksInPath().standardizedFileURL.path else { return .rejected(.ambiguous) }
        guard resolved.deletingLastPathComponent().path == resolvedRoot.path else { return .rejected(.notDirectChild) }
        guard isInsideHome(resolved), ancestorsStayInsideHome(resolved) else { return .rejected(.symlink) }
        return .allowed(resolved)
    }

    func isInsideHome(_ url: URL) -> Bool {
        let path = resolve(url).path
        return path == home.path || path.hasPrefix(home.path + "/")
    }

    func ownerUID(_ url: URL) -> uid_t? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return nil }
        return info.st_uid
    }

    private func resolve(_ url: URL) -> URL {
        url.resolvingSymlinksInPath().standardizedFileURL
    }

    private func isSafeName(_ name: String) -> Bool {
        name != "." && name != ".." && !name.contains("/") && !name.contains("\0") && name != ".localized"
    }

    private func isSymlink(_ url: URL) -> Bool {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return false }
        return (info.st_mode & S_IFMT) == S_IFLNK
    }

    private func ancestorsStayInsideHome(_ resolved: URL) -> Bool {
        var cursor = resolved.standardizedFileURL
        while cursor.path != home.path {
            let parent = cursor.deletingLastPathComponent()
            if parent.path == cursor.path { return false }
            if !isInsideHome(parent) && parent.path != home.path { return false }
            if fileManager.fileExists(atPath: parent.path), isSymlink(parent) { return false }
            let parentResolved = resolve(parent)
            if parentResolved.path != home.path && !parentResolved.path.hasPrefix(home.path + "/") && parent.path != home.path {
                return false
            }
            cursor = parent
        }
        return true
    }

    private func isPermissionDenied(_ url: URL) -> Bool {
        do {
            _ = try fileManager.contentsOfDirectory(atPath: url.path)
            return false
        } catch {
            return isPermissionError(error)
        }
    }

    private func isPermissionError(_ error: Error) -> Bool {
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
