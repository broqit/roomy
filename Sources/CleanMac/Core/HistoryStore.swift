import Foundation

struct HistoryEntry: Codable, Equatable, Identifiable {
    var id: UUID
    var date: Date
    var categoryIDs: [String]
    var categoryNames: [String]
    var action: String
    var cacheReductionBytes: Int64
    var trashedBytes: Int64
    var irreversible: Bool
    var freeBefore: Int64
    var freeAfter: Int64
    var failures: [String]
    var skipped: [String]
}

@MainActor
final class HistoryStore: ObservableObject {
    static let shared = HistoryStore()

    @Published private(set) var entries: [HistoryEntry] = []
    private let fileURL: URL
    private let limit = 80

    init(fileURL: URL? = nil) {
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/CleanMac", isDirectory: true)
        self.fileURL = fileURL ?? directory.appendingPathComponent("history.json")
        load()
    }

    func append(_ entry: HistoryEntry) {
        entries.insert(entry, at: 0)
        if entries.count > limit {
            entries.removeLast(entries.count - limit)
        }
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([HistoryEntry].self, from: data) else { return }
        entries = decoded
    }

    private func save() {
        let directory = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
