import AppKit

// Renders an SVG into a macOS-style rounded square (transparent outside the squircle),
// the master art for Icon.icns. Used by Scripts/build_icon.sh.
// Usage: swift build_mac_icon.swift <svg> <out.png> <size> <cornerRadius>

let args = CommandLine.arguments
guard args.count >= 5 else {
    FileHandle.standardError.write(Data("usage: build_mac_icon.swift <svg> <out.png> <size> <cornerRadius>\n".utf8))
    exit(2)
}
let inPath = args[1]
let outPath = args[2]
let size = Int(args[3]) ?? 1024
let radius = CGFloat(Double(args[4]) ?? 225)

guard let img = NSImage(contentsOf: URL(fileURLWithPath: inPath)) else {
    FileHandle.standardError.write(Data("could not load \(inPath)\n".utf8)); exit(1)
}
img.size = NSSize(width: size, height: size)

guard let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { exit(1) }

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let rect = NSRect(x: 0, y: 0, width: size, height: size)
NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).addClip()
img.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
NSGraphicsContext.restoreGraphicsState()

guard let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
try png.write(to: URL(fileURLWithPath: outPath))
