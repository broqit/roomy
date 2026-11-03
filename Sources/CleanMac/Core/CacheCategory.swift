import Foundation

enum CleanMethod: Hashable {
    case command(executable: URL, arguments: [String], display: String, scope: URL)
    case trashContents
    case revealOnly

    var isCommand: Bool {
        if case .command = self { return true }
        return false
    }

    var isRevealOnly: Bool {
        if case .revealOnly = self { return true }
        return false
    }

    var scope: URL? {
        if case let .command(_, _, _, scope) = self { return scope }
        return nil
    }

    var userDescription: String {
        switch self {
        case let .command(_, _, display, _):
            return L10n.f("method.command", display)
        case .trashContents:
            return L10n.t("method.trash")
        case .revealOnly:
            return L10n.t("method.view")
        }
    }
}

enum ChildFilter: Hashable {
    case everything
    case identifiedApplications
    case unrecognized
    /// Each root is one file in the home directory, not a folder whose children can be deleted.
    case namedFiles
}

struct BlockingApp: Hashable {
    var bundleID: String
    var name: String
}

enum UsageProbe: Hashable {
    /// Read `docker system df`. Cleaning, when offered, is only `docker builder prune`.
    case dockerSystemDF
    /// Xcode simulator runtimes or Android system images. Each image is deleted on its own.
    case deviceImages
}

enum CategoryGroup: String, Hashable, CaseIterable {
    case ai
    case development
    case messengers
    case browsers
    case system

    var title: String {
        switch self {
        case .ai: return L10n.t("group.ai")
        case .development: return L10n.t("group.development")
        case .messengers: return L10n.t("group.messengers")
        case .browsers: return L10n.t("group.browsers")
        case .system: return L10n.t("group.system")
        }
    }

    var order: Int {
        switch self {
        case .ai: return 0
        case .development: return 1
        case .messengers: return 2
        case .browsers: return 3
        case .system: return 4
        }
    }
}

struct CacheCategory: Identifiable, Hashable {
    var id: String
    var name: String
    var symbol: String
    var roots: [URL]
    var method: CleanMethod
    var group: CategoryGroup = .system
    var usageProbe: UsageProbe? = nil
    var childFilter: ChildFilter = .everything
    var excludedChildNames: Set<String> = []
    var blockingApps: [BlockingApp] = []
    /// When set, a direct child whose name is a bundle id is skipped while that app runs.
    var blocksMatchingBundleChildren = false
    var note: String?
    var consequences: String
    var includeInRecommendations: Bool
    var toolProblem: String?

    func isExcluded(childName: String) -> Bool {
        excludedChildNames.contains(childName)
    }

    func grouped(_ group: CategoryGroup) -> CacheCategory {
        var copy = self
        copy.group = group
        return copy
    }
}
