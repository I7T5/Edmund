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
        ("##   Spaced   ##   ", "Spaced"),
        ("#\tTabbed\t#", "Tabbed"),
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

    /// Past the threshold the outline opens at two levels: the roots open, the
    /// headings under them closed. Decided once — a short outline that grows
    /// past it stays as it was.
    @Test func longOutlineOpensFoldedToTwoLevels() {
        func headings(_ sections: Int) -> [OutlineHeading] {
            [OutlineHeading(level: 1, title: "Doc", range: NSRange())] + (0..<sections).flatMap { i in
                [OutlineHeading(level: 2, title: "S\(i)", range: NSRange()),
                 OutlineHeading(level: 3, title: "S\(i).a", range: NSRange())]
            }
        }
        let long = InspectorViewController()
        _ = long.view
        long.setHeadings(headings(InspectorViewController.foldThreshold))
        let outline = long.outlineView
        #expect(outline.isItemExpanded(long.roots[0]))
        #expect(long.roots[0].children.allSatisfy { !outline.isItemExpanded($0) })

        let growing = InspectorViewController()
        _ = growing.view
        growing.setHeadings(headings(2))
        growing.setHeadings(headings(InspectorViewController.foldThreshold))
        #expect(growing.roots[0].children.allSatisfy { growing.outlineView.isItemExpanded($0) })
    }

    /// Return on the selected heading goes to it, as a click does — the only
    /// way a keyboard user reaches a heading they arrowed to.
    @Test func returnGoesToTheSelectedHeading() throws {
        let inspector = InspectorViewController()
        _ = inspector.view
        inspector.setHeadings([(1, "A"), (2, "a1"), (1, "B")].map {
            OutlineHeading(level: $0.0, title: $0.1, range: NSRange(location: 0, length: 0))
        })
        var went: Int?
        inspector.onSelectHeading = { went = $0 }
        let outline = inspector.outlineView
        let row = outline.row(forItem: inspector.roots[1])
        outline.selectRowIndexes([row], byExtendingSelection: false)

        let returnKey = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
            context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
            isARepeat: false, keyCode: 36))
        outline.keyDown(with: returnKey)
        #expect(went == 2)
    }

    /// Typing in a heading only retitles it: the node on screen is updated in
    /// place, so the selection and a collapsed parent survive, rather than the
    /// tree being rebuilt.
    @Test func retitleUpdatesTheNodeInPlace() {
        let inspector = InspectorViewController()
        _ = inspector.view
        func headings(_ titles: [(Int, String)]) -> [OutlineHeading] {
            titles.map { OutlineHeading(level: $0.0, title: $0.1, range: NSRange(location: 0, length: 0)) }
        }
        inspector.setHeadings(headings([(1, "A"), (2, "a1"), (1, "B"), (2, "b1")]))
        let outline = inspector.outlineView
        let a = inspector.roots[0], b = inspector.roots[1]
        outline.collapseItem(a)
        outline.selectRowIndexes([outline.row(forItem: b)], byExtendingSelection: false)

        inspector.setHeadings(headings([(1, "A!"), (2, "a1"), (1, "B"), (2, "b1")]))
        #expect(inspector.roots[0] === a)
        #expect(a.heading.title == "A!")
        #expect(!outline.isItemExpanded(a))
        #expect(outline.selectedRow == outline.row(forItem: b))

        // A level change is a new shape: the tree is rebuilt, and the renamed
        // heading is still remembered as collapsed.
        inspector.setHeadings(headings([(1, "A!"), (2, "a1"), (2, "B"), (2, "b1")]))
        #expect(inspector.roots[0] !== a)
        #expect(!outline.isItemExpanded(inspector.roots[0]))
    }

    /// Retitling many headings at once (a Replace All) rebuilds once instead
    /// of reloading row by row.
    @Test func massRetitleRebuilds() {
        let inspector = InspectorViewController()
        _ = inspector.view
        let count = InspectorViewController.maxInPlaceRetitles + 1
        func headings(_ prefix: String) -> [OutlineHeading] {
            (0..<count).map { OutlineHeading(level: 1, title: "\(prefix)\($0)", range: NSRange(location: 0, length: 0)) }
        }
        inspector.setHeadings(headings("a"))
        let first = inspector.roots[0]
        inspector.setHeadings(headings("b"))
        #expect(inspector.roots[0] !== first)
        #expect(inspector.roots[0].heading.title == "b0")
    }

    /// Two collapsed headings share a title; renaming one must not make the
    /// other forget it was collapsed.
    @Test func renamingOneTwinKeepsTheOtherCollapsed() {
        let inspector = InspectorViewController()
        _ = inspector.view
        func headings(_ titles: [(Int, String)]) -> [OutlineHeading] {
            titles.map { OutlineHeading(level: $0.0, title: $0.1, range: NSRange(location: 0, length: 0)) }
        }
        inspector.setHeadings(headings([(1, "Notes"), (2, "x"), (1, "Notes"), (2, "y")]))
        let outline = inspector.outlineView
        outline.collapseItem(inspector.roots[0])
        outline.collapseItem(inspector.roots[1])

        inspector.setHeadings(headings([(1, "Renamed"), (2, "x"), (1, "Notes"), (2, "y")]))
        // A level change forces a rebuild, which re-applies remembered state.
        inspector.setHeadings(headings([(1, "Renamed"), (2, "x"), (1, "Notes"), (3, "y")]))
        #expect(!outline.isItemExpanded(inspector.roots[0]))
        #expect(!outline.isItemExpanded(inspector.roots[1]))
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
