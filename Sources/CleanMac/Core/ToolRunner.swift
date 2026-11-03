import Foundation

enum ToolLocator {
    static func searchDirectories(home: URL) -> [URL] {
        var directories = [
            URL(fileURLWithPath: "/opt/homebrew/bin", isDirectory: true),
            URL(fileURLWithPath: "/usr/local/bin", isDirectory: true),
            home.appendingPathComponent(".bun/bin", isDirectory: true),
            home.appendingPathComponent(".local/bin", isDirectory: true),
            home.appendingPathComponent(".volta/bin", isDirectory: true),
        ]
        directories += nodeVersionBins(home: home)
        directories += [
            URL(fileURLWithPath: "/usr/bin", isDirectory: true),
            URL(fileURLWithPath: "/bin", isDirectory: true),
        ]
        return directories
    }

    static func find(_ name: String, home: URL) -> URL? {
        findAll(name, home: home).first
    }

    static func findAll(_ name: String, home: URL) -> [URL] {
        var found: [URL] = []
        var seen = Set<String>()
        for directory in searchDirectories(home: home) {
            let candidate = directory.appendingPathComponent(name)
            guard FileManager.default.isExecutableFile(atPath: candidate.path) else { continue }
            let key = candidate.resolvingSymlinksInPath().standardizedFileURL.path
            guard seen.insert(key).inserted else { continue }
            found.append(candidate)
        }
        return found
    }

    static func pnpmShim(home: URL) -> URL? {
        let shim = home.appendingPathComponent("Library/pnpm/pnpm")
        guard FileManager.default.isExecutableFile(atPath: shim.path) else { return nil }
        return shim
    }

    private static func nodeVersionBins(home: URL) -> [URL] {
        let versionsDirectory = home.appendingPathComponent(".nvm/versions/node", isDirectory: true)
        let versions = (try? FileManager.default.contentsOfDirectory(atPath: versionsDirectory.path)) ?? []
        return versions
            .sorted { $0.compare($1, options: .numeric) == .orderedDescending }
            .map { versionsDirectory.appendingPathComponent($0).appendingPathComponent("bin", isDirectory: true) }
    }
}

struct ToolResult: Equatable {
    var exitCode: Int32
    var output: String
    var timedOut: Bool
}

enum ToolRunner {
    static func environment(home: URL, tool: URL) -> [String: String] {
        let path = ([tool.deletingLastPathComponent()] + ToolLocator.searchDirectories(home: home))
            .map(\.path)
            .joined(separator: ":")
        let language = Locale.preferredLanguages.first?.replacingOccurrences(of: "-", with: "_") ?? "uk_UA.UTF-8"
        return [
            "PATH": path,
            "HOME": home.path,
            "USER": NSUserName(),
            "LOGNAME": NSUserName(),
            "TMPDIR": NSTemporaryDirectory(),
            "LANG": language,
            "HOMEBREW_NO_AUTO_UPDATE": "1",
            "HOMEBREW_NO_ENV_HINTS": "1",
            "NO_COLOR": "1",
            "npm_config_fund": "false",
            "npm_config_audit": "false",
            "npm_config_update_notifier": "false",
        ]
    }

    static func run(_ tool: URL, _ arguments: [String], home: URL, timeout: TimeInterval) -> ToolResult {
        let process = Process()
        process.executableURL = tool
        process.arguments = arguments
        process.environment = environment(home: home, tool: tool)
        process.currentDirectoryURL = home
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
        } catch {
            return ToolResult(exitCode: 127, output: "Не вдалося запустити \(tool.lastPathComponent)", timedOut: false)
        }

        let group = DispatchGroup()
        group.enter()
        process.terminationHandler = { _ in group.leave() }
        let wait = group.wait(timeout: .now() + timeout)
        var timedOut = false
        if wait == .timedOut {
            timedOut = true
            process.terminate()
            if group.wait(timeout: .now() + 2) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                group.wait()
            }
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let raw = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let clipped = raw.count > 2000 ? String(raw.suffix(2000)) : raw
        return ToolResult(exitCode: process.terminationStatus, output: clipped, timedOut: timedOut)
    }
}
