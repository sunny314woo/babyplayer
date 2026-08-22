import AppKit

private let canvas = CGSize(width: 1280, height: 768)
private let orange = NSColor(calibratedRed: 0.976, green: 0.345, blue: 0.025, alpha: 1)
private let brown = NSColor(calibratedRed: 0.235, green: 0.090, blue: 0.035, alpha: 1)
private let cream = NSColor(calibratedRed: 1.000, green: 0.957, blue: 0.855, alpha: 1)

guard CommandLine.arguments.count == 2 else {
    fputs("Usage: render_app_icon.swift OUTPUT.png\n", stderr)
    exit(2)
}

guard let context = CGContext(
    data: nil,
    width: Int(canvas.width),
    height: Int(canvas.height),
    bitsPerComponent: 8,
    bytesPerRow: Int(canvas.width) * 4,
    space: CGColorSpaceCreateDeviceRGB(),
    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
) else {
    fputs("Unable to create graphics context\n", stderr)
    exit(1)
}
context.setAllowsAntialiasing(true)
context.setShouldAntialias(true)

context.setFillColor(orange.cgColor)
context.fill(CGRect(origin: .zero, size: canvas))

// A deliberately neutral child seen from behind: round head, tiny hair tuft,
// short neck, and simple shoulders. It remains a single silhouette.
context.setFillColor(brown.cgColor)
context.fillEllipse(in: CGRect(x: 248, y: 286, width: 390, height: 390))
context.fillEllipse(in: CGRect(x: 216, y: 386, width: 78, height: 104))
context.fillEllipse(in: CGRect(x: 592, y: 386, width: 78, height: 104))
context.fill(CGRect(x: 405, y: 242, width: 82, height: 96))

let shoulders = CGMutablePath()
shoulders.move(to: CGPoint(x: 222, y: 104))
shoulders.addCurve(to: CGPoint(x: 665, y: 104),
                   control1: CGPoint(x: 246, y: 245),
                   control2: CGPoint(x: 640, y: 245))
shoulders.addLine(to: CGPoint(x: 665, y: 86))
shoulders.addLine(to: CGPoint(x: 222, y: 86))
shoulders.closeSubpath()
context.addPath(shoulders)
context.fillPath()

let tuft = CGMutablePath()
tuft.move(to: CGPoint(x: 405, y: 653))
tuft.addCurve(to: CGPoint(x: 453, y: 718),
              control1: CGPoint(x: 408, y: 688),
              control2: CGPoint(x: 429, y: 719))
tuft.addCurve(to: CGPoint(x: 470, y: 661),
              control1: CGPoint(x: 477, y: 717),
              control2: CGPoint(x: 478, y: 683))
tuft.closeSubpath()
context.addPath(tuft)
context.fillPath()

context.setFillColor(cream.cgColor)
let play = CGMutablePath()
play.move(to: CGPoint(x: 812, y: 220))
play.addLine(to: CGPoint(x: 812, y: 548))
play.addLine(to: CGPoint(x: 1090, y: 384))
play.closeSubpath()
context.addPath(play)
context.fillPath()

guard let cgImage = context.makeImage(),
      let png = NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:]) else {
    fputs("Unable to render PNG\n", stderr)
    exit(1)
}

try png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]), options: .atomic)
