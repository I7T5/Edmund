import Testing
import AppKit
@testable import EdmundCore

// MARK: - textDiff

@Suite("Undo/redo text diff")
struct TextDiffTests {

    @Test("Equal strings diff to nil")
    func equalStrings() {
        #expect(EditorTextView.textDiff(old: "abc", new: "abc") == nil)
        #expect(EditorTextView.textDiff(old: "", new: "") == nil)
    }

    @Test("Pure insertion")
    func insertion() {
        let d = EditorTextView.textDiff(old: "ac", new: "abc")
        #expect(d?.oldRange == NSRange(location: 1, length: 0))
        #expect(d?.replacement == "b")
    }

    @Test("Pure deletion")
    func deletion() {
        let d = EditorTextView.textDiff(old: "abc", new: "ac")
        #expect(d?.oldRange == NSRange(location: 1, length: 1))
        #expect(d?.replacement == "")
    }

    @Test("Replacement")
    func replacement() {
        let d = EditorTextView.textDiff(old: "hello world", new: "hello brave world")
        #expect(d?.oldRange == NSRange(location: 6, length: 0))
        #expect(d?.replacement == "brave ")
    }

    @Test("Whole-string replacement")
    func wholeString() {
        let d = EditorTextView.textDiff(old: "abc", new: "xyz")
        #expect(d?.oldRange == NSRange(location: 0, length: 3))
        #expect(d?.replacement == "xyz")
    }

    @Test("Repeated character insertion picks a single contiguous span")
    func repeatedChars() {
        // "aaa" → "aaaa": prefix eats 3, suffix 0 → insert at 3.
        let d = EditorTextView.textDiff(old: "aaa", new: "aaaa")
        #expect(d?.oldRange.length == 0)
        #expect(d?.replacement == "a")
    }

    @Test("Surrogate pairs are never split")
    func surrogates() {
        // 😀 = D83D DE00, 😅 = D83D DE05 — common lead surrogate would split
        // the pair if the diff were computed naively per UTF-16 unit.
        let d = EditorTextView.textDiff(old: "a😀b", new: "a😅b")
        let old = "a😀b" as NSString
        let range = d!.oldRange
        // Boundaries must sit on scalar boundaries: the range covers the
        // whole emoji, and the replacement is the whole new emoji.
        #expect(range == NSRange(location: 1, length: 2))
        #expect(d?.replacement == "😅")
        #expect(old.substring(with: range) == "😀")
    }
}

// MARK: - Undo/redo selection

/// Puts the caret at `offset` through the recompose path so
/// `activeBlockIndex` is in sync (bare `setSelectedRange` in headless tests
/// leaves it stale, which splits the next typing run into two undo groups).
@MainActor
private func placeCaret(_ editor: EditorTextView, at offset: Int) {
    editor.setSelectedRange(NSRange(location: offset, length: 0))
    editor.recomposeIncremental(cursorInRaw: offset)
}

@Suite("Undo/redo selects the changed text")
struct UndoRedoSelectionTests {

    @Test("Redo selects the restored text")
    @MainActor func redoSelectsRestoredText() {
        let editor = makeEditor()
        editor.loadContent("aaa\nbbb\nccc")
        editor.setSelectedRange(NSRange(location: 3, length: 0))
        type(" X", into: editor)
        #expect(editor.rawSource == "aaa X\nbbb\nccc")

        editor.undo(nil)
        #expect(editor.rawSource == "aaa\nbbb\nccc")
        // Undo of an insertion is a deletion — caret at the deletion point.
        #expect(editor.selectedRange() == NSRange(location: 3, length: 0))

        editor.redo(nil)
        #expect(editor.rawSource == "aaa X\nbbb\nccc")
        // The re-inserted text is selected.
        #expect(editor.selectedRange() == NSRange(location: 3, length: 2))
    }

    @Test("Redo targets the changed text, not the caret at undo time")
    @MainActor func redoIgnoresStaleCaret() {
        let editor = makeEditor()
        editor.loadContent("aaa\nbbb\nccc")
        placeCaret(editor, at: 8)
        type("ZZ", into: editor)
        editor.undo(nil)
        // Move the caret far from the change before redoing.
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        editor.redo(nil)
        #expect(editor.rawSource == "aaa\nbbb\nZZccc")
        #expect(editor.selectedRange() == NSRange(location: 8, length: 2))
    }

    @Test("Undo of a deletion selects the restored text")
    @MainActor func undoDeletionSelectsRestoredText() {
        let editor = makeEditor()
        editor.loadContent("aaa\nbbb\nccc")
        placeCaret(editor, at: 7)
        pressBackspace(in: editor)
        pressBackspace(in: editor)
        #expect(editor.rawSource == "aaa\nb\nccc")

        editor.undo(nil)
        #expect(editor.rawSource == "aaa\nbbb\nccc")
        // The two restored characters are selected.
        #expect(editor.selectedRange() == NSRange(location: 5, length: 2))
    }

    @Test("Undo/redo round-trip keeps storage == rawSource")
    @MainActor func invariantHolds() {
        let editor = makeEditor()
        editor.loadContent("# Title\n\n- item one\n- item two\n\npara")
        editor.setSelectedRange(NSRange(location: 12, length: 0))
        type("hello", into: editor)
        editor.undo(nil)
        #expect(editor.textStorage?.string == editor.rawSource)
        editor.redo(nil)
        #expect(editor.textStorage?.string == editor.rawSource)
        assertMatchesFullRecomposeOracle(editor)
    }
}

// MARK: - Undo/redo viewport

@Suite("Undo/redo viewport placement")
struct UndoRedoViewportTests {

    @MainActor
    private func makeScrollingEditor(_ doc: String) -> (EditorTextView, NSScrollView) {
        let editor = makeEditor()
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300),
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
        editor.loadContent(doc)
        drainAllStyling(editor)
        ensureFullLayout(editor)
        editor.sizeToFit()
        editor.layoutSubtreeIfNeeded()
        return (editor, scroll)
    }

    /// The changed line's vertical distance from the viewport's center.
    @MainActor
    private func distanceFromViewportCenter(of offset: Int, _ editor: EditorTextView,
                                            _ scroll: NSScrollView) -> CGFloat? {
        guard let rect = editor.lineRect(forCharacterAt: offset) else { return nil }
        let visible = scroll.contentView.bounds
        return abs(rect.midY + editor.textContainerOrigin.y - visible.midY)
    }

    @Test("Undo of an off-screen edit centers the changed text")
    @MainActor func undoCentersOffscreenChange() {
        var doc = ""
        for i in 0..<80 { doc += "paragraph number \(i)\n\n" }
        let (editor, scroll) = makeScrollingEditor(doc)

        // Edit deep in the document…
        let target = (editor.rawSource as NSString).range(of: "paragraph number 60").location
        editor.setSelectedRange(NSRange(location: target, length: 0))
        editor.recomposeIncremental(cursorInRaw: target)
        type("XYZ", into: editor)

        // …then scroll away to the top and undo.
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
        editor.undo(nil)

        // The deletion point (the changed text) is vertically centered.
        let caret = editor.selectedRange().location
        #expect(caret == target)
        let dist = distanceFromViewportCenter(of: caret, editor, scroll)
        #expect(dist != nil && dist! < 30,
                "changed text is \(dist ?? -1)pt from the viewport center")
    }

    @Test("Redo centers the changed text, not the pre-undo caret")
    @MainActor func redoCentersChangedText() {
        var doc = ""
        for i in 0..<80 { doc += "paragraph number \(i)\n\n" }
        let (editor, scroll) = makeScrollingEditor(doc)

        let target = (editor.rawSource as NSString).range(of: "paragraph number 60").location
        editor.setSelectedRange(NSRange(location: target, length: 0))
        editor.recomposeIncremental(cursorInRaw: target)
        type("XYZ", into: editor)
        editor.undo(nil)

        // Simulate the user moving the caret and viewport far away, then redo.
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
        editor.redo(nil)

        // The restored text is selected and centered.
        #expect(editor.selectedRange() == NSRange(location: target, length: 3))
        let dist = distanceFromViewportCenter(of: target, editor, scroll)
        #expect(dist != nil && dist! < 30,
                "changed text is \(dist ?? -1)pt from the viewport center")
    }

    @Test("Undo of a visible edit holds the viewport still")
    @MainActor func undoHoldsViewportWhenVisible() {
        var doc = ""
        for i in 0..<80 { doc += "paragraph number \(i)\n\n" }
        let (editor, scroll) = makeScrollingEditor(doc)

        let target = (editor.rawSource as NSString).range(of: "paragraph number 40").location
        editor.setSelectedRange(NSRange(location: target, length: 0))
        editor.recomposeIncremental(cursorInRaw: target)
        // Bring the edit on screen the way undo will see it.
        guard let lineY = editor.lineRect(forCharacterAt: target)?.midY else {
            Issue.record("no line rect for the target"); return
        }
        scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, lineY - 150)))
        scroll.reflectScrolledClipView(scroll.contentView)
        type("XYZ", into: editor)

        let yBefore = scroll.contentView.bounds.origin.y
        editor.undo(nil)
        let yAfter = scroll.contentView.bounds.origin.y
        #expect(abs(yAfter - yBefore) < 2.0,
                "viewport moved by \(yAfter - yBefore) on a visible undo")
    }
}
