import Testing
import AppKit
@testable import EdmundCore

/// The handles hang off the grid, and the grid is read back off the same
/// `.tableRow` decoration the fragment draws its borders from — so what these
/// really check is that the two never drift apart.

@Suite("Table handles")
@MainActor
struct TableHandleTests {

    private let doc = "Intro.\n\n| c1 | c2 |\n| --- | --- |\n| a | b |\n| c | d |\n"

    private func loadEditor(_ text: String) -> EditorTextView {
        let editor = makeEditor()
        editor.updateContentInset()
        editor.loadContent(text)
        ensureFullLayout(editor)
        layOutViewport(editor)
        return editor
    }

    /// Puts the caret in a cell and lets the styling and layout catch up, the
    /// way a click would.
    private func caret(_ editor: EditorTextView, to needle: String) {
        let offset = (editor.rawSource as NSString).range(of: needle).location
        editor.setSelectedRange(NSRange(location: offset, length: 0))
        if let block = editor.blockIndexForRawOffset(offset) {
            editor.restyleBlock(block, cursorInBlock: offset - editor.blocks[block].range.location)
        }
        ensureFullLayout(editor)
        layOutViewport(editor)
    }

    private func tableIndex(_ editor: EditorTextView) -> Int {
        editor.blocks.firstIndex { $0.kind == .table } ?? -1
    }

    // MARK: - The grid

    @Test("The grid has a rect per row and an edge per column boundary")
    func gridShape() {
        let editor = loadEditor(doc)
        guard let grid = editor.tableGrid(blockIndex: tableIndex(editor)) else {
            Issue.record("no grid")
            return
        }
        #expect(grid.rows.count == 4)        // header, separator, two body rows
        #expect(grid.columnEdges.count == 3) // left edge, one border, right edge
        #expect(grid.columns == 2)
        // Rows stack downward and do not overlap.
        for (above, below) in zip(grid.rows, grid.rows.dropFirst()) {
            #expect(below.minY >= above.maxY - 0.5)
        }
        // Column edges run left to right.
        for (left, right) in zip(grid.columnEdges, grid.columnEdges.dropFirst()) {
            #expect(right > left)
        }
    }

    /// The internal edges are the decoration's own offsets, which is what keeps
    /// a handle centred on the column the reader sees rather than on a
    /// re-measurement of it.
    @Test("Column edges come from the row decoration")
    func gridMatchesTheDecoration() {
        let editor = loadEditor(doc)
        let block = editor.blocks[tableIndex(editor)]
        guard let grid = editor.tableGrid(blockIndex: tableIndex(editor)),
              let decoration = editor.textStorage?.attribute(
                .blockDecoration, at: block.range.location, effectiveRange: nil) as? BlockDecoration,
              case .tableRow(let offsets, let width, let leftInset, _, _, _) = decoration.kind
        else {
            Issue.record("no decoration")
            return
        }
        #expect(offsets.count == grid.columnEdges.count - 2)
        // The decoration's offsets are measured from the row's text start; the
        // grid's from the table's left edge, one `leftInset` further left.
        for (offset, edge) in zip(offsets, grid.columnEdges.dropFirst()) {
            #expect(abs((edge - grid.columnEdges[0]) - (offset + leftInset)) < 0.5)
        }
        #expect(abs((grid.columnEdges.last! - grid.columnEdges[0]) - width) < 0.5)
    }

    /// The band the column handle sits in belongs to the header row's fragment
    /// but not to the table, or the handle would overlap the header.
    @Test("The reserved band is not part of the header row")
    func headerRowExcludesTheBand() {
        let editor = loadEditor(doc)
        guard let grid = editor.tableGrid(blockIndex: tableIndex(editor)),
              let header = grid.rows.first else {
            Issue.record("no grid")
            return
        }
        caret(editor, to: "c1")
        guard let column = editor.tableHandles().first(where: { $0.axis == .column }) else {
            Issue.record("no column handle")
            return
        }
        #expect(column.rect.maxY <= header.minY)
    }

    // MARK: - The handles

    @Test("A caret in a cell yields a row and a column handle")
    func handlesFollowTheActiveCell() {
        let editor = loadEditor(doc)
        caret(editor, to: "a")
        let handles = editor.tableHandles()
        #expect(handles.count == 2)
        #expect(handles.contains { $0.axis == .row })
        #expect(handles.contains { $0.axis == .column })
    }

    @Test("The handles sit outside the table")
    func handlesSitOutside() {
        let editor = loadEditor(doc)
        caret(editor, to: "b")
        guard let grid = editor.tableGrid(blockIndex: tableIndex(editor)) else {
            Issue.record("no grid")
            return
        }
        for handle in editor.tableHandles() {
            switch handle.axis {
            case .row:    #expect(handle.rect.maxX <= grid.columnEdges[0])
            case .column: #expect(handle.rect.maxY <= grid.rows[0].minY)
            }
        }
    }

    /// The row handle centres on the caret's row, the column handle on its
    /// column — so both move when the caret does.
    @Test("The handles move with the caret")
    func handlesTrackTheCaret() {
        let editor = loadEditor(doc)
        caret(editor, to: "| a")
        guard let firstRow = editor.tableHandles().first(where: { $0.axis == .row }),
              let firstColumn = editor.tableHandles().first(where: { $0.axis == .column })
        else {
            Issue.record("no handles")
            return
        }
        caret(editor, to: "d")
        guard let laterRow = editor.tableHandles().first(where: { $0.axis == .row }),
              let laterColumn = editor.tableHandles().first(where: { $0.axis == .column })
        else {
            Issue.record("no handles")
            return
        }
        #expect(laterRow.rect.midY > firstRow.rect.midY)     // a lower row
        #expect(laterColumn.rect.midX > firstColumn.rect.midX) // a righter column
        #expect(abs(laterRow.rect.minX - firstRow.rect.minX) < 0.5) // same margin slot
    }

    /// The pills name one row and one column, which is not what a block of
    /// cells is — Notes takes them off screen for the duration too.
    @Test("No handles while a block of cells is selected")
    func noHandlesDuringACellSelection() {
        let editor = loadEditor(doc)
        caret(editor, to: "a")
        #expect(!editor.tableHandles().isEmpty)
        let ns = editor.rawSource as NSString
        let from = ns.range(of: "a").location
        editor.setSelectedRange(NSRange(location: from,
                                        length: ns.range(of: "d").location + 1 - from))
        #expect(editor.tableHandles().isEmpty)
    }

    @Test("No handles with the caret outside a table")
    func noHandlesOutsideATable() {
        let editor = loadEditor(doc)
        caret(editor, to: "Intro")
        #expect(editor.tableHandles().isEmpty)
    }

    /// A raw table is showing its pipes; there is no grid to hang a handle off.
    @Test("No handles while the table is raw")
    func noHandlesWhenRaw() {
        let editor = loadEditor(doc)
        caret(editor, to: "c1")
        #expect(!editor.tableHandles().isEmpty)
        editor.rawTableEditing = true
        #expect(editor.tableHandles().isEmpty)
        #expect(editor.activeTableCell == nil)
    }

    // MARK: - Menus

    @Test("A row handle's menu offers the row operations")
    func rowMenuItems() {
        let editor = loadEditor(doc)
        caret(editor, to: "a")
        guard let handle = editor.tableHandles().first(where: { $0.axis == .row }) else {
            Issue.record("no row handle")
            return
        }
        let titles = editor.tableHandleMenu(handle).items.map(\.title)
        // The operations and nothing else — no trailing "Edit as Markdown",
        // and no AutoFill or Shortcuts entry from the text system.
        #expect(titles == ["Add Row Above", "Add Row Below", "Delete Row"])
    }

    @Test("A column handle's menu offers the column operations")
    func columnMenuItems() {
        let editor = loadEditor(doc)
        caret(editor, to: "a")
        guard let handle = editor.tableHandles().first(where: { $0.axis == .column }) else {
            Issue.record("no column handle")
            return
        }
        let titles = editor.tableHandleMenu(handle).items.map(\.title)
        #expect(titles == ["Add Column Before", "Add Column After", "Delete Column"])
    }

    /// The guards the operations enforce have to show up as a greyed item, not
    /// as a menu command that quietly does nothing.
    @Test("Delete is disabled where the operation would refuse")
    func deleteDisabledAtTheLimits() {
        let editor = loadEditor("Intro.\n\n| c1 |\n| --- |\n| a |\n")
        caret(editor, to: "| a")
        guard let column = editor.tableHandles().first(where: { $0.axis == .column }) else {
            Issue.record("no column handle")
            return
        }
        let item = editor.tableHandleMenu(column).items.first { $0.title == "Delete Column" }
        #expect(item?.isEnabled == false)   // the last column

        let bodyless = loadEditor("Intro.\n\n| c1 | c2 |\n| --- | --- |\n")
        caret(bodyless, to: "c1")
        guard let row = bodyless.tableHandles().first(where: { $0.axis == .row }) else {
            Issue.record("no row handle")
            return
        }
        let deleteRow = bodyless.tableHandleMenu(row).items.first { $0.title == "Delete Row" }
        #expect(deleteRow?.isEnabled == false)   // no body row to promote
    }

    // MARK: - The caret in a cell's padding

    /// A column pads by kerning the cell's last character, so that one space
    /// can be hundreds of points wide and a click past its midpoint puts the
    /// caret at the far end of it — drawn out in the middle of the cell rather
    /// than against the text. Measured before the fix: the caret for the cell
    /// end sat at x=652 in a cell spanning 459…802.
    @Test("A caret in a cell's trailing pad snaps back to the text")
    func caretSnapsOutOfThePad() {
        let editor = loadEditor("Intro.\n\n| c1 | c2 |\n| --- | --- |\n| c21 | b |\n")
        let ns = editor.rawSource as NSString
        guard let cell = editor.tableCell(atRawOffset: ns.range(of: "c21").location) else {
            Issue.record("no cell")
            return
        }
        let afterText = ns.range(of: "c21").upperBound
        // The cell's own end is past the text; it comes back to just after "1".
        #expect(editor.tableCellCaretSnap(cell.contentRange.upperBound) == afterText)
        // A caret already on the text is left alone.
        #expect(editor.tableCellCaretSnap(afterText) == nil)
        #expect(editor.tableCellCaretSnap(cell.contentRange.location) == nil)
    }

    /// A pill that has moved has to be repainted where it *was*, and only a
    /// draw knows where that is. The regression this pins: the record used to
    /// be written by the invalidation instead, which runs before the restyle a
    /// click triggers — so a grid that was briefly unavailable made it record
    /// nothing, and the pill it forgot stayed on screen next to the live one.
    @Test("The handles remember where they were drawn, not where they were computed")
    func drawnHandleBandsSurviveAnInvalidation() {
        let editor = loadEditor(doc)
        caret(editor, to: "a")
        let drawn = editor.tableHandles().map { editor.handleHitBox($0) }
        #expect(!drawn.isEmpty)
        drawOffscreen(editor)
        #expect(editor.lastTableHandleBands == drawn)

        // The caret moves to another row and the pills move with it. Until the
        // next draw, the bands the old ones occupy must still be on record.
        caret(editor, to: "c")
        editor.invalidateTableHandles()
        #expect(editor.lastTableHandleBands == drawn)
        drawOffscreen(editor)
        #expect(editor.lastTableHandleBands != drawn)
    }

    /// Runs the background pass the handles draw on, into a throwaway bitmap.
    private func drawOffscreen(_ editor: EditorTextView) {
        let size = NSSize(width: max(1, editor.bounds.width), height: max(1, editor.bounds.height))
        guard let rep = editor.bitmapImageRepForCachingDisplay(
                in: NSRect(origin: .zero, size: size)),
              let context = NSGraphicsContext(bitmapImageRep: rep) else {
            Issue.record("no context")
            return
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        editor.drawTableHandles(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
    }

    /// The failure the offset-only snap could not see: AppKit splits a pad
    /// glyph's advance down the middle, so a click in the far part of a cell's
    /// pad hit-tests as the *next* cell's first character — the caret crosses a
    /// drawn border the click never went near. The point decides the cell.
    @Test("A click in a cell's far pad stays in that cell")
    func farPadClickStaysInTheCell() {
        let editor = loadEditor("Intro.\n\n| c1 | c2 |\n| --- | --- |\n| c21 | b |\n")
        caret(editor, to: "c21")
        let ns = editor.rawSource as NSString
        let index = tableIndex(editor)
        guard let grid = editor.tableGrid(blockIndex: index),
              let box = grid.cellRect(row: 2, column: 0),
              let cell = editor.tableCell(blockIndex: index, row: 2, column: 0) else {
            Issue.record("no grid")
            return
        }
        let afterText = ns.range(of: "c21").upperBound
        let point = NSPoint(x: box.maxX - 2, y: box.midY)
        #expect(editor.tableCell(at: point)?.contentRange == cell.contentRange)
        // Every offset AppKit can hand back for that click — the cell's own
        // end, its closing pipe, the next cell's first character — comes back
        // to the text this cell ends with.
        for stray in [cell.contentRange.upperBound,
                      cell.contentRange.upperBound + 1,
                      cell.contentRange.upperBound + 2] {
            #expect(editor.tableCellCaretSnap(at: point, offset: stray) == afterText)
        }
        // A click on the text itself still leaves AppKit's own answer alone.
        let onText = NSPoint(x: box.minX + 6, y: box.midY)
        #expect(editor.tableCellCaretSnap(at: onText, offset: afterText) == nil)
    }

    /// The cell has to be taken as the selection is installed, not once the
    /// gesture is over. `super.mouseDown` does not return until the mouse comes
    /// up and it paints while it tracks, so a selection installed afterwards is
    /// one the user watches replace whatever AppKit put there first — which is
    /// the caret flash this gesture was reported for.
    @Test("A blank-space double-click takes the cell in flight")
    func padDoubleClickIsInstalledInFlight() {
        let editor = loadEditor("Intro.\n\n| a rather wide heading | c2 |\n"
            + "| --- | --- |\n| c21 | b |\n")
        caret(editor, to: "c21")
        let ns = editor.rawSource as NSString
        let index = tableIndex(editor)
        guard let grid = editor.tableGrid(blockIndex: index),
              let box = grid.cellRect(row: 2, column: 0),
              let cell = editor.tableCell(blockIndex: index, row: 2, column: 0) else {
            Issue.record("no grid")
            return
        }
        editor.tableClickPoint = NSPoint(x: box.maxX - 2, y: box.midY)
        editor.tableClickCount = 2
        editor.tableClickHit = cell.contentRange.upperBound
        defer {
            editor.tableClickPoint = nil
            editor.tableClickCount = 0
            editor.tableClickHit = nil
        }
        // Whatever AppKit installs for that click — a caret out at the cell's
        // far edge is what it installed in the report — comes out as the cell.
        for stray in [cell.contentRange.upperBound, cell.contentRange.upperBound + 1] {
            editor.setSelectedRange(NSRange(location: stray, length: 0))
            #expect(editor.selectedRange() == ns.range(of: "c21"))
        }
    }

    /// A click on a wrapped cell's drawn text has one right answer — the
    /// character it landed on in the scratch layout — and it has to be the
    /// first selection installed. Applied after the gesture, it was a second
    /// answer, and the caret visibly jumped from the first one to it.
    @Test("A click in a wrapped cell installs its caret in flight")
    func wrappedCellClickIsInstalledInFlight() {
        let editor = loadEditor("Intro.\n\n| a | b |\n| --- | --- |\n| "
            + String(repeating: "long ", count: 30) + " | b2 |\n")
        caret(editor, to: "long")
        let ns = editor.rawSource as NSString
        let text = ns.range(of: "long long")
        guard let cell = editor.tableCell(atRawOffset: text.location) else {
            Issue.record("no cell")
            return
        }
        // The answer the scratch layout gave for the click: mid-text.
        let landed = text.location + 7
        editor.tableClickPoint = NSPoint(x: 0, y: 0)   // any point; the answer is given
        editor.tableClickWrappedCaret = landed
        defer {
            editor.tableClickPoint = nil
            editor.tableClickWrappedCaret = nil
        }
        // Whatever AppKit installs from the hidden characters — the cell's
        // start, its end — comes out as the landed character.
        for stray in [cell.contentRange.location, cell.contentRange.upperBound] {
            editor.setSelectedRange(NSRange(location: stray, length: 0))
            #expect(editor.selectedRange() == NSRange(location: landed, length: 0))
        }
    }

    /// The correction has to happen as the selection is installed, not after
    /// the gesture. `super.mouseDown` does not return until the mouse comes up
    /// and it paints while it tracks, so a caret corrected afterwards is one
    /// the user watches sit in the wrong place and then jump.
    @Test("A click's caret is corrected before it is ever installed")
    func clickCaretIsCorrectedInFlight() {
        let editor = loadEditor("Intro.\n\n| c1 | c2 |\n| --- | --- |\n| c21 | b |\n")
        caret(editor, to: "c21")
        let ns = editor.rawSource as NSString
        let afterText = ns.range(of: "c21").upperBound
        let index = tableIndex(editor)
        guard let grid = editor.tableGrid(blockIndex: index),
              let box = grid.cellRect(row: 2, column: 0),
              let cell = editor.tableCell(blockIndex: index, row: 2, column: 0) else {
            Issue.record("no grid")
            return
        }
        editor.tableClickPoint = NSPoint(x: box.maxX - 2, y: box.midY)
        defer { editor.tableClickPoint = nil }
        // Every offset AppKit's own hit test could hand back for that click.
        for stray in [cell.contentRange.upperBound, cell.contentRange.upperBound + 1] {
            editor.setSelectedRange(NSRange(location: stray, length: 0))
            #expect(editor.selectedRange() == NSRange(location: afterText, length: 0))
        }
    }

    /// The pipe is invisible and carries half its column's padding as kern, so
    /// a caret resting on one appears to float in the middle of the cell's
    /// blank space. Whatever put it there, it does not stay.
    @Test("A caret never rests on a hidden pipe")
    func caretNeverRestsOnAPipe() {
        let editor = loadEditor("Intro.\n\n| c1 | c2 |\n| --- | --- |\n| c21 | b |\n")
        caret(editor, to: "c21")
        let ns = editor.rawSource as NSString
        let afterText = ns.range(of: "c21").upperBound
        guard let cell = editor.tableCell(atRawOffset: ns.range(of: "c21").location) else {
            Issue.record("no cell")
            return
        }
        let pipe = cell.contentRange.upperBound
        #expect(ns.substring(with: NSRange(location: pipe, length: 1)) == "|")

        // Reached from the left: forward, to the text of the cell it opens.
        editor.setSelectedRange(NSRange(location: afterText, length: 0))
        editor.setSelectedRange(NSRange(location: pipe, length: 0))
        let forward = editor.selectedRange().location
        #expect(forward != pipe)
        #expect(forward > pipe)

        // Reached from the right: back to the text of the cell it closes.
        editor.setSelectedRange(NSRange(location: pipe + 2, length: 0))
        editor.setSelectedRange(NSRange(location: pipe, length: 0))
        #expect(editor.selectedRange().location == afterText)

        // A pipe outside a rendered table is an ordinary character.
        let plain = loadEditor("a | b\n")
        let bar = (plain.rawSource as NSString).range(of: "|").location
        plain.setSelectedRange(NSRange(location: bar, length: 0))
        #expect(plain.selectedRange().location == bar)
    }

    /// The whole invariant, walked: from every offset in a table, arrowing one
    /// step in either direction lands the caret on a cell's text — never in the
    /// padding beside a pipe, never on a pipe. `previous` is the step's origin,
    /// so the resting rule reads the direction the way an arrow key would.
    @Test("No arrow step ever rests the caret in padding or on a pipe")
    func noArrowStepRestsInDeadSpace() {
        let editor = loadEditor("Intro.\n\n| aa | bb | cc |\n| --- | --- | --- |\n"
            + "| x | longer | z |\n|  | q |  |\n")
        let ns = editor.rawSource as NSString
        guard let index = editor.blocks.firstIndex(where: { $0.kind == .table }) else {
            Issue.record("no table")
            return
        }
        let table = editor.blocks[index].range
        // Every offset a caret could be moved to inside the table, stepped from
        // each side. The separator row is skipped: its dashes are ordinary text.
        for target in table.location...table.upperBound {
            for previous in [target - 1, target + 1] {
                guard let landing = editor.tableCellCaretResting(target, from: previous) else {
                    // No correction: the target must itself be a live position.
                    if let cell = editor.tableCell(atRawOffset: target), cell.row != 1 {
                        let live = editor.tableCellLiveRange(cell)
                        #expect(target >= live.lower && target <= live.upper,
                                "offset \(target) rests uncorrected outside the text")
                    }
                    continue
                }
                // A correction must land on some cell's live text.
                guard let cell = editor.tableCell(atRawOffset: landing) else {
                    Issue.record("landing \(landing) is not in any cell")
                    continue
                }
                let live = editor.tableCellLiveRange(cell)
                #expect(landing >= live.lower && landing <= live.upper,
                        "step \(previous)->\(target) landed at \(landing), in dead space")
                // Never on a pipe. (An empty cell's one caret spot is a pad
                // space by necessity — there is no text — so a pad landing is
                // only wrong when it is outside the cell's live range, which the
                // check above already covers.)
                #expect(!editor.tableStructuralPipe(at: landing))
            }
        }
    }

    /// A double-click needs a word, and out in a cell's padding there is none.
    /// The next unit up is the cell, which is what a double-click in a
    /// spreadsheet gives you too.
    @Test("A double-click on a cell's empty space selects the cell's contents")
    func padDoubleClickSelectsTheCell() {
        // A wide column, so there is real empty space beside a short cell —
        // the case this is for. In a column the width of its own text there is
        // nowhere to put the gesture.
        let editor = loadEditor("Intro.\n\n| a rather wide heading | c2 |\n"
            + "| --- | --- |\n| c21 | b |\n")
        caret(editor, to: "c21")
        let ns = editor.rawSource as NSString
        let index = tableIndex(editor)
        guard let grid = editor.tableGrid(blockIndex: index),
              let box = grid.cellRect(row: 2, column: 0) else {
            Issue.record("no grid")
            return
        }
        guard let ref = editor.tableCell(blockIndex: index, row: 2, column: 0) else {
            Issue.record("no cell")
            return
        }
        let text = editor.tableCellTextRange(ref)
        // Out in the padding, at either end of it. The hit index is what AppKit
        // rounds the pointer to: the trailing space at the near end, the row's
        // hidden pipe at the far end — both past the cell's text, which is the
        // whole point. Neither end may be read as a click on the text.
        for (x, hit) in [(box.midX, text.upperBound),
                         (box.maxX - 2, ref.contentRange.upperBound)] {
            #expect(editor.tableCellEmptySpace(at: NSPoint(x: x, y: box.midY),
                                               hit: hit) != nil)
        }
        // No glyph under the pointer at all is empty space too.
        #expect(editor.tableCellEmptySpace(at: NSPoint(x: box.maxX - 2, y: box.midY),
                                           hit: nil) != nil)
        // On the text it is an ordinary double-click, whatever it selects.
        #expect(editor.tableCellEmptySpace(at: NSPoint(x: box.minX + 6, y: box.midY),
                                           hit: text.location) == nil)

        // What the gesture then does: the cell's contents, without the padding
        // or the delimiters.
        guard let cell = editor.tableCellEmptySpace(
            at: NSPoint(x: box.maxX - 2, y: box.midY), hit: nil) else {
            Issue.record("no cell")
            return
        }
        editor.selectCellText(cell)
        #expect(editor.selectedRange() == ns.range(of: "c21"))
        #expect(ns.substring(with: editor.selectedRange()) == "c21")

        // The grid is not always able to supply a cell for the block under the
        // pointer — in a real document it returns nothing often enough that the
        // gesture cannot depend on it. A point nowhere near the table stands in
        // for that here: the offset AppKit hit still resolves the pad.
        let nowhere = NSPoint(x: -500, y: -500)
        #expect(editor.tableCell(at: nowhere) == nil)
        #expect(editor.tableCellEmptySpace(at: nowhere,
                                           hit: ref.contentRange.upperBound)?.contentRange
                == ref.contentRange)
        // Still not a licence to fire on text: an offset on the text is on the
        // text whatever the pointer is doing.
        #expect(editor.tableCellEmptySpace(at: nowhere, hit: text.location) == nil)

        // A raw table has no grid, so no point resolves to a cell.
        editor.activateRawTableEditing(blockIndex: index)
        #expect(editor.rawTableEditing)
        #expect(editor.tableCellEmptySpace(at: NSPoint(x: box.maxX - 2, y: box.midY),
                                           hit: nil) == nil)
    }

    /// The regression the resting rule introduced: it read a direction into a
    /// click. A caret arriving at a pipe from earlier in the document looked
    /// like forward motion, so a click near the end of a long cell was sent to
    /// the beginning of the next column's cell instead of back to its own text.
    @Test("A click near a cell's end stays in that cell")
    func clickNearTheEndStaysPut() {
        let editor = loadEditor("Intro.\n\n| c1 | c2 |\n| --- | --- |\n| c21 | b |\n")
        caret(editor, to: "c21")
        let ns = editor.rawSource as NSString
        let afterText = ns.range(of: "c21").upperBound
        let index = tableIndex(editor)
        guard let grid = editor.tableGrid(blockIndex: index),
              let box = grid.cellRect(row: 2, column: 0),
              let cell = editor.tableCell(blockIndex: index, row: 2, column: 0) else {
            Issue.record("no grid")
            return
        }
        let pipe = cell.contentRange.upperBound
        // Right against the closing border, with the caret coming from before
        // it — which is what made the old rule call this forward motion.
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        editor.tableClickPoint = NSPoint(x: box.maxX - 1, y: box.midY)
        defer { editor.tableClickPoint = nil }
        editor.setSelectedRange(NSRange(location: pipe, length: 0))
        #expect(editor.selectedRange() == NSRange(location: afterText, length: 0))
    }

    /// A drag across a cell's padding sweeps up the pad's kerned space and the
    /// row's hidden pipe. Both are invisible, so the highlight looks like it
    /// covers blank space — and a copy takes a delimiter with it.
    @Test("A selection inside a cell covers its text and nothing else")
    func selectionStopsAtTheCellText() {
        let editor = loadEditor("Intro.\n\n| c1 | c2 |\n| --- | --- |\n| c21 | b |\n")
        caret(editor, to: "c21")
        let ns = editor.rawSource as NSString
        let text = ns.range(of: "c21")
        guard let cell = editor.tableCell(atRawOffset: text.location) else {
            Issue.record("no cell")
            return
        }
        // From the cell's first character through its closing pipe.
        editor.setSelectedRange(NSRange(location: cell.contentRange.location,
                                        length: cell.contentRange.length + 1))
        #expect(editor.selectedRange() == text)
        let selected = ns.substring(with: editor.selectedRange())
        #expect(!selected.contains("|"))
        #expect(selected == "c21")
        // A selection already inside the text is left exactly as it is.
        let inner = NSRange(location: text.location, length: 2)
        editor.setSelectedRange(inner)
        #expect(editor.selectedRange() == inner)
    }

    /// A double-click has to find a word. In a cell's padding there is none —
    /// the pad is one kerned space with the row's hidden pipe beside it — so
    /// AppKit selects one of those, and a one-character selection of an
    /// invisible glyph draws exactly like a caret stranded mid-cell.
    @Test("A double-click in a cell's pad catches only delimiters")
    func padDoubleClickIsJunk() {
        let editor = loadEditor("Intro.\n\n| c1 | c2 |\n| --- | --- |\n| c21 | b |\n")
        caret(editor, to: "c21")
        let ns = editor.rawSource as NSString
        let index = tableIndex(editor)
        guard let grid = editor.tableGrid(blockIndex: index),
              let box = grid.cellRect(row: 2, column: 0),
              let cell = editor.tableCell(blockIndex: index, row: 2, column: 0) else {
            Issue.record("no grid")
            return
        }
        let inThePad = NSPoint(x: box.maxX - 2, y: box.midY)
        // The closing pipe, and the padded space before it.
        let pipe = NSRange(location: cell.contentRange.upperBound, length: 1)
        let pad = NSRange(location: cell.contentRange.upperBound - 1, length: 1)
        #expect(ns.substring(with: pipe) == "|")
        #expect(ns.substring(with: pad) == " ")
        #expect(editor.tableCellSelectionIsJunk(pipe, at: inThePad))
        #expect(editor.tableCellSelectionIsJunk(pad, at: inThePad))
        // A double-click that did find a word keeps it.
        let word = ns.range(of: "c21")
        let onText = NSPoint(x: box.minX + 6, y: box.midY)
        #expect(!editor.tableCellSelectionIsJunk(word, at: onText))
        // And nothing outside a table is ever junk — the rule is about pads.
        #expect(!editor.tableCellSelectionIsJunk(ns.range(of: "Intro"),
                                                 at: NSPoint(x: 5, y: 5)))
    }

    /// An all-blank cell has no text to snap to, so it keeps one space — the
    /// same rule `selectCellText` uses, so typing does not eat the pad before
    /// the closing pipe.
    @Test("An empty cell snaps one space in, not to its far end")
    func emptyCellSnapsOneSpaceIn() {
        let editor = loadEditor("Intro.\n\n| c1 | c2 |\n| --- | --- |\n|    | b |\n")
        let ns = editor.rawSource as NSString
        let row = ns.range(of: "|    |").location
        guard let cell = editor.tableCell(atRawOffset: row + 2) else {
            Issue.record("no cell")
            return
        }
        #expect(editor.tableCellCaretSnap(cell.contentRange.upperBound)
                == cell.contentRange.location + 1)
    }

    @Test("Nothing snaps outside a table")
    func noSnapOutsideATable() {
        let editor = loadEditor(doc)
        #expect(editor.tableCellCaretSnap((editor.rawSource as NSString)
                                            .range(of: "Intro").location + 2) == nil)
    }

    // MARK: - Cell selection

    /// A selection that stops inside two different cells is widened to cover
    /// both whole — the box has to be able to say what a Copy would take — and
    /// is installed as one range per row. A single range spanning both rows
    /// would cover row 2 through its newline, and AppKit runs the highlight of
    /// such a line out to the text container's edge, far past the table.
    @Test("A cross-cell selection snaps to whole cells, one range per row")
    func crossCellSelectionSnaps() {
        let editor = loadEditor(doc)
        let ns = editor.rawSource as NSString
        let from = ns.range(of: "a").location
        let to = ns.range(of: "d").location + 1
        editor.setSelectedRange(NSRange(location: from, length: to - from))

        let ranges = editor.selectedRanges.map(\.rangeValue)
        #expect(ranges.count == 2)
        for (range, row) in zip(ranges, [2, 3]) {
            guard let first = editor.tableCell(blockIndex: tableIndex(editor), row: row, column: 0),
                  let last = editor.tableCell(blockIndex: tableIndex(editor), row: row, column: 1)
            else {
                Issue.record("no cells in row \(row)")
                continue
            }
            #expect(range == NSRange(
                location: first.contentRange.location,
                length: last.contentRange.upperBound - first.contentRange.location))
            // Stops at the last cell, never over the newline that ends the row.
            #expect(ns.character(at: range.upperBound) != 0x0A)
        }
        // Idempotent, or a drag tick would creep the selection.
        editor.setSelectedRanges(editor.selectedRanges, affinity: .downstream,
                                 stillSelecting: false)
        #expect(editor.selectedRanges.map(\.rangeValue) == ranges)
    }

    @Test("A selection inside one cell is left alone")
    func withinOneCellDoesNotSnap() {
        let editor = loadEditor("Intro.\n\n| c1 | c2 |\n| --- | --- |\n| alpha | b |\n")
        let ns = editor.rawSource as NSString
        let range = NSRange(location: ns.range(of: "alpha").location, length: 3)
        editor.setSelectedRange(range)
        #expect(editor.selectedRange() == range)
        #expect(editor.tableCellSelection == nil)
        #expect(editor.tableCellSelectionBox() == nil)
        // Its text highlight is AppKit's own — only a block of cells drops it.
        #expect(editor.tableCellHighlightSuppressed == false)
    }

    /// Notes drops the text highlight the moment a drag crosses out of its
    /// cell: what is selected then is cells, and the box is the only marker.
    @Test("A block of cells drops the text highlight, a single cell keeps it")
    func cellBlockDropsTheHighlight() {
        let editor = loadEditor(doc)
        let ns = editor.rawSource as NSString
        let from = ns.range(of: "a").location
        let to = ns.range(of: "d").location + 1
        editor.setSelectedRange(NSRange(location: from, length: to - from))
        #expect(editor.tableCellHighlightSuppressed)
        #expect(editor.selectedTextAttributes[.backgroundColor] as? NSColor == .clear)

        editor.setSelectedRange(NSRange(location: from, length: 1))
        #expect(editor.tableCellHighlightSuppressed == false)
        #expect(editor.selectedTextAttributes[.backgroundColor] as? NSColor != .clear)
    }

    /// Once a drag has left its cell, coming back to one selects that cell
    /// whole — the gesture stays a cell-picking gesture rather than reverting
    /// to picking characters partway through.
    @Test("Returning to one cell after crossing selects it whole")
    func returningToOneCellSelectsItWhole() {
        let editor = loadEditor(doc)
        let ns = editor.rawSource as NSString
        let from = ns.range(of: "a").location
        // Cross into another cell...
        editor.setSelectedRange(NSRange(location: from,
                                        length: ns.range(of: "d").location + 1 - from))
        #expect(editor.tableCellSelection != nil)
        // ...then back inside the first one.
        editor.setSelectedRange(NSRange(location: from, length: 1))
        guard let cell = editor.tableCell(blockIndex: tableIndex(editor), row: 2, column: 0) else {
            Issue.record("no cell")
            return
        }
        #expect(editor.selectedRange() == cell.contentRange)

        // A drag that never left its cell keeps its own range.
        editor.tableDragCrossedCells = false
        editor.setSelectedRange(NSRange(location: from, length: 1))
        #expect(editor.selectedRange() == NSRange(location: from, length: 1))
    }

    /// The box is the hull of the cells, and it stays inside the table — the
    /// bug it replaces was a highlight running to the text container's edge.
    @Test("The selection box is the hull of the selected cells")
    func selectionBoxIsTheHull() {
        let editor = loadEditor(doc)
        let ns = editor.rawSource as NSString
        let from = ns.range(of: "a").location
        let to = ns.range(of: "d").location + 1
        editor.setSelectedRange(NSRange(location: from, length: to - from))

        guard let grid = editor.tableGrid(blockIndex: tableIndex(editor)),
              let box = editor.tableCellSelectionBox(),
              let topLeft = grid.cellRect(row: 2, column: 0),
              let bottomRight = grid.cellRect(row: 3, column: 1) else {
            Issue.record("no box")
            return
        }
        #expect(abs(box.minX - topLeft.minX) < 0.5)
        #expect(abs(box.maxX - bottomRight.maxX) < 0.5)
        #expect(abs(box.minY - topLeft.minY) < 0.5)
        #expect(abs(box.maxY - bottomRight.maxY) < 0.5)
        // Inside the table, not out at the container edge.
        #expect(box.maxX <= grid.columnEdges.last! + 0.5)
    }

    /// The dots drag the box wider by holding the opposite corner, so a grab on
    /// the bottom-right one has to anchor on the top-left cell.
    @Test("A dot grab anchors on the opposite corner")
    func dotGrabAnchorsOnTheOppositeCorner() {
        let editor = loadEditor(doc)
        let ns = editor.rawSource as NSString
        let from = ns.range(of: "a").location
        let to = ns.range(of: "b").location + 1
        editor.setSelectedRange(NSRange(location: from, length: to - from))
        guard let box = editor.tableCellSelectionBox() else {
            Issue.record("no box")
            return
        }
        let grab = editor.tableCellSelectionAnchor(at: NSPoint(x: box.maxX, y: box.maxY))
        #expect(grab?.anchor.row == 2)
        #expect(grab?.anchor.column == 0)
        // Nowhere near a dot.
        #expect(editor.tableCellSelectionAnchor(at: NSPoint(x: box.midX, y: box.midY)) == nil)
    }

    /// Extending to a further cell must not stop at the separator row, which
    /// holds no text and is never a selectable corner.
    @Test("Extending across the header skips the separator row")
    func extendingSkipsTheSeparator() {
        let editor = loadEditor(doc)
        editor.selectTableCells(blockIndex: tableIndex(editor), from: (0, 0), to: (3, 1))
        guard let block = editor.tableCellSelection else {
            Issue.record("no selection")
            return
        }
        #expect(block.rows == 0...3)
        #expect(block.columns == 0...1)
        guard let grid = editor.tableGrid(blockIndex: tableIndex(editor)) else { return }
        // A point on the separator resolves to a real row either side of it.
        let onSeparator = NSPoint(x: grid.columnEdges[0] + 1, y: grid.rows[1].midY + 1)
        #expect(editor.tableCellPosition(at: onSeparator,
                                         blockIndex: tableIndex(editor))?.row == 2)
    }

    /// The reported glitch: dragging diagonally out of a header cell flashed
    /// the box across the table's full width before it settled.
    ///
    /// A selection's character range is linear, so the range for that drag ran
    /// through the whole rest of the header row on its way down — which reads
    /// as "the header row, every column". The drag is a rectangle between two
    /// cells, and that is what it is read off now.
    @Test("A diagonal drag covers the rectangle between two cells")
    func diagonalDragIsARectangle() {
        let editor = loadEditor("Intro.\n\n| a | b | c |\n| --- | --- | --- |\n"
            + "| 1 | 2 | 3 |\n| 4 | 5 | 6 |\n")
        caret(editor, to: "a")
        let index = tableIndex(editor)
        guard let grid = editor.tableGrid(blockIndex: index),
              let headerCell = grid.cellRect(row: 0, column: 0),
              let middle = grid.cellRect(row: 2, column: 1),
              let last = grid.cellRect(row: 3, column: 2) else {
            Issue.record("no grid")
            return
        }
        let from = NSPoint(x: headerCell.midX, y: headerCell.midY)

        // Down and one column across: the header's other columns are not in it.
        let block = editor.tableCellBlock(fromPoint: from,
                                          toPoint: NSPoint(x: middle.midX, y: middle.midY))
        #expect(block?.rows == 0...2)
        #expect(block?.columns == 0...1)

        // The far corner takes the whole grid.
        let whole = editor.tableCellBlock(fromPoint: from,
                                          toPoint: NSPoint(x: last.midX, y: last.midY))
        #expect(whole?.rows == 0...3)
        #expect(whole?.columns == 0...2)

        // Still inside the cell it started in: an ordinary text selection.
        #expect(editor.tableCellBlock(fromPoint: from,
                                      toPoint: NSPoint(x: headerCell.midX + 2,
                                                       y: headerCell.midY)) == nil)
    }

    /// A right-click used to select the cell's text. It no longer does: moving
    /// the selection under a menu the user only meant to open is a surprise.
    @Test("A cell's context menu leaves the selection alone")
    func contextMenuDoesNotSelectTheCell() {
        let editor = loadEditor(doc)
        caret(editor, to: "a")
        let before = editor.selectedRange()
        let menu = NSMenu()
        editor.addTableItems(to: menu, blockIndex: tableIndex(editor), row: 2, column: 0, axis: nil)
        #expect(editor.selectedRange() == before)
        #expect(editor.tableCellSelectionBox() == nil)
    }

    /// "Add Row Below" on the header has to skip the separator, or the new row
    /// would land on line 1 and stop the block parsing as a table.
    @Test("Add Row Below on the header targets the first body row")
    func addRowBelowHeaderSkipsSeparator() {
        let editor = loadEditor(doc)
        caret(editor, to: "c1")
        guard let handle = editor.tableHandles().first(where: { $0.axis == .row }),
              let item = editor.tableHandleMenu(handle).items
                .first(where: { $0.title == "Add Row Below" }),
              let op = item.representedObject as? TableOperation else {
            Issue.record("no operation")
            return
        }
        #expect(op.row == 2)
        editor.performTableOperation(item)
        #expect(editor.rawSource
                == "Intro.\n\n| c1 | c2 |\n| --- | --- |\n|  |  |\n| a | b |\n| c | d |\n")
        #expect(editor.blocks.contains { $0.kind == .table })
    }
}
