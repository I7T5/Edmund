import Testing
import AppKit
@testable import EdmundCore

/// Width changes must rebuild the table's stored geometry, not just ask
/// TextKit to lay out the old column widths in a narrower container.
@Suite("Table resize", .serialized)
@MainActor
struct TableResizeTests {
    private let source = """
    | Name | Description |
    | --- | ---: |
    | Example | A long description that should wrap across several lines when the window becomes narrow, and use fewer lines when it becomes wide again. |

    after table
    """

    private func settle() { settleContentWidth() }

    private func editor(width: CGFloat = 500,
                        cap: CGFloat = .greatestFiniteMagnitude) throws -> EditorTextView {
        let editor = makeEditor()
        editor.setFrameSize(NSSize(width: width, height: 300))
        editor.maxContentWidthPoints = cap
        editor.loadContent(source)
        editor.recompose(cursorInRaw: (source as NSString).length)
        settle()
        return editor
    }

    private func tableStyle(_ editor: EditorTextView) throws -> NSAttributedString {
        let block = try #require(editor.blocks.first { $0.kind == .table })
        return try #require(editor.textStorage).attributedSubstring(from: block.range)
    }

    private func tableWidth(_ editor: EditorTextView) throws -> CGFloat {
        let styled = try tableStyle(editor)
        guard case .tableRow(_, let width, _, _, _, _)? = blockDecoration(at: 0, in: styled)?.kind
        else { Issue.record("Expected a rendered table"); return 0 }
        return width
    }

    private func expectFreshLayout(_ editor: EditorTextView) throws {
        let fresh = try self.editor(width: editor.frame.width,
                                         cap: editor.maxContentWidthPoints)
        #expect(try tableStyle(editor).isEqual(to: tableStyle(fresh)))
        ensureFullLayout(editor)
        ensureFullLayout(fresh)
        let offset = (source as NSString).range(of: "after table").location
        #expect(editor.lineRect(forCharacterAt: offset)?.minY
                == fresh.lineRect(forCharacterAt: offset)?.minY)
    }

    @Test("Resizing with fixed margins matches a fresh table at each width")
    func windowResize() throws {
        let editor = try editor(width: 800)
        let wide = try tableWidth(editor)
        let inset = editor.textContainerInset.width
        editor.setFrameSize(NSSize(width: 350, height: 300))
        settle()
        #expect(editor.textContainerInset.width == inset)
        #expect(try tableWidth(editor) < wide)
        try expectFreshLayout(editor)
        editor.setFrameSize(NSSize(width: 800, height: 300))
        settle()
        #expect(try tableWidth(editor) == wide)
        try expectFreshLayout(editor)
    }

    @Test("Changing the content cap refreshes tables and preserves selection and source")
    func contentCap() throws {
        let editor = try editor(width: 900)
        let selection = NSRange(location: (source as NSString).length - 5, length: 5)
        editor.setSelectedRange(selection)
        let undoCount = editor.undoStack.count
        for cap: CGFloat in [300, 650] {
            editor.maxContentWidthPoints = cap
            settle()
            let padding = try #require(editor.textContainer).lineFragmentPadding
            #expect(abs(editor.availableContentWidth - (cap - 2 * padding)) < 1)
            #expect(try tableWidth(editor) <= editor.availableContentWidth)
            try expectFreshLayout(editor)
            #expect(editor.selectedRange() == selection)
            #expect(editor.rawSource == source)
            #expect(editor.textStorage?.string == source)
            #expect(editor.undoStack.count == undoCount)
        }
    }

    @Test("Height and margin changes with the same content width reuse table styling")
    func unchangedContentWidth() throws {
        let editor = try editor(width: 800)
        editor.maxContentWidthPoints = 400
        settle()
        let decoration = try #require(blockDecoration(at: 0, in: editor))
        editor.setFrameSize(NSSize(width: 1000, height: 500))
        settle()
        #expect(blockDecoration(at: 0, in: editor) === decoration)
    }

    @Test("A burst of resizes applies the latest width")
    func coalescedResize() throws {
        let editor = try editor()
        for width: CGFloat in [350, 800, 400, 700] {
            editor.setFrameSize(NSSize(width: width, height: 300))
        }
        settle()
        try expectFreshLayout(editor)
    }

    @Test("A resize deferred during an update is retried")
    func updatingEditor() throws {
        let editor = try editor(width: 800)
        let wide = try tableWidth(editor)
        editor.isUpdating = true
        editor.setFrameSize(NSSize(width: 350, height: 300))
        settle()
        #expect(try tableWidth(editor) == wide)
        editor.isUpdating = false
        settle()
        try expectFreshLayout(editor)
    }

    @Test("Offscreen tables refresh when promoted after a width change")
    func offscreenTable() throws {
        let editor = makeEditor()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let scroll = NSScrollView(frame: window.contentLayoutRect)
        scroll.documentView = editor
        window.contentView = scroll
        editor.typewriterModeEnabled = false
        editor.isVerticallyResizable = true
        editor.minSize = .zero
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                               height: CGFloat.greatestFiniteMagnitude)
        editor.autoresizingMask = [.width]
        editor.setFrameSize(NSSize(width: 800, height: 300))
        editor.loadContent("before\n\n" + Array(repeating: source, count: 20).joined(separator: "\n\n"))
        drainAllStyling(editor)
        editor.updateContentWidths()
        drainAllStyling(editor)
        let lastTable = try #require(editor.blocks.lastIndex { $0.kind == .table })

        scroll.setFrameSize(NSSize(width: 350, height: 300))
        editor.setFrameSize(NSSize(width: 350, height: editor.frame.height))
        // Drive the worker before the idle drain gets a turn, so this checks
        // scroll promotion rather than accidentally relying on idle styling.
        editor.updateContentWidths()
        #expect(!editor.blocks[lastTable].isStyled)
        ensureFullLayout(editor)
        editor.sizeToFit()
        editor.layoutSubtreeIfNeeded()
        scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, editor.frame.height - 300)))
        scroll.reflectScrolledClipView(scroll.contentView)
        editor.layoutSubtreeIfNeeded()
        editor.promoteVisibleUnstyledBlocks()
        #expect(editor.blocks[lastTable].isStyled)
        let block = editor.blocks[lastTable]
        let actual = try #require(editor.textStorage).attributedSubstring(from: block.range)
        #expect(actual.isEqual(to: editor.styleBlock(block.content, cursorPosition: nil)))
    }

    @Test("A resize waits for marked text to commit")
    func markedText() throws {
        let editor = try editor(width: 800)
        let wide = try tableWidth(editor)
        editor.setMarkedText("é", selectedRange: NSRange(location: 0, length: 1),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(editor.hasMarkedText())
        editor.setFrameSize(NSSize(width: 350, height: 300))
        settle()
        #expect(editor.hasMarkedText())
        #expect(try tableWidth(editor) == wide)
        editor.insertText("é", replacementRange: NSRange(location: NSNotFound, length: 0))
        settle()
        #expect(!editor.hasMarkedText())
        #expect(try tableWidth(editor) < wide)
        #expect(editor.textStorage?.string == editor.rawSource)
    }

    @Test("A table with the caret in a cell re-renders at the new width and the caret follows")
    func caretInTable() throws {
        let editor = try editor(width: 800)
        let wide = try tableWidth(editor)
        // Inside the long Description cell, which wraps at the narrow width.
        let cell = (source as NSString).range(of: "several lines")
        let caret = NSRange(location: cell.location + 3, length: 0)
        editor.setSelectedRange(caret)
        settle()
        editor.setFrameSize(NSSize(width: 350, height: 300))
        settle()
        // Tables stay rendered with the caret inside (the `</>` toggle reveals
        // the markdown), so the restyle must reach the active table too.
        #expect(blockDecoration(at: 0, in: editor) != nil)
        #expect(try tableWidth(editor) < wide)
        #expect(editor.selectedRange() == caret)
        // Attributes differ from a caret-outside render (the active cell is
        // styled), so compare geometry, not the styled string.
        let fresh = try self.editor(width: 350)
        #expect(try tableWidth(editor) == tableWidth(fresh))
        ensureFullLayout(editor)
        ensureFullLayout(fresh)
        let offset = (source as NSString).range(of: "after table").location
        #expect(editor.lineRect(forCharacterAt: offset)?.minY
                == fresh.lineRect(forCharacterAt: offset)?.minY)
        // `setFrameSize` positioned the in-cell caret against the old column
        // geometry; the restyle has to re-read it once the new geometry is laid
        // out. Driven directly and given one short hop: the 0.5s blink tick
        // also refreshes the band, and it must not be what makes this pass.
        editor.setFrameSize(NSSize(width: 500, height: 300))
        editor.updateContentWidths()
        settle()
        let band = editor.wrappedCaretRect
        editor.updateWrappedCaret()
        #expect(band == editor.wrappedCaretRect)
    }
}
