import Testing
import AppKit
@testable import EdmundCore

/// Lazy rendering: in a scroll view, loads style only the viewport window
/// synchronously; the idle drain and scroll promotion converge the rest.
/// (Headless editors — no scroll view — style everything synchronously, which
/// is what every other suite exercises.)
@Suite("Lazy rendering")
struct LazyRenderingTests {

    @MainActor private func windowedEditor(height: CGFloat = 300) -> (EditorTextView, NSScrollView) {
        let editor = makeEditor()
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: height),
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

    @MainActor private func bigDocument() -> String {
        (0..<800).map { "paragraph **number** \($0)" }.joined(separator: "\n\n")
    }

    @Test("Load styles the viewport window; far blocks stay base-attributed")
    @MainActor func loadIsViewportFirst() {
        let (editor, _) = windowedEditor()
        editor.loadContent(bigDocument())

        #expect(editor.blocks.first?.isStyled == true)
        let last = editor.blocks.count - 1
        #expect(editor.blocks[last].isStyled == false)

        // An unstyled block's characters carry exactly the base attributes:
        // the bold delimiters are not yet hidden.
        let lastLoc = editor.blocks[last].range.location
        let f = font(at: lastLoc, in: editor)
        #expect(f?.fontName == editor.bodyFont.fontName)
        #expect((f?.pointSize ?? 0) >= 1.0)
        assertMatchesFullRecomposeOracle(editor, "viewport-first load")
    }

    @Test("The idle drain converges the whole document to the oracle")
    @MainActor func drainConverges() {
        let (editor, _) = windowedEditor()
        editor.loadContent(bigDocument())
        drainAllStyling(editor)
        #expect(editor.blocks.allSatisfy { $0.isStyled })
        assertMatchesFullRecomposeOracle(editor, "after drain")
    }

    @Test("The drain builds the list-depth map once, not once per block")
    @MainActor func drainBuildsDepthMapOnce() {
        let (editor, _) = windowedEditor()
        editor.loadContent(bigDocument())
        let before = editor.listDepthsBuildCount
        drainAllStyling(editor)
        #expect(editor.listDepthsBuildCount - before <= 1)
    }

    /// After a zoom, the blocks above the viewport keep their old font until
    /// the drain reaches them; restyled, they change height. Past the
    /// full-layout threshold those heights are estimates, and the viewport
    /// must not slide while the drain catches up.
    @Test("Zoom keeps the top line while the drain restyles the rest")
    @MainActor func zoomHoldsTopLineThroughDrain() throws {
        let (editor, scroll) = windowedEditor(height: 400)
        let doc = (0..<1300).map {
            "## Heading \($0)\n\nparagraph **\($0)** with enough words to wrap a couple of times here."
        }.joined(separator: "\n\n")
        #expect((doc as NSString).length > EditorTextView.fullLayoutMaxLength)
        editor.loadContent(doc)
        drainAllStyling(editor)
        let tlm = try #require(editor.textLayoutManager)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: editor.frame.height / 2))
        scroll.reflectScrolledClipView(scroll.contentView)
        tlm.textViewportLayoutController.layoutViewport()

        editor.setZoom(1.3)
        tlm.textViewportLayoutController.layoutViewport()
        let afterZoom = try #require(editor.topmostVisibleCharacterOffset())
        var slices = 0
        while editor.blocks.contains(where: { !$0.isStyled }), slices < 10_000 {
            editor.drainStylingSlice()
            tlm.textViewportLayoutController.layoutViewport()   // the display pass
            slices += 1
        }
        let afterDrain = try #require(editor.topmostVisibleCharacterOffset())
        let lineAfterZoom = editor.line(forOffset: afterZoom)
        let lineAfterDrain = editor.line(forOffset: afterDrain)
        #expect(abs(lineAfterDrain - lineAfterZoom) <= 2,
                "top line slid from \(lineAfterZoom) to \(lineAfterDrain) as the drain ran")
    }

    @Test("Scrolling promotes newly visible blocks synchronously")
    @MainActor func scrollPromotes() {
        let (editor, scroll) = windowedEditor()
        editor.loadContent(bigDocument())
        ensureFullLayout(editor)
        editor.sizeToFit()
        editor.layoutSubtreeIfNeeded()

        let last = editor.blocks.count - 1
        #expect(editor.blocks[last].isStyled == false)

        // Jump to the bottom of the document. The scroll notification defers
        // promotion off the run loop (so it doesn't fight momentum scrolling);
        // invoke the worker directly to test the styling itself.
        scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, editor.frame.height - 300)))
        scroll.reflectScrolledClipView(scroll.contentView)
        editor.promoteVisibleUnstyledBlocks()

        #expect(editor.blocks[last].isStyled == true,
                "scroll promotion must style blocks entering the viewport")
    }

    @Test("Clicking into an unstyled block styles it as the active block")
    @MainActor func clickIntoUnstyled() {
        let (editor, _) = windowedEditor()
        editor.loadContent(bigDocument())

        let last = editor.blocks.count - 1
        #expect(editor.blocks[last].isStyled == false)
        let target = editor.blocks[last].range.location + 2
        editor.setSelectedRange(NSRange(location: target, length: 0))
        editor.recomposeIncremental(cursorInRaw: target)

        #expect(editor.blocks[last].isStyled == true)
        #expect(editor.activeBlockIndex == last)
        assertMatchesFullRecomposeOracle(editor, "after activating unstyled block")
    }

    @Test("Undo mid-drain converges cleanly")
    @MainActor func undoMidDrain() {
        let (editor, _) = windowedEditor()
        editor.loadContent(bigDocument())
        // One edit so there's an undo snapshot, then undo before draining.
        type("x", into: editor)
        editor.performUndo()
        drainAllStyling(editor)
        #expect(editor.blocks.allSatisfy { $0.isStyled })
        #expect(editor.rawSource == bigDocument())
        assertMatchesFullRecomposeOracle(editor, "after undo + drain")
    }
    @Test("Pending-block index stays correct across styling, edits, undo and reload")
    @MainActor func pendingIndexTracksChanges() {
        let (editor, _) = windowedEditor()
        func checkIndex() {
            let expected = IndexSet(editor.blocks.indices.filter { !editor.blocks[$0].isStyled })
            #expect(editor.unstyledBlockIndexes == expected)
            #expect(editor.unstyledBlockCount == expected.count)
        }
        editor.loadContent(bigDocument())
        checkIndex()
        let last = editor.blocks.count - 1
        let before = editor.unstyledBlockCount
        let depths = editor.listDepths
        let builds = editor.listDepthsBuildCount
        editor.setStyled(last, true)
        editor.setStyled(last, true)
        #expect(editor.unstyledBlockCount == before - 1)
        editor.setStyled(last, false)
        #expect(editor.unstyledBlockCount == before)
        #expect(editor.listDepths == depths)
        #expect(editor.listDepthsBuildCount == builds)
        checkIndex()
        type("x", into: editor)
        checkIndex()
        editor.performUndo()
        checkIndex()
        drainAllStyling(editor)
        checkIndex()
        #expect(editor.unstyledBlockCount == 0)
        editor.loadContent("replacement")
        checkIndex()
        #expect(editor.unstyledBlockCount == 0)
    }

}
