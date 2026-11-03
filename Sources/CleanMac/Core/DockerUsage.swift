import Foundation

/// Parses `docker system df`. Sizes are decimal, matching Docker's own GB/MB labels.
enum DockerUsage {
    struct Row: Equatable {
        var name: String
        var bytes: Int64
        var reclaimable: Int64
    }

    static func parse(_ output: String) -> [Row] {
        let labels = [
            ("Build Cache", "Кеш збірки"),
            ("Local Volumes", "Томи"),
            ("Images", "Образи"),
            ("Containers", "Контейнери"),
        ]
        var rows: [Row] = []
        for raw in output.split(whereSeparator: \.isNewline) {
            let line = String(raw).trimmingCharacters(in: .whitespaces)
            guard let label = labels.first(where: { line.hasPrefix($0.0) }) else { continue }
            let rest = line.dropFirst(label.0.count)
            let sizes = rest.split(whereSeparator: \.isWhitespace).compactMap { parseSize(String($0)) }
            guard let used = sizes.first else { continue }
            rows.append(Row(name: label.1, bytes: used, reclaimable: sizes.dropFirst().first ?? 0))
        }
        return rows
    }

    private static func localizedRow(_ name: String) -> String {
        switch name {
        case "Образи": return L10n.t("docker.images")
        case "Контейнери": return L10n.t("docker.containers")
        case "Томи": return L10n.t("docker.volumes")
        case "Кеш збірки": return L10n.t("docker.buildCache")
        default: return name
        }
    }

    /// What `docker builder prune` can drop: the reclaimable build cache, not images or volumes.
    static func buildCacheReclaimable(in rows: [Row]) -> Int64 {
        rows.first { $0.name == "Кеш збірки" }?.reclaimable ?? 0
    }

    static func parseSize(_ token: String) -> Int64? {
        let trimmed = token.trimmingCharacters(in: .whitespaces)
        guard let match = trimmed.range(of: #"^([0-9]*\.?[0-9]+)([KMGT]?i?B)$"#, options: .regularExpression) else { return nil }
        let body = String(trimmed[match])
        let split = body.firstIndex(where: { $0.isLetter }) ?? body.endIndex
        guard let value = Double(body[..<split]) else { return nil }
        let unit = body[split...].uppercased()
        let binary = unit.contains("I")
        let base: Double = binary ? 1024 : 1000
        let power: Double
        switch unit {
        case "B": power = 0
        case "KB", "KIB": power = 1
        case "MB", "MIB": power = 2
        case "GB", "GIB": power = 3
        case "TB", "TIB": power = 4
        default: return nil
        }
        return Int64((value * pow(base, power)).rounded())
    }

    static func measure(home: URL) -> ScanResult {
        guard let docker = ToolLocator.find("docker", home: home) else {
            return ScanResult(
                bytes: nil, cleanableBytes: 0, access: .unknown, children: [], oldest: nil, skippedSymlinks: 0,
                note: L10n.t("docker.note.missing")
            )
        }
        let result = ToolRunner.run(docker, ["system", "df"], home: home, timeout: 25)
        if result.timedOut {
            return ScanResult(
                bytes: nil, cleanableBytes: 0, access: .unknown, children: [], oldest: nil, skippedSymlinks: 0,
                note: L10n.t("docker.note.timeout")
            )
        }
        let rows = parse(result.output)
        guard result.exitCode == 0, !rows.isEmpty else {
            return ScanResult(
                bytes: nil, cleanableBytes: 0, access: .unknown, children: [], oldest: nil, skippedSymlinks: 0,
                note: L10n.t("docker.note.down")
            )
        }
        let cache = buildCacheReclaimable(in: rows)
        let children = rows.map { row in
            let disposition: ChildDisposition = row.name == "Кеш збірки" && row.reclaimable > 0
                ? .cleanable
                : .viewOnly(L10n.t("docker.view"))
            return MeasuredChild(name: localizedRow(row.name), bytes: row.bytes, modified: nil, disposition: disposition)
        }
        return ScanResult(
            bytes: rows.reduce(0) { $0 + $1.bytes },
            cleanableBytes: cache,
            access: .full,
            children: children,
            oldest: nil,
            skippedSymlinks: 0,
            note: cache > 0
                ? L10n.f("docker.note.cache", ByteFormat.string(cache))
                : L10n.t("docker.note.empty")
        )
    }
}
