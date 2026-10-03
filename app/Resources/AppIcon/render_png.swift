// Rasterizes an SVG to a transparent PNG with AppKit.
// Usage: swift render_png.swift <in.svg> <out.png> <width> [height]  (height defaults to width)
import AppKit

let args = CommandLine.arguments
guard args.count == 4 || args.count == 5, let width = Int(args[3]),
      let height = args.count == 5 ? Int(args[4]) : width else {
    FileHandle.standardError.write("usage: render_png.swift <in.svg> <out.png> <width> [height]\n".data(using: .utf8)!)
    exit(2)
}
guard let image = NSImage(contentsOf: URL(fileURLWithPath: args[1])) else {
    FileHandle.standardError.write("cannot load \(args[1])\n".data(using: .utf8)!)
    exit(1)
}
let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
    hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
image.draw(in: NSRect(x: 0, y: 0, width: width, height: height))
NSGraphicsContext.restoreGraphicsState()
try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[2]))
