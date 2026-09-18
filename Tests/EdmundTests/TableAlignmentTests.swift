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

    @Test("A backslash-escaped pipe does not split a cell")
    func escapedPipeNotSeparator() {
        #expect(splitTableRow("| a \\| b | c |").count == 2)
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

    /// A caret in a table used to strip it back to raw monospace. It no longer
    /// does — the table stays aligned and the cell is edited in place — so the
    /// column kern must survive the caret.
    @Test("A caret in a table keeps its alignment kern")
    func caretKeepsAlignment() {
        let editor = makeEditor()
        let table = "| aaa | bbb |\n|--:|--:|\n| x | y |"
        let styled = editor.styleBlock(table, cursorPosition: 2)
        let start = lastRowStart(styled)
        #expect(kern(at: start, in: styled) != nil)
    }

    @Test("A raw table has no alignment kern (raw monospace)")
    func rawUnaffected() {
        let editor = makeEditor()
        editor.rawTableEditing = true
        let table = "| aaa | bbb |\n|--:|--:|\n| x | y |"
        let styled = editor.styleBlock(table, cursorPosition: 2)
        let start = lastRowStart(styled)
        #expect(kern(at: start, in: styled) == nil)
    }

    @Test("Column width uses the styled cell width, not the raw source width")
    func styledWidthAlignment() {
        let editor = makeEditor()
        // Col 0: "**wide**" renders as bold "wide" (4 chars), so the raw
        // 8-char source must not inflate the column. The plain data cell
        // "wide" needs (nearly) no slack once the ** measure ~zero — its
        // only slack is the header's bold-vs-regular width difference.
        let styled = editor.styleBlock("| **wide** | b |\n|---|---|\n| wide | y |", cursorPosition: nil)
        let start = lastRowStart(styled)
        // Data cell content "wide" starts after "| " → trailing char is 'e'
        // at start+5; its left-align kern must be tiny (bold-regular delta),
        // far below the ~4-character width the raw `**`s would add.
        let s = styled.string as NSString
        let cellEnd = s.range(of: "wide", options: [], range: NSRange(location: start, length: styled.length - start))
        #expect(cellEnd.location != NSNotFound)
        let slack = kern(at: cellEnd.upperBound - 1, in: styled) ?? 0
        let twoChars = "aa".size(withAttributes: [.font: editor.bodyFont]).width
        #expect(slack < twoChars)
    }
}

@Suite("Table cell inline styling")
@MainActor
struct TableInlineStylingTests {

    private func table(_ cell: String) -> NSAttributedString {
        makeEditor().styleBlock("| \(cell) | b |\n|---|---|\n| x | y |", cursorPosition: nil)
    }

    @Test("Bold in a header cell renders bold at body size")
    func boldCell() {
        let editor = makeEditor()
        let styled = editor.styleBlock("| a | b |\n|---|---|\n| **bold** | y |", cursorPosition: nil)
        let s = styled.string as NSString
        let bold = s.range(of: "bold")
        let f = styled.attribute(.font, at: bold.location, effectiveRange: nil) as? NSFont
        #expect(f != nil && NSFontManager.shared.traits(of: f!).contains(.boldFontMask))
        // Its ** delimiters are hidden.
        let d = styled.attribute(.font, at: bold.location - 1, effectiveRange: nil) as? NSFont
        #expect((d?.pointSize ?? 99) < 1.0)
    }

    @Test("Inline code in a cell gets the mono font")
    func codeCell() {
        let editor = makeEditor()
        let styled = editor.styleBlock("| a | b |\n|---|---|\n| `code` | y |", cursorPosition: nil)
        let s = styled.string as NSString
        let code = s.range(of: "code", options: .backwards)
        let f = styled.attribute(.font, at: code.location, effectiveRange: nil) as? NSFont
        #expect(f == editor.inlineCodeFont)
    }

    @Test("Link in a cell is colored and carries its destination")
    func linkCell() {
        let editor = makeEditor()
        let styled = editor.styleBlock("| a | b |\n|---|---|\n| [x](http://e.com) | y |", cursorPosition: nil)
        let s = styled.string as NSString
        let x = s.range(of: "[x]", options: .backwards)
        let dest = styled.attribute(.editorLinkURL, at: x.location + 1, effectiveRange: nil) as? String
        #expect(dest == "http://e.com")
    }

    @Test("Header-row styling stays bold when a cell has italic (boldItalic)")
    func headerItalicCell() {
        let editor = makeEditor()
        let styled = editor.styleBlock("| *it* | b |\n|---|---|\n| x | y |", cursorPosition: nil)
        let s = styled.string as NSString
        let it = s.range(of: "it")
        let f = styled.attribute(.font, at: it.location, effectiveRange: nil) as? NSFont
        let traits = f.map { NSFontManager.shared.traits(of: $0) } ?? []
        #expect(traits.contains(.boldFontMask))
        #expect(traits.contains(.italicFontMask))
    }

    @Test("Escaped pipe in a data cell stays visible; structural pipes stay hidden")
    func escapedPipeStaysVisible() {
        let editor = makeEditor()
        let styled = editor.styleBlock("| a | b |\n|---|---|\n| x \\| y | z |", cursorPosition: nil)
        let s = styled.string as NSString
        let escaped = s.range(of: "\\|")
        #expect(escaped.location != NSNotFound)
        let escapedPipeFont = styled.attribute(.font, at: escaped.location + 1, effectiveRange: nil) as? NSFont
        #expect((escapedPipeFont?.pointSize ?? 0) >= 1.0)

        // A structural pipe (the leading pipe of the data row) stays hidden.
        let lastRow = s.range(of: "\n", options: .backwards).location + 1
        let structuralPipeFont = styled.attribute(.font, at: lastRow, effectiveRange: nil) as? NSFont
        #expect((structuralPipeFont?.pointSize ?? 99) < 1.0)
    }

    /// A table with no outer pipes may start its header with a space. cmark
    /// puts the table's source range at the first non-blank column, which used
    /// to leave that space outside the span — and a layout fragment reads its
    /// paragraph style and decoration from character 0, so the header row lost
    /// its column borders and its indent while every row below kept both.
    @Test("A header row indented by a space still owns its row geometry")
    func leadingSpaceHeaderKeepsRowGeometry() {
        let editor = makeEditor()
        let styled = editor.styleBlock(" a | b\n---|---\n c | d", cursorPosition: nil)
        let ps = styled.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        #expect(ps != nil && ps!.firstLineHeadIndent > 0)
        #expect(styled.attribute(.blockDecoration, at: 0, effectiveRange: nil) != nil)
    }

    @Test("Row paragraph geometry survives cell styling (table owns it)")
    func rowGeometryPreserved() {
        let styled = table("**b**")
        // First char of the header row still carries the table's paragraph
        // style (indent = cell padding), not styleBlock's body style.
        let ps = styled.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        #expect(ps != nil && ps!.firstLineHeadIndent > 0)
        // And the row decoration is a table row.
        #expect(styled.attribute(.blockDecoration, at: 0, effectiveRange: nil) != nil)
    }
}
