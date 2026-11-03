import AppKit

let dimension = 1024
let destination = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.png"

let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
guard let context = CGContext(
    data: nil,
    width: dimension,
    height: dimension,
    bitsPerComponent: 8,
    bytesPerRow: 0,
    space: colorSpace,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else {
    fputs("Could not draw the app icon.\n", stderr)
    exit(1)
}
context.setAllowsAntialiasing(true)
context.interpolationQuality = .high

let bounds = CGRect(x: 0, y: 0, width: CGFloat(dimension), height: CGFloat(dimension))
let shape = squircle(in: bounds.insetBy(dx: 6, dy: 6))

context.saveGState()
context.addPath(shape)
context.clip()
if let gradient = CGGradient(
    colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
    colors: [
        CGColor(srgbRed: 0.20, green: 0.28, blue: 0.42, alpha: 1),
        CGColor(srgbRed: 0.07, green: 0.08, blue: 0.12, alpha: 1),
    ] as CFArray,
    locations: [0, 1]
) {
    context.drawLinearGradient(
        gradient,
        start: CGPoint(x: bounds.midX, y: bounds.maxY),
        end: CGPoint(x: bounds.midX, y: bounds.minY),
        options: []
    )
}
if let sheen = CGGradient(
    colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
    colors: [
        CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.16),
        CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0),
    ] as CFArray,
    locations: [0, 1]
) {
    context.drawLinearGradient(
        sheen,
        start: CGPoint(x: bounds.midX, y: bounds.maxY),
        end: CGPoint(x: bounds.midX, y: bounds.midY + 40),
        options: []
    )
}
let card = CGRect(x: 148, y: 118, width: 728, height: 640)
let notch = CGRect(x: 362, y: 640, width: 300, height: 420)
context.setShadow(offset: CGSize(width: 0, height: -12), blur: 32, color: CGColor(gray: 0, alpha: 0.38))
context.setFillColor(CGColor(srgbRed: 0.98, green: 0.98, blue: 0.99, alpha: 1))
context.addPath(CGPath(roundedRect: card, cornerWidth: 92, cornerHeight: 92, transform: nil))
context.addPath(CGPath(roundedRect: notch, cornerWidth: 52, cornerHeight: 52, transform: nil))
context.fillPath()
context.setShadow(offset: .zero, blur: 0, color: nil)

let rows: [(CGFloat, CGColor)] = [
    (430, CGColor(srgbRed: 0.78, green: 0.82, blue: 0.88, alpha: 1)),
    (310, CGColor(srgbRed: 0.78, green: 0.82, blue: 0.88, alpha: 1)),
    (196, CGColor(srgbRed: 0.33, green: 0.52, blue: 0.98, alpha: 1)),
]
var rowY: CGFloat = 430
for (width, color) in rows {
    let row = CGRect(x: 228, y: rowY, width: width, height: 34)
    context.setFillColor(color)
    context.addPath(CGPath(roundedRect: row, cornerWidth: 14, cornerHeight: 14, transform: nil))
    context.fillPath()
    rowY -= 92
}
context.restoreGState()

guard let rendered = context.makeImage() else {
    fputs("Could not encode the app icon.\n", stderr)
    exit(1)
}
let rep = NSBitmapImageRep(cgImage: rendered)
guard let png = rep.representation(using: .png, properties: [.compressionFactor: 1]) else {
    fputs("Could not encode the app icon.\n", stderr)
    exit(1)
}
try png.write(to: URL(fileURLWithPath: destination))

func squircle(in rect: CGRect) -> CGPath {
    let path = CGMutablePath()
    let steps = 240
    let exponent = 2.0 / 5.4
    let center = CGPoint(x: rect.midX, y: rect.midY)
    let radius = CGSize(width: rect.width / 2, height: rect.height / 2)
    for step in 0...steps {
        let angle = CGFloat(step) / CGFloat(steps) * 2 * .pi
        let cosine = cos(angle)
        let sine = sin(angle)
        let point = CGPoint(
            x: center.x + radius.width * pow(abs(cosine), exponent) * (cosine < 0 ? -1 : 1),
            y: center.y + radius.height * pow(abs(sine), exponent) * (sine < 0 ? -1 : 1)
        )
        if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
    }
    path.closeSubpath()
    return path
}
