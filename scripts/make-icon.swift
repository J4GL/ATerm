// Draws the ATerm icon, the logo in a macOS icon tile, at every size of a macOS iconset (SPEC/app/bundle.md).
// Usage: swift scripts/make-icon.swift <Logo.png> <output.iconset>
import AppKit

func drawIcon(logo: CGImage, size: CGFloat, in context: CGContext) {
    let scale = size / 1024
    context.scaleBy(x: scale, y: scale)

    // Squircle on the standard macOS icon grid: 824 × 824, centered, with a soft shadow.
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: CGColor(gray: 0, alpha: 0.45))
    context.addPath(shape)
    context.setFillColor(CGColor(srgbRed: 0.03, green: 0.05, blue: 0.16, alpha: 1))
    context.fillPath()
    context.restoreGState()

    // The logo, aspect-filled into the tile.
    context.saveGState()
    context.addPath(shape)
    context.clip()
    let fill = max(tile.width / CGFloat(logo.width), tile.height / CGFloat(logo.height))
    let logoSize = CGSize(width: CGFloat(logo.width) * fill, height: CGFloat(logo.height) * fill)
    context.interpolationQuality = .high
    context.draw(logo, in: CGRect(x: tile.midX - logoSize.width / 2, y: tile.midY - logoSize.height / 2,
                                  width: logoSize.width, height: logoSize.height))
    context.restoreGState()
}

let arguments = CommandLine.arguments
guard arguments.count == 3,
      let logo = NSImage(contentsOfFile: arguments[1])?.cgImage(forProposedRect: nil, context: nil, hints: nil)
else {
    print("usage: swift scripts/make-icon.swift <Logo.png> <output.iconset>")
    exit(1)
}
let output = arguments[2]
let sizes: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for (name, pixels) in sizes {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!.retagging(with: .sRGB)!
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    drawIcon(logo: logo, size: CGFloat(pixels), in: context.cgContext)
    context.flushGraphics()
    let data = rep.representation(using: .png, properties: [:])!
    try! data.write(to: URL(fileURLWithPath: "\(output)/\(name).png"))
}
