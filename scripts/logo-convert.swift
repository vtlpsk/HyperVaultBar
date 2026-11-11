import AppKit

let source = URL(fileURLWithPath: "/private/tmp/hyper-foundation.svg.png")
let destination = URL(fileURLWithPath: CommandLine.arguments[1])
guard let image = NSImage(contentsOf: source),
      let tiff = image.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiff) else { fatalError("Cannot read SVG preview") }
guard let output = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: bitmap.pixelsWide,
                                   pixelsHigh: bitmap.pixelsHigh, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else {
    fatalError("Cannot create transparent image")
}
for y in 0..<bitmap.pixelsHigh {
    for x in 0..<bitmap.pixelsWide {
        guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
        let darkness = 1 - (color.redComponent + color.greenComponent + color.blueComponent) / 3
        output.setColor(NSColor(calibratedRed: 48 / 255, green: 120 / 255, blue: 99 / 255,
                                alpha: darkness), atX: x, y: y)
    }
}
guard let png = output.representation(using: .png, properties: [:]) else { fatalError("Cannot encode PNG") }
try png.write(to: destination)
