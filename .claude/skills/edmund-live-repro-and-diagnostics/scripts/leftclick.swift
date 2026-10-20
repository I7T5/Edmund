// leftclick.swift — post a real left-mouse-down/up at screen coordinates.
// For chrome no in-process driver reaches — a Settings sheet's own buttons,
// where ReproScript's `realclick` (document-view coordinates) cannot aim.
// The sibling of rightclick.swift; same HID path (edmund-live-repro §4).
//
//   swift leftclick.swift <pid> <x> <y> [<x> <y> …]   # screen points, top-left origin
//
// Refuses to click unless the topmost normal window under the point belongs
// to <pid>: a HID click lands on whatever is on top, and an unchecked run once
// clicked into another app because the target had not come to the front.
// Several points click in order, 400 ms apart, so a two-step interaction
// (press +, then −) runs without a shell round-trip between the clicks.
import Cocoa

let args = CommandLine.arguments.dropFirst()
guard let pid = args.first.flatMap({ Int32($0) }) else {
    FileHandle.standardError.write("usage: leftclick.swift <pid> <x> <y> [<x> <y> …]\n".data(using: .utf8)!)
    exit(64)
}
let nums = args.dropFirst().compactMap(Double.init)
guard nums.count >= 2, nums.count % 2 == 0 else {
    FileHandle.standardError.write("usage: leftclick.swift <pid> <x> <y> [<x> <y> …]\n".data(using: .utf8)!)
    exit(64)
}

/// The owner pid of the topmost on-screen normal window containing `p`.
func ownerOfTopWindow(at p: CGPoint) -> Int32? {
    let infos = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                           kCGNullWindowID) as? [[String: Any]] ?? []
    for info in infos {
        // Normal (0) and floating (3) layers; the menu bar and Dock sit higher.
        guard (info[kCGWindowLayer as String] as? Int ?? 99) <= 3,
              let b = info[kCGWindowBounds as String] as? [String: Any],
              let r = CGRect(dictionaryRepresentation: b as CFDictionary),
              r.contains(p) else { continue }
        return info[kCGWindowOwnerPID as String] as? Int32
    }
    return nil
}

for i in stride(from: 0, to: nums.count, by: 2) {
    let p = CGPoint(x: nums[i], y: nums[i + 1])
    let owner = ownerOfTopWindow(at: p)
    guard owner == pid else {
        print("REFUSED at \(Int(p.x)),\(Int(p.y)): topmost window belongs to pid \(owner.map(String.init) ?? "none"), not \(pid)")
        exit(3)
    }
    for type in [CGEventType.mouseMoved, .leftMouseDown, .leftMouseUp] {
        guard let ev = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: p,
                               mouseButton: .left) else {
            FileHandle.standardError.write("event creation failed\n".data(using: .utf8)!)
            exit(1)
        }
        ev.post(tap: .cghidEventTap)
        usleep(60_000)
    }
    print("clicked at \(Int(p.x)),\(Int(p.y))")
    usleep(400_000)
}
