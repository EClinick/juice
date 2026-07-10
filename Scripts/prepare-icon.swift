import AppKit
import Foundation

guard CommandLine.arguments.count == 3 else {
    fputs("usage: prepare-icon.swift <source.png> <output.png>\n", stderr)
    exit(1)
}

let sourceURL = URL(fileURLWithPath: CommandLine.arguments[1])
let outputURL = URL(fileURLWithPath: CommandLine.arguments[2])
let outputSize = 1024

guard let source = NSImage(contentsOf: sourceURL),
    let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: outputSize,
        pixelsHigh: outputSize,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ),
    let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
    fputs("Could not prepare Juice icon artwork\n", stderr)
    exit(1)
}

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context
NSColor.clear.setFill()
NSBezierPath(rect: NSRect(x: 0, y: 0, width: outputSize, height: outputSize)).fill()
source.draw(
    in: NSRect(x: 0, y: 0, width: outputSize, height: outputSize),
    from: .zero,
    operation: .sourceOver,
    fraction: 1,
    respectFlipped: false,
    hints: [.interpolation: NSImageInterpolation.high]
)
NSGraphicsContext.restoreGraphicsState()

guard let png = bitmap.representation(using: NSBitmapImageRep.FileType.png, properties: [:]) else {
    fputs("Could not encode Juice icon artwork\n", stderr)
    exit(1)
}

try png.write(to: outputURL)
