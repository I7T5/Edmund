// Places window captures (with their shadows, from `screencapture -l`) on a
// soft gradient, or on --background's image (scaled to fill, centre-cropped),
// at the Mac App Store's 2880×1800 screenshot size or --size's. Windows stack
// in order, all at one scale. With --offset dx,dy each window sits that
// fraction of the canvas right of and below the one before it — a cascade, or
// side by side — and the group as a whole is centred and scaled to fit.
// --layout "x,y x,y …" instead puts each window's centre at that fraction of
// the canvas. No alpha in the output: App Store Connect rejects it.
//
// One set of shots serves the App Store, the README and edmund.md. On its own
// it composes hand-taken captures too (⇧⌘4, Space, click a window — shadow
// included), e.g. a light and a dark window side by side for the README:
//   swift scripts/screenshots/compose.swift hero.png light --layout "0.38,0.42 0.62,0.58" \
//       --background ~/Pictures/wall.jpg dark.png light.png
//
// Usage: swift scripts/screenshots/compose.swift <out.png> light|dark [--size WxH]
//            [--offset dx,dy | --layout "x,y …"] [--background image] <window.png>...
import AppKit

var args = Array(CommandLine.arguments.dropFirst())
guard args.count >= 3 else {
    FileHandle.standardError.write("usage: compose.swift <out.png> light|dark [--size WxH] [--offset dx,dy | --layout \"x,y …\"] [--background image] <window.png>...\n".data(using: .utf8)!)
    exit(2)
}
let out = args.removeFirst()
let dark = args.removeFirst() == "dark"
var step = CGPoint.zero
var background: NSImage?
var layout: [CGPoint] = []
var size = NSSize(width: 2880, height: 1800)
while let flag = args.first, flag.hasPrefix("--") {
    if flag == "--size" {
        let wh = args[1].split(separator: "x").compactMap { Double($0) }
        size = NSSize(width: wh[0], height: wh[1])
    } else if flag == "--offset" {
        let parts = args[1].split(separator: ",").compactMap { Double($0) }
        step = CGPoint(x: parts[0], y: parts[1])
    } else if flag == "--layout" {
        layout = args[1].split(separator: " ").map { pair in
            let xy = pair.split(separator: ",").compactMap { Double($0) }
            return CGPoint(x: xy[0], y: xy[1])
        }
    } else if flag == "--background" {
        background = NSImage(contentsOfFile: args[1])
    }
    args.removeFirst(2)
}
let windows = args.map { NSImage(contentsOfFile: $0)! }

// Pixels, not points: an NSImage from a Retina capture reports half its size.
func pixels(_ image: NSImage) -> NSSize {
    NSSize(width: image.representations[0].pixelsWide, height: image.representations[0].pixelsHigh)
}
// Window centres, in canvas pixels, y down; the group's middle on the canvas's.
let middle = Double(windows.count - 1) / 2
let centres = windows.indices.map { i in
    i < layout.count
        ? CGPoint(x: layout[i].x * size.width, y: layout[i].y * size.height)
        : CGPoint(x: size.width / 2 + (Double(i) - middle) * step.x * size.width,
                  y: size.height / 2 + (Double(i) - middle) * step.y * size.height)
}
// The largest scale that keeps every window 4% inside each edge. Up to 1.6×: a
// small window scaled up is how the text gets big enough to read in the Store
// (Settings can't zoom), and a 2× capture at 1.6× is still sharper than the
// Store ever displays it. A larger --size raises the cap with it.
var scale = 1.6 * size.width / 2880
for (window, centre) in zip(windows, centres) {
    let p = pixels(window)
    scale = min(scale,
                (size.width * 0.92 / 2 - abs(centre.x - size.width / 2)) * 2 / p.width,
                (size.height * 0.92 / 2 - abs(centre.y - size.height / 2)) * 2 / p.height)
}

// No alpha channel: App Store Connect rejects screenshots that have one.
let canvas = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                              bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false,
                              colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 32)!
canvas.size = size
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: canvas)
NSGraphicsContext.current?.imageInterpolation = .high
let top = dark ? NSColor(srgbRed: 0.20, green: 0.20, blue: 0.22, alpha: 1)
               : NSColor(srgbRed: 0.97, green: 0.97, blue: 0.98, alpha: 1)
let bottom = dark ? NSColor(srgbRed: 0.10, green: 0.10, blue: 0.11, alpha: 1)
                  : NSColor(srgbRed: 0.88, green: 0.89, blue: 0.92, alpha: 1)
NSGradient(starting: top, ending: bottom)!.draw(in: NSRect(origin: .zero, size: size), angle: -90)
if let background {
    // Aspect fill: the larger of the two ratios covers the canvas; the rest is cropped evenly.
    let p = pixels(background)
    let fill = max(size.width / p.width, size.height / p.height)
    let drawn = NSSize(width: p.width * fill, height: p.height * fill)
    background.draw(in: NSRect(x: (size.width - drawn.width) / 2, y: (size.height - drawn.height) / 2,
                               width: drawn.width, height: drawn.height),
                    from: .zero, operation: .copy, fraction: 1)
}
for (window, centre) in zip(windows, centres) {
    let drawn = NSSize(width: pixels(window).width * scale, height: pixels(window).height * scale)
    // AppKit's y runs up; the centres were laid out top-down.
    window.draw(in: NSRect(x: centre.x - drawn.width / 2, y: size.height - centre.y - drawn.height / 2,
                           width: drawn.width, height: drawn.height),
                from: .zero, operation: .sourceOver, fraction: 1)
}
NSGraphicsContext.restoreGraphicsState()

try! canvas.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
