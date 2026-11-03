import AppKit

let destination = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "background.png"
let width: CGFloat = 680
let height: CGFloat = 420
let image = NSImage(size: NSSize(width: width, height: height))
image.lockFocus()
NSColor(srgbRed: 0.945, green: 0.945, blue: 0.955, alpha: 1).setFill()
NSRect(x: 0, y: 0, width: width, height: height).fill()

let midY = height * 0.48
let arrow = NSBezierPath()
arrow.move(to: NSPoint(x: width / 2 - 34, y: midY))
arrow.line(to: NSPoint(x: width / 2 + 22, y: midY))
arrow.move(to: NSPoint(x: width / 2 + 10, y: midY + 12))
arrow.line(to: NSPoint(x: width / 2 + 22, y: midY))
arrow.line(to: NSPoint(x: width / 2 + 10, y: midY - 12))
NSColor(white: 0.55, alpha: 1).setStroke()
arrow.lineWidth = 3
arrow.lineCapStyle = .round
arrow.lineJoinStyle = .round
arrow.stroke()

let caption = "Перетягніть у Програми" as NSString
let attributes: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 15, weight: .medium),
    .foregroundColor: NSColor(white: 0.28, alpha: 1),
]
let captionSize = caption.size(withAttributes: attributes)
caption.draw(at: NSPoint(x: (width - captionSize.width) / 2, y: 48), withAttributes: attributes)
image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    fputs("Could not draw the disk image background.\n", stderr)
    exit(1)
}
try png.write(to: URL(fileURLWithPath: destination))
