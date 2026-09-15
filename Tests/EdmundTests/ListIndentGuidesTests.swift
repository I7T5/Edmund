import Testing
import AppKit
@testable import EdmundCore

// Indent guides mark a list item's indent columns: one per ancestor level plus
// the item's own column last, each centered on the marker box that level
// occupies. The ancestor guides span the item; the own-column one is drawn only
// beside wrapped continuation lines (a draw-time distinction — these tests
// cover the columns). The offsets are baked into the text at render time
// regardless of the setting (the layout fragment gates the drawing), so these
// tests read them straight off the storage.
@Suite("List indent guides")
@MainActor
struct ListIndentGuidesTests {

    private func guides(_ editor: EditorTextView, blockIdx: Int) -> [CGFloat]? {
        let r = editor.blocks[blockIdx].range
        return editor.textStorage?.attribute(.listGuides, at: r.location,
                                             effectiveRange: nil) as? [CGFloat]
    }

    private func slotWidth(_ editor: EditorTextView) -> CGFloat {
        let space = (" " as NSString).size(withAttributes: [.font: editor.bodyFont]).width
        return editor.bodyFont.pointSize + space
    }

    @Test("A top-level item carries only its own column")
    func topLevel() {
        let editor = makeEditor()
        editor.loadContent("- alpha\n")
        #expect(guides(editor, blockIdx: 0) == [editor.listPadding + editor.bodyFont.pointSize / 2])
    }

    @Test("Each level adds one guide, a slot apart")
    func oneGuidePerLevel() {
        let editor = makeEditor()
        editor.loadContent("- alpha\n    - beta\n        - gamma\n            - delta\n")
        let slot = slotWidth(editor)
        let first = editor.listPadding + editor.bodyFont.pointSize / 2
        // depth + 1 offsets: the ancestors, then the item's own column.
        #expect(guides(editor, blockIdx: 0) == [first])
        #expect(guides(editor, blockIdx: 1) == [first, first + slot])
        #expect(guides(editor, blockIdx: 2) == [first, first + slot, first + 2 * slot])
        #expect(guides(editor, blockIdx: 3)?.count == 4)
    }

    @Test("A guide is centered on that level's marker column")
    func centeredOnMarkerColumn() {
        let editor = makeEditor()
        editor.loadContent("- alpha\n    - beta\n        - gamma\n")
        let slot = slotWidth(editor)
        // The depth-k item's marker box is pointSize wide, starting at
        // listPadding + k * slot — the same box the depth-k guide bisects.
        for (k, offset) in (guides(editor, blockIdx: 2) ?? []).enumerated() {
            let markerStart = editor.listPadding + CGFloat(k) * slot
            #expect(offset == markerStart + editor.bodyFont.pointSize / 2)
        }
    }

    @Test("The last offset is the item's own column")
    func ownColumnLast() {
        let editor = makeEditor()
        editor.loadContent("- alpha\n    - beta\n")
        // beta's own column is where a deeper child's ancestor guide would fall.
        let deeper = makeEditor()
        deeper.loadContent("- alpha\n    - beta\n        - gamma\n")
        #expect(guides(editor, blockIdx: 1)?.last == guides(deeper, blockIdx: 2)?.dropLast().last)
    }

    @Test("Tab and space indentation at the same depth give the same guides")
    func tabsMatchSpaces() {
        let spaced = makeEditor()
        spaced.loadContent("- alpha\n    - beta\n        - gamma\n")
        let tabbed = makeEditor()
        tabbed.loadContent("- alpha\n\t- beta\n\t\t- gamma\n")
        #expect(guides(tabbed, blockIdx: 1) == guides(spaced, blockIdx: 1))
        #expect(guides(tabbed, blockIdx: 2) == guides(spaced, blockIdx: 2))
    }

    @Test("Ordered and checkbox items guide like bullets")
    func markerTypesAgree() {
        let bullets = makeEditor()
        bullets.loadContent("- alpha\n    - beta\n")
        let mixed = makeEditor()
        mixed.loadContent("1. alpha\n    - [ ] beta\n")
        #expect(guides(mixed, blockIdx: 1) == guides(bullets, blockIdx: 1))
    }

    @Test("Offsets are container-relative, so an item's own indent doesn't move them")
    func independentOfOwnFirstLineIndent() {
        // An ordered marker right-aligns into its slot, giving the item a very
        // different firstLineHeadIndent than a bullet at the same depth — the
        // guides must not follow it.
        let editor = makeEditor()
        editor.loadContent("- alpha\n    - beta\n    100. gamma\n")
        #expect(guides(editor, blockIdx: 2) == guides(editor, blockIdx: 1))
    }
}
