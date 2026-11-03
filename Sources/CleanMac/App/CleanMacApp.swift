import AppKit
import Combine
import SwiftUI

struct CleanMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // Required so the App lifecycle runs. The visible control is the status item, not this extra.
        MenuBarExtra(isInserted: .constant(false)) {
            EmptyView()
        } label: {
            Image(systemName: "sparkles")
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var notchController: NotchController?
    private var statusItem: NSStatusItem?
    private var cancellables: Set<AnyCancellable> = []

    var hasNotch: Bool { notchController?.hasNotch ?? (NotchGeometry.current()?.hasNotch ?? false) }

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        for window in NSApp.windows where window.level == .normal {
            window.orderOut(nil)
        }
        let settings = AppSettings.shared
        DiskMonitor.shared.start()
        notchController = NotchController(store: CacheStore.shared, settings: settings)
        applyNotchSetting()
        // SwiftUI finishes its own status-bar setup after this method and drops an item created here.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(200))
            self.installStatusItem()
            try? await Task.sleep(for: .milliseconds(400))
            self.recordStatusItemFrame()
        }

        settings.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.applyNotchSetting()
                self?.updateStatusItemVisibility()
            }
            .store(in: &cancellables)

        let workspace = NSWorkspace.shared.notificationCenter
        workspace.publisher(for: NSWorkspace.sessionDidResignActiveNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.sessionBecameInactive() }
            .store(in: &cancellables)
        workspace.publisher(for: NSWorkspace.sessionDidBecomeActiveNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.sessionBecameActive() }
            .store(in: &cancellables)

        CacheStore.shared.refresh()
        if CommandLine.arguments.contains("--expand-notch") {
            notchController?.expand(pinned: true)
            keepStatusItemAbovePanel()
        }
        observeDebugRequests()
    }

    private func sessionBecameInactive() {
        CacheStore.shared.pauseForInactiveSession()
        DiskMonitor.shared.setSessionActive(false)
        notchController?.hide()
    }

    private func sessionBecameActive() {
        CacheStore.shared.resumeSession()
        DiskMonitor.shared.setSessionActive(true)
        applyNotchSetting()
        DiskMonitor.shared.refresh()
    }

    /// Debug channel for local verification. Deliver immediately: an LSUIElement app is not "active",
    /// so the default suspension behavior never forwards the notification.
    private func observeDebugRequests() {
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handleDebugNotification(_:)),
            name: Notification.Name("com.mortimer.CleanMac.debug"),
            object: nil,
            suspensionBehavior: .deliverImmediately
        )
    }

    @objc private func handleDebugNotification(_ notification: Notification) {
        let request = (notification.object as? String) ?? (notification.userInfo?["request"] as? String) ?? ""
        handleDebugRequest(request)
    }

    private func handleDebugRequest(_ request: String) {
        if request.hasPrefix("snapshot:"), let notchController {
            let path = String(request.dropFirst("snapshot:".count))
            let written = notchController.writeSnapshot(to: URL(fileURLWithPath: path))
            try? "\(notchController.modeDescription)\nwritten: \(written)\n"
                .write(toFile: path + ".txt", atomically: true, encoding: .utf8)
            return
        }
        if request == "expand" {
            notchController?.expand(pinned: true)
        } else if request == "collapse" {
            notchController?.isPinned = false
            notchController?.collapse()
        } else if request.hasPrefix("request-clean:") {
            let id = String(request.dropFirst("request-clean:".count))
            notchController?.expand(pinned: true)
            CacheStore.shared.requestClean(ids: [id])
        } else if request == "confirm-clean" {
            CacheStore.shared.confirmPendingClean()
        } else if request == "cancel-clean" {
            CacheStore.shared.cancelPendingClean()
        } else if request.hasPrefix("toast:") {
            CacheStore.shared.cleanupFinished.send(String(request.dropFirst("toast:".count)))
        }
    }

    private func applyNotchSetting() {
        guard DiskMonitor.shared.sessionActive else { return }
        if AppSettings.shared.notchPanelEnabled {
            notchController?.show()
        } else {
            notchController?.hide()
        }
    }

    private func installStatusItem() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.isVisible = true
        if let button = item.button {
            if let image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: "Roomy") {
                image.isTemplate = true
                button.image = image.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 15, weight: .medium))
            } else {
                button.title = "R"
            }
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        statusItem = item
        keepStatusItemAbovePanel()
        recordStatusItemFrame()
    }

    /// The notch panel sits above the menu bar. The icon's window has to stay above that panel
    /// so a click can still open and close the widget.
    private func keepStatusItemAbovePanel() {
        guard let window = statusItem?.button?.window else { return }
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 5)
        window.orderFrontRegardless()
    }

    private func updateStatusItemVisibility() {
        if AppSettings.shared.showMenuBarIcon {
            installStatusItem()
        } else if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
            self.statusItem = nil
        }
    }

    /// Left click opens or closes the notch widget. Right click is only Quit.
    @objc private func statusItemClicked(_ sender: Any?) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp {
            let menu = NSMenu()
            let quit = NSMenuItem(title: "Завершити Roomy", action: #selector(quitFromStatusItem), keyEquivalent: "q")
            quit.target = self
            menu.addItem(quit)
            statusItem?.menu = menu
            statusItem?.button?.performClick(nil)
            statusItem?.menu = nil
            return
        }
        notchController?.show()
        notchController?.toggleFromStatusItem()
        keepStatusItemAbovePanel()
        recordStatusItemFrame()
    }

    @objc private func quitFromStatusItem() {
        NSApp.terminate(nil)
    }

    private func recordStatusItemFrame() {
        guard let button = statusItem?.button, let window = button.window else { return }
        let frame = window.frame
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/CleanMac", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        notchController?.passthroughRect = frame
        let text = "\(frame.origin.x) \(frame.origin.y) \(frame.width) \(frame.height)\n"
        try? text.write(to: directory.appendingPathComponent("status-item.txt"), atomically: true, encoding: .utf8)
    }
}
