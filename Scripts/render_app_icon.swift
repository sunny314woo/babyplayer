import AppKit
import ImageIO

private let outputSize = CGSize(width: 1280, height: 768)

guard CommandLine.arguments.count == 2 else {
    fputs("Usage: render_app_icon.swift OUTPUT.png\n", stderr)
    exit(2)
}

let scriptURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
let sourceURL = scriptURL.deletingLastPathComponent()
    .appendingPathComponent("babyplayer-app-icon-source.png")
let outputURL = URL(fileURLWithPath: CommandLine.arguments[1])

guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
    fputs("Unable to load icon source: \(sourceURL.path)\n", stderr)
    exit(1)
}

let targetAspect = outputSize.width / outputSize.height
let sourceAspect = CGFloat(image.width) / CGFloat(image.height)
let cropRect: CGRect
if sourceAspect > targetAspect {
    let cropWidth = CGFloat(image.height) * targetAspect
    cropRect = CGRect(x: (CGFloat(image.width) - cropWidth) / 2,
                      y: 0,
                      width: cropWidth,
                      height: CGFloat(image.height))
} else {
    let cropHeight = CGFloat(image.width) / targetAspect
    cropRect = CGRect(x: 0,
                      y: (CGFloat(image.height) - cropHeight) / 2,
                      width: CGFloat(image.width),
                      height: cropHeight)
}

guard let croppedImage = image.cropping(to: cropRect),
      let context = CGContext(
        data: nil,
        width: Int(outputSize.width),
        height: Int(outputSize.height),
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
      ) else {
    fputs("Unable to prepare icon rendering context\n", stderr)
    exit(1)
}

context.interpolationQuality = .high
context.draw(croppedImage, in: CGRect(origin: .zero, size: outputSize))

guard let renderedImage = context.makeImage(),
      let png = NSBitmapImageRep(cgImage: renderedImage)
        .representation(using: .png, properties: [:]) else {
    fputs("Unable to render PNG\n", stderr)
    exit(1)
}

try png.write(to: outputURL, options: .atomic)
