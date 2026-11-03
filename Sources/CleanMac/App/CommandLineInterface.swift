import Foundation

/// Headless mode: `Roomy --scan` lists categories; `Roomy --clean <id> --yes` cleans one.
enum CommandLineInterface {
    static func handles(_ arguments: [String]) -> Bool {
        arguments.contains("--scan") || arguments.contains("--clean")
    }

    static func run(_ arguments: [String]) async -> Int32 {
        let environment = UserEnvironment.current()
        let categories = await CategoryCatalog.detect(environment: environment)
        if let status = VolumeReader.read() {
            let pressure = PressureThresholds.default.pressure(freeBytes: status.freeBytes, previous: .normal)
            print("disk\t\(ByteFormat.string(status.freeBytes))\t\(pressure.title)")
        }

        if let flagIndex = arguments.firstIndex(of: "--clean") {
            guard arguments.indices.contains(flagIndex + 1),
                  let category = categories.first(where: { $0.id == arguments[flagIndex + 1] }) else {
                print("Unknown category. Available: \(categories.map(\.id).joined(separator: ", "))")
                return 2
            }
            guard arguments.contains("--yes") else {
                print("Refusing to clean \(category.name) without --yes")
                return 2
            }
            if category.method.isRevealOnly || category.toolProblem != nil {
                print("\(category.id)\trefused\t\(category.toolProblem ?? "view only")")
                return 2
            }
            if let app = RunningApps.firstRunning(of: category.blockingApps, uid: environment.uid) {
                print("\(category.id)\trefused\t\(app.name) running")
                return 2
            }
            let outcome = await CacheCleaner.clean(category, environment: environment)
            if let failure = outcome.failure {
                print("\(category.id)\terror: \(failure)")
                return 1
            }
            let report = CleanReport(
                trashedBytes: outcome.trashedBytes,
                cacheReductionBytes: outcome.cacheReduction,
                irreversible: outcome.irreversible,
                freeBefore: 0,
                freeAfter: 0,
                failures: [],
                skipped: outcome.skipped,
                categoryNames: [category.name]
            )
            print("\(category.id)\t\(ResultCopy.toast(report))\tremaining \(ByteFormat.string(outcome.after.bytes ?? 0))")
            return 0
        }

        var known: Int64 = 0
        var incomplete = false
        await withTaskGroup(of: (CacheCategory, ScanResult).self) { group in
            for category in categories {
                group.addTask { (category, await CacheScanner.scan(category, environment: environment)) }
            }
            var results: [String: ScanResult] = [:]
            for await (category, result) in group {
                results[category.id] = result
            }
            for category in categories {
                guard let result = results[category.id] else { continue }
                if let bytes = result.bytes { known += bytes } else { incomplete = true }
                if result.access != .full { incomplete = true }
                let running = RunningApps.firstRunning(of: category.blockingApps, uid: environment.uid).map { " [\($0.name) running]" } ?? ""
                let access: String
                switch result.access {
                case .full: access = ""
                case .partial: access = " [partial]"
                case .denied: access = " [no access]"
                case .unknown: access = " [not scanned]"
                }
                let amount = result.bytes.map(ByteFormat.string) ?? "unavailable"
                let view = category.method.isRevealOnly ? " [view only]" : ""
                print("\(category.id)\t\(amount)\t\(category.name)\(running)\(access)\(view)\t\(category.method.userDescription)")
                for root in category.roots {
                    print("\t\(root.path)")
                }
                if let problem = category.toolProblem {
                    print("\tproblem: \(problem)")
                }
            }
        }
        print("known\t\(ByteFormat.string(known))\(incomplete ? "\tincomplete" : "")")
        return 0
    }
}
