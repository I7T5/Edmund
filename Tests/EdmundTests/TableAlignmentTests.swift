import Testing
import Foundation
import AppKit
@testable import EdmundCore

// GFM table column alignment (`:--`/`:-:`/`--:`) applied in the live editor.
// The non-active render distributes each cell's slack via `.kern`: left pads
// after content, right pads before it (on the leading hidden pipe), center
// splits. The kern *location* encodes the alignment.

@Suite("Table column alignment — parsing")
struct TableAlignmentParseTests {

    @Test("Separator row maps to left/center/right")
    func mixed() {
        #expect(tableColumnAlignments(separatorRow: "|:--|:-:|--:|", count: 3)
                == [.left, .center, .right])
    }

    @Test("Plain `---` columns default to left")
    func plain() {
        #expect(tableColumnAlignments(separatorRow: "| --- | --- |", count: 2)
                == [.left, .left])
    }

    @Test("Missing cells pad with .left")
    func shortRow() {
        #expect(tableColumnAlignments(separatorRow: "|--:|", count: 3)
                == [.right, .left, .left])
    }
}

@Suite("Table column alignment — rendering")
@MainActor
struct TableAlignmentRenderTests {

    /// Offset of the leading `|` of the table's last (data) row.
    private func lastRowStart(_ styled: NSAttributedString) -> Int {
        let s = styled.string as NSString
        let nl = s.range(of: "\n", options: .backwards)
        return nl.location == NSNotFound ? 0 : nl.location + 1
    }

    private func kern(at offset: Int, in styled: NSAttributedString) -> CGFloat? {
        guard offset < styled.length else { return nil }
        return styled.attribute(.kern, at: offset, effectiveRange: nil) as? CGFloat
    }

    @Test("Right-aligned column kerns the leading pipe of the data cell")
    func rightAlign() {
        let editor = makeEditor()
        let styled = editor.styleBlock("| aaa | bbb |\n|--:|--:|\n| x | y |", cursorPosition: nil)
        let start = lastRowStart(styled)
        // Leading pipe of col 0 carries the right-pad kern.
        #expect((kern(at: start, in: styled) ?? 0) > 0.5)
    }

    @Test("Left-aligned column does NOT kern the leading pipe")
    func leftAlign() {
        let editor = makeEditor()
        let styled = editor.styleBlock("| aaa | bbb |\n|---|---|\n| x | y |", cursorPosition: nil)
        let start = lastRowStart(styled)
        // Slack sits after the content, not on the leading pipe.
        #expect(kern(at: start, in: styled) == nil)
    }

    @Test("Active table has no alignment kern (raw monospace)")
    func activeUnaffected() {
        let editor = makeEditor()
        let table = "| aaa | bbb |\n|--:|--:|\n| x | y |"
        let styled = editor.styleBlock(table, cursorPosition: 2)
        let start = lastRowStart(styled)
        #expect(kern(at: start, in: styled) == nil)
    }
}
