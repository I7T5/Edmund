import AppKit

/// Table styling: the largest single case of the `styleBlock` switch. When the
/// caret is inside, the table shows as dimmed monospace; otherwise it's laid out
/// with a bold header, hidden pipes, kern-padded columns, and drawn borders (via
/// a `.tableRow` BlockDecoration). Row parsing helpers live in
/// EditorTextView+TableSupport; extracted from EditorTextView+Rendering.
extension EditorTextView {

    /// Styles the `.table` content for one span. The caller has already
    /// bounds-checked `span.fullRange` against `result`.
    /// Every row wraps its overflowing cells, the row holding the caret
    /// included: the caret follows the drawn text through
    /// `DecoratedTextLayoutFragment.cellWrapRects` (see
    /// EditorTextView+TableCellCaret), so nothing has to run long to stay
    /// editable.
    func styleTableSpan(_ result: NSMutableAttributedString,
                        span: SyntaxHighlighter.Span,
                        cursorInToken: Bool) {
        if cursorInToken {
            // Active: monospace, all pipes dimmed
            result.addAttribute(.font, value: tableFont, range: span.fullRange)
            let nsStr = (result.string as NSString)
            var sr = span.fullRange
            while sr.length > 0 {
                let pr = nsStr.range(of: "|", options: [], range: sr)
                guard pr.location != NSNotFound else { break }
                result.addAttribute(.foregroundColor, value: syntaxDimColor, range: pr)
                let ns = pr.upperBound
                sr = NSRange(location: ns, length: max(0, span.fullRange.upperBound - ns))
            }
        } else {
            // Non-active: bold header, hidden pipes, column-width alignment
            // via kern, drawn vertical + horizontal borders via TableRowTextBlock,
            // with cell padding for breathing room. A cell wider than its
            // column instead hides its real characters and gets redrawn
            // wrapped via `.tableCellWraps` (see EditorTextView+TextKit2.swift).
            let tableNS = (result.string as NSString)
            let tableStr = tableNS.substring(with: span.fullRange)
            let lines = tableStr.components(separatedBy: "\n")

            // Room to breathe inside a cell. At 0.3/0.15 the text all but
            // touched the column border it sits against; half an em beside it
            // and a quarter above and below reads like a table rather than
            // like text with lines drawn through it, and stays close to the
            // row height Notes uses at the same body size.
            let cellHPad = bodyFont.pointSize * 0.5
            let cellVPad = bodyFont.pointSize * 0.25

            // --- Style each cell's inline markdown and measure the result ---
            // Each cell runs through styleBlock so `**bold**`, `code`, links,
            // ==marks== etc. render inside tables; hidden delimiters measure
            // ~zero, so column widths reflect what's actually visible. Header
            // cells are bolded before measuring.
            // ponytail: block-level markdown in a cell (`# x`, `- x`) keeps its
            // fonts but loses its block chrome (paragraph styles / decorations
            // are row-owned, see the transplant below); tall math or image
            // overlays get no extra line height in cells. A wrapped (overflowing)
            // cell is drawn from a detached scratch text layout rather than the
            // live glyph run, so its caret, selection and vertical movement all
            // come from that layout instead (EditorTextView+TableCellCaret).
            let headerCells = splitTableRow(lines[0])
            let numCols = headerCells.count
            guard numCols > 0 else { return }
            var natural = [CGFloat](repeating: 0, count: numCols)
            // Per line: the cell's character range within the line + its
            // styled form (empty for the separator row).
            var rowCells: [[(start: Int, end: Int, styled: NSAttributedString)]] = []
            for (li, line) in lines.enumerated() {
                guard li != 1 else { rowCells.append([]); continue }
                let lineNS = line as NSString
                var cells: [(start: Int, end: Int, styled: NSAttributedString)] = []
                for cr in cellRanges(in: lineNS) {
                    let text = lineNS.substring(with: NSRange(location: cr.start,
                                                              length: cr.end - cr.start))
                    let styled = NSMutableAttributedString(
                        attributedString: styleBlock(text, cursorPosition: nil))
                    if li == 0 {
                        styled.enumerateAttribute(
                            .font, in: NSRange(location: 0, length: styled.length)
                        ) { value, r, _ in
                            guard let f = value as? NSFont else { return }
                            styled.addAttribute(
                                .font,
                                value: NSFontManager.shared.convert(f, toHaveTrait: .boldFontMask),
                                range: r)
                        }
                    }
                    cells.append((cr.start, cr.end, styled))
                }
                rowCells.append(cells)
                for ci in 0..<min(cells.count, numCols) {
                    natural[ci] = max(natural[ci], cells[ci].styled.size().width)
                }
            }
            // Clamp column content widths to the available line width so a
            // pathologically wide cell doesn't stretch the whole table off
            // screen — the overflow gets wrapped (below) instead. Columns
            // that already fit their fair share keep their natural width.
            let minColWidth = bodyFont.pointSize * 3
            // Leave the row some slack at the container edge. A right- or
            // center-aligned column kerns its pad *before* its text, so the
            // cell's real glyphs sit at the very end of the row's advance;
            // filling the container exactly then force-wraps the row, because
            // a trailing pad may hang past the edge but glyphs may not. Same
            // reason `applyOverlay` caps its kern short of the full width.
            let rowSlack: CGFloat = 8
            let available = max(0, availableContentWidth
                - CGFloat(numCols) * 2 * cellHPad - rowSlack)
            let clamped = distributeColumnWidths(natural: natural, available: available,
                                                 minWidth: minColWidth)
            // Add horizontal padding to each column (space after cell text).
            var colWidths = clamped
            for ci in 0..<numCols {
                colWidths[ci] += 2 * cellHPad
            }

            // Column-border X offsets (between columns) and total width.
            // Each border is drawn cellHPad before the column boundary
            // so the 2*cellHPad per column splits evenly: hPad of right
            // padding for the current cell, hPad of left padding for the next.
            var borderXOffsets: [CGFloat] = []
            var colStartX: [CGFloat] = []
            var cumX: CGFloat = 0
            for ci in 0..<numCols {
                // Relative to the row's *text* start, which is where a wrapped
                // cell is drawn from — and that already includes this row's
                // firstLineHeadIndent (= cellHPad), so the left pad must not be
                // added again here or the cell sits a pad right of the in-line
                // cells above and below it.
                colStartX.append(cumX)
                cumX += colWidths[ci]
                if ci < numCols - 1 { borderXOffsets.append(cumX - cellHPad) }
            }
            let totalWidth = cumX

            // Per-column alignment from the separator row (`:--`/`:-:`/`--:`).
            let aligns = tableColumnAlignments(separatorRow: lines.count > 1 ? lines[1] : "",
                                               count: numCols)

            // --- Style each row ---
            var lineOffset = span.fullRange.location
            for (i, line) in lines.enumerated() {
                let lineLen = (line as NSString).length
                let lineRange = NSRange(location: lineOffset, length: lineLen)
                guard lineRange.upperBound <= result.length else { break }

                // Row geometry via the paragraph style; the borders are
                // drawn by a .tableRow BlockDecoration. Vertical padding
                // becomes paragraph spacing (row gap = trailing + leading
                // spacing = 2*cellVPad, same as the old block padding).
                let ps = NSMutableParagraphStyle()
                ps.lineSpacing = 0
                ps.firstLineHeadIndent = cellHPad
                ps.headIndent = cellHPad
                if i == 1 {
                    // Separator row: its text is hidden; force a thin
                    // strip and draw the horizontal rule through it.
                    ps.minimumLineHeight = 4
                    ps.maximumLineHeight = 4
                    ps.paragraphSpacingBefore = 0
                    ps.paragraphSpacing = 0
                } else {
                    // The header row reserves the band its column handle sits
                    // in, above everything the table draws. Unconditionally, so
                    // that clicking into a table never shifts the page — the
                    // cost is a little more air above every table.
                    ps.paragraphSpacingBefore = cellVPad + ((i == 0)
                        ? max(bodyParagraphStyle.paragraphSpacingBefore,
                              Self.tableHandleBand)
                        : 0)
                    ps.paragraphSpacing = cellVPad
                }
                result.addAttribute(.paragraphStyle, value: ps, range: lineRange)
                result.addAttribute(
                    .blockDecoration,
                    value: BlockDecoration(.tableRow(columnXOffsets: borderXOffsets,
                                                     width: totalWidth,
                                                     leftInset: cellHPad,
                                                     separator: i == 1,
                                                     // Including the last row: the table
                                                     // is closed on all four sides.
                                                     bottomBorder: i > 1,
                                                     topInset: i == 0 ? Self.tableHandleBand : 0)),
                    range: lineRange)

                // Cells whose styled width exceeds their column's (clamped)
                // content width can't be kern-aligned in place — they get
                // hidden and redrawn wrapped by `.tableCellWraps` instead
                // (see DecoratedTextLayoutFragment). Computed once per row so
                // both the hide/transplant step and the kern step below agree.
                var overflowsCol = [Bool](repeating: false, count: numCols)
                if i != 1, i < rowCells.count {
                    for ci in 0..<min(rowCells[i].count, numCols) {
                        overflowsCol[ci] = rowCells[i][ci].styled.size().width
                            > colWidths[ci] - 2 * cellHPad + 0.5
                    }
                }

                if i == 1 {
                    // Separator row: hide all text
                    result.addAttribute(.font, value: hiddenFont, range: lineRange)
                    result.addAttribute(.foregroundColor, value: NSColor.clear, range: lineRange)
                } else if i < rowCells.count {
                    // Transplant each styled cell's attributes onto the table,
                    // skipping .paragraphStyle and .blockDecoration — row
                    // geometry and borders stay owned by the table code.
                    // Overflowing cells instead hide their real characters and
                    // get redrawn wrapped, since kern alone can't wrap text.
                    var wraps: [TableCellWrap] = []
                    for (ci, cell) in rowCells[i].enumerated() where ci < numCols {
                        let offset = lineOffset + cell.start
                        if overflowsCol[ci] {
                            let hideRange = NSRange(location: offset, length: cell.end - cell.start)
                            guard hideRange.upperBound <= result.length else { continue }
                            result.addAttribute(.font, value: hiddenFont, range: hideRange)
                            result.addAttribute(.foregroundColor, value: NSColor.clear, range: hideRange)
                            wraps.append(TableCellWrap(styled: cell.styled, x: colStartX[ci],
                                                       contentWidth: colWidths[ci] - 2 * cellHPad,
                                                       align: aligns[ci], charStart: cell.start))
                        } else {
                            cell.styled.enumerateAttributes(
                                in: NSRange(location: 0, length: cell.styled.length)
                            ) { attrs, r, _ in
                                let target = NSRange(location: offset + r.location, length: r.length)
                                guard target.upperBound <= result.length else { return }
                                for (key, value) in attrs {
                                    guard key != .paragraphStyle && key != .blockDecoration else { continue }
                                    result.addAttribute(key, value: value, range: target)
                                }
                            }
                        }
                    }
                    if !wraps.isEmpty {
                        result.addAttribute(.tableCellWraps, value: TableCellWrapList(wraps),
                                            range: lineRange)
                    }
                }

                // Hide all structural pipes (zero-width + clear). A `\|` is
                // escaped cell content, not a separator — leave it visible
                // (its `\` is already hidden by the cell's escape span).
                let lineNS = line as NSString
                for ci in 0..<lineNS.length {
                    if lineNS.character(at: ci) == 0x7C,
                       !(ci > 0 && lineNS.character(at: ci - 1) == 0x5C) {
                        let pipeRange = NSRange(location: lineOffset + ci, length: 1)
                        result.addAttribute(.font, value: hiddenFont, range: pipeRange)
                        result.addAttribute(.foregroundColor, value: NSColor.clear, range: pipeRange)
                    }
                }

                // Kern-pad each cell to its column width, distributing the slack
                // by column alignment (skip separator). Left pads after content;
                // right pads before it (kern on the cell's leading hidden pipe,
                // which still adds advance though it's near-zero-width); center
                // splits the slack. Kern adds advance *after* a glyph, so the
                // "before" kern goes on the char preceding the cell content.
                if i != 1, i < rowCells.count {
                    for ci in 0..<min(rowCells[i].count, numCols) {
                        let cr = rowCells[i][ci]
                        // An overflowing cell is redrawn wrapped from its own
                        // column x, but its real characters still sit in the
                        // line at `hiddenFont` — so it must kern out its whole
                        // column too, or every cell after it in the row slides
                        // left onto its neighbour (#251). Its hidden run is
                        // measured rather than assumed zero: 0.01 pt advances
                        // over a long cell would otherwise push the row past
                        // the container edge and force-wrap the paragraph.
                        let cellWidth = overflowsCol[ci]
                            ? NSAttributedString(
                                string: lineNS.substring(
                                    with: NSRange(location: cr.start, length: cr.end - cr.start)),
                                attributes: [.font: hiddenFont]).size().width
                            : cr.styled.size().width
                        let padding = colWidths[ci] - cellWidth
                        guard padding > 0.5 else { continue }
                        let leadingIdx = (cr.start - 1 >= 0 && lineNS.character(at: cr.start - 1) == 0x7C)
                            ? cr.start - 1 : cr.start
                        let trailingIdx = cr.end - 1
                        func kern(_ amount: CGFloat, at idx: Int) {
                            result.addAttribute(.kern, value: amount,
                                                range: NSRange(location: lineOffset + idx, length: 1))
                        }
                        // A wrapped cell's slack always goes after it: the pad
                        // only reserves the column (its characters are hidden
                        // and the visible text is drawn separately, aligned
                        // per line), so keeping them at the column start keeps
                        // them inside the column they belong to.
                        switch overflowsCol[ci] ? .left : aligns[ci] {
                        case .left:   kern(padding, at: trailingIdx)
                        case .right:  kern(padding, at: leadingIdx)
                        case .center:
                            let half = (padding / 2).rounded()
                            kern(half, at: leadingIdx)
                            kern(padding - half, at: trailingIdx)
                        }
                    }
                }

                lineOffset += lineLen + 1
            }
        }
    }
}
