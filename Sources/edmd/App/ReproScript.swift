#if DEBUG
import AppKit
import EdmundCore
import WebKit

/// In-process repro driver: `-debug.reproScript <path>` replays a keystroke
/// script against the front document through the real AppKit key-event path
/// (window.sendEvent → keyDown → interpretKeyEvents → insertText /
/// deleteBackward). Exists because TCC-denied automation sessions cannot post
/// CGEvents at the app; this keeps live-app bug repros scriptable without
/// Accessibility permission. Commands, one per line:
///   sleep <ms>        wait before the next command
///   caret <needle>    place the caret before the first occurrence of <needle>
///   selectoff <n> <len>  select an absolute range (chrome that reacts to a
///                     selection, not just a caret)
///   type <text>       type text, one key event per character
///   backspace <n>     press delete n times (300ms apart)
///   tab / backtab     indent / dedent the selected list line(s)
///   scroll <y>        scroll the clip view to y (bypasses the caret/typewriter
///                     recentering, so a block can be driven off-screen)
///   logsel            log the current selection
///   viewmode          toggle Edit ↔ Read via the same action as ⌘E
///   readscroll <y>    raw-scroll the Read-mode webview to y
///   logstate          NSLog view-swap state (mode, hidden flags, clip y,
///                     webview scrollTop) for mode-switch harness debugging
///   logtoolbar        log every toolbar item's identifier and enabled state
///   logwindows        log each visible window's id, for `screencapture -l`
///   clicktoolbar <id> click a toolbar item by identifier (real target/action)
///   clickrow <title>  press a format-popover row by its title
///   clickicon <id>    press a format-popover icon button by its style id
///   assertsource <s>  PASS iff <s> appears in the document
@MainActor
enum ReproScript {

    static func runIfRequested() {
        guard let path = UserDefaults.standard.string(forKey: "debug.reproScript"),
              let script = try? String(contentsOfFile: path, encoding: .utf8) else { return }
        Log.info("repro script: \(path)", category: .app)
        reportPath = path + ".log"
        try? "".write(toFile: path + ".log", atomically: true, encoding: .utf8)
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
            case "selectoff":
                // "<location> <length>" — an absolute selection, for checking
                // what a range (not just a caret) does to the chrome.
                schedule(after: delay) { editor in
                    let parts = arg.split(separator: " ").compactMap { Int($0) }
                    guard parts.count == 2 else { return }
                    let length = (editor.rawSource as NSString).length
                    let location = min(parts[0], length)
                    editor.setSelectedRange(NSRange(location: location,
                                                    length: min(parts[1], length - location)))
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
            case "tab":
                schedule(after: delay) { $0.insertTab(nil) }
                delay += 0.05
            case "backtab":
                schedule(after: delay) { $0.insertBacktab(nil) }
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
                    report("repro logsel sel=\(editor.selectedRange()) " +
                           "rawLen=\((editor.rawSource as NSString).length) " +
                           "docs=\(NSDocumentController.shared.documents.count)")
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
            case "viewmode":
                // Toggles Edit ↔ Read through the same @objc action the ⌘E
                // menu item fires, so the switch takes the real code path.
                scheduleDoc(after: delay) { doc in
                    doc.toggleViewMode(nil)
                    Log.info("repro viewmode toggled", category: .app)
                }
            case "readscroll":
                // Raw-scrolls the Read-mode webview to y (simulates the user
                // scrolling while reading — arbitrary position, independent of
                // the block anchors the scroll-sync bridge uses).
                scheduleDoc(after: delay) { doc in
                    guard let content = doc.windowControllers.first?.window?.contentView,
                          let web = firstWebView(in: content) else {
                        Log.info("repro readscroll: no webview", category: .app); return
                    }
                    let y = Double(arg) ?? 0
                    web.evaluateJavaScript("document.scrollingElement.scrollTop = \(y)",
                                           completionHandler: nil)
                    Log.info("repro readscroll y=\(y)", category: .app)
                }
            case "logstate":
                // Dumps view-swap state to stdout (shell-visible even when the
                // file logger is off) for mode-switch harness debugging.
                scheduleDoc(after: delay) { doc in
                    let editor = doc.editor!
                    let sv = editor.enclosingScrollView
                    let web = doc.windowControllers.first?.window?.contentView
                        .flatMap { firstWebView(in: $0) }
                    NSLog("STATE mode=\(editor.viewMode) " +
                          "scrollHidden=\(sv?.isHidden ?? false) " +
                          "webHidden=\(web?.isHidden ?? true) webNil=\(web == nil) " +
                          "clipY=\(sv?.contentView.bounds.origin.y ?? -1) " +
                          "winKey=\(editor.window?.isKeyWindow ?? false) " +
                          "occl=\(editor.window?.occlusionState.contains(.visible) ?? false)")
                    let off = editor.topmostVisibleCharacterOffset()
                    let line = off.map { editor.line(forOffset: $0) }
                    let spans = ReadModeAnchors.topLevelBlockSpans(for: editor.rawSource)
                    let span = line.flatMap { l in spans.last(where: { $0.startLine <= l }) }
                    NSLog("MAP off=\(off ?? -1) line=\(line ?? -1) span=\(span.map { "\($0.startLine)-\($0.endLine)" } ?? "nil") spans=\(spans.count)")
                    (web as? ReadModeWebView)?.readScrollPosition { pos in
                        NSLog("READPOS \(pos.map { "line=\($0.line) f=\($0.fraction)" } ?? "nil")")
                    }
                    web?.evaluateJavaScript("document.scrollingElement.scrollTop + ',' + document.body.childElementCount") { v, e in
                        NSLog("WEBSTATE \(v.map(String.init(describing:)) ?? "nil") err=\(e.map(String.init(describing:)) ?? "none")")
                    }
                }
            case "logwindows":
                // `NSWindow.windowNumber` is the CGWindowID `screencapture -l`
                // takes. Reporting it is the only way to grab a window from a
                // script here: a freshly built tool has no Screen Recording grant
                // of its own, so it cannot look the id up from outside.
                schedule(after: delay) { _ in
                    for window in NSApp?.windows ?? [] where window.isVisible {
                        report("repro window \(window.windowNumber) " +
                               "\(type(of: window)) frame=\(window.frame)")
                    }
                }
            case "logtoolbar":
                scheduleDoc(after: delay) { doc in
                    let window = doc.windowControllers.first?.window
                    let target = NSApp?.target(forAction: #selector(EditorTextView.formatChecklist(_:)))
                    report("repro responders active=\(NSApp?.isActive ?? false) " +
                           "keyIsDoc=\(NSApp?.keyWindow === window) " +
                           "key=\(NSApp?.keyWindow.map { String(describing: type(of: $0)) } ?? "nil") " +
                           "first=\(window?.firstResponder.map { String(describing: type(of: $0)) } ?? "nil") " +
                           "target=\(target.map { String(describing: type(of: $0)) } ?? "nil")")
                    for item in window?.toolbar?.items ?? [] {
                        item.validate()
                        // A custom-view item's own `isEnabled` is not what draws;
                        // the button inside it is. Nil-target items validate off the
                        // key window, which a script-launched app never has, so ask
                        // this window's first responder instead.
                        let on: Bool
                        if let control = item.view as? NSControl {
                            on = control.isEnabled
                        } else if let validator = window?.firstResponder as? NSToolbarItemValidation {
                            on = validator.validateToolbarItem(item)
                        } else {
                            on = item.isEnabled
                        }
                        // The tooltip too: hovering an item to read one cannot be
                        // driven from here, so this is the only way to check it.
                        let tip = (item.view as? NSView)?.toolTip ?? item.toolTip
                        report("repro toolbar \(item.itemIdentifier.rawValue) " +
                               "enabled=\(on) tip=\(tip ?? "nil")")
                    }
                }
            case "clicktoolbar":
                scheduleDoc(after: delay) { doc in
                    guard let item = doc.windowControllers.first?.window?.toolbar?
                        .items.first(where: { $0.itemIdentifier.rawValue == arg }) else {
                        report("repro clicktoolbar: no item \(arg)"); return
                    }
                    item.validate()
                    if let button = item.view as? NSButton {
                        report("repro clicktoolbar \(arg) enabled=\(button.isEnabled)")
                        button.performClick(nil)
                    } else if let action = item.action {
                        // A script-launched binary never becomes the active app, so
                        // `NSApp.keyWindow` is nil and `sendAction` — which starts
                        // from the key window — finds nobody. Walking this window's
                        // own responder chain is what a real click would reach.
                        // …and the chain starts at the first responder, not at the
                        // window: `NSWindow.tryToPerform` walks its own nextResponder.
                        let window = doc.windowControllers.first?.window
                        let sent = window?.firstResponder?.tryToPerform(action, with: item) ?? false
                        report("repro clicktoolbar \(arg) sent=\(sent)")
                    } else {
                        report("repro clicktoolbar \(arg) has no button and no action")
                    }
                }
            case "clickrow":
                scheduleDoc(after: delay) { _ in
                    guard let row = findInPopover({ ($0 as? FormatPopoverRow)?.item.title == arg })
                            as? FormatPopoverRow else {
                        report("repro clickrow: no row titled \(arg)"); return
                    }
                    report("repro clickrow \(arg) enabled=\(row.isEnabled)")
                    _ = row.accessibilityPerformPress()
                }
            case "clickicon":
                scheduleDoc(after: delay) { _ in
                    guard let button = findInPopover({
                        (($0 as? FormatIconButton)?.target as? FormatIconTarget)?.styleID == arg
                    }) as? FormatIconButton else {
                        report("repro clickicon: no button for \(arg)"); return
                    }
                    report("repro clickicon \(arg) enabled=\(button.isEnabled)")
                    button.performClick(nil)
                }
            case "assertsource":
                schedule(after: delay) { editor in
                    let ok = (editor.rawSource as NSString).range(of: arg).location != NSNotFound
                    report("repro assertsource \(ok ? "PASS" : "FAIL") needle=\(arg)")
                }
            default:
                break
            }
            delay += 0.02
        }
    }

    /// Where a run's results are written: `<script>.log`, next to the script.
    private static var reportPath: String?

    /// Results go to a file of their own. The daily log is shared with every
    /// other running instance, and NSLog does not reach the redirected stderr of
    /// a bundle-less binary — so neither can be relied on to read a run back.
    private static func report(_ line: String) {
        Log.info(line, category: .app)
        guard let path = reportPath else { return }
        let data = Data((line + "\n").utf8)
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        }
    }

    private static func scheduleDoc(after: TimeInterval,
                                    _ body: @escaping @MainActor (Document) -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + after) {
            guard let doc = NSDocumentController.shared.documents.first as? Document else {
                report("repro: no document yet"); return
            }
            body(doc)
        }
    }

    /// First view in any open popover satisfying `match`. The popover keeps its
    /// own window, so it is reachable from `NSApp.windows` without the toolbar
    /// having to hand out a reference to it.
    private static func findInPopover(_ match: (NSView) -> Bool) -> NSView? {
        func search(_ view: NSView) -> NSView? {
            if match(view) { return view }
            for sub in view.subviews { if let hit = search(sub) { return hit } }
            return nil
        }
        for window in NSApp?.windows ?? [] {
            if let content = window.contentView, let hit = search(content) { return hit }
        }
        return nil
    }

    private static func firstWebView(in view: NSView) -> WKWebView? {
        if let web = view as? WKWebView { return web }
        for sub in view.subviews {
            if let web = firstWebView(in: sub) { return web }
        }
        return nil
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
