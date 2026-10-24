// Captures every on-screen window of a process — a document window and the
// menu open over it — each with its shadow (`screencapture -l`), and stacks
// them at their screen positions into one transparent PNG, for compose.swift
// to treat like a single window. A menu is a window of its own, so a capture
// of the document window alone leaves it out.
//
// Usage: stack.swift <out.png> <pid> <window id>...
// The given windows (the document's, from `logwindows`) plus whatever of the
// process is on screen (the menu). The document window can sit on a Space
// that isn't showing, which the on-screen list leaves out but
// `screencapture -l` still draws.
import AppKit

let args = CommandLine.arguments
guard args.count >= 3, let pid = Int32(args[2]) else {
    FileHandle.standardError.write("usage: stack.swift <out.png> <pid> <window id>...\n".data(using: .utf8)!)
    exit(2)
}
let given = Set(args.dropFirst(3).compactMap { Int($0) })
let info = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
// Back to front: the list comes front to back.
let mine = info.filter { window in
    guard (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
          let id = (window[kCGWindowNumber as String] as? NSNumber)?.intValue else { return false }
    return given.contains(id) || (window[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue == true
}.reversed()

struct Layer { var image: NSBitmapImageRep; var frame: CGRect; var inset: CGPoint }
var layers: [Layer] = []
for window in mine {
    guard let id = (window[kCGWindowNumber as String] as? NSNumber)?.intValue,
          let bounds = window[kCGWindowBounds as String],
          let frame = CGRect(dictionaryRepresentation: bounds as! CFDictionary),
          frame.width > 1, frame.height > 1 else { continue }
    let file = NSTemporaryDirectory() + "stack-\(id).png"
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    p.arguments = ["-x", "-l", "\(id)", file]
    try? p.run(); p.waitUntilExit()
    guard let rep = NSImage(contentsOfFile: file)?.representations.first as? NSBitmapImageRep else { continue }
    // Where the window sits inside its capture: the shadow is uneven (deeper
    // below), so find the first opaque pixel along the middle row and column.
    func opaque(_ x: Int, _ y: Int) -> Bool { (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.99 }
    let midX = rep.pixelsWide / 2, midY = rep.pixelsHigh / 2
    let left = (0..<rep.pixelsWide).first { opaque($0, midY) } ?? 0
    let top = (0..<rep.pixelsHigh).first { opaque(midX, $0) } ?? 0
    layers.append(Layer(image: rep, frame: frame, inset: CGPoint(x: left, y: top)))
}
guard !layers.isEmpty else {
    let owners = info.map { "\($0[kCGWindowOwnerName as String] ?? "?")/\($0[kCGWindowOwnerPID as String] ?? "?")" }
    FileHandle.standardError.write("no windows for \(pid); on screen: \(Set(owners).sorted())\n".data(using: .utf8)!)
    exit(1)
}

// Captures are 2x: a window's capture origin is its screen origin (points × 2)
// less the shadow inset. The canvas spans every capture.
let scale = 2.0
let origins = layers.map { CGPoint(x: $0.frame.minX * scale - $0.inset.x, y: $0.frame.minY * scale - $0.inset.y) }
let minX = origins.map(\.x).min()!, minY = origins.map(\.y).min()!
let maxX = zip(layers, origins).map { $1.x + Double($0.image.pixelsWide) }.max()!
let maxY = zip(layers, origins).map { $1.y + Double($0.image.pixelsHigh) }.max()!
let canvas = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(maxX - minX), pixelsHigh: Int(maxY - minY),
                              bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                              colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 32)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: canvas)
for (layer, origin) in zip(layers, origins) {
    let w = Double(layer.image.pixelsWide), h = Double(layer.image.pixelsHigh)
    // AppKit's y runs up; screen y runs down.
    layer.image.draw(in: NSRect(x: origin.x - minX, y: (maxY - minY) - (origin.y - minY) - h, width: w, height: h),
                     from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: false, hints: nil)
}
NSGraphicsContext.restoreGraphicsState()
try! canvas.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[1]))
