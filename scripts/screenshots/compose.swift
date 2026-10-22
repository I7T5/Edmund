// Places window captures (with their shadows, from `screencapture -l`) on a
// soft gradient, at the Mac App Store's 2880×1800 screenshot size. Windows stack
// in order, all at one scale. With --offset dx,dy each window sits that fraction
// of the canvas right of and below the one before it — a cascade, or side by
// side — and the group as a whole is centred and scaled to fit.
//
// Usage: swift scripts/screenshots/compose.swift <out.png> light|dark [--offset dx,dy] <window.png>...
import AppKit

var args = Array(CommandLine.arguments.dropFirst())
guard args.count >= 3 else {
    FileHandle.standardError.write("usage: compose.swift <out.png> light|dark [--offset dx,dy] <window.png>...\n".data(using: .utf8)!)
    exit(2)
}
let out = args.removeFirst()
let dark = args.removeFirst() == "dark"
var step = CGPoint.zero
if args.first == "--offset" {
    let parts = args[1].split(separator: ",").compactMap { Double($0) }
    step = CGPoint(x: parts[0], y: parts[1])
    args.removeFirst(2)
}
let windows = args.map { NSImage(contentsOfFile: $0)! }
let size = NSSize(width: 2880, height: 1800)

// Pixels, not points: an NSImage from a Retina capture reports half its size.
func pixels(_ image: NSImage) -> NSSize {
    NSSize(width: image.representations[0].pixelsWide, height: image.representations[0].pixelsHigh)
}
// Window centres, in canvas pixels, y down; the group's middle on the canvas's.
let middle = Double(windows.count - 1) / 2
let centres = windows.indices.map { i in
    CGPoint(x: size.width / 2 + (Double(i) - middle) * step.x * size.width,
            y: size.height / 2 + (Double(i) - middle) * step.y * size.height)
}
// The largest scale (at most 1) that keeps every window inside a 4% margin.
var scale = 1.0
for (window, centre) in zip(windows, centres) {
    let p = pixels(window)
    scale = min(scale,
                (size.width * 0.96 / 2 - abs(centre.x - size.width / 2)) * 2 / p.width,
                (size.height * 0.96 / 2 - abs(centre.y - size.height / 2)) * 2 / p.height)
}

// No alpha channel: App Store Connect rejects screenshots that have one.
let canvas = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                              bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false,
                              colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 32)!
canvas.size = size
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: canvas)
let top = dark ? NSColor(srgbRed: 0.20, green: 0.20, blue: 0.22, alpha: 1)
               : NSColor(srgbRed: 0.97, green: 0.97, blue: 0.98, alpha: 1)
let bottom = dark ? NSColor(srgbRed: 0.10, green: 0.10, blue: 0.11, alpha: 1)
                  : NSColor(srgbRed: 0.88, green: 0.89, blue: 0.92, alpha: 1)
NSGradient(starting: top, ending: bottom)!.draw(in: NSRect(origin: .zero, size: size), angle: -90)
for (window, centre) in zip(windows, centres) {
    let drawn = NSSize(width: pixels(window).width * scale, height: pixels(window).height * scale)
    // AppKit's y runs up; the centres were laid out top-down.
    window.draw(in: NSRect(x: centre.x - drawn.width / 2, y: size.height - centre.y - drawn.height / 2,
                           width: drawn.width, height: drawn.height),
                from: .zero, operation: .sourceOver, fraction: 1)
}
NSGraphicsContext.restoreGraphicsState()

try! canvas.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
