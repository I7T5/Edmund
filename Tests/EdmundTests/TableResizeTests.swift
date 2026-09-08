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

    private func settle() async throws {
        try await Task.sleep(for: .milliseconds(100))
    }

    private func editor(width: CGFloat = 500,
                        cap: CGFloat = .greatestFiniteMagnitude) async throws -> EditorTextView {
        let editor = makeEditor()
        editor.setFrameSize(NSSize(width: width, height: 300))
        editor.maxContentWidthPoints = cap
        editor.loadContent(source)
        editor.recompose(cursorInRaw: (source as NSString).length)
        try await settle()
        return editor
    }

    private func tableStyle(_ editor: EditorTextView) throws -> NSAttributedString {
        let block = try #require(editor.blocks.first { $0.kind == .table })
        return try #require(editor.textStorage).attributedSubstring(from: block.range)
    }

    private func tableWidth(_ editor: EditorTextView) throws -> CGFloat {
        let styled = try tableStyle(editor)
        guard case .tableRow(_, let width, _, _, _)? = blockDecoration(at: 0, in: styled)?.kind
        else { Issue.record("Expected a rendered table"); return 0 }
        return width
    }

    private func expectFreshLayout(_ editor: EditorTextView) async throws {
        let fresh = try await self.editor(width: editor.frame.width,
                                         cap: editor.maxContentWidthPoints)
        #expect(try tableStyle(editor).isEqual(to: tableStyle(fresh)))
        ensureFullLayout(editor)
        ensureFullLayout(fresh)
        let offset = (source as NSString).range(of: "after table").location
        #expect(editor.lineRect(forCharacterAt: offset)?.minY
                == fresh.lineRect(forCharacterAt: offset)?.minY)
    }

    @Test("Resizing with fixed margins matches a fresh table at each width")
    func windowResize() async throws {
        let editor = try await editor(width: 800)
        let wide = try tableWidth(editor)
        let inset = editor.textContainerInset.width
        editor.setFrameSize(NSSize(width: 350, height: 300))
        try await settle()
        #expect(editor.textContainerInset.width == inset)
        #expect(try tableWidth(editor) < wide)
        try await expectFreshLayout(editor)
        editor.setFrameSize(NSSize(width: 800, height: 300))
        try await settle()
        #expect(try tableWidth(editor) == wide)
        try await expectFreshLayout(editor)
    }

    @Test("Changing the content cap refreshes tables and preserves selection and source")
    func contentCap() async throws {
        let editor = try await editor(width: 900)
        let selection = NSRange(location: (source as NSString).length - 5, length: 5)
        editor.setSelectedRange(selection)
        let undoCount = editor.undoStack.count
        for cap: CGFloat in [300, 650] {
            editor.maxContentWidthPoints = cap
            try await settle()
            let padding = try #require(editor.textContainer).lineFragmentPadding
            #expect(abs(editor.availableContentWidth - (cap - 2 * padding)) < 1)
            #expect(try tableWidth(editor) <= editor.availableContentWidth)
            try await expectFreshLayout(editor)
            #expect(editor.selectedRange() == selection)
            #expect(editor.rawSource == source)
            #expect(editor.textStorage?.string == source)
            #expect(editor.undoStack.count == undoCount)
        }
    }

    @Test("Height and margin changes with the same content width reuse table styling")
    func unchangedContentWidth() async throws {
        let editor = try await editor(width: 800)
        editor.maxContentWidthPoints = 400
        try await settle()
        let decoration = try #require(blockDecoration(at: 0, in: editor))
        editor.setFrameSize(NSSize(width: 1000, height: 500))
        try await settle()
        #expect(blockDecoration(at: 0, in: editor) === decoration)
    }

    @Test("A burst of resizes applies the latest width")
    func coalescedResize() async throws {
        let editor = try await editor()
        for width: CGFloat in [350, 800, 400, 700] {
            editor.setFrameSize(NSSize(width: width, height: 300))
        }
        try await settle()
        try await expectFreshLayout(editor)
    }

    @Test("A resize deferred during an update is retried")
    func updatingEditor() async throws {
        let editor = try await editor(width: 800)
        let wide = try tableWidth(editor)
        editor.isUpdating = true
        editor.setFrameSize(NSSize(width: 350, height: 300))
        try await settle()
        #expect(try tableWidth(editor) == wide)
        editor.isUpdating = false
        try await settle()
        try await expectFreshLayout(editor)
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
        editor.updateTableWidths()
        drainAllStyling(editor)
        let lastTable = try #require(editor.blocks.lastIndex { $0.kind == .table })

        scroll.setFrameSize(NSSize(width: 350, height: 300))
        editor.setFrameSize(NSSize(width: 350, height: editor.frame.height))
        // Drive the worker before the idle drain gets a turn, so this checks
        // scroll promotion rather than accidentally relying on idle styling.
        editor.updateTableWidths()
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
    func markedText() async throws {
        let editor = try await editor(width: 800)
        let wide = try tableWidth(editor)
        editor.setMarkedText("é", selectedRange: NSRange(location: 0, length: 1),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(editor.hasMarkedText())
        editor.setFrameSize(NSSize(width: 350, height: 300))
        try await settle()
        #expect(editor.hasMarkedText())
        #expect(try tableWidth(editor) == wide)
        editor.insertText("é", replacementRange: NSRange(location: NSNotFound, length: 0))
        try await settle()
        #expect(!editor.hasMarkedText())
        #expect(try tableWidth(editor) < wide)
        #expect(editor.textStorage?.string == editor.rawSource)
    }

    @Test("An active table stays raw and renders at the new width on exit")
    func activeTable() async throws {
        let editor = try await editor(width: 800)
        editor.setSelectedRange(NSRange(location: 3, length: 0))
        try await settle()
        editor.setFrameSize(NSSize(width: 350, height: 300))
        try await settle()
        #expect(blockDecoration(at: 0, in: editor) == nil)
        #expect(editor.selectedRange().location == 3)
        editor.setSelectedRange(NSRange(location: (source as NSString).length, length: 0))
        try await settle()
        drainAllStyling(editor)
        try await expectFreshLayout(editor)
    }
}
