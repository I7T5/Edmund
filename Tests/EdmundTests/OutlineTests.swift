import Testing
import AppKit
@testable import edmd
@testable import EdmundCore

// The inspector's outline: which blocks count as headings, what each one is
// called, and how the flat list nests.

@MainActor @Suite struct OutlineTests {

    @Test func headingsComeFromParsedBlocksOnly() {
        let editor = makeEditor()
        editor.loadContent("""
        ---
        title: x
        ---
        # One ##
        text
        ```
        # not a heading
        ```
        Two
        ===
        ### C#
        """)
        let headings = editor.outlineHeadings
        #expect(headings.map(\.title) == ["One", "Two", "C#"])
        #expect(headings.map(\.level) == [1, 1, 3])
        let source = editor.rawSource as NSString
        #expect(source.substring(with: headings[0].range).hasPrefix("# One"))
    }

    @Test(arguments: [
        ("# Title", "Title"),
        ("## Title ##", "Title"),
        ("# C#", "C#"),
        ("#", ""),
        ("# #", ""),
        ("Line one\nline two\n---", "Line one line two"),
    ])
    func titles(_ content: String, _ expected: String) {
        #expect(OutlineHeading.title(of: content) == expected)
    }

    @Test func treeNestsUnderTheNearestShallowerHeading() {
        let levels = [2, 1, 3, 2, 4, 1]
        let roots = OutlineNode.tree(levels.enumerated().map {
            OutlineHeading(level: $1, title: "h\($0)", range: NSRange(location: $0, length: 1))
        })
        func shape(_ nodes: [OutlineNode]) -> String {
            nodes.map { n in n.heading.title + (n.children.isEmpty ? "" : "(\(shape(n.children)))") }
                .joined(separator: " ")
        }
        // A leading H2 is a root; H1 → H3 nests despite the skipped level.
        #expect(shape(roots) == "h0 h1(h2 h3(h4)) h5")
        #expect(roots[1].children[1].children[0].index == 4)
    }

    /// Collapsing a heading survives a rebuild, which creates new node objects.
    @Test func userCollapseSurvivesRebuild() throws {
        let inspector = InspectorViewController()
        _ = inspector.view
        func headings(_ titles: [(Int, String)]) -> [OutlineHeading] {
            titles.map { OutlineHeading(level: $0.0, title: $0.1, range: NSRange(location: 0, length: 0)) }
        }
        inspector.setHeadings(headings([(1, "A"), (2, "a1"), (1, "B"), (2, "b1")]))
        let outline = inspector.outlineView
        #expect(outline.isItemExpanded(inspector.roots[0]))
        outline.collapseItem(inspector.roots[0])

        inspector.setHeadings(headings([(1, "A"), (2, "a1"), (1, "B"), (2, "b1"), (2, "b2")]))
        #expect(!outline.isItemExpanded(inspector.roots[0]))
        #expect(outline.isItemExpanded(inspector.roots[1]))
    }
}
