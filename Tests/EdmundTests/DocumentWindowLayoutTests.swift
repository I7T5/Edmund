import Testing
import AppKit
@testable import edmd
@testable import EdmundCore

// A document window has `.fullSizeContentView` so its inspector runs up
// behind the toolbar. The editor and the inspector's tabs must still start
// below it — measured against `contentLayoutRect`, because the safe area
// misses the toolbar inside a split item on macOS 14 (CI's runner).
@MainActor @Suite struct DocumentWindowLayoutTests {

    @Test("The editor and the inspector tabs sit below the toolbar; the inspector runs full height")
    func belowToolbar() throws {
        let doc = Document()
        doc.makeWindowControllers()
        let window = try #require(doc.windowControllers.first?.window)
        defer { window.close() }
        doc.inspectorItem.isCollapsed = false
        window.layoutIfNeeded()
        let content = try #require(window.contentView)
        let below = window.contentLayoutRect.maxY
        #expect(below < content.bounds.height - 1, "no toolbar inset to test against")

        let scroll = try #require(doc.editor.enclosingScrollView)
        #expect(abs(scroll.convert(scroll.bounds, to: nil).maxY - below) < 1)

        let inspector = doc.inspector.view
        #expect(abs(inspector.convert(inspector.bounds, to: nil).maxY - content.bounds.height) < 1)
        let tabs = try #require(inspector.subviews.first { $0 is NSStackView })
        #expect(tabs.convert(tabs.bounds, to: nil).maxY <= below + 0.5)
    }
}
