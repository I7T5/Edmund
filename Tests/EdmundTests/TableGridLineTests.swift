import Testing
import AppKit
@testable import EdmundCore

/// Every boundary between two data rows carries a grid line, and the row above
/// the boundary is the one that owns it. Which side of the boundary the line
/// lands on is not cosmetic: the editor repaints a single row at a time (a
/// caret move restyles one row and dirties only its rect), so a line drawn on
/// the far side of the boundary is inside a rect that some other row will
/// repaint without knowing the line is there — and it disappears.

@Suite("Table grid lines")
@MainActor
struct TableGridLineTests {

    private func loadEditor(_ text: String) -> EditorTextView {
        let editor = makeEditor()
        editor.updateContentInset()
        editor.loadContent(text)
        ensureFullLayout(editor)
        layOutViewport(editor)
        return editor
    }

    /// Renders the view and returns, for every device scanline, how many pixels
    /// carry ink. A grid line shows up as a run the width of the table; text
    /// shows up as a much shorter one.
    private func inkPerRow(_ editor: EditorTextView) -> [Int] {
        let bounds = NSRect(origin: .zero, size: NSSize(width: max(1, editor.bounds.width),
                                                        height: max(1, editor.bounds.height)))
        guard let rep = editor.bitmapImageRepForCachingDisplay(in: bounds) else { return [] }
        editor.cacheDisplay(in: bounds, to: rep)
        var rows: [Int] = []
        for y in 0..<rep.pixelsHigh {
            var count = 0
            for x in 0..<rep.pixelsWide where (rep.colorAt(x: x, y: y)?
                .usingColorSpace(.sRGB)?.brightnessComponent ?? 1) < 0.97 {
                count += 1
            }
            rows.append(count)
        }
        return rows
    }

    private struct Render {
        let ink: [Int]
        let scale: CGFloat
        let tableWidth: Int
        let grid: TableGrid

        /// Whether a scanline is inked most of the way across the table.
        func isRule(_ row: Int) -> Bool {
            ink.indices.contains(row) && ink[row] > Int(Double(tableWidth) * 0.6)
        }
    }

    private func render(_ text: String) -> Render? {
        let editor = loadEditor(text)
        guard let index = editor.blocks.firstIndex(where: { $0.kind == .table }),
              let grid = editor.tableGrid(blockIndex: index) else { return nil }
        let ink = inkPerRow(editor)
        guard !ink.isEmpty else { return nil }
        let scale = CGFloat(ink.count) / max(1, editor.bounds.height)
        let width = Int(((grid.columnEdges.last ?? 0) - (grid.columnEdges.first ?? 0)) * scale)
        return Render(ink: ink, scale: scale, tableWidth: width, grid: grid)
    }

    /// The bug as reported: a grid line between two content rows goes missing.
    /// It went missing because it was drawn on the wrong side of the boundary,
    /// so this checks the side, not merely the presence.
    @Test("A data row's grid line is drawn inside the row that owns it")
    func gridLineSitsAboveTheBoundary() throws {
        for table in ["| a | b |\n| --- | --- |\n| has `code` inside | b2 |\n| plain | b3 |\n",
                      " no outer | border \n---- | ----\n"
                        + " *inline **styling*** with `code` and math hi there | c12 \n"
                        + " c21 | c22 \n"] {
            let shot = try #require(render("Intro.\n\n" + table))
            #expect(shot.grid.rows.count == 4)
            // The boundary between the two data rows, and the table's bottom.
            for boundary in [shot.grid.rows[2].maxY, shot.grid.rows[3].maxY] {
                let edge = Int((boundary * shot.scale).rounded())
                let above = (edge - 2..<edge).contains { shot.isRule($0) }
                #expect(above, "no grid line above the boundary at y=\(boundary)")
                // Not on the far side: that pixel belongs to the next row's
                // rect, and the next row repaints without it.
                #expect(!shot.isRule(edge + 1),
                        "grid line spills into the row below at y=\(boundary)")
            }
        }
    }
}
