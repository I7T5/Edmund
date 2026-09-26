import AppKit

/// Cached styling + column geometry for one rendered table. A table is a
/// single block, so without this cache every caret move inside it re-parses
/// and re-typesets every cell (a full `SyntaxHighlighter.parse` per cell) and
/// re-measures every column width three times. Keyed by the styling
/// environment (see `stylingEnvironmentKey`) plus the table's source, so any
/// change to content, width, theme, or fonts invalidates the entry.
private final class TableLayoutCacheEntry {
    struct Cell {
        let start: Int
        let end: Int
        let styled: NSAttributedString
        /// The styled cell's measured width. Also feeds the natural column
        /// widths, so `size()` runs once per cell per environment instead of
        /// once per restyle pass (it used to run up to three times).
        let width: CGFloat
        /// Width of the cell's characters at `hiddenFont` — only meaningful
        /// for overflowing cells, whose hidden run must still kern out its
        /// column by its real advance.
        let hiddenWidth: CGFloat
    }
    /// Per line (the separator row's entry is empty): the cell's character
    /// range within the line + its styled form.
    var rowCells: [[Cell]] = []
    /// Per row, per column: the cell doesn't fit its (clamped) column and is
    /// redrawn wrapped instead of kern-aligned.
    var overflows: [[Bool]] = []
    var colWidths: [CGFloat] = []
    var borderXOffsets: [CGFloat] = []
    var colStartX: [CGFloat] = []
    var totalWidth: CGFloat = 0
    var aligns: [ColumnAlign] = []
}

/// NSCache is internally thread-safe; `nonisolated(unsafe)` opts it out of
/// the global-actor isolation check, matching the overlay caches in
/// EditorTextView+MathRendering.swift and EditorTextView+CalloutRendering.swift.
nonisolated(unsafe) private let tableLayoutCache: NSCache<
    NSString,
    TableLayoutCacheEntry
> = {
    let cache = NSCache<NSString, TableLayoutCacheEntry>()
    cache.countLimit = 32
    return cache
}()

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

            // Cached styled cells are safe only when they cannot resolve
            // images or links against mutable load state or a document folder.
            let cacheKey: NSString? = canCacheStyledContent(tableStr)
                ? "\(stylingEnvironmentKey)|\(tableStr)" as NSString : nil
            let layout: TableLayoutCacheEntry
            if let cacheKey, let cached = tableLayoutCache.object(forKey: cacheKey) {
                layout = cached
            } else {
                guard let built = buildTableLayout(tableStr) else { return }
                if let cacheKey { tableLayoutCache.setObject(built, forKey: cacheKey) }
                layout = built
            }

            let cellHPad = bodyFont.pointSize * 0.3
            let cellVPad = bodyFont.pointSize * 0.15
            let numCols = layout.colWidths.count
            let lines = tableStr.components(separatedBy: "\n")

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
                              tableHandleBand)
                        : 0)
                    ps.paragraphSpacing = cellVPad
                }
                result.addAttribute(.paragraphStyle, value: ps, range: lineRange)
                result.addAttribute(
                    .blockDecoration,
                    value: BlockDecoration(.tableRow(columnXOffsets: layout.borderXOffsets,
                                                     width: layout.totalWidth,
                                                     leftInset: cellHPad,
                                                     separator: i == 1,
                                                     // Including the last row: the table
                                                     // is closed on all four sides.
                                                     bottomBorder: i > 1,
                                                     topInset: i == 0 ? tableHandleBand : 0)),
                    range: lineRange)

                // Cells whose styled width exceeds their column's (clamped)
                // content width can't be kern-aligned in place — they get
                // hidden and redrawn wrapped by `.tableCellWraps` instead
                // (see DecoratedTextLayoutFragment). Computed once per row so
                // both the hide/transplant step and the kern step below agree.
                let overflowsCol = i < layout.overflows.count ? layout.overflows[i] : []

                if i == 1 {
                    // Separator row: hide all text
                    result.addAttribute(.font, value: hiddenFont, range: lineRange)
                    result.addAttribute(.foregroundColor, value: NSColor.clear, range: lineRange)
                } else if i < layout.rowCells.count {
                    // Transplant each styled cell's attributes onto the table,
                    // skipping .paragraphStyle and .blockDecoration — row
                    // geometry and borders stay owned by the table code.
                    // Overflowing cells instead hide their real characters and
                    // get redrawn wrapped, since kern alone can't wrap text.
                    var wraps: [TableCellWrap] = []
                    for (ci, cell) in layout.rowCells[i].enumerated() where ci < numCols {
                        let offset = lineOffset + cell.start
                        if ci < overflowsCol.count && overflowsCol[ci] {
                            let hideRange = NSRange(location: offset, length: cell.end - cell.start)
                            guard hideRange.upperBound <= result.length else { continue }
                            result.addAttribute(.font, value: hiddenFont, range: hideRange)
                            result.addAttribute(.foregroundColor, value: NSColor.clear, range: hideRange)
                            // The cell's padding is not content and must not
                            // go into the scratch layout: in a narrow column a
                            // leading space can take the first line by itself,
                            // and the text then starts a line lower than the
                            // cells beside it. `charStart` moves with the trim
                            // so caret and hit-test mapping stay exact.
                            let text = cell.styled.string as NSString
                            var lead = 0
                            while lead < text.length, text.character(at: lead) == 0x20 { lead += 1 }
                            var trail = text.length
                            while trail > lead, text.character(at: trail - 1) == 0x20 { trail -= 1 }
                            let trimmed = cell.styled.attributedSubstring(
                                from: NSRange(location: lead, length: trail - lead))
                            wraps.append(TableCellWrap(styled: trimmed, x: layout.colStartX[ci],
                                                       contentWidth: layout.colWidths[ci] - 2 * cellHPad,
                                                       align: layout.aligns[ci],
                                                       charStart: cell.start + lead))
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
                if i != 1, i < layout.rowCells.count {
                    for ci in 0..<min(layout.rowCells[i].count, numCols) {
                        let cr = layout.rowCells[i][ci]
                        let overflow = ci < overflowsCol.count && overflowsCol[ci]
                        // An overflowing cell is redrawn wrapped from its own
                        // column x, but its real characters still sit in the
                        // line at `hiddenFont` — so it must kern out its whole
                        // column too, or every cell after it in the row slides
                        // left onto its neighbour (#251). Its hidden run is
                        // measured rather than assumed zero: 0.01 pt advances
                        // over a long cell would otherwise push the row past
                        // the container edge and force-wrap the paragraph.
                        let cellWidth = overflow ? cr.hiddenWidth : cr.width
                        let padding = layout.colWidths[ci] - cellWidth
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
                        switch overflow ? .left : layout.aligns[ci] {
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

    /// Styles every cell of one table and computes its column geometry — the
    /// expensive half of `styleTableSpan`, pure in (table source, styling
    /// environment) and cached as a whole by the caller. Returns nil for a
    /// table with no columns (the caller then styles nothing, as before).
    private func buildTableLayout(_ tableStr: String) -> TableLayoutCacheEntry? {
        let lines = tableStr.components(separatedBy: "\n")
        let cellHPad = bodyFont.pointSize * 0.3

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
        guard numCols > 0 else { return nil }
        var natural = [CGFloat](repeating: 0, count: numCols)
        var rowCells: [[TableLayoutCacheEntry.Cell]] = []
        for (li, line) in lines.enumerated() {
            guard li != 1 else { rowCells.append([]); continue }
            let lineNS = line as NSString
            var cells: [TableLayoutCacheEntry.Cell] = []
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
                cells.append(TableLayoutCacheEntry.Cell(start: cr.start, end: cr.end,
                                                        styled: styled,
                                                        width: styled.size().width,
                                                        hiddenWidth: 0))
            }
            rowCells.append(cells)
            for ci in 0..<min(cells.count, numCols) {
                natural[ci] = max(natural[ci], cells[ci].width)
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
        // The row's paragraph is indented by `cellHPad` (its head indent,
        // set below) so the table's left border can stand that far left of
        // the text — which takes the same amount off the line. It has to
        // come out of this budget too, or the slack is eaten before the row
        // is laid out: at a 4.8pt pad it left 3.2pt, at 8pt it left none and
        // every row's closing pipe wrapped onto a second line, dragging the
        // last cell down under the first once the window was a little
        // narrower.
        let available = max(0, availableContentWidth
            - CGFloat(numCols) * 2 * cellHPad - cellHPad - rowSlack)
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

        // Per-column alignment from the separator row (`:--`/`:-:`/`--:`).
        let aligns = tableColumnAlignments(separatorRow: lines.count > 1 ? lines[1] : "",
                                           count: numCols)

        // Overflow flags + the hidden-run widths of overflowing cells,
        // computed once here so the styling pass never re-measures.
        var overflows: [[Bool]] = []
        for (i, cells) in rowCells.enumerated() {
            guard i != 1 else { overflows.append([]); continue }
            let lineNS = lines[i] as NSString
            var rowOver = [Bool](repeating: false, count: numCols)
            for ci in 0..<min(cells.count, numCols) {
                rowOver[ci] = cells[ci].width > colWidths[ci] - 2 * cellHPad + 0.5
                if rowOver[ci] {
                    let cr = cells[ci]
                    let hidden = NSAttributedString(
                        string: lineNS.substring(
                            with: NSRange(location: cr.start, length: cr.end - cr.start)),
                        attributes: [.font: hiddenFont]).size().width
                    rowCells[i][ci] = TableLayoutCacheEntry.Cell(
                        start: cr.start, end: cr.end, styled: cr.styled,
                        width: cr.width, hiddenWidth: hidden)
                }
            }
            overflows.append(rowOver)
        }

        let entry = TableLayoutCacheEntry()
        entry.rowCells = rowCells
        entry.overflows = overflows
        entry.colWidths = colWidths
        entry.borderXOffsets = borderXOffsets
        entry.colStartX = colStartX
        entry.totalWidth = cumX
        entry.aligns = aligns
        return entry
    }
}
