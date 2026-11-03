import Testing
import AppKit
@testable import EdmundCore

/// Regression: a table that is the last block of a document ending in a
/// newline. TextKit 2 folds the document's empty last line into the last
/// row's fragment, at the container's left and without the row's indent; the
/// row's borders and its grid rect followed that frame, so while the caret was
/// in the table the last row drew one cell padding left of the rows above and
/// hung a line below them.
@Suite("Table as last block — last row lines up")
struct TableLastBlockGeometryTests {

    @MainActor private func grid(_ source: String, font: String? = nil, size: CGFloat = 16) -> TableGrid? {
        let e = makeEditor()
        if let font {
            var theme = e.theme
            theme.fontName = font
            theme.fontSize = size
            e.applyTheme(theme)
        }
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 500),
                           styleMask: [.titled], backing: .buffered, defer: false)
        let scroll = NSScrollView(frame: win.contentLayoutRect)
        scroll.documentView = e
        win.contentView = scroll
        win.makeFirstResponder(e)
        e.loadContent(source)
        // The caret in the last row's last cell, as while typing there.
        let caret = (source as NSString).range(of: "f", options: .backwards).location
        e.setSelectedRange(NSRange(location: caret, length: 0))
        e.recompose(cursorInRaw: caret)
        ensureFullLayout(e)
        guard let index = e.blocks.firstIndex(where: { $0.kind == .table }) else { return nil }
        return e.tableGrid(blockIndex: index, ensuringLayout: true)
    }

    // The app's default serif and the odd sizes where line metrics round
    // differently, not just the test default (system 16).
    @Test("A trailing newline doesn't move or stretch the last row",
          arguments: [(nil, 16), ("Iowan Old Style", 16), ("Iowan Old Style", 17),
                      ("Helvetica", 15), ("Menlo", 13)] as [(String?, CGFloat)])
    @MainActor func trailingNewlineKeepsLastRow(font: String?, size: CGFloat) throws {
        let table = "Intro\n\n| A | B |\n| --- | --- |\n| c | d |\n| e | f |"
        let withNL = try #require(grid(table + "\n", font: font, size: size))
        let withoutNL = try #require(grid(table, font: font, size: size))
        #expect(withNL.columnEdges == withoutNL.columnEdges)
        #expect(withNL.rows.count == withoutNL.rows.count)
        for (a, b) in zip(withNL.rows, withoutNL.rows) {
            #expect(abs(a.minX - b.minX) < 0.01 && abs(a.minY - b.minY) < 0.01, "\(a) vs \(b)")
        }
        // The last row starts where the rows above it do, and is as tall as
        // the body row above it: the absorbed line is gone, the row's own
        // spacing below its text is not.
        let rows = withNL.rows
        #expect(abs(rows[rows.count - 1].minX - rows[rows.count - 2].minX) < 0.01)
        #expect(abs(rows[rows.count - 1].height - rows[rows.count - 2].height) < 0.01,
                "last \(rows[rows.count - 1].height) vs above \(rows[rows.count - 2].height)")
    }
}
