import AppKit
import Combine
import Foundation
import ServiceManagement
import SwiftUI
import UserNotifications

enum AppAppearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return L10n.t("appearance.system")
        case .light: return L10n.t("appearance.light")
        case .dark: return L10n.t("appearance.dark")
        }
    }
}

@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    @AppStorage("showMenuBarIcon") var showMenuBarIcon = true { didSet { publishChange() } }
    @AppStorage("notchPanelEnabled") var notchPanelEnabled = true { didSet { publishChange() } }
    @AppStorage("showNotchIndicator") var showNotchIndicator = true { didSet { publishChange() } }
    @AppStorage("appearance") var appearanceRaw = AppAppearance.system.rawValue { didSet { publishChange() } }
    @AppStorage("language") var languageRaw = AppLanguage.system.rawValue {
        didSet {
            L10n.setPreference(languageRaw)
            publishChange()
        }
    }
    @AppStorage("showCPUMeter") var showCPUMeter = true { didSet { publishChange() } }
    @AppStorage("showMemoryMeter") var showMemoryMeter = true { didSet { publishChange() } }
    @AppStorage("showGPUMeter") var showGPUMeter = true { didSet { publishChange() } }
    @AppStorage("showDiskMeter") var showDiskMeter = true { didSet { publishChange() } }
    @AppStorage("notificationsEnabled") var notificationsEnabled = false { didSet { publishChange() } }
    @AppStorage("pressureLowBytes") var pressureLowBytes = 20_000_000_000 { didSet { publishChange() } }
    @AppStorage("pressureCriticalBytes") var pressureCriticalBytes = 10_000_000_000 { didSet { publishChange() } }
    @AppStorage("pressureUrgentBytes") var pressureUrgentBytes = 5_000_000_000 { didSet { publishChange() } }
    @AppStorage("pressureHysteresisBytes") var pressureHysteresisBytes = 1_000_000_000 { didSet { publishChange() } }
    @AppStorage("notificationSnoozeUntil") var notificationSnoozeUntilStamp = 0.0 { didSet { publishChange() } }
    @AppStorage("excludedSuggestions") private var excludedSuggestionsRaw = "[]" { didSet { publishChange() } }

    /// Deferred so a defaults write during a SwiftUI update does not publish in the middle of that update.
    private func publishChange() {
        Task { @MainActor in
            objectWillChange.send()
        }
    }

    @Published private(set) var launchAtLoginStatus: SMAppService.Status = SMAppService.mainApp.status
    @Published var launchAtLoginError: String?
    @Published var notificationError: String?

    var appearance: AppAppearance {
        get { AppAppearance(rawValue: appearanceRaw) ?? .system }
        set { appearanceRaw = newValue.rawValue }
    }

    var language: AppLanguage {
        get { AppLanguage(rawValue: languageRaw) ?? .system }
        set {
            guard newValue.rawValue != languageRaw else { return }
            languageRaw = newValue.rawValue
            CacheStore.shared.refresh()
        }
    }

    var detectedLanguageName: String {
        switch L10n.resolvedCode() {
        case "uk": return "Українська"
        case "es": return "Español"
        case "de": return "Deutsch"
        case "kk": return "Қазақша"
        default: return "English"
        }
    }

    var launchAtLogin: Bool {
        launchAtLoginStatus == .enabled || launchAtLoginStatus == .requiresApproval
    }

    var notificationSnoozeUntil: Date? {
        notificationSnoozeUntilStamp > 0 ? Date(timeIntervalSince1970: notificationSnoozeUntilStamp) : nil
    }

    var pressureThresholds: PressureThresholds {
        PressureThresholds(
            lowBytes: Int64(pressureLowBytes),
            criticalBytes: Int64(pressureCriticalBytes),
            urgentBytes: Int64(pressureUrgentBytes),
            hysteresisBytes: Int64(pressureHysteresisBytes)
        ).normalized()
    }

    var excludedSuggestions: Set<String> {
        Set((try? JSONDecoder().decode([String].self, from: Data(excludedSuggestionsRaw.utf8))) ?? [])
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        launchAtLoginError = nil
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            launchAtLoginError = error.localizedDescription
        }
        launchAtLoginStatus = SMAppService.mainApp.status
    }

    func refreshLaunchAtLoginStatus() {
        launchAtLoginStatus = SMAppService.mainApp.status
    }

    func setExcluded(_ id: String, excluded: Bool) {
        var values = excludedSuggestions
        if excluded { values.insert(id) } else { values.remove(id) }
        excludedSuggestionsRaw = String(data: (try? JSONEncoder().encode(Array(values).sorted())) ?? Data(), encoding: .utf8) ?? "[]"
    }

    func setNotificationsEnabled(_ enabled: Bool) {
        notificationError = nil
        guard enabled else {
            notificationsEnabled = false
            return
        }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { [weak self] granted, error in
            Task { @MainActor in
                if let error {
                    self?.notificationError = error.localizedDescription
                    self?.notificationsEnabled = false
                    return
                }
                self?.notificationsEnabled = granted
                if !granted {
                    self?.notificationError = L10n.t("notify.denied")
                } else {
                    NotificationCoordinator.shared.rememberCurrentPressure()
                }
            }
        }
    }

    func snoozeNotifications(hours: Double = 24) {
        notificationSnoozeUntilStamp = Date().addingTimeInterval(hours * 3600).timeIntervalSince1970
    }

    func clearSnooze() {
        notificationSnoozeUntilStamp = 0
    }

    func postPressureNotification(pressure: DiskPressure, freeBytes: Int64) {
        let content = UNMutableNotificationContent()
        content.title = pressure.title
        content.body = L10n.f("notify.body", ByteFormat.string(freeBytes))
        content.sound = nil
        let request = UNNotificationRequest(identifier: "cleanmac.pressure", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    func openFullDiskAccessSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }

    func openStorageSettings() {
        let candidates = [
            "x-apple.systempreferences:com.apple.settings.Storage",
            "x-apple.systempreferences:com.apple.preference.storage",
        ]
        for candidate in candidates {
            if let url = URL(string: candidate) {
                NSWorkspace.shared.open(url)
                return
            }
        }
    }
}
