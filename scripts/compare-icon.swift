// Test helper for APP-BUNDLE-002 (SPEC/app/bundle.md): compares an extracted iconset with the logo drawn
// aspect-filled into the macOS icon tile. Prints the failures and exits 1 when there is one.
// Usage: swift scripts/compare-icon.swift <AppIcon.iconset> <Logo.png>
import AppKit

let iconset = CommandLine.arguments[1]
let logoPath = CommandLine.arguments[2]
var failures: [String] = []

let sizes = ["icon_16x16", "icon_16x16@2x", "icon_32x32", "icon_32x32@2x", "icon_128x128", "icon_128x128@2x",
             "icon_256x256", "icon_256x256@2x", "icon_512x512", "icon_512x512@2x"]
for name in sizes where !FileManager.default.fileExists(atPath: "\(iconset)/\(name).png") {
    failures.append("missing \(name).png")
}

/// RGBA bytes (premultiplied, sRGB) of a 1024 × 1024 rendering, row 0 at the top.
func render(_ draw: (CGContext) -> Void) -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: 1024 * 1024 * 4)
    bytes.withUnsafeMutableBytes { buffer in
        let context = CGContext(data: buffer.baseAddress, width: 1024, height: 1024, bitsPerComponent: 8,
                                bytesPerRow: 1024 * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        draw(context)
    }
    return bytes
}

func cgImage(_ path: String) -> CGImage? {
    NSImage(contentsOfFile: path)?.cgImage(forProposedRect: nil, context: nil, hints: nil)
}

guard let icon = cgImage("\(iconset)/icon_512x512@2x.png"), icon.width == 1024, icon.height == 1024,
      let logo = cgImage(logoPath)
else {
    print("cannot read the 1024 × 1024 icon or the logo")
    exit(1)
}

let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let actual = render { $0.draw(icon, in: CGRect(x: 0, y: 0, width: 1024, height: 1024)) }
let reference = render { context in
    context.addPath(CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil))
    context.clip()
    let scale = max(tile.width / CGFloat(logo.width), tile.height / CGFloat(logo.height))
    let size = CGSize(width: CGFloat(logo.width) * scale, height: CGFloat(logo.height) * scale)
    context.interpolationQuality = .high
    context.draw(logo, in: CGRect(x: tile.midX - size.width / 2, y: tile.midY - size.height / 2,
                                  width: size.width, height: size.height))
}

var differing = 0
var compared = 0
for y in 160..<864 {
    for x in 160..<864 {
        let offset = (y * 1024 + x) * 4
        compared += 1
        if (0..<4).contains(where: { abs(Int(actual[offset + $0]) - Int(reference[offset + $0])) > 16 }) {
            differing += 1
        }
    }
}
let ratio = Double(differing) / Double(compared)
if ratio > 0.02 {
    failures.append(String(format: "%.2f %% of the tile's pixels differ from the logo (max 2 %%)", ratio * 100))
}
for (x, y) in [(0, 0), (1023, 1023), (110, 110)] {
    let alpha = Double(actual[(y * 1024 + x) * 4 + 3]) / 255
    if alpha > 0.05 { failures.append(String(format: "pixel (%d, %d) has alpha %.2f (max 0.05)", x, y, alpha)) }
}

if failures.isEmpty {
    print(String(format: "icon matches the logo (%.2f %% differing pixels)", ratio * 100))
} else {
    failures.forEach { print($0) }
    exit(1)
}
