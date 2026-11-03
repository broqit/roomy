import Foundation

enum SuggestionAction: Equatable {
    case reviewLargest
    case reviewCategory(String)
    case refresh
    case openStorageSettings
    case explainPermission
    case explainCloseApp(String)
}

struct Suggestion: Equatable, Identifiable {
    var id: String
    var title: String
    var detail: String
    var action: SuggestionAction
}

struct SuggestionItem: Equatable {
    var id: String
    var name: String
    var bytes: Int64?
    var accessDenied: Bool
    var partial: Bool
    var blockedApp: String?
    var toolProblem: String?
    var recommend: Bool
    var viewOnly: Bool
}

struct SuggestionInput: Equatable {
    var pressure: DiskPressure
    var freeBytes: Int64
    var items: [SuggestionItem]
    var scanDate: Date?
    var now: Date
    var lastReport: CleanReport?
    var staleAfter: TimeInterval = 600
}

enum SuggestionEngine {
    static func make(_ input: SuggestionInput) -> [Suggestion] {
        var results: [Suggestion] = []
        func append(_ suggestion: Suggestion) {
            guard results.count < 3, !results.contains(where: { $0.id == suggestion.id }) else { return }
            results.append(suggestion)
        }

        let known = input.items.reduce(Int64(0)) { $0 + ($1.bytes ?? 0) }
        let recommended = input.items.filter(\.recommend).compactMap(\.bytes).reduce(0, +)
        let stale = input.scanDate.map { input.now.timeIntervalSince($0) > input.staleAfter } ?? true
        let staleNote = stale ? L10n.t("suggestion.stale") : ""

        if let problem = input.items.compactMap(\.toolProblem).first {
            append(Suggestion(
                id: "tool",
                title: L10n.t("suggestion.tool.title"),
                detail: problem,
                action: .refresh
            ))
        }

        if input.items.contains(where: \.accessDenied) {
            append(Suggestion(
                id: "access",
                title: L10n.t("suggestion.access.title"),
                detail: L10n.t("suggestion.access.detail"),
                action: .explainPermission
            ))
        }

        if let blockedItem = input.items.first(where: { $0.blockedApp != nil }), let blocked = blockedItem.blockedApp {
            append(Suggestion(
                id: "blocked-\(blocked)",
                title: L10n.f("suggestion.blocked.title", blocked),
                detail: L10n.f("suggestion.blocked.detail", blocked),
                action: .reviewCategory(blockedItem.id)
            ))
        }

        if let report = input.lastReport {
            let expected = max(report.trashedBytes, report.cacheReductionBytes)
            if expected >= 200_000_000, report.freeDelta + 50_000_000 < expected / 5 {
            append(Suggestion(
                id: "shortfall",
                title: L10n.t("suggestion.shortfall.title"),
                detail: ResultCopy.details(report),
                action: report.trashedBytes > 0 ? .reviewCategory("trash") : .openStorageSettings
            ))
            }
        }

        if input.pressure >= .low {
            if recommended < 1_000_000_000 {
                append(Suggestion(
                    id: "not-enough",
                    title: input.pressure.title,
                    detail: L10n.f("suggestion.lowCaches", ByteFormat.string(input.freeBytes), ByteFormat.string(known), staleNote),
                    action: .openStorageSettings
                ))
            } else if let largest = input.items.filter(\.recommend).max(by: { ($0.bytes ?? 0) < ($1.bytes ?? 0) }),
                      let bytes = largest.bytes, bytes > 0 {
                append(Suggestion(
                    id: "pressure-largest",
                    title: input.pressure.title,
                    detail: L10n.f("suggestion.largest", ByteFormat.string(input.freeBytes), largest.name, ByteFormat.string(bytes), staleNote),
                    action: .reviewCategory(largest.id)
                ))
            } else {
                append(Suggestion(
                    id: "pressure-review",
                    title: input.pressure.title,
                    detail: L10n.f("suggestion.review", ByteFormat.string(input.freeBytes), ByteFormat.string(known), staleNote),
                    action: .reviewLargest
                ))
            }
        } else if let largest = input.items.filter({ $0.recommend && ($0.bytes ?? 0) >= 1_000_000_000 }).max(by: { ($0.bytes ?? 0) < ($1.bytes ?? 0) }),
                  let bytes = largest.bytes {
            append(Suggestion(
                id: "large-dev",
                title: L10n.t("suggestion.large.title"),
                detail: L10n.f("suggestion.large.detail", largest.name, ByteFormat.string(bytes), staleNote),
                action: .reviewCategory(largest.id)
            ))
        }

        return results
    }
}
