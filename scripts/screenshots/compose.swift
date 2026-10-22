// Places window captures (with their shadows, from `screencapture -l`) centred
// on a soft gradient, at the Mac App Store's 2880×1800 screenshot size. Several
// captures stack in order, all at the first one's scale — Settings over the
// document window it was opened from.
//
// Usage: swift scripts/screenshots/compose.swift <out.png> light|dark <window.png>...
import AppKit

let args = CommandLine.arguments
guard args.count >= 4 else {
    FileHandle.standardError.write("usage: compose.swift <out.png> light|dark <window.png>...\n".data(using: .utf8)!)
    exit(2)
}
let dark = args[2] == "dark"
let windows = args[3...].map { NSImage(contentsOfFile: $0)! }
let size = NSSize(width: 2880, height: 1800)

// Pixels, not points: an NSImage from a Retina capture reports half its size.
func pixels(_ image: NSImage) -> NSSize {
    NSSize(width: image.representations[0].pixelsWide, height: image.representations[0].pixelsHigh)
}
let base = pixels(windows[0])
let scale = min(1, size.width * 0.92 / base.width, size.height * 0.92 / base.height)

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
for window in windows {
    let drawn = NSSize(width: pixels(window).width * scale, height: pixels(window).height * scale)
    window.draw(in: NSRect(x: (size.width - drawn.width) / 2, y: (size.height - drawn.height) / 2,
                           width: drawn.width, height: drawn.height),
                from: .zero, operation: .sourceOver, fraction: 1)
}
NSGraphicsContext.restoreGraphicsState()

try! canvas.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[1]))
