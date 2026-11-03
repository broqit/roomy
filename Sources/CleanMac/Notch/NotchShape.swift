import SwiftUI

/// Rounded card. Top and bottom corners use the same inward curve, so nothing flares past the card.
struct NotchShape: Shape {
    var topRadius: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topRadius, bottomRadius) }
        set {
            topRadius = newValue.first
            bottomRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let limit = min(rect.width / 2, rect.height / 2)
        let top = reach(topRadius, limit: limit)
        let bottom = reach(bottomRadius, limit: limit)
        let ease: CGFloat = 0.64

        var path = Path()
        path.move(to: CGPoint(x: rect.minX + top, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - top, y: rect.minY))
        path.addCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY + top),
            control1: CGPoint(x: rect.maxX - top * (1 - ease), y: rect.minY),
            control2: CGPoint(x: rect.maxX, y: rect.minY + top * (1 - ease))
        )
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - bottom))
        path.addCurve(
            to: CGPoint(x: rect.maxX - bottom, y: rect.maxY),
            control1: CGPoint(x: rect.maxX, y: rect.maxY - bottom * (1 - ease)),
            control2: CGPoint(x: rect.maxX - bottom * (1 - ease), y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.minX + bottom, y: rect.maxY))
        path.addCurve(
            to: CGPoint(x: rect.minX, y: rect.maxY - bottom),
            control1: CGPoint(x: rect.minX + bottom * (1 - ease), y: rect.maxY),
            control2: CGPoint(x: rect.minX, y: rect.maxY - bottom * (1 - ease))
        )
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + top))
        path.addCurve(
            to: CGPoint(x: rect.minX + top, y: rect.minY),
            control1: CGPoint(x: rect.minX, y: rect.minY + top * (1 - ease)),
            control2: CGPoint(x: rect.minX + top * (1 - ease), y: rect.minY)
        )
        path.closeSubpath()
        return path
    }

    /// A continuous corner starts its curve earlier than a circular arc.
    private func reach(_ radius: CGFloat, limit: CGFloat) -> CGFloat {
        max(0, min(radius * 1.28, limit))
    }
}
