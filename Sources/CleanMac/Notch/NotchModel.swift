import AppKit
import SwiftUI

enum NotchMode: Equatable {
    case collapsed
    case expanded
    case toast(String)
}

/// Where the panel lives: over the hardware notch, or a pill at the top-center of a notch-less screen.
struct NotchGeometry: Equatable {
    var screenFrame: CGRect
    var hasNotch: Bool
    /// Size of the hardware notch, or of the fallback pill.
    var notchSize: CGSize
    /// Horizontal center of the notch in screen coordinates.
    var centerX: CGFloat
    /// Height of the menu bar on this screen. The opened panel drops by this much; the content shifts back up.
    var menuBarHeight: CGFloat

    static let expandedSize = CGSize(width: 606, height: 660)
    static let openBottomRadius: CGFloat = 30
    /// Extra gap under the menu bar once the card has left the notch.
    static let openedGap: CGFloat = 15
    /// Right-hand wing beside the hardware notch. The notch itself stays the screen's own size.
    static let indicatorWidth: CGFloat = 88
    static let toastSize = CGSize(width: 360, height: 36)

    /// Prefers the built-in display with a notch; falls back to the menu-bar screen.
    static func current() -> NotchGeometry? {
        if let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }),
           let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            let notchWidth = screen.frame.width - left.width - right.width
            return NotchGeometry(
                screenFrame: screen.frame,
                hasNotch: true,
                notchSize: CGSize(width: notchWidth, height: screen.safeAreaInsets.top),
                centerX: screen.frame.minX + left.width + notchWidth / 2,
                menuBarHeight: Self.menuBarHeight(of: screen)
            )
        }
        guard let screen = NSScreen.screens.first ?? NSScreen.main else { return nil }
        let menuBarHeight = max(24, screen.frame.maxY - screen.visibleFrame.maxY)
        return NotchGeometry(
            screenFrame: screen.frame,
            hasNotch: false,
            notchSize: CGSize(width: 0, height: min(menuBarHeight, 32)),
            centerX: screen.frame.midX,
            menuBarHeight: menuBarHeight
        )
    }

    /// The strip above `visibleFrame`. On a notched display that is the menu bar, which matches the notch inset.
    private static func menuBarHeight(of screen: NSScreen) -> CGFloat {
        max(0, max(screen.frame.maxY - screen.visibleFrame.maxY, screen.safeAreaInsets.top))
    }

    var panelFrame: CGRect {
        let size = Self.expandedSize
        return CGRect(x: centerX - size.width / 2, y: screenFrame.maxY - size.height, width: size.width, height: size.height)
    }

    func shapeSize(for mode: NotchMode, showsIndicator: Bool) -> CGSize {
        switch mode {
        case .expanded:
            return Self.expandedSize
        case .toast:
            return CGSize(width: max(Self.toastSize.width, notchSize.width + 2 * Self.indicatorWidth),
                          height: notchSize.height + Self.toastSize.height)
        case .collapsed:
            if hasNotch {
                let extra: CGFloat = showsIndicator ? Self.indicatorWidth : 0
                return CGSize(width: notchSize.width + extra, height: notchSize.height)
            }
            return CGSize(width: 150, height: max(notchSize.height, 28))
        }
    }

    /// The shape's rectangle in screen coordinates (AppKit, bottom-left origin).
    /// A size indicator hangs to the right of the hardware notch, so the left edge stays on the notch.
    func shapeRect(for mode: NotchMode, showsIndicator: Bool) -> CGRect {
        let size = shapeSize(for: mode, showsIndicator: showsIndicator)
        let x: CGFloat
        if hasNotch, case .collapsed = mode, showsIndicator {
            x = centerX - notchSize.width / 2
        } else {
            x = centerX - size.width / 2
        }
        return CGRect(x: x, y: screenFrame.maxY - size.height, width: size.width, height: size.height)
    }
}

@MainActor
final class NotchViewModel: ObservableObject {
    @Published var mode: NotchMode = .collapsed
    @Published var geometry: NotchGeometry
    /// 0 is the resting notch, 1 is the full panel. Driven by a timer so it still moves when the app is not active.
    @Published var openAmount: CGFloat = 0
    @Published var reduceMotion = false

    init(geometry: NotchGeometry) {
        self.geometry = geometry
    }
}
