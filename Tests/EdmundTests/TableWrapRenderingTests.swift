import Testing
import Foundation
import AppKit
@testable import EdmundCore

// A table cell wider than its (clamped) column can't be kern-aligned in
// place — TextKit 2 only wraps a whole paragraph at the container edge, and
// NSTextTable/NSTextBlock are banned (they revert the view to TextKit 1). The
// fix hides that cell's real characters and records a `.tableCellWraps`
// attribute the layout fragment redraws wrapped. See EditorTextView+TextKit2.swift.

@Suite("Table cell wrapping")
@MainActor
struct TableWrapRenderingTests {

    private func lastRowStart(_ styled: NSAttributedString) -> Int {
        let s = styled.string as NSString
        let nl = s.range(of: "\n", options: .backwards)
        return nl.location == NSNotFound ? 0 : nl.location + 1
    }

    private func cellWraps(at offset: Int, in styled: NSAttributedString) -> [TableCellWrap] {
        guard offset < styled.length else { return [] }
        let list = styled.attribute(.tableCellWraps, at: offset, effectiveRange: nil) as? TableCellWrapList
        return list?.wraps ?? []
    }

    @Test("Cells that fit their column carry no wrap attribute")
    func fittingCellsUnaffected() {
        let editor = makeEditor()
        let styled = editor.styleBlock("| a | b |\n|---|---|\n| x | y |", cursorPosition: nil)
        let start = lastRowStart(styled)
        #expect(cellWraps(at: start, in: styled).isEmpty)
        // Existing kern-based alignment still runs for the fitting cell.
        #expect(styled.attribute(.tableCellWraps, at: 0, effectiveRange: nil) == nil)
    }

    @Test("A cell wider than its column gets a wrap marker sized to overflow")
    func overflowingCellGetsWrapMarker() {
        let editor = makeEditor()
        let longText = Array(repeating: "overflow", count: 30).joined(separator: " ")
        let source = "| short | wide |\n|---|---|\n| x | \(longText) |"
        let styled = editor.styleBlock(source, cursorPosition: nil)
        let start = lastRowStart(styled)

        let wraps = cellWraps(at: start, in: styled)
        #expect(wraps.count == 1)
        guard let wrap = wraps.first else { return }
        // The cell's natural width must genuinely exceed the column it was
        // clamped to — otherwise it wouldn't need to wrap at all.
        #expect(wrap.styled.size().width > wrap.contentWidth)
        #expect(wrap.contentWidth > 0)
    }

    /// Advance width from the start of `rowIndex`'s line to the start of its
    /// `cellIndex`-th cell — i.e. where that cell's glyphs actually land.
    private func cellStartX(_ styled: NSAttributedString,
                            rowIndex: Int, cellIndex: Int) -> CGFloat {
        let lines = styled.string.components(separatedBy: "\n")
        var rowStart = 0
        for i in 0..<rowIndex { rowStart += (lines[i] as NSString).length + 1 }
        let cells = cellRanges(in: lines[rowIndex] as NSString)
        let run = NSRange(location: rowStart, length: cells[cellIndex].start)
        return styled.attributedSubstring(from: run).size().width
    }

    @Test("A cell after a wrapping cell still starts at its column's x (#251)")
    func cellAfterWrapKeepsColumnX() {
        let editor = makeEditor()
        let longText = Array(repeating: "overflow", count: 30).joined(separator: " ")
        let source = "| a | b | c |\n|---|---|---|\n| x | \(longText) | y |\n| p | q | r |"
        let styled = editor.styleBlock(source, cursorPosition: nil)

        // Row 2 wraps its middle cell; row 3 doesn't. Both must put their
        // third cell at the same x — the wrapping cell's hidden characters
        // still have to reserve their whole column.
        let wrapRowStart = (source.components(separatedBy: "\n")[0...1]
            .map { ($0 as NSString).length + 1 }).reduce(0, +)
        #expect(!cellWraps(at: wrapRowStart, in: styled).isEmpty)
        let wrapped = cellStartX(styled, rowIndex: 2, cellIndex: 2)
        let plain = cellStartX(styled, rowIndex: 3, cellIndex: 2)
        #expect(abs(wrapped - plain) < 1)
    }

    @Test("A wrapped cell draws from the same x its in-line characters would")
    func wrapDrawXMatchesInlineCellX() {
        let editor = makeEditor()
        let longText = Array(repeating: "overflow", count: 30).joined(separator: " ")
        let source = "| a | b | c |\n|---|---|---|\n| x | \(longText) | y |"
        let styled = editor.styleBlock(source, cursorPosition: nil)
        let rowStart = lastRowStart(styled)

        // `x` is relative to the row's text start, which the drawing code
        // passes in already indented by the cell padding.
        let wraps = cellWraps(at: rowStart, in: styled)
        #expect(wraps.count == 1)
        guard let wrap = wraps.first else { return }
        #expect(abs(wrap.x - cellStartX(styled, rowIndex: 2, cellIndex: 1)) < 0.5)
    }

    /// The editor with `source` styled and the caret parked outside the table,
    /// so its rows are rendered (not shown as raw monospace), plus the layout
    /// fragment of the table row at `rowIndex`.
    private func laidOutRow(_ source: String, rowIndex: Int)
        -> (editor: EditorTextView, fragment: DecoratedTextLayoutFragment, rowStart: Int)? {
        let editor = makeEditor()
        let full = source + "\n\nafter"
        editor.loadContent(full)
        editor.recompose(cursorInRaw: (full as NSString).length)
        editor.layoutSubtreeIfNeeded()
        guard let tlm = editor.textLayoutManager else { return nil }
        tlm.ensureLayout(for: tlm.documentRange)

        let rowStart = source.components(separatedBy: "\n")[0..<rowIndex]
            .reduce(0) { $0 + ($1 as NSString).length + 1 }
        var found: DecoratedTextLayoutFragment?
        tlm.enumerateTextLayoutFragments(from: tlm.documentRange.location,
                                         options: [.ensuresLayout]) { fragment in
            let offset = tlm.offset(from: tlm.documentRange.location,
                                    to: fragment.rangeInElement.location)
            if offset == rowStart { found = fragment as? DecoratedTextLayoutFragment }
            return found == nil
        }
        guard let found else { return nil }
        return (editor, found, rowStart)
    }

    /// `styled` laid out into lines at `width`, the same way the fragment lays
    /// a wrapped cell out for drawing.
    private func scratchLines(_ styled: NSAttributedString, width: CGFloat) -> [NSTextLineFragment] {
        let contentStorage = NSTextContentStorage()
        contentStorage.textStorage = NSTextStorage(attributedString: styled)
        let layoutManager = NSTextLayoutManager()
        contentStorage.addTextLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layoutManager.textContainer = container
        var lines: [NSTextLineFragment] = []
        layoutManager.enumerateTextLayoutFragments(
            from: layoutManager.documentRange.location, options: [.ensuresLayout]
        ) { fragment in
            lines.append(contentsOf: fragment.textLineFragments)
            return true
        }
        return lines
    }

    @Test("A click inside a wrapped cell resolves to the character it landed on")
    func clickInsideWrappedCellIsExact() throws {
        let long = Array(repeating: "overflow", count: 30).joined(separator: " ")
        let source = "| a | b | c |\n|---|---|---|\n| x | \(long) | y |"
        let row = try #require(laidOutRow(source, rowIndex: 2))
        let storage = try #require(row.editor.textStorage)
        let wrap = try #require(
            (storage.attribute(.tableCellWraps, at: row.rowStart, effectiveRange: nil)
                as? TableCellWrapList)?.wraps.first)

        // Sweep the cell's drawn width: without the wrap-aware mapping every
        // one of these lands on the single character carrying the column's
        // kern pad, so the indices must both move and stay inside the cell.
        var indices: [Int] = []
        for x in stride(from: wrap.x + 2, to: wrap.x + wrap.contentWidth, by: 20) {
            let point = CGPoint(x: x, y: row.fragment.layoutFragmentFrame.height / 4)
            if let index = row.fragment.cellWrapCharacterIndex(for: point) {
                indices.append(index)
            }
        }
        #expect(indices.count > 5)
        #expect(Set(indices).count > 5)
        #expect(indices == indices.sorted())
        // Every hit is inside the cell, and the text there is the cell's.
        let cellRange = NSRange(location: wrap.charStart, length: wrap.styled.length)
        #expect(indices.allSatisfy { NSLocationInRange($0, cellRange) })
    }

    @Test("Wrapped cell lines shift for a centered or right-aligned column")
    func wrappedCellHonorsColumnAlignment() throws {
        let long = Array(repeating: "overflow", count: 30).joined(separator: " ")
        for (separator, align) in [("|---|:-:|---|", ColumnAlign.center),
                                   ("|---|--:|---|", ColumnAlign.right)] {
            let source = "| a | b | c |\n\(separator)\n| x | \(long) | y |"
            let row = try #require(laidOutRow(source, rowIndex: 2))
            let storage = try #require(row.editor.textStorage)
            let wrap = try #require(
                (storage.attribute(.tableCellWraps, at: row.rowStart, effectiveRange: nil)
                    as? TableCellWrapList)?.wraps.first)
            #expect(wrap.align == align)

            // The last line is the short one, so it has slack to distribute;
            // a full line has none either way.
            let last = try #require(scratchLines(wrap.styled, width: wrap.contentWidth).last)
            let offset = cellWrapLineOffset(last, contentWidth: wrap.contentWidth, align: align)
            #expect(offset > 0)
            #expect(cellWrapLineOffset(last, contentWidth: wrap.contentWidth, align: .left) == 0)
            if align == .right {
                // Right-aligned means the line's *visible* text ends at the
                // column edge. The cell's trailing space (`… |`) is excluded
                // on purpose — counting it would push the text a space short.
                let text = last.attributedString.attributedSubstring(from: last.characterRange)
                let full = text.size().width
                let lastInk = (text.string as NSString).rangeOfCharacter(
                    from: CharacterSet.whitespacesAndNewlines.inverted, options: .backwards)
                let visible = text.attributedSubstring(
                    from: NSRange(location: 0, length: lastInk.upperBound)).size().width
                #expect(abs(offset + visible - wrap.contentWidth) < 0.5)
                #expect(full > visible)
            }
        }
    }

    @Test("Table storage stays byte-for-byte unchanged when a cell wraps")
    func storageUnchangedByWrapping() {
        let editor = makeEditor()
        let longText = Array(repeating: "overflow", count: 30).joined(separator: " ")
        let source = "| short | wide |\n|---|---|\n| x | \(longText) |"
        let styled = editor.styleBlock(source, cursorPosition: nil)
        #expect(styled.string == source)
    }

    @Test("Every row shares the same column border offsets even with a wrapping row")
    func columnOffsetsConsistentAcrossRows() {
        let editor = makeEditor()
        let longText = Array(repeating: "overflow", count: 30).joined(separator: " ")
        let source = "| short | wide |\n|---|---|\n| x | \(longText) |\n| a | b |"
        let styled = editor.styleBlock(source, cursorPosition: nil)

        var offsetsPerRow: [[CGFloat]] = []
        let s = styled.string as NSString
        var lineStart = 0
        while lineStart <= s.length {
            if case .tableRow(let offsets, _, _, _, _, _)? =
                blockDecoration(at: lineStart, in: styled)?.kind {
                offsetsPerRow.append(offsets)
            }
            let nl = s.range(of: "\n", range: NSRange(location: lineStart, length: s.length - lineStart))
            guard nl.location != NSNotFound else { break }
            lineStart = nl.upperBound
        }
        #expect(offsetsPerRow.count >= 2)
        #expect(offsetsPerRow.dropFirst().allSatisfy { $0 == offsetsPerRow[0] })
    }

    @Test("Every data row gets a bottom grid line, the last one included")
    func bottomBorderOnDataRowsOnly() {
        let editor = makeEditor()
        let styled = editor.styleBlock("| a | b |\n|---|---|\n| x | y |\n| p | q |", cursorPosition: nil)
        var bottoms: [Bool] = []
        let s = styled.string as NSString
        var lineStart = 0
        while lineStart <= s.length {
            if case .tableRow(_, _, _, _, let bottomBorder, _)? =
                blockDecoration(at: lineStart, in: styled)?.kind {
                bottoms.append(bottomBorder)
            }
            let nl = s.range(of: "\n", range: NSRange(location: lineStart, length: s.length - lineStart))
            guard nl.location != NSNotFound else { break }
            lineStart = nl.upperBound
        }
        // Rows: header, separator, "x | y", "p | q". The last row draws its
        // rule too — the table is closed on all four sides, like Notes'. The
        // header's own top rule rides its `topInset`, not this flag, and the
        // separator draws the header divider through its middle instead.
        #expect(bottoms == [false, false, true, true])
    }

    @Test("distributeColumnWidths keeps under-fair-share columns, clamps the rest")
    func distributeColumnWidthsClamps() {
        let result = distributeColumnWidths(natural: [20, 200], available: 100, minWidth: 10)
        #expect(result[0] == 20)
        #expect(result[1] < 200)
        #expect(result[1] >= 10)
    }

    @Test("distributeColumnWidths returns natural widths when everything fits")
    func distributeColumnWidthsNoOp() {
        let result = distributeColumnWidths(natural: [20, 30], available: 1000, minWidth: 10)
        #expect(result == [20, 30])
    }
}
