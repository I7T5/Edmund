#if DEBUG
import AppKit
import EdmundCore
import WebKit
import ScreenCaptureKit

/// In-process repro driver: `-debug.reproScript <path>` replays a keystroke
/// script against the front document through the real AppKit key-event path
/// (window.sendEvent → keyDown → interpretKeyEvents → insertText /
/// deleteBackward). Exists because TCC-denied automation sessions cannot post
/// CGEvents at the app; this keeps live-app bug repros scriptable without
/// Accessibility permission. Commands, one per line:
///   sleep <ms>        wait before the next command
///   caret <needle>    place the caret before the first occurrence of <needle>
///   hoveroff <n>      hover the glyph at offset n (reveals margin chrome)
///   copycode <n>      press the copy button of the code block at offset n
///   snapshot <path>   render the window content to a PNG in-process
///   selectoff <n> <len>  select an absolute range (chrome that reacts to a
///                     selection, not just a caret)
///   type <text>       type text, one key event per character
///   backspace <n>     press delete n times (300ms apart)
///   enter             press Return (insertNewline: list continuation, table rows)
///   shiftenter        press Shift-Return as a real key event (list soft break)
///   tab / backtab     indent / dedent the selected list line(s)
///   scroll <y>        scroll the clip view to y (bypasses the caret/typewriter
///                     recentering, so a block can be driven off-screen)
///   logsel            log the current selection
///   viewmode          toggle Edit ↔ Read via the same action as ⌘E
///   find on|off|replace  open/close the find bar (⌘F's own handler) without
///                     activating the app the way an AX-driven ⌘F would
///   readscroll <y>    raw-scroll the Read-mode webview to y
///   readclick <css>   click the first element matching a CSS selector in Read
///   logstate          NSLog view-swap state (mode, hidden flags, clip y,
///                     webview scrollTop) for mode-switch harness debugging
///   logtoolbar        log every toolbar item's identifier and enabled state
///   celltype <text>   type into the open table-cell card
///   logwindows        log each visible window's id, for `screencapture -l`
///   clicktoolbar <id> click a toolbar item by identifier (real target/action)
///   clickrow <title>  press a format-popover row by its title
///   clickicon <id>    press a format-popover icon button by its style id
///   handlemenu row|column  open a table handle's menu via its real hit test
///   cellmenu <needle>  right-click menu for the cell holding <needle>
///   selectcells r0,c0,r1,c1  select that block of table cells
///   ime <text>        compose <text> as marked text (NSTextInputClient)
///   imecommit [text]  commit the composition as <text> (empty: as marked)
///   undo / redo       the editor's own undo stack
///   dumpsource        write the document (newlines as \\n) and selection to the log
///   done              write `repro DONE pass=N fail=M` and exit (1 on any FAIL);
///                     a failing run dumps the source first
/// Assertions (each writes PASS/FAIL to `<script>.log`, counted by `done`):
///   assertsource <s>  <s> appears in the document
///   assertnot <s>     <s> does not appear
///   assertcaret <s>   caret sits right before the first <s>
///   assertsel N M     selection is exactly {N, M}
///   assertinvariants  storage == rawSource, blocks rebuild it, no open marked text
///   assertsourceorig  document equals what it opened with
///   assertsourcefile <f>  document equals file <f> (relative to the script)
/// An unknown command, or a caret/bypassdelete needle that isn't found, FAILs.
/// Run whole suites with `scripts/repro.sh` (Tests/Repro/).
@MainActor
enum ReproScript {

    static func runIfRequested() {
        guard let path = UserDefaults.standard.string(forKey: "debug.reproScript"),
              let script = try? String(contentsOfFile: path, encoding: .utf8) else { return }
        Log.info("repro script: \(path)", category: .app)
        reportPath = path + ".log"
        try? "".write(toFile: path + ".log", atomically: true, encoding: .utf8)
        var delay: TimeInterval = 1.5   // let the document finish opening
        schedule(after: delay) { editor in originalSource = editor.rawSource }
        let scriptDir = (path as NSString).deletingLastPathComponent
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
                        verdict("caret", false, "needle not found: \(arg)")
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
            case "hoveroff":
                // Hover pass at an absolute offset's glyph, without moving the
                // real pointer: reveals the margin chrome (a table's `</>`, a
                // code block's copy button) for a capture.
                schedule(after: delay) { editor in
                    editor.reproHover(atOffset: Int(arg) ?? 0)
                }
            case "snapshot":
                // Renders the window's content view to a PNG at <path>
                // in-process (`cacheDisplay`), so a capture is exact and never
                // a stale compositor frame — `screencapture -l` of a window that
                // is behind another returns whatever it last showed on screen.
                schedule(after: delay) { editor in
                    guard let view = editor.window?.contentView,
                          let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
                        report("repro snapshot: no content view"); return
                    }
                    view.cacheDisplay(in: view.bounds, to: rep)
                    guard let png = rep.representation(using: .png, properties: [:]) else { return }
                    try? png.write(to: URL(fileURLWithPath: arg))
                    report("repro snapshot \(arg)")
                }
            case "copycode":
                // Press the copy button of the code block at an absolute offset.
                schedule(after: delay) { editor in
                    editor.reproCopyCode(atOffset: Int(arg) ?? 0)
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
            case "enter":
                // The Return *key*, which AppKit routes to `insertNewline` — a
                // different path from `return` above, and the only one that
                // reaches list continuation and table row stepping.
                schedule(after: delay) { $0.insertNewline(nil) }
                delay += 0.05
            case "shiftenter":
                // Shift-Return as a real key event through the window, so it
                // takes the editor's keyDown route.
                schedule(after: delay) { press("\r", keyCode: 36, modifiers: .shift, in: $0) }
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
                        verdict("bypassdelete", false, "needle not found: \(arg)")
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
                    verdict("assertcaret", sel.location == want && sel.length == 0,
                            "sel=\(sel) want=\(want) needle=\(arg)")
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
            case "find":
                // Opens/closes the find bar through the same handler ⌘F fires.
                // `find on|off|replace`. The AX route (ui-harness.sh open-find)
                // activates the app, which takes the machine away from whoever
                // is using it — guard-focus-steal.sh denies it, so this is how a
                // harness gets the find bar up.
                scheduleDoc(after: delay) { doc in
                    guard let handler = doc.editor?.findHandler else {
                        Log.info("repro find: no find handler", category: .app); return
                    }
                    switch arg {
                    case "off":     handler.editorHideFind()
                    case "replace": handler.editorToggleFind(replace: true)
                    default:        handler.editorToggleFind(replace: false)
                    }
                    Log.info("repro find \(arg)", category: .app)
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
            case "readclick":
                // Clicks the first element matching a CSS selector in the
                // Read-mode webview. A synthetic `click()` on an `<a>` still
                // navigates, so a private-scheme link (`a.task-toggle`,
                // `a.code-copy-btn`) takes the real policy-delegate path.
                scheduleDoc(after: delay) { doc in
                    guard let content = doc.windowControllers.first?.window?.contentView,
                          let web = firstWebView(in: content) else {
                        Log.info("repro readclick: no webview", category: .app); return
                    }
                    let selector = arg.replacingOccurrences(of: "'", with: "\\'")
                    web.evaluateJavaScript("document.querySelector('\(selector)').click()",
                                           completionHandler: nil)
                    Log.info("repro readclick \(arg)", category: .app)
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
            case "cellpopup":
                // Opens the table cell editor on a raw offset, in-process. The
                // card is driven by a real mouse click in the app; there is no
                // way to synthesize one here that lands, because a background
                // app cannot take focus. This is the seam that lets the card be
                // seen at all from a script.
                schedule(after: delay) { editor in
                    guard let cell = editor.reproTableCell(atRawOffset: Int(arg) ?? 0) else {
                        report("repro cellpopup no cell at \(arg)")
                        return
                    }
                    editor.reproOpenTableCellEditor(cell)
                    report("repro cellpopup opened at \(arg)")
                }
            case "cellstep":
                // Tab / Shift-Tab equivalent: move the open card along the row.
                schedule(after: delay) { editor in
                    editor.reproStepTableCellEditor(by: Int(arg) ?? 1)
                    report("repro cellstep \(arg)")
                }
            case "celltype":
                // The card is key while it is up, so `type` — which aims at the
                // document's editor — would land in the wrong view.
                for ch in arg {
                    let s = String(ch)
                    schedule(after: delay) { $0.reproTypeInCellEditor(s) }
                    delay += 0.08
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
                        let tip = item.view?.toolTip ?? item.toolTip
                        report("repro toolbar \(item.itemIdentifier.rawValue) " +
                               "enabled=\(on) label=\(item.label) tip=\(tip ?? "nil")")
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
            case "handlemenu":
                // Opens a table row/column handle's menu through the real hit
                // test, at the pill's own centre. `popUp` runs its own event
                // loop, so nothing after this fires until the menu is dismissed.
                schedule(after: delay) { editor in
                    report("repro handlemenu \(arg) "
                        + editor.debugOpenTableHandleMenu(column: arg == "column"))
                }
            case "cellmenu":
                // The right-click menu for the cell holding <needle>, through
                // `menu(for:)` — so the cell outline and the appended Table
                // section come from the real path. Also modal; see above.
                schedule(after: delay) { editor in
                    report("repro cellmenu \(arg) " + editor.debugOpenTableCellMenu(needle: arg))
                }
            case "activate":
                // Makes the window key. AppKit draws an *unemphasized* selection
                // in an inactive window and ignores `selectedTextAttributes`
                // there, so anything about the selection's appearance has to be
                // checked with the window actually focused.
                //
                // Only works for an instance LaunchServices launched (`open -n
                // <bundle> --args …`, launch-debug.sh --front). macOS 14
                // activation is cooperative: a process the user did not launch
                // — a harness exec'ing the binary — is refused by
                // `NSApp.activate`, and neither `NSWorkspace.openApplication`
                // on its own bundle nor `open -a` will raise it afterwards
                // (both tried; `key=false` every time). The report line says
                // which case this run is in.
                schedule(after: delay) { editor in
                    NSApp.activate(ignoringOtherApps: true)
                    editor.window?.makeKeyAndOrderFront(nil)
                    editor.window?.makeFirstResponder(editor)
                    let key = editor.window?.isKeyWindow == true
                    report("repro activate key=\(key)"
                           + (key ? "" : " (exec'd binary cannot self-activate; launch with open -n / --front)"))
                }
            case "caretpositions":
                schedule(after: delay) { editor in
                    report("repro caretpositions " + editor.debugCaretPositions(needle: arg))
                }
            case "tablerules":
                schedule(after: delay) { editor in
                    report("repro tablerules\n" + editor.debugTableRules())
                }
            case "resizewindow":
                // "resizewindow w,h" — the window geometry is part of the
                // repro: column widths, and therefore the pad each cell
                // carries, come out of the content width.
                schedule(after: delay) { editor in
                    let n = arg.split(separator: ",").compactMap { Double($0) }
                    guard n.count == 2, let window = editor.window else {
                        report("repro resizewindow: want w,h"); return
                    }
                    var frame = window.frame
                    frame.size = NSSize(width: n[0], height: n[1])
                    window.setFrame(frame, display: true)
                    report("repro resizewindow \(window.frame.size)")
                }
            case "menuitems":
                // "menuitems row" / "menuitems column" — what is on a pill's
                // menu once it is on screen, injected entries included.
                schedule(after: delay) { editor in
                    report("repro menuitems " + editor.debugTableHandleMenuItems(
                        column: arg.hasPrefix("col")))
                }
            case "copyprobe":
                schedule(after: delay) { editor in
                    report("repro copyprobe " + editor.debugCopyProbe())
                }
            case "clickaudit":
                // Clicks every cell of every table and reports what came out
                // wrong. See `debugClickAudit`.
                schedule(after: delay) { editor in
                    let n = arg.split(separator: ",").compactMap { Int($0) }
                    let rows = n.count == 2 ? n[0]...n[1] : nil
                    report("repro clickaudit " + editor.debugClickAudit(rows: rows))
                }
            case "clickprobe":
                // "clickprobe x y" — a real click at a view point, with a
                // report of what every stage of `mouseDown` decided.
                schedule(after: delay) { editor in
                    let n = arg.split(separator: ",").compactMap { Double($0) }
                    guard n.count == 2 || n.count == 3 else {
                        report("repro clickprobe: want x,y[,clicks]"); return
                    }
                    report("repro clickprobe " + editor.debugClickProbe(
                        x: n[0], y: n[1], clicks: n.count == 3 ? Int(n[2]) : 1))
                }
            case "clickhold":
                // "clickhold x,y,ms" — a click whose mouse-up arrives `ms`
                // later, so frames paint during the gesture (see debugClickHold).
                schedule(after: delay) { editor in
                    let n = arg.split(separator: ",").compactMap { Double($0) }
                    guard n.count == 3 else { report("repro clickhold: want x,y,ms"); return }
                    report("repro clickhold " + editor.debugClickHold(x: n[0], y: n[1], holdMs: n[2]))
                }
            case "realclick":
                // "realclick x,y[,holdms]" — a REAL HID click (CGEvent) at a view
                // point: the genuine delivery path (WindowServer → sendEvent →
                // hit-test → mouseDown), which the in-process probes bypass.
                // Needs Accessibility trust for this process (prompts once).
                // The window is brought to the front and verified to be the
                // topmost window under the point first — a HID click lands on
                // whatever is on top, and that must never be someone else's window.
                schedule(after: delay) { editor in
                    let n = arg.split(separator: ",").compactMap { Double($0) }
                    guard (2...4).contains(n.count), let window = editor.window else {
                        report("repro realclick: want x,y[,holdms[,clicks]]"); return
                    }
                    let hold = n.count >= 3 ? n[2] : 80
                    // clickState: 2 makes AppKit see a double-click (clickCount 2).
                    let clicks = n.count == 4 ? Int64(n[3]) : 1
                    // Activation is asynchronous, and another app's window may
                    // overlap ours: float the window for the click's duration,
                    // and only check what is on top once that has taken effect.
                    window.level = .floating
                    let trusted = AXIsProcessTrustedWithOptions(
                        ["AXTrustedCheckOptionPrompt" as CFString: true] as CFDictionary)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    let cocoa = window.convertPoint(toScreen: editor.convert(NSPoint(x: n[0], y: n[1]), to: nil))
                    // CG coordinates: top-left of the PRIMARY display.
                    let primaryMaxY = NSScreen.screens.first?.frame.maxY ?? 0
                    let p = CGPoint(x: cocoa.x, y: primaryMaxY - cocoa.y)
                    // Topmost window at the point must be ours (the list is
                    // front-to-back; ours sits at the floating layer, so no
                    // layer filter — anything above it there is a real cover).
                    let infos = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                           kCGNullWindowID) as? [[String: Any]] ?? []
                    var top: (num: Int, owner: String)? = nil
                    for info in infos {
                        // Normal (0) and floating (3) windows only: the Dock and
                        // the menu bar sit higher and cover the whole screen edge.
                        guard (info[kCGWindowLayer as String] as? Int ?? 99) <= 3,
                              let b = info[kCGWindowBounds as String] as CFTypeRef?,
                              CFGetTypeID(b) == CFDictionaryGetTypeID(),
                              let r = CGRect(dictionaryRepresentation: b as! CFDictionary) else { continue }
                        if r.contains(p) {
                            top = (info[kCGWindowNumber as String] as? Int ?? -1,
                                   info[kCGWindowOwnerName as String] as? String ?? "?")
                            break
                        }
                    }
                    let ours = top?.num == window.windowNumber
                    let listed = infos.contains { ($0[kCGWindowNumber as String] as? Int) == window.windowNumber }
                    report("repro realclick t=\(EditorTextView.debugMs()) view=(\(Int(n[0])),\(Int(n[1])))"
                           + " cg=(\(Int(p.x)),\(Int(p.y))) trusted=\(trusted)"
                           + " top=\(top.map { "\($0.num) \($0.owner)" } ?? "none") ours=\(ours)"
                           + " ourWin=\(window.windowNumber) onScreen=\(listed) frame=\(window.frame)")
                    guard trusted, ours else {
                        window.level = .normal
                        report("repro realclick ABORTED"); return
                    }
                    let restore = NSEvent.mouseLocation
                    let restoreCG = CGPoint(x: restore.x, y: primaryMaxY - restore.y)
                    // Main-actor closure: Sendable, so the background thread can
                    // carry it without capturing the editor itself.
                    let finish: @MainActor () -> Void = {
                        window.level = .normal
                        report("repro realclick done t=\(EditorTextView.debugMs()) sel=\(editor.selectedRange())")
                    }
                    DispatchQueue.global(qos: .userInteractive).async {
                        func post(_ t: CGEventType) {
                            let e = CGEvent(mouseEventSource: nil, mouseType: t, mouseCursorPosition: p,
                                            mouseButton: .left)
                            if t != .mouseMoved { e?.setIntegerValueField(.mouseEventClickState, value: clicks) }
                            e?.post(tap: .cghidEventTap)
                        }
                        post(.mouseMoved); usleep(30_000)
                        post(.leftMouseDown); usleep(useconds_t(hold * 1000))
                        post(.leftMouseUp); usleep(30_000)
                        CGWarpMouseCursorPosition(restoreCG)
                        DispatchQueue.main.async { MainActor.assumeIsolated { finish() } }
                    }
                    }
                }
            case "realseq":
                // "realseq holdms,gapms,x1,y1,x2,y2,…" — a run of real HID
                // clicks from ONE thread with exact spacing and a mouse-move
                // trail between them, as a hand does. Click counts are left to
                // the system. Same topmost-window guard as `realclick`.
                schedule(after: delay) { editor in
                    let n = arg.split(separator: ",").compactMap { Double($0) }
                    guard n.count >= 4, n.count % 2 == 0, let window = editor.window else {
                        report("repro realseq: want holdms,gapms,x1,y1,…"); return
                    }
                    var viewPoints: [NSPoint] = []
                    var i = 2
                    while i + 1 < n.count {
                        viewPoints.append(NSPoint(x: n[i], y: n[i + 1]))
                        i += 2
                    }
                    Self.realSequence(editor: editor, window: window, hold: n[0], gap: n[1], viewPoints: viewPoints)
                }
            case "realoff":
                // "realoff holdms,gapms,off1,off2,…" — like `realseq`, but each
                // click lands on a raw-source OFFSET, located through the same
                // rects the editor draws the caret with (wrapped cells included)
                // — so the script survives the window being moved or resized.
                schedule(after: delay) { editor in
                    let n = arg.split(separator: ",").compactMap { Double($0) }
                    guard n.count >= 3, let window = editor.window else {
                        report("repro realoff: want holdms,gapms,off1,…"); return
                    }
                    var viewPoints: [NSPoint] = []
                    for off in n.dropFirst(2).map({ Int($0) }) {
                        let range = NSRange(location: off, length: 0)
                        if let r = editor.wrappedCellRects(for: range).first {
                            viewPoints.append(NSPoint(x: r.minX + 1, y: r.midY))
                        } else {
                            var actual = NSRange()
                            let s = editor.firstRect(forCharacterRange: range, actualRange: &actual)
                            let v = editor.convert(window.convertPoint(fromScreen: s.origin), from: nil)
                            viewPoints.append(NSPoint(x: v.x + 1, y: v.y + s.height / 2))
                        }
                    }
                    report("repro realoff offsets=\(n.dropFirst(2).map { Int($0) }) points=\(viewPoints.map { "(\(Int($0.x)),\(Int($0.y)))" })")
                    Self.realSequence(editor: editor, window: window, hold: n[0], gap: n[1], viewPoints: viewPoints)
                }
            case "redraw":
                schedule(after: delay) { editor in
                    editor.needsDisplay = true
                    report("repro redraw t=\(EditorTextView.debugMs()) opaque=\(editor.isOpaque)"
                           + " drawsBackground=\(editor.drawsBackground)"
                           + " layerOpaque=\(editor.layer?.isOpaque ?? false)"
                           + " layerBg=\(editor.layer?.backgroundColor.map { "\($0)" } ?? "nil")"
                           + " policy=\(editor.layerContentsRedrawPolicy.rawValue)"
                           + " clipLayerBg=\(editor.superview?.layer?.backgroundColor.map { "\($0)" } ?? "nil")")
                }
            case "hideviews":
                // "hideviews Content|Selection|Insertion|none" — hide every
                // subview of the editor whose class name contains the word,
                // to find which layer a stray pixel lives in. "none" unhides.
                schedule(after: delay) { editor in
                    var n = 0
                    for v in editor.subviews {
                        let name = "\(type(of: v))"
                        if arg == "none" { v.isHidden = false; n += 1; continue }
                        if name.contains(arg) { v.isHidden = true; n += 1 }
                    }
                    report("repro hideviews \(arg) touched=\(n)")
                }
            case "zoom":
                // "zoom in|out|actual" — View ▸ Zoom, through the document's
                // own actions (what ⌘= / ⌘- / ⌘0 run).
                scheduleDoc(after: delay) { doc in
                    switch arg {
                    case "in": doc.zoomIn(nil)
                    case "out": doc.zoomOut(nil)
                    default: doc.actualSize(nil)
                    }
                    report("repro zoom \(arg)")
                }
            case "appearance":
                // "appearance light|dark|system" — force the app's appearance.
                schedule(after: delay) { _ in
                    switch arg {
                    case "light": NSApp.appearance = NSAppearance(named: .aqua)
                    case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
                    default: NSApp.appearance = nil
                    }
                    report("repro appearance \(arg)")
                }
            case "realmove":
                // "realmove x,y" — move the real pointer to a view point (hover).
                schedule(after: delay) { editor in
                    let n = arg.split(separator: ",").compactMap { Double($0) }
                    guard n.count == 2, let window = editor.window else { report("repro realmove: want x,y"); return }
                    let cocoa = window.convertPoint(toScreen: editor.convert(NSPoint(x: n[0], y: n[1]), to: nil))
                    let primaryMaxY = NSScreen.screens.first?.frame.maxY ?? 0
                    let p = CGPoint(x: cocoa.x, y: primaryMaxY - cocoa.y)
                    CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: p,
                            mouseButton: .left)?.post(tap: .cghidEventTap)
                    report("repro realmove view=(\(Int(n[0])),\(Int(n[1]))) cg=(\(Int(p.x)),\(Int(p.y)))")
                }
            case "fontprobe":
                // "fontprobe off1,off2,…" — the font in storage at each offset,
                // plus the theme's sizes, to check a live restyle landed.
                schedule(after: delay) { editor in
                    let offs = arg.split(separator: ",").compactMap { Int($0) }
                    let out = offs.map { off -> String in
                        guard let ts = editor.textStorage, off < ts.length,
                              let f = ts.attribute(.font, at: off, effectiveRange: nil) as? NSFont
                        else { return "\(off):nil" }
                        return "\(off):\(f.fontName)@\(f.pointSize)"
                    }
                    report("repro fontprobe theme=\(editor.theme.fontSize)/\(editor.theme.monospaceFontSize)"
                           + " body=\(editor.bodyFont.pointSize) " + out.joined(separator: " "))
                }
            case "relayout":
                // Invalidate TextKit 2 layout for the whole document and repaint,
                // without touching attributes — separates a stale layout from a
                // wrong one.
                schedule(after: delay) { editor in
                    if let tlm = editor.textLayoutManager { tlm.invalidateLayout(for: tlm.documentRange) }
                    editor.needsDisplay = true
                    report("repro relayout")
                }
            case "kernprobe":
                // "kernprobe from,to" — every kern attribute in the range, with
                // the font size under it, and whether the paragraph carries
                // table cell wraps. Checks a table row's pad kerns survived.
                schedule(after: delay) { editor in
                    let n = arg.split(separator: ",").compactMap { Int($0) }
                    guard n.count == 2, let ts = editor.textStorage else { report("repro kernprobe: want from,to"); return }
                    var out: [String] = []
                    let range = NSRange(location: n[0], length: min(ts.length, n[1]) - n[0])
                    ts.enumerateAttribute(.kern, in: range) { value, r, _ in
                        guard let k = value as? CGFloat, k != 0 else { return }
                        let f = ts.attribute(.font, at: r.location, effectiveRange: nil) as? NSFont
                        out.append("\(r.location):k=\(Int(k))@\(f?.pointSize ?? -1)")
                    }
                    let wraps = ts.attribute(.tableCellWraps, at: n[0], effectiveRange: nil) as? TableCellWrapList
                    var lines = "?"
                    if let tlm = editor.textLayoutManager,
                       let loc = tlm.location(tlm.documentRange.location, offsetBy: n[0]),
                       let frag = tlm.textLayoutFragment(for: loc) {
                        lines = "\(frag.textLineFragments.count) frame=\(frag.layoutFragmentFrame)"
                            + " lineWidths=\(frag.textLineFragments.map { Int($0.typographicBounds.width) })"
                    }
                    let cw = editor.textContainer?.size.width ?? -1
                    report("repro kernprobe container=\(Int(cw)) lines=\(lines) wraps=\(wraps?.wraps.count ?? 0) "
                           + (wraps?.wraps.map { "x=\(Int($0.x)) w=\(Int($0.contentWidth))" }.joined(separator: ";") ?? "")
                           + " kerns=" + out.joined(separator: " "))
                }
            case "rectsprobe":
                // "rectsprobe off1,off2,…" — the caret rects the editor would
                // draw for each raw offset (empty = not in a wrapped cell).
                schedule(after: delay) { editor in
                    let offs = arg.split(separator: ",").compactMap { Int($0) }
                    let out = offs.map { off -> String in
                        let rs = editor.wrappedCellRects(for: NSRange(location: off, length: 0))
                        return "\(off):" + rs.map { "(\(Int($0.minX)),\(Int($0.minY)))" }.joined(separator: "+")
                    }
                    report("repro rectsprobe " + out.joined(separator: " "))
                }
            case "caretstate":
                schedule(after: delay) { editor in
                    report("repro caretstate t=\(EditorTextView.debugMs()) mode=\(RunLoop.main.currentMode?.rawValue ?? "nil")"
                           + " sel=\(editor.selectedRange()) on=\(editor.wrappedCaretOn)"
                           + " band=\(editor.wrappedCaretRect.map { "\($0)" } ?? "nil")"
                           + " timer=\(editor.wrappedCaretTimer.map { $0.isValid ? "valid" : "invalid" } ?? "nil")"
                           + " caretRect=\(editor.wrappedCellCaretRect().map { "\($0)" } ?? "nil")"
                           + " firstResponder=\(editor.window?.firstResponder === editor)")
                }
            case "viewtree":
                schedule(after: delay) { editor in
                    report("repro viewtree t=\(EditorTextView.debugMs())\n" + editor.debugViewTree())
                }
            case "front":
                // Bring the window to the active Space and the front, once,
                // so later `realclick`s land in a stable window.
                schedule(after: delay) { editor in
                    guard let window = editor.window else { return }
                    window.collectionBehavior.insert(.moveToActiveSpace)
                    window.orderFrontRegardless()
                    NSApp.activate(ignoringOtherApps: true)
                    window.makeKeyAndOrderFront(nil)
                    report("repro front t=\(EditorTextView.debugMs())")
                }
            case "indicators":
                schedule(after: delay) { editor in
                    report("repro indicators " + editor.debugInsertionIndicators())
                }
            case "burst":
                // "burst ms,interval,dir" — capture ONLY the document window
                // (a ScreenCaptureKit stream filtered to this window id; nothing
                // else on screen is included) for `ms` ms, at most one frame per
                // `interval` ms, to dir/NNNN-<uptime ms>.png. A stream delivers
                // a frame whenever the window repaints, so a single-frame paint
                // a still screenshot cannot catch lands as its own file. Needs
                // Screen Recording for the bundle.
                schedule(after: delay) { editor in
                    let parts = arg.split(separator: ",", maxSplits: 2).map(String.init)
                    guard parts.count == 3, let total = Double(parts[0]),
                          let interval = Double(parts[1]), let window = editor.window else {
                        report("repro burst: want ms,interval,dir"); return
                    }
                    let dir = parts[2]
                    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
                    let wid = CGWindowID(window.windowNumber)
                    let scale = window.backingScaleFactor
                    report("repro burst started wid=\(wid)")
                    Task.detached(priority: .userInitiated) {
                        let output = BurstOutput(dir: dir)
                        do {
                            let content = try await SCShareableContent.excludingDesktopWindows(
                                false, onScreenWindowsOnly: true)
                            guard let target = content.windows.first(where: { $0.windowID == wid }) else {
                                throw NSError(domain: "repro", code: 1,
                                              userInfo: [NSLocalizedDescriptionKey: "window \(wid) not shareable"])
                            }
                            let filter = SCContentFilter(desktopIndependentWindow: target)
                            let config = SCStreamConfiguration()
                            config.width = Int(target.frame.width * scale)
                            config.height = Int(target.frame.height * scale)
                            config.showsCursor = false
                            config.captureResolution = .best
                            config.minimumFrameInterval = CMTime(value: CMTimeValue(max(1, interval)), timescale: 1000)
                            config.queueDepth = 8
                            let stream = SCStream(filter: filter, configuration: config, delegate: nil)
                            try stream.addStreamOutput(output, type: .screen,
                                                       sampleHandlerQueue: DispatchQueue(label: "repro.burst"))
                            try await stream.startCapture()
                            try await Task.sleep(nanoseconds: UInt64(total * 1_000_000))
                            try await stream.stopCapture()
                        } catch {
                            let text = "\(error)"
                            await MainActor.run { report("repro burst error \(text)") }
                        }
                        let frames = output.frames, ok = output.written
                        await MainActor.run {
                            report("repro burst done frames=\(frames) written=\(ok) dir=\(dir)")
                        }
                    }
                }
            case "drag":
                // "drag x1,y1,x2,y2[,steps]" — a real drag-select at view points,
                // through the same mouseDown tracking loop a mouse would drive.
                schedule(after: delay) { editor in
                    let n = arg.split(separator: ",").compactMap { Double($0) }
                    guard n.count == 4 || n.count == 5 else {
                        report("repro drag: want x1,y1,x2,y2[,steps]"); return
                    }
                    report("repro drag " + editor.debugDrag(
                        fromX: n[0], fromY: n[1], toX: n[2], toY: n[3],
                        steps: n.count == 5 ? Int(n[4]) : 8))
                }
            case "hovertable":
                schedule(after: delay) { editor in
                    report("repro hovertable " + editor.debugHoverTable())
                }
            case "selectcells":
                // `selectcells r0,c0,r1,c1` — the selection a drag across those
                // cells would leave, so a screenshot can show the box.
                schedule(after: delay) { editor in
                    let n = arg.split(separator: ",").compactMap { Int($0) }
                    guard n.count == 4 else {
                        report("repro selectcells: want r0,c0,r1,c1"); return
                    }
                    report("repro selectcells " + editor.debugSelectTableCells(
                        fromRow: n[0], fromColumn: n[1], toRow: n[2], toColumn: n[3]))
                }
            case "assertsource":
                schedule(after: delay) { editor in
                    verdict("assertsource", editor.rawSource.contains(arg), "needle=\(arg)")
                }
            case "assertnot":
                schedule(after: delay) { editor in
                    verdict("assertnot", !editor.rawSource.contains(arg), "needle=\(arg)")
                }
            case "assertsel":
                // "assertsel N M": the selection is exactly {N, M}.
                schedule(after: delay) { editor in
                    let f = arg.split(separator: " ").compactMap { Int($0) }
                    let sel = editor.selectedRange()
                    verdict("assertsel", f.count == 2 && sel == NSRange(location: f[0], length: f[1]),
                            "sel=\(sel) want=\(arg)")
                }
            case "assertinvariants":
                // storage == rawSource, blocks rebuild rawSource, ranges in
                // bounds, no marked text left open.
                schedule(after: delay) { editor in
                    let bad = editor.debugInvariantViolations()
                    verdict("assertinvariants", bad.isEmpty, bad.joined(separator: "; "))
                }
            case "assertsourceorig":
                // The document is byte-identical to how it opened (undo round-trips).
                schedule(after: delay) { editor in
                    verdict("assertsourceorig", editor.rawSource == originalSource,
                            "len=\((editor.rawSource as NSString).length) " +
                            "orig=\(((originalSource ?? "") as NSString).length)")
                }
            case "assertsourcefile":
                // The document equals a golden file (path relative to the script).
                let golden = try? String(contentsOfFile: (scriptDir as NSString)
                    .appendingPathComponent(arg), encoding: .utf8)
                schedule(after: delay) { editor in
                    verdict("assertsourcefile", golden != nil && editor.rawSource == golden,
                            golden == nil ? "missing \(arg)" : "file=\(arg)")
                }
            case "ime":
                // Compose <text> as marked text through NSTextInputClient, as an
                // input method does; repeat to replace the composition.
                schedule(after: delay) { editor in
                    editor.setMarkedText(arg, selectedRange: NSRange(location: (arg as NSString).length, length: 0),
                                         replacementRange: NSRange(location: NSNotFound, length: 0))
                }
            case "imecommit":
                // Commit the composition as <text> (empty: keep the marked text as typed).
                schedule(after: delay) { editor in
                    if arg.isEmpty { editor.unmarkText() }
                    else { editor.insertText(arg, replacementRange: NSRange(location: NSNotFound, length: 0)) }
                }
            case "undo":
                schedule(after: delay) { editor in editor.undo(nil) }
            case "redo":
                schedule(after: delay) { editor in editor.redo(nil) }
            case "dumpsource":
                schedule(after: delay) { editor in
                    report("repro source sel=\(editor.selectedRange()) " + editor.rawSource
                        .replacingOccurrences(of: "\\", with: "\\\\")
                        .replacingOccurrences(of: "\n", with: "\\n"))
                }
            case "done":
                // Summary, then exit with the verdict (no save prompt: the runner
                // works on a temp copy of the fixture). A failing run also dumps
                // the final source, so the log shows what the assertions saw.
                schedule(after: delay) { editor in
                    if failures > 0 {
                        report("repro source sel=\(editor.selectedRange()) " + editor.rawSource
                            .replacingOccurrences(of: "\\", with: "\\\\")
                            .replacingOccurrences(of: "\n", with: "\\n"))
                    }
                    report("repro DONE pass=\(passes) fail=\(failures)")
                    exit(failures == 0 ? 0 : 1)
                }
            default:
                // A typo would otherwise pass silently by doing nothing.
                schedule(after: delay) { _ in verdict("command", false, "unknown: \(cmd)") }
            }
            delay += 0.02
        }
    }

    /// A run of real HID clicks from one background thread with exact spacing
    /// and a mouse-move trail between them, as a hand does; click counts are
    /// left to the system. Aborts unless our window is topmost at the first
    /// point (normal/floating layers only — the Dock and menu bar span the
    /// screen edge at higher layers and are ignored).
    private static func realSequence(editor: EditorTextView, window: NSWindow,
                                     hold: Double, gap: Double, viewPoints: [NSPoint]) {
        let primaryMaxY = NSScreen.screens.first?.frame.maxY ?? 0
        let points: [CGPoint] = viewPoints.map {
            let cocoa = window.convertPoint(toScreen: editor.convert($0, to: nil))
            return CGPoint(x: cocoa.x, y: primaryMaxY - cocoa.y)
        }
        guard let first = points.first else { return }
        let infos = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                               kCGNullWindowID) as? [[String: Any]] ?? []
        var top: Int? = nil
        for info in infos {
            guard (info[kCGWindowLayer as String] as? Int ?? 99) <= 3,
                  let b = info[kCGWindowBounds as String] as CFTypeRef?,
                  CFGetTypeID(b) == CFDictionaryGetTypeID(),
                  let r = CGRect(dictionaryRepresentation: b as! CFDictionary) else { continue }
            if r.contains(first) { top = info[kCGWindowNumber as String] as? Int; break }
        }
        guard top == window.windowNumber else {
            report("repro realseq ABORTED top=\(top.map(String.init) ?? "none")"); return
        }
        report("repro realseq t=\(EditorTextView.debugMs()) clicks=\(points.count) hold=\(Int(hold)) gap=\(Int(gap))")
        let finish: @MainActor () -> Void = {
            report("repro realseq done t=\(EditorTextView.debugMs()) sel=\(editor.selectedRange())")
        }
        DispatchQueue.global(qos: .userInteractive).async {
            var last = first
            for p in points {
                for k in 1...4 {
                    let t = CGFloat(k) / 4
                    let m = CGPoint(x: last.x + (p.x - last.x) * t, y: last.y + (p.y - last.y) * t)
                    CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: m,
                            mouseButton: .left)?.post(tap: .cghidEventTap)
                    usleep(4_000)
                }
                CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: p,
                        mouseButton: .left)?.post(tap: .cghidEventTap)
                usleep(useconds_t(hold * 1000))
                CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: p,
                        mouseButton: .left)?.post(tap: .cghidEventTap)
                usleep(useconds_t(gap * 1000))
                last = p
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { finish() } }
        }
    }

    /// Where a run's results are written: `<script>.log`, next to the script.
    private static var reportPath: String?

    /// Assertion tallies for the `done` summary and exit status.
    private static var passes = 0
    private static var failures = 0
    /// The document as it was before the first command, for `assertsourceorig`.
    private static var originalSource: String?

    /// One assertion result: `repro <name> PASS|FAIL <detail>`, counted.
    private static func verdict(_ name: String, _ ok: Bool, _ detail: String) {
        if ok { passes += 1 } else { failures += 1 }
        report("repro \(name) \(ok ? "PASS" : "FAIL") \(detail)")
    }

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
    private static func press(_ chars: String, keyCode: UInt16,
                              modifiers: NSEvent.ModifierFlags = [], in editor: EditorTextView) {
        guard let window = editor.window,
              let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                                           timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: window.windowNumber, context: nil,
                                           characters: chars, charactersIgnoringModifiers: chars,
                                           isARepeat: false, keyCode: keyCode) else { return }
        window.makeFirstResponder(editor)
        window.sendEvent(event)
    }
}

/// Writes every frame a burst stream delivers as a PNG named by its index and
/// the process-uptime ms at delivery — the clock the caret trace uses.
private final class BurstOutput: NSObject, SCStreamOutput, @unchecked Sendable {
    private let dir: String
    private let context = CIContext()
    private let lock = NSLock()
    private(set) var frames = 0
    private(set) var written = 0

    init(dir: String) { self.dir = dir }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .screen, let buffer = sampleBuffer.imageBuffer else { return }
        let ms = EditorTextView.debugMs()
        lock.lock(); let n = frames; frames += 1; lock.unlock()
        let image = CIImage(cvPixelBuffer: buffer)
        guard let cg = context.createCGImage(image, from: image.extent),
              let dest = CGImageDestinationCreateWithURL(
                URL(fileURLWithPath: "\(dir)/\(String(format: "%04d", n))-\(ms).png") as CFURL,
                "public.png" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, cg, nil)
        if CGImageDestinationFinalize(dest) { lock.lock(); written += 1; lock.unlock() }
    }
}
#endif
