import Foundation

struct CleanReport: Equatable {
    var trashedBytes: Int64
    var cacheReductionBytes: Int64
    var irreversible: Bool
    var freeBefore: Int64
    var freeAfter: Int64
    var failures: [String]
    var skipped: [String]
    var categoryNames: [String]

    var freeDelta: Int64 { freeAfter - freeBefore }
}

enum ResultCopy {
    static func toast(_ report: CleanReport) -> String {
        if report.cacheReductionBytes <= 0, report.trashedBytes <= 0 {
            if !report.failures.isEmpty { return L10n.t("result.failed") }
            return L10n.t("result.unchanged")
        }
        if report.trashedBytes > 0, !report.irreversible {
            return L10n.f("result.trashed", ByteFormat.string(report.trashedBytes))
        }
        if report.irreversible, report.trashedBytes == 0 {
            return L10n.f("result.shrunk", ByteFormat.string(max(0, report.cacheReductionBytes)))
        }
        return L10n.f("result.both", ByteFormat.string(max(0, report.cacheReductionBytes)), ByteFormat.string(report.trashedBytes))
    }

    static func details(_ report: CleanReport) -> String {
        var lines: [String] = [toast(report)]
        lines.append(L10n.f("result.free", ByteFormat.string(report.freeBefore), ByteFormat.string(report.freeAfter)))
        if report.trashedBytes > 0, report.freeDelta + 50_000_000 < report.trashedBytes {
            lines.append(L10n.t("result.trashNote"))
        }
        if report.irreversible {
            lines.append(L10n.t("result.commandNote"))
        }
        if !report.skipped.isEmpty {
            lines.append(L10n.f("result.skipped", report.skipped.joined(separator: "; ")))
        }
        if !report.failures.isEmpty {
            lines.append(report.failures.joined(separator: "\n"))
        }
        return lines.joined(separator: "\n")
    }
}
