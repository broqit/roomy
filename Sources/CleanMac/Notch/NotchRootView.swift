import SwiftUI

struct NotchRootView: View {
    @ObservedObject var model: NotchViewModel
    @ObservedObject var store: CacheStore
    @ObservedObject var settings: AppSettings
    @ObservedObject var disk: DiskMonitor

    private var geometry: NotchGeometry { model.geometry }
    private var isExpanded: Bool { model.mode == .expanded && model.openAmount > 0.42 }

    /// Resting state matches the hardware notch. The size lives in the opened widget, not in a bar over the menu.
    private var showsIndicator: Bool { false }

    var body: some View {
        let size = presentedSize
        let shape = NotchShape(topRadius: topRadius, bottomRadius: bottomRadius(for: size))
        let glass = glassAmount
        ZStack(alignment: .top) {
            shape
                .fill(Color.black.opacity(1 - glass))
                .frame(width: size.width, height: size.height)
            if glass > 0 {
                shape
                    .fill(.ultraThinMaterial)
                    .frame(width: size.width, height: size.height)
                    .opacity(glass)
            }
            shape
                .stroke(Color.primary.opacity(0.14 * glass), lineWidth: 1)
                .frame(width: size.width, height: size.height)
            content
                .frame(width: size.width, height: size.height, alignment: .top)
                .clipShape(shape)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .offset(x: horizontalShift)
        .ignoresSafeArea()
        .environment(\.colorScheme, settings.appearance.colorScheme ?? systemColorScheme)
    }

    @Environment(\.colorScheme) private var systemColorScheme

    /// Glass belongs to the opened card. The toast and the resting notch stay black.
    private var glassAmount: Double {
        if case .toast = model.mode { return 0 }
        return Double(min(1, max(0, model.openAmount / 0.5)))
    }

    /// Keeps the hardware notch covered and puts the size on its right, instead of growing both ears.
    /// The offset eases out as the panel opens so the expanded card is centered on the notch.
    private var horizontalShift: CGFloat {
        guard geometry.hasNotch, showsIndicator else { return 0 }
        let wing = NotchGeometry.indicatorWidth / 2
        switch model.mode {
        case .collapsed:
            return wing
        case .expanded:
            return wing * (1 - model.openAmount)
        case .toast:
            return 0
        }
    }

    private var presentedSize: CGSize {
        let collapsed = geometry.shapeSize(for: .collapsed, showsIndicator: showsIndicator)
        switch model.mode {
        case .toast:
            return geometry.shapeSize(for: .toast(""), showsIndicator: showsIndicator)
        case .expanded, .collapsed:
            let expanded = NotchGeometry.expandedSize
            return CGSize(
                width: collapsed.width + (expanded.width - collapsed.width) * model.openAmount,
                height: collapsed.height + (expanded.height - collapsed.height) * model.openAmount
            )
        }
    }

    /// The resting notch has tiny shoulders; they widen as the island opens.
    private var topRadius: CGFloat {
        if case .toast = model.mode { return 10 }
        return 6 + (NotchGeometry.openBottomRadius - 6) * model.openAmount
    }

    private func bottomRadius(for size: CGSize) -> CGFloat {
        if case .toast = model.mode { return 18 }
        let resting = geometry.hasNotch ? 10 : size.height / 2
        return resting + (NotchGeometry.openBottomRadius - resting) * model.openAmount
    }

    @ViewBuilder
    private var content: some View {
        switch model.mode {
        case .expanded where isExpanded:
            CacheListView(store: store, settings: settings, disk: disk, history: HistoryStore.shared, hasNotch: geometry.hasNotch)
                .padding(.top, 18)
                .padding(.horizontal, 22)
                .padding(.bottom, 16)
                .opacity(Double(min(1, max(0, (model.openAmount - 0.45) / 0.35))))
                .offset(y: model.reduceMotion ? 0 : -8 * (1 - model.openAmount))
        case let .toast(message):
            VStack(spacing: 0) {
                Color.clear.frame(height: geometry.notchSize.height)
                Text(message)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
                    .frame(maxHeight: .infinity)
            }
            .accessibilityLabel(message)
        default:
            Color.clear
                .accessibilityElement()
                .accessibilityLabel("Roomy")
                .accessibilityHint("Відкрити панель з іконки в рядку меню")
        }
    }
}
