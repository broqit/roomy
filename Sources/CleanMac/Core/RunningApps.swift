import AppKit
import Darwin
import Foundation

enum ProcessIdentity {
    static func uid(of pid: pid_t) -> uid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        let count = u_int(mib.count)
        guard sysctl(&mib, count, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info.kp_eproc.e_ucred.cr_uid
    }
}

enum ProcessOwnership {
    /// This user's process, and not Roomy itself.
    case ours
    /// Another account, or this process.
    case notOurs
    /// The uid could not be read. Treat as running, but never terminate it.
    case unknown
}

struct RunningMatch: Equatable {
    var bundleID: String
    var name: String
}

enum RunningApps {
    /// A match counts only for this user's processes. An unreadable uid still counts as running, so another account is never treated as idle.
    static func firstRunning(of apps: [BlockingApp], uid: uid_t) -> BlockingApp? {
        matches(of: apps, uid: uid).first.map { BlockingApp(bundleID: $0.bundleID, name: $0.name) }
    }

    static func isRunning(bundleID: String, uid: uid_t) -> Bool {
        firstRunning(of: [BlockingApp(bundleID: bundleID, name: bundleID)], uid: uid) != nil
    }

    static func matches(of apps: [BlockingApp], uid: uid_t) -> [RunningMatch] {
        var seen = Set<String>()
        var results: [RunningMatch] = []
        for app in apps {
            let processes = NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID)
            for process in processes {
                switch ownership(of: process, uid: uid) {
                case .notOurs:
                    continue
                case .ours, .unknown:
                    guard seen.insert(app.bundleID).inserted else { continue }
                    let name = process.localizedName ?? app.name
                    results.append(RunningMatch(bundleID: app.bundleID, name: name))
                }
            }
        }
        return results
    }

    static func ownership(of process: NSRunningApplication, uid: uid_t) -> ProcessOwnership {
        if process.processIdentifier == getpid() { return .notOurs }
        if let own = Bundle.main.bundleIdentifier, process.bundleIdentifier == own { return .notOurs }
        guard let processUID = ProcessIdentity.uid(of: process.processIdentifier) else { return .unknown }
        return processUID == uid ? .ours : .notOurs
    }
}

struct QuitAttempt: Equatable {
    /// Bundle ids that are still running, or whose owner could not be confirmed.
    var failedBundleIDs: [String]
    var terminatedAny: Bool
}

enum AppQuitter {
    /// Asks each of this user's apps to quit, then force-quits any that are still running.
    /// Processes with an unreadable uid are left alone and reported as failed.
    static func quit(bundleIDs: [String], uid: uid_t) async -> QuitAttempt {
        let ownBundle = Bundle.main.bundleIdentifier
        let ids = Array(Set(bundleIDs)).filter { $0 != ownBundle }
        let (targets, unknown) = await MainActor.run { () -> ([NSRunningApplication], [String]) in
            var targets: [NSRunningApplication] = []
            var unknown: [String] = []
            var seenPID = Set<pid_t>()
            for bundleID in ids {
                for process in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID) {
                    switch RunningApps.ownership(of: process, uid: uid) {
                    case .notOurs:
                        continue
                    case .unknown:
                        unknown.append(bundleID)
                    case .ours:
                        if seenPID.insert(process.processIdentifier).inserted {
                            targets.append(process)
                        }
                    }
                }
            }
            for process in targets {
                process.terminate()
            }
            return (targets, unknown)
        }
        await waitUntilGone(targets, seconds: 3)
        let stubborn = await MainActor.run { targets.filter { !$0.isTerminated } }
        if !stubborn.isEmpty {
            await MainActor.run {
                for process in stubborn {
                    process.forceTerminate()
                }
            }
            await waitUntilGone(stubborn, seconds: 2)
        }
        let (still, terminatedAny) = await MainActor.run { () -> ([String], Bool) in
            let still = targets.compactMap { process -> String? in
                process.isTerminated ? nil : process.bundleIdentifier
            }
            return (still, targets.contains { $0.isTerminated })
        }
        return QuitAttempt(failedBundleIDs: Array(Set(unknown + still)), terminatedAny: terminatedAny)
    }

    private static func waitUntilGone(_ apps: [NSRunningApplication], seconds: Double) async {
        let steps = Int(seconds / 0.2)
        for _ in 0..<max(steps, 1) {
            let done = await MainActor.run { apps.allSatisfy(\.isTerminated) }
            if done { return }
            try? await Task.sleep(for: .milliseconds(200))
        }
    }
}

enum InstalledApps {
    static func isInstalled(bundleID: String) -> Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
    }
}
