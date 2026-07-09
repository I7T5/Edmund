#if DEBUG
import AppKit
import EdmundCore

/// In-process repro driver: `-debug.reproScript <path>` replays a keystroke
/// script against the front document through the real AppKit key-event path
/// (window.sendEvent → keyDown → interpretKeyEvents → insertText /
/// deleteBackward). Exists because TCC-denied automation sessions cannot post
/// CGEvents at the app; this keeps live-app bug repros scriptable without
/// Accessibility permission. Commands, one per line:
///   sleep <ms>        wait before the next command
///   caret <needle>    place the caret before the first occurrence of <needle>
///   type <text>       type text, one key event per character
///   backspace <n>     press delete n times (300ms apart)
///   scroll <y>        scroll the clip view to y (bypasses the caret/typewriter
///                     recentering, so a block can be driven off-screen)
///   logsel            log the current selection
@MainActor
enum ReproScript {

    static func runIfRequested() {
        guard let path = UserDefaults.standard.string(forKey: "debug.reproScript"),
              let script = try? String(contentsOfFile: path, encoding: .utf8) else { return }
        Log.info("repro script: \(path)", category: .app)
        var delay: TimeInterval = 1.5   // let the document finish opening
        for line in script.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
            guard let cmd = parts.first, !cmd.hasPrefix("#") else { continue }
            let arg = parts.count > 1 ? parts[1] : ""
            switch cmd {
            case "sleep":
                delay += (Double(arg) ?? 0) / 1000
            case "caret":
                schedule(after: delay) { editor in
                    let r = (editor.rawSource as NSString).range(of: arg)
                    guard r.location != NSNotFound else {
                        Log.info("repro caret: needle not found: \(arg)", category: .app)
                        return
                    }
                    editor.setSelectedRange(NSRange(location: r.location, length: 0))
                }
            case "caretoff":
                // Absolute-offset caret move (arrow-key-like: fromMouse=false).
                schedule(after: delay) { editor in
                    let n = min(Int(arg) ?? 0, (editor.rawSource as NSString).length)
                    editor.setSelectedRange(NSRange(location: n, length: 0))
                }
            case "clickoff":
                // Absolute-offset caret move on the MOUSE path: sets
                // suppressTypewriterCentering for the selection change so the
                // +SelectionTracking restyle captures fromMouse=true and takes
                // the preservingViewportAnchor branch (what a real click does).
                schedule(after: delay) { editor in
                    editor.reproClickSelect(Int(arg) ?? 0)
                }
            case "realclickoff":
                // Absolute-offset caret move via a REAL synthesized mouse click
                // at the glyph's on-screen position: goes through hit-testing and
                // NSTextView.mouseDown, the genuine mouse path (fromMouse=true),
                // which programmatic setSelectedRange does not replicate. Needed
                // because faithful keystroke replay alone does not arm the
                // round-7 drift — the arming caret moves were real clicks.
                schedule(after: delay) { editor in
                    let n = min(Int(arg) ?? 0, (editor.rawSource as NSString).length)
                    var actual = NSRange()
                    let scr = editor.firstRect(forCharacterRange: NSRange(location: n, length: 0),
                                               actualRange: &actual)
                    guard let screen = editor.window?.screen else { return }
                    // firstRect: Cocoa screen coords (origin bottom-left). CGEvent
                    // wants top-left origin.
                    let cocoaPt = CGPoint(x: scr.midX, y: scr.midY)
                    let p = CGPoint(x: cocoaPt.x, y: screen.frame.maxY - cocoaPt.y)
                    func post(_ t: CGEventType) {
                        CGEvent(mouseEventSource: nil, mouseType: t, mouseCursorPosition: p,
                                mouseButton: .left)?.post(tap: .cghidEventTap)
                    }
                    post(.mouseMoved); post(.leftMouseDown); post(.leftMouseUp)
                }
            case "selrange":
                // "selrange N M" — select M chars at offset N.
                schedule(after: delay) { editor in
                    let f = arg.split(separator: " ")
                    guard f.count == 2, let n = Int(f[0]), let m = Int(f[1]) else { return }
                    editor.setSelectedRange(NSRange(location: n, length: m))
                }
            case "caretend":
                // Place the caret at the very end of the document (the phantom
                // empty final line when rawSource ends in "\n"). Needles can't
                // target an empty line, so this is the only way to sit there.
                schedule(after: delay) { editor in
                    let end = (editor.rawSource as NSString).length
                    editor.setSelectedRange(NSRange(location: end, length: 0))
                }
            case "type":
                for ch in arg {
                    let s = String(ch)
                    // Direct action call (not a synthesized NSEvent through the
                    // input context): the storage mutation + queued-fixup path is
                    // identical, but avoids the input-context fragility that a
                    // long scripted replay hits when programmatic selections and
                    // synthetic key events interleave.
                    schedule(after: delay) { $0.insertText(s, replacementRange: NSRange(location: NSNotFound, length: 0)) }
                    delay += 0.08
                }
            case "backspace":
                for _ in 0 ..< (Int(arg) ?? 1) {
                    schedule(after: delay) { $0.deleteBackward(nil) }
                    delay += 0.3
                }
            case "return":
                schedule(after: delay) { $0.insertText("\n", replacementRange: NSRange(location: NSNotFound, length: 0)) }
                delay += 0.05
            case "bypassdelete":
                // Mimics AppKit's drag-move source deletion (the issue-#156
                // trigger): select the range, run shouldChangeText and the
                // storage mutation, and never call didChangeText — the
                // bypassed-edit heal then fires on the next run-loop pass.
                schedule(after: delay) { editor in
                    let r = (editor.rawSource as NSString).range(of: arg)
                    guard r.location != NSNotFound else {
                        Log.info("repro bypassdelete: needle not found: \(arg)", category: .app)
                        return
                    }
                    editor.setSelectedRange(r)
                    guard editor.shouldChangeText(in: r, replacementString: "") else { return }
                    editor.textStorage?.replaceCharacters(in: r, with: "")
                }
            case "bypassoff":
                // "bypassoff N M" — offset form of bypassdelete: delete M chars
                // at N via shouldChangeText + storage mutation, no didChangeText.
                schedule(after: delay) { editor in
                    let f = arg.split(separator: " ")
                    guard f.count == 2, let n = Int(f[0]), let m = Int(f[1]) else { return }
                    let r = NSRange(location: n, length: m)
                    editor.setSelectedRange(r)
                    guard editor.shouldChangeText(in: r, replacementString: "") else { return }
                    editor.textStorage?.replaceCharacters(in: r, with: "")
                }
            case "assertcaret":
                // PASS iff the caret sits exactly before the first occurrence
                // of <needle> — position-independent drift check for soaks.
                schedule(after: delay) { editor in
                    let want = (editor.rawSource as NSString).range(of: arg).location
                    let sel = editor.selectedRange()
                    let ok = sel.location == want && sel.length == 0
                    Log.info("repro assertcaret \(ok ? "PASS" : "FAIL") " +
                             "sel=\(sel) want=\(want) needle=\(arg)", category: .app)
                }
            case "logsel":
                schedule(after: delay) { editor in
                    Log.info("repro logsel sel=\(editor.selectedRange()) " +
                             "rawLen=\((editor.rawSource as NSString).length) " +
                             "docs=\(NSDocumentController.shared.documents.count)",
                             category: .app)
                }
            case "scroll":
                // Scrolls the clip view directly (bypassing the caret, so the
                // active block can be driven off-screen independent of where
                // typewriter-mode recentering would otherwise put it).
                // `scroll(to:)` posts boundsDidChange, same as a real drag/wheel
                // scroll, so promotion/idle-drain react exactly as they would live.
                schedule(after: delay) { editor in
                    guard let clipView = editor.enclosingScrollView?.contentView else { return }
                    let y = CGFloat(Double(arg) ?? 0)
                    let proposed = NSRect(origin: NSPoint(x: 0, y: y), size: clipView.bounds.size)
                    let clamped = clipView.constrainBoundsRect(proposed)
                    clipView.scroll(to: clamped.origin)
                    editor.enclosingScrollView?.reflectScrolledClipView(clipView)
                    Log.info("repro scroll y=\(y) clamped=\(clamped.origin.y)", category: .app)
                }
            default:
                break
            }
            delay += 0.02
        }
    }

    private static func schedule(after: TimeInterval,
                                 _ body: @escaping @MainActor (EditorTextView) -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + after) {
            guard let doc = NSDocumentController.shared.documents.first as? Document,
                  let editor = doc.editor else { return }
            body(editor)
        }
    }

    /// Sends a key event through the window so it takes the full AppKit
    /// keyDown route, exactly like a physical keystroke.
    private static func press(_ chars: String, keyCode: UInt16, in editor: EditorTextView) {
        guard let window = editor.window,
              let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                           timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: window.windowNumber, context: nil,
                                           characters: chars, charactersIgnoringModifiers: chars,
                                           isARepeat: false, keyCode: keyCode) else { return }
        window.makeFirstResponder(editor)
        window.sendEvent(event)
    }
}
#endif
