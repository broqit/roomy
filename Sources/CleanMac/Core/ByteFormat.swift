import Foundation

/// Decimal (Finder-style) sizes. Units follow the selected language.
enum ByteFormat {
    private static var units: [String] {
        switch L10n.resolvedCode() {
        case "uk", "kk": return ["Б", "КБ", "МБ", "ГБ", "ТБ"]
        default: return ["B", "KB", "MB", "GB", "TB"]
        }
    }

    static func string(_ bytes: Int64) -> String {
        var value = Double(max(0, bytes))
        var unitIndex = 0
        let labels = units
        while value >= 1000, unitIndex < labels.count - 1 {
            value /= 1000
            unitIndex += 1
        }
        let formatter = NumberFormatter()
        formatter.locale = L10n.locale
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = (unitIndex >= 2 && value < 100) ? 1 : 0
        let number = formatter.string(from: NSNumber(value: value)) ?? "\(Int(value))"
        return "\(number) \(labels[unitIndex])"
    }
}

enum AgeHint {
    /// A hint only. Age never selects files for deletion.
    static func text(oldest: Date?, now: Date = Date()) -> String? {
        guard let oldest else { return nil }
        let days = Int(now.timeIntervalSince(oldest) / 86_400)
        guard days >= 14 else { return nil }
        if days < 60 { return L10n.f("age.days", days) }
        return L10n.f("age.months", max(2, days / 30))
    }
}
