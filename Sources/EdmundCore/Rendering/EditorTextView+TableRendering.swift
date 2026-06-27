import AppKit

/// Table styling: the largest single case of the `styleBlock` switch. When the
/// caret is inside, the table shows as dimmed monospace; otherwise it's laid out
/// with a bold header, hidden pipes, kern-padded columns, and drawn borders (via
/// a `.tableRow` BlockDecoration). Row parsing helpers live in
/// EditorTextView+TableSupport; extracted from EditorTextView+Rendering.
extension EditorTextView {

    /// Styles the `.table` content for one span. The caller has already
    /// bounds-checked `span.fullRange` against `result`.
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
            // with cell padding for breathing room.
            let tableNS = (result.string as NSString)
            let tableStr = tableNS.substring(with: span.fullRange)
            let lines = tableStr.components(separatedBy: "\n")

            let boldFont = NSFontManager.shared.convert(bodyFont, toHaveTrait: .boldFontMask)
            let cellHPad = bodyFont.pointSize * 0.3
            let cellVPad = bodyFont.pointSize * 0.15

            // --- Compute column widths (max cell width + horizontal padding) ---
            let headerCells = splitTableRow(lines[0])
            let numCols = headerCells.count
            guard numCols > 0 else { return }
            var colWidths = [CGFloat](repeating: 0, count: numCols)
            for (li, line) in lines.enumerated() {
                guard li != 1 else { continue }
                let cells = splitTableRow(line)
                let f: NSFont = (li == 0) ? boldFont : bodyFont
                for ci in 0..<min(cells.count, numCols) {
                    let w = (cells[ci] as NSString).size(withAttributes: [.font: f]).width
                    colWidths[ci] = max(colWidths[ci], w)
                }
            }
            // Add horizontal padding to each column (space after cell text).
            for ci in 0..<numCols {
                colWidths[ci] += 2 * cellHPad
            }

            // Column-border X offsets (between columns) and total width.
            // Each border is drawn cellHPad before the column boundary
            // so the 2*cellHPad per column splits evenly: hPad of right
            // padding for the current cell, hPad of left padding for the next.
            var borderXOffsets: [CGFloat] = []
            var cumX: CGFloat = 0
            for ci in 0..<numCols {
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

                let rowFont: NSFont = (i == 0) ? boldFont : bodyFont

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
                    ps.paragraphSpacingBefore = cellVPad + ((i == 0)
                        ? bodyParagraphStyle.paragraphSpacingBefore : 0)
                    ps.paragraphSpacing = cellVPad
                }
                result.addAttribute(.paragraphStyle, value: ps, range: lineRange)
                result.addAttribute(
                    .blockDecoration,
                    value: BlockDecoration(.tableRow(columnXOffsets: borderXOffsets,
                                                     width: totalWidth,
                                                     leftInset: cellHPad,
                                                     separator: i == 1)),
                    range: lineRange)

                if i == 0 {
                    result.addAttribute(.font, value: boldFont, range: lineRange)
                }

                if i == 1 {
                    // Separator row: hide all text
                    result.addAttribute(.font, value: hiddenFont, range: lineRange)
                    result.addAttribute(.foregroundColor, value: NSColor.clear, range: lineRange)
                }

                // Hide all pipes (zero-width + clear)
                let lineNS = line as NSString
                for ci in 0..<lineNS.length {
                    if lineNS.character(at: ci) == 0x7C {
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
                if i != 1 {
                    let ranges = cellRanges(in: lineNS)
                    for ci in 0..<min(ranges.count, numCols) {
                        let cr = ranges[ci]
                        let cellText = lineNS.substring(with: NSRange(location: cr.start, length: cr.end - cr.start))
                        let cellWidth = (cellText as NSString).size(withAttributes: [.font: rowFont]).width
                        let padding = colWidths[ci] - cellWidth
                        guard padding > 0.5 else { continue }
                        let leadingIdx = (cr.start - 1 >= 0 && lineNS.character(at: cr.start - 1) == 0x7C)
                            ? cr.start - 1 : cr.start
                        let trailingIdx = cr.end - 1
                        func kern(_ amount: CGFloat, at idx: Int) {
                            result.addAttribute(.kern, value: amount,
                                                range: NSRange(location: lineOffset + idx, length: 1))
                        }
                        switch aligns[ci] {
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
