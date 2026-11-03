import AppKit
import SwiftUI

extension AppAppearance {
    /// Nil follows the system appearance.
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

/// Behind-window vibrancy cut to the island outline, so the desktop shows through the opened card.
/// A layer mask does not clip behind-window blending; `maskImage` does.
struct NotchGlass: NSViewRepresentable {
    var shape: NotchShape
    var appearance: AppAppearance

    func makeNSView(context: Context) -> ShapedEffectView {
        let view = ShapedEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        view.isEmphasized = false
        return view
    }

    func updateNSView(_ view: ShapedEffectView, context: Context) {
        view.appearance = appearance.nsAppearance
        view.shape = shape
    }
}

final class ShapedEffectView: NSVisualEffectView {
    var shape: NotchShape? {
        didSet {
            guard shape?.topRadius != oldValue?.topRadius || shape?.bottomRadius != oldValue?.bottomRadius else { return }
            updateMask()
        }
    }

    private var maskedSize: CGSize = .zero

    override func layout() {
        super.layout()
        if bounds.size != maskedSize { updateMask() }
    }

    private func updateMask() {
        guard let shape, bounds.width > 0, bounds.height > 0 else { return }
        let size = bounds.size
        maskedSize = size
        let path = shape.path(in: CGRect(origin: .zero, size: size)).cgPath
        maskImage = NSImage(size: size, flipped: true) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.addPath(path)
            context.setFillColor(NSColor.black.cgColor)
            context.fillPath()
            return true
        }
    }
}
