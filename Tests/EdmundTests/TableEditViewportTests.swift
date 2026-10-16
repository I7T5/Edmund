import Testing
import AppKit
@testable import EdmundCore

/// Typing in a table cell near the top or bottom edge of the window must not
/// move the viewport. A keystroke restyles the whole table block; the caret
/// autoscroll that follows measured the caret's row from a partly invalid
/// layout (the table's top rather than the row) and scrolled to it.
@Suite("Table editing viewport")
struct TableEditViewportTests {
    @MainActor private func windowedEditor() -> (EditorTextView, NSScrollView) {
        let editor = makeEditor()
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 400),
                           styleMask: [.titled], backing: .buffered, defer: false)
        let scroll = NSScrollView(frame: win.contentLayoutRect)
        scroll.documentView = editor
        win.contentView = scroll
        win.makeFirstResponder(editor)
        editor.typewriterModeEnabled = false
        editor.isVerticallyResizable = true
        editor.minSize = NSSize(width: 0, height: 0)
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                height: CGFloat.greatestFiniteMagnitude)
        editor.autoresizingMask = [.width]
        return (editor, scroll)
    }

    /// `caretOffset`: distance from the viewport top to the caret line's top.
    @Test(arguments: [4.0, 10.0, 30.0, 340.0, 360.0])
    @MainActor func typingHoldsViewport(caretOffset: Double) throws {
        let (editor, scroll) = windowedEditor()
        let table = "| one | two | three |\n| --- | --- | --- |\n| a | b | c |\n| d | e | f |\n| g | h | i |"
        let doc = ((0..<40).map { "paragraph \($0) words" } + [table] + (0..<40).map { "after \($0)" })
            .joined(separator: "\n\n")
        editor.loadContent(doc)
        drainAllStyling(editor)
        let tlm = try #require(editor.textLayoutManager)
        tlm.ensureLayout(for: tlm.documentRange)
        // The headless view is never sized to its content; without a real
        // height every scroll target clamps to 0.
        editor.setFrameSize(NSSize(width: 500, height: 4000))
        let cell = (editor.rawSource as NSString).range(of: "| e |").location + 2
        editor.setSelectedRange(NSRange(location: cell, length: 0))
        editor.recomposeIncremental(cursorInRaw: cell)
        tlm.ensureLayout(for: tlm.documentRange)
        let caretY = try #require(editor.lineRect(forCharacterAt: cell)).minY
        scroll.contentView.scroll(to: NSPoint(x: 0, y: caretY - caretOffset))
        scroll.reflectScrolledClipView(scroll.contentView)
        let y0 = scroll.contentView.bounds.origin.y
        var deltas: [CGFloat] = []
        for ch in "xyz" {
            editor.insertText(String(ch), replacementRange: editor.selectedRange())
            deltas.append(scroll.contentView.bounds.origin.y - y0)
        }
        #expect(deltas.allSatisfy { abs($0) < 1 }, "offset \(caretOffset) y0=\(y0) deltas \(deltas)")
    }

    /// A click restyles the table block, which invalidates its rows' layout. The
    /// full-layout settle that follows runs inside `preservingViewportAnchor`,
    /// and with the rows still invalid (zero height) its "before" reading put
    /// the anchor line hundreds of points too high, so the "correction" scrolled
    /// the viewport by about a table's height.
    @Test(arguments: [0.0, 20.0, 60.0])
    @MainActor func settleAfterTableRestyleHoldsViewport(anchorOffset: Double) throws {
        let (editor, scroll) = windowedEditor()
        let rows = (1...21).map { "| \($0) | a\($0) | b\($0) |" }
        let table = (["| id | x | y |", "| --- | --- | --- |"] + rows).joined(separator: "\n")
        let doc = ((0..<6).map { "lead \($0) words" } + [table]
                   + (0..<40).map { "after \($0) with some words" }).joined(separator: "\n\n")
        editor.loadContent(doc)
        drainAllStyling(editor)
        let tlm = try #require(editor.textLayoutManager)
        editor.setFrameSize(NSSize(width: 500, height: 6000))
        tlm.ensureLayout(for: tlm.documentRange)
        // Viewport top on the first paragraph below the table.
        let below = (editor.rawSource as NSString).range(of: "after 0 ").location
        let belowY = try #require(editor.lineRect(forCharacterAt: below)).minY
        scroll.contentView.scroll(to: NSPoint(x: 0, y: belowY - anchorOffset))
        scroll.reflectScrolledClipView(scroll.contentView)
        tlm.textViewportLayoutController.layoutViewport()
        let y0 = scroll.contentView.bounds.origin.y

        // What a click's restyle leaves behind: the table's layout invalidated.
        let tableIndex = try #require(editor.blocks.firstIndex { $0.kind == .table })
        let cell = (editor.rawSource as NSString).range(of: "| 5 |").location + 2
        editor.recomposeDirty(IndexSet(integer: tableIndex), cursorInRaw: cell)
        editor.scheduleFullLayoutSettle()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        let delta = scroll.contentView.bounds.origin.y - y0
        #expect(abs(delta) < 1, "anchor offset \(anchorOffset): clip y moved \(delta)")
    }

    /// The same, for a caret that moves between cells of a table that is already
    /// the active block: that restyle (`applyBlockStyle`) never goes through
    /// `recomposeDirty`, and invalidates the rows all the same.
    @Test @MainActor func settleAfterMovingBetweenCellsHoldsViewport() throws {
        let (editor, scroll) = windowedEditor()
        let rows = (1...21).map { "| \($0) | a\($0) | b\($0) |" }
        let table = (["| id | x | y |", "| --- | --- | --- |"] + rows).joined(separator: "\n")
        let doc = ((0..<6).map { "lead \($0) words" } + [table]
                   + (0..<40).map { "after \($0) with some words" }).joined(separator: "\n\n")
        editor.loadContent(doc)
        drainAllStyling(editor)
        let tlm = try #require(editor.textLayoutManager)
        editor.setFrameSize(NSSize(width: 500, height: 6000))
        let first = (editor.rawSource as NSString).range(of: "| 5 |").location + 2
        editor.setSelectedRange(NSRange(location: first, length: 0))
        editor.recomposeIncremental(cursorInRaw: first)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        tlm.ensureLayout(for: tlm.documentRange)
        let below = (editor.rawSource as NSString).range(of: "after 0 ").location
        let belowY = try #require(editor.lineRect(forCharacterAt: below)).minY
        scroll.contentView.scroll(to: NSPoint(x: 0, y: belowY - 20))
        scroll.reflectScrolledClipView(scroll.contentView)
        tlm.textViewportLayoutController.layoutViewport()
        let y0 = scroll.contentView.bounds.origin.y

        let second = (editor.rawSource as NSString).range(of: "| 9 |").location + 2
        editor.suppressTypewriterCentering = true
        editor.setSelectedRange(NSRange(location: second, length: 0))
        editor.suppressTypewriterCentering = false
        editor.scheduleFullLayoutSettle()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        let delta = scroll.contentView.bounds.origin.y - y0
        #expect(abs(delta) < 1, "clip y moved \(delta)")
    }

    /// Clicking into a table, out of it and back in restyles it each time, which
    /// invalidates its rows. The last restyle of a click is the caret's own, with
    /// no recompose and so no settle; if nothing then lays the rows out again they
    /// stay at zero height and the table vanishes from the screen (and the text
    /// below moves up by its height) until the next click elsewhere.
    @Test(arguments: [0.0, 200.0])
    @MainActor func tableRowsAreLaidOutAfterClickingBackIn(rowOffset: Double) throws {
        let (editor, scroll) = windowedEditor()
        let rows = (1...21).map { "| \($0) | a\($0) | b\($0) |" }
        let table = (["| id | x | y |", "| --- | --- | --- |"] + rows).joined(separator: "\n")
        let doc = ((0..<6).map { "lead \($0) words" } + [table]
                   + (0..<40).map { "after \($0) with some words" }).joined(separator: "\n\n")
        editor.loadContent(doc)
        drainAllStyling(editor)
        let tlm = try #require(editor.textLayoutManager)
        editor.setFrameSize(NSSize(width: 900, height: 6000))
        tlm.ensureLayout(for: tlm.documentRange)
        let cell = (editor.rawSource as NSString).range(of: "| 9 |").location + 2
        let outside = (editor.rawSource as NSString).range(of: "after 1 ").location
        let cellY = try #require(editor.lineRect(forCharacterAt: cell)).minY
        scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, cellY - rowOffset)))
        scroll.reflectScrolledClipView(scroll.contentView)
        tlm.textViewportLayoutController.layoutViewport()
        let y0 = scroll.contentView.bounds.origin.y

        for offset in [cell, outside, cell] {
            editor.reproClickSelect(offset)
            RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        }
        var collapsed = 0
        tlm.enumerateTextLayoutFragments(from: tlm.documentRange.location, options: []) { frag in
            if frag.layoutFragmentFrame.height < 0.5 { collapsed += 1 }
            return true
        }
        #expect(collapsed == 0, "\(collapsed) laid-out fragments have no height")
        #expect(abs(scroll.contentView.bounds.origin.y - y0) < 1)
    }
}
