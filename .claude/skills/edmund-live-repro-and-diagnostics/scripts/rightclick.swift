// rightclick.swift — post a real right-mouse-down/up at screen coordinates.
// SwiftUI's .contextMenu does not reliably perform AXShowMenu on macOS 26
// (kAXErrorActionUnsupported despite listing the action); a context menu is a
// mouse-only path, so drive it with a real HID event — the repo's sanctioned
// fallback for mouse-shaped interactions (edmund-live-repro §4).
//
//   swift rightclick.swift <x> <y>     # screen points, global coordinates
import Cocoa

let args = CommandLine.arguments
guard args.count > 2, let x = Double(args[1]), let y = Double(args[2]) else {
    FileHandle.standardError.write("usage: rightclick.swift <x> <y>\n".data(using: .utf8)!)
    exit(64)
}
let p = CGPoint(x: x, y: y)
for type in [CGEventType.rightMouseDown, .rightMouseUp] {
    guard let ev = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: p, mouseButton: .right) else {
        FileHandle.standardError.write("event creation failed\n".data(using: .utf8)!)
        exit(1)
    }
    ev.post(tap: .cghidEventTap)
    usleep(60_000)
}
print("right-clicked at \(Int(x)),\(Int(y))")
