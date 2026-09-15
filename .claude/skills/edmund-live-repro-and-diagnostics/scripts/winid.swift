// winid.swift — print CGWindow ids for a process, newest first.
//
//   swift winid.swift <pid> [title]
//
// With a title, prints just that window's id; without, prints
// "id=<n> name=<title> X= Y= W= H=" for every window the pid owns.
//
// Why Swift and not JXA: `ObjC.deepUnwrap($.CGWindowListCopyWindowInfo(...))`
// returns something with no `.length` under osascript — the CoreGraphics
// bridge does not carry this call, so the JS route reports nothing at all
// rather than failing loudly. Verified broken 2026-07-26.
//
// Uses .optionAll, NOT .optionOnScreenOnly: a freshly launched app that has
// not been activated yet owns windows that onScreenOnly omits entirely, so
// the on-screen filter makes a just-launched app look windowless.
import CoreGraphics
import Foundation

let args = CommandLine.arguments
guard args.count > 1, let pid = Int32(args[1]) else {
    FileHandle.standardError.write("usage: swift winid.swift <pid> [title]\n".data(using: .utf8)!)
    exit(64)
}
let wanted: String? = args.count > 2 ? args[2] : nil

let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
for w in list {
    guard (w[kCGWindowOwnerPID as String] as? Int32) == pid else { continue }
    let id = w[kCGWindowNumber as String] as? Int ?? -1
    let name = w[kCGWindowName as String] as? String ?? ""
    if let wanted {
        if name == wanted { print(id); exit(0) }
        continue
    }
    let b = w[kCGWindowBounds as String] as? [String: Any] ?? [:]
    print("id=\(id) name=\(name) X=\(b["X"] ?? "") Y=\(b["Y"] ?? "") W=\(b["Width"] ?? "") H=\(b["Height"] ?? "")")
}
