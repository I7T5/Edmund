// axfind.swift — dump or press AX elements of any process's windows, WITHOUT
// activating the app. System Events cannot enumerate a background process's
// windows ("can't get window … until activated once"); the AX C API can, and
// AXPress/AXShowMenu land on background windows fine.
//
//   swift axfind.swift <pid> <windowTitle> --dump
//   swift axfind.swift <pid> <windowTitle> --press <title>
//   swift axfind.swift <pid> <windowTitle> --showmenu <title>
//
// Exit 3 when the window or the target is not found (the caller's signal that
// the UI did not reach the expected state — never silently succeed).
import Cocoa

let args = CommandLine.arguments
guard args.count > 3, let pid = Int32(args[1]) else {
    FileHandle.standardError.write("usage: axfind.swift <pid> <windowTitle> --dump|--press <t>|--showmenu <t>\n".data(using: .utf8)!)
    exit(64)
}
let windowTitle = args[2]
let mode = args[3]
let target = args.count > 4 ? args[4] : nil

func attr<T>(_ el: AXUIElement, _ name: String) -> T? {
    var v: CFTypeRef?
    guard AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success else { return nil }
    return v as? T
}

func actions(_ el: AXUIElement) -> [String] {
    var names: CFArray?
    guard AXUIElementCopyActionNames(el, &names) == .success else { return [] }
    return (names as? [String]) ?? []
}

func point(_ el: AXUIElement) -> CGPoint {
    guard let v: AXValue = attr(el, kAXPositionAttribute) else { return .zero }
    var p = CGPoint.zero
    AXValueGetValue(v, .cgPoint, &p)
    return p
}

func size(_ el: AXUIElement) -> CGSize {
    guard let v: AXValue = attr(el, kAXSizeAttribute) else { return .zero }
    var s = CGSize.zero
    AXValueGetValue(v, .cgSize, &s)
    return s
}

let app = AXUIElementCreateApplication(pid)
guard let windows: [AXUIElement] = attr(app, kAXWindowsAttribute) else {
    FileHandle.standardError.write("no windows\n".data(using: .utf8)!)
    exit(3)
}
guard let win = windows.first(where: { (attr($0, kAXTitleAttribute) as String?) == windowTitle }) else {
    FileHandle.standardError.write("no window titled \(windowTitle); have: \(windows.compactMap { attr($0, kAXTitleAttribute) as String? })\n".data(using: .utf8)!)
    exit(3)
}

var hits: [(AXUIElement, String, String)] = []

func walk(_ el: AXUIElement, _ depth: Int) {
    let role: String = attr(el, kAXRoleAttribute) ?? "?"
    let title: String = attr(el, kAXTitleAttribute) ?? attr(el, kAXDescriptionAttribute) ?? ""
    if let target, title == target { hits.append((el, role, title)) }
    if mode == "--dump" {
        let p = point(el), s = size(el)
        print("\(String(repeating: "  ", count: depth))\(role) \"\(title)\" at (\(Int(p.x)),\(Int(p.y))) \(Int(s.width))x\(Int(s.height)) [\(actions(el).joined(separator: ","))]")
    }
    for child in (attr(el, kAXChildrenAttribute) as [AXUIElement]?) ?? [] {
        walk(child, depth + 1)
    }
}
walk(win, 0)

if mode == "--dump" { exit(0) }

// Among title matches, prefer elements that actually vend the requested
// action (the script rows' Select… carries AXShowMenu; the font rows' does
// not), then honor an optional trailing occurrence index.
let wanted = mode == "--showmenu" ? kAXShowMenuAction : kAXPressAction
let capable = hits.filter { actions($0.0).contains(wanted) }
let pool = capable.isEmpty ? hits : capable
let index = (args.count > 5 ? Int(args[5]) : nil) ?? 0
guard pool.indices.contains(index) else {
    FileHandle.standardError.write("no element titled \(target ?? "?") at index \(index) in \(windowTitle)\n".data(using: .utf8)!)
    exit(3)
}
let hit = pool[index]
let action = mode == "--showmenu" ? kAXShowMenuAction : kAXPressAction
let err = AXUIElementPerformAction(hit.0, action as CFString)
if err != .success {
    FileHandle.standardError.write("\(action) failed: \(err.rawValue)\n".data(using: .utf8)!)
    exit(3)
}
print("\(action) on \(hit.1) \"\(hit.2)\" at \(point(hit.0))")
