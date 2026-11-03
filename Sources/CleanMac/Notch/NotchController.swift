import AppKit
import Combine
import SwiftUI

/// Borderless, non-activating panel that sits above the menu bar over the built-in notch.
final class NotchPanel: NSPanel {
    init(frame: CGRect) {
        super.init(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 3)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        animationBehavior = .none
        ignoresMouseEvents = true
        acceptsMouseMovedEvents = true
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown || event.type == .rightMouseDown {
            makeKey()
        }
        super.sendEvent(event)
    }
}

private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var isOpaque: Bool { false }
}

@MainActor
final class NotchController {
    private let store: CacheStore
    private let settings: AppSettings
    private let model: NotchViewModel
    private let panel: NotchPanel
    private var pollTimer: Timer?
    private var animator: Timer?
    private var outsideClickMonitor: Any?
    private var keyMonitor: Any?
    private var cancellables: Set<AnyCancellable> = []
    private var hoverStart: Date?
    private var exitStart: Date?
    private var toastTask: Task<Void, Never>?
    private var menuIsOpen = false
    private var openTarget: CGFloat = 0
    private var pendingToast: String?
    var isPinned = false
    /// Menu-bar icon. A click there toggles the panel and must not also count as "click outside".
    var passthroughRect: CGRect = .zero

    init?(store: CacheStore, settings: AppSettings) {
        guard let geometry = NotchGeometry.current() else { return nil }
        self.store = store
        self.settings = settings
        model = NotchViewModel(geometry: geometry)
        panel = NotchPanel(frame: geometry.panelFrame)
        model.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

        let root = NotchRootView(model: model, store: store, settings: settings, disk: DiskMonitor.shared)
        let hostingView = FirstMouseHostingView(rootView: root)
        hostingView.sizingOptions = []
        hostingView.safeAreaRegions = []
        hostingView.frame = CGRect(origin: .zero, size: geometry.panelFrame.size)
        hostingView.wantsLayer = true
        hostingView.layer?.isOpaque = false
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        hostingView.autoresizingMask = [.width, .height]
        panel.contentView = hostingView
        observe()
    }

    var hasNotch: Bool { model.geometry.hasNotch }
    var isExpanded: Bool {
        if case .expanded = model.mode { return true }
        return false
    }

    func toggleFromStatusItem() {
        if isExpanded {
            isPinned = false
            collapse()
        } else {
            show()
            expand(pinned: true)
        }
    }

    func show() {
        updateWindowFrame()
        panel.orderFrontRegardless()
        startTracking()
    }

    func hide() {
        stopTracking()
        isPinned = false
        setMode(.collapsed)
        panel.orderOut(nil)
    }

    func expand(pinned: Bool = false) {
        isPinned = pinned
        setMode(.expanded)
    }

    func collapse() {
        guard !blocksCollapse else { return }
        isPinned = false
        setMode(.collapsed)
    }

    var modeDescription: String {
        switch model.mode {
        case .collapsed: return "collapsed"
        case .expanded: return "expanded"
        case let .toast(message): return "toast: \(message)"
        }
    }

    func writeSnapshot(to url: URL) -> Bool {
        guard let view = panel.contentView,
              let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return false }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { return false }
        return (try? data.write(to: url)) != nil
    }

    private var blocksCollapse: Bool {
        menuIsOpen
    }

    private func observe() {
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.relayout() }
            .store(in: &cancellables)

        let workspace = NSWorkspace.shared.notificationCenter
        workspace.publisher(for: NSWorkspace.didWakeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.relayout()
                DiskMonitor.shared.refresh()
            }
            .store(in: &cancellables)
        workspace.publisher(for: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.model.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: NSMenu.didBeginTrackingNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.menuIsOpen = true }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: NSMenu.didEndTrackingNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.menuIsOpen = false }
            .store(in: &cancellables)

        store.cleanupFinished
            .receive(on: RunLoop.main)
            .sink { [weak self] message in self?.showToast(message) }
            .store(in: &cancellables)

        panel.appearance = settings.appearance.nsAppearance
        settings.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                let appearance = self.settings.appearance.nsAppearance
                if self.panel.appearance?.name != appearance?.name {
                    self.panel.appearance = appearance
                }
            }
            .store(in: &cancellables)
    }

    private func relayout() {
        guard let geometry = NotchGeometry.current() else {
            hide()
            return
        }
        model.geometry = geometry
        updateWindowFrame()
    }

    private func setMode(_ mode: NotchMode) {
        var mode = mode
        if case .collapsed = mode, let pending = pendingToast {
            pendingToast = nil
            mode = .toast(pending)
            scheduleToastDismissal()
        }
        let changed = model.mode != mode
        if changed, mode == .expanded {
            toastTask?.cancel()
            store.refreshIfStale()
            panel.makeKey()
        }
        model.mode = mode
        let target: CGFloat
        switch mode {
        case .expanded: target = 1
        case .collapsed, .toast: target = 0
        }
        openTarget = target
        panel.ignoresMouseEvents = mode != .expanded
        hoverStart = nil
        exitStart = nil
        updateWindowFrame()
        startAnimator()
    }

    /// The window itself grows out of the notch. `openAmount` is the animation, not a jump to the full card.
    private func updateWindowFrame() {
        let closed = model.geometry.shapeRect(for: .collapsed, showsIndicator: false)
        let open = model.geometry.panelFrame
        let rect: CGRect
        if case .toast = model.mode {
            rect = model.geometry.shapeRect(for: model.mode, showsIndicator: false)
        } else {
            let t = model.openAmount
            let drop = (model.geometry.menuBarHeight + NotchGeometry.openedGap) * t
            rect = CGRect(
                x: closed.minX + (open.minX - closed.minX) * t,
                y: closed.minY + (open.minY - closed.minY) * t - drop,
                width: closed.width + (open.width - closed.width) * t,
                height: closed.height + (open.height - closed.height) * t
            )
        }
        panel.setFrame(rect, display: false)
        panel.contentView?.frame = CGRect(origin: .zero, size: rect.size)
    }

    private func showToast(_ message: String) {
        guard panel.isVisible else { return }
        if model.mode == .expanded {
            pendingToast = message
            return
        }
        pendingToast = nil
        setMode(.toast(message))
        scheduleToastDismissal()
    }

    private func scheduleToastDismissal() {
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.8))
            guard !Task.isCancelled, let self, case .toast = self.model.mode else { return }
            self.pendingToast = nil
            self.setMode(.collapsed)
        }
    }

    private func startAnimator() {
        if model.reduceMotion {
            model.openAmount = openTarget
            updateWindowFrame()
            animator?.invalidate()
            animator = nil
            return
        }
        guard animator == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.stepAnimation() }
        }
        RunLoop.main.add(timer, forMode: .common)
        animator = timer
    }

    private func stepAnimation() {
        let delta = openTarget - model.openAmount
        if abs(delta) < 0.02 {
            model.openAmount = openTarget
            updateWindowFrame()
            animator?.invalidate()
            animator = nil
            return
        }
        model.openAmount += delta * 0.22
        updateWindowFrame()
    }

    private func startTracking() {
        guard pollTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer

        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleOutsideClick() }
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let keyCode = event.keyCode
            let handled = MainActor.assumeIsolated { self?.handleKeyCode(keyCode) ?? false }
            return handled ? nil : event
        }
    }

    private func stopTracking() {
        pollTimer?.invalidate()
        pollTimer = nil
        animator?.invalidate()
        animator = nil
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        outsideClickMonitor = nil
        keyMonitor = nil
    }

    private func handleKeyCode(_ keyCode: UInt16) -> Bool {
        guard keyCode == 53 else { return false }
        if store.pendingClean != nil {
            store.cancelPendingClean()
            return true
        }
        if model.mode == .expanded {
            isPinned = false
            setMode(.collapsed)
            return true
        }
        return false
    }

    private func handleOutsideClick() {
        let location = NSEvent.mouseLocation
        let showsIndicator = settings.showNotchIndicator && (store.hasScannedAnything || store.isScanning)
        switch model.mode {
        case .collapsed, .toast:
            let hotZone = model.geometry.shapeRect(for: .collapsed, showsIndicator: showsIndicator).insetBy(dx: -8, dy: -8)
            if hotZone.contains(location) {
                setMode(.expanded)
            }
        case .expanded:
            guard !blocksCollapse else { return }
            if passthroughRect.contains(location) { return }
            if !panel.frame.contains(location) {
                store.cancelPendingClean()
                isPinned = false
                setMode(.collapsed)
            }
        }
    }

    private func tick() {
        let location = NSEvent.mouseLocation
        let geometry = model.geometry
        let showsIndicator = settings.showNotchIndicator && (store.hasScannedAnything || store.isScanning)

        switch model.mode {
        case .collapsed, .toast:
            // Open from the menu-bar icon (or a click on the notch), not from the pointer resting there.
            hoverStart = nil
        case .expanded:
            guard !isPinned, !blocksCollapse else { return }
            let keepOpenZone = geometry.shapeRect(for: .expanded, showsIndicator: showsIndicator).insetBy(dx: -16, dy: -20)
            if keepOpenZone.contains(location) || NSApp.modalWindow != nil {
                exitStart = nil
            } else {
                if exitStart == nil { exitStart = Date() }
                if let exitStart, Date().timeIntervalSince(exitStart) > 0.4 {
                    setMode(.collapsed)
                }
            }
        }
    }
}
