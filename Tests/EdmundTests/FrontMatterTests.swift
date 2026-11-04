import Testing
import AppKit
@testable import edmd
@testable import EdmundCore

// Front matter's top-level pairs, as the inspector's Info pane shows them.
@MainActor @Suite struct FrontMatterTests {

    @Test func readsFlatPairsListsAndQuotes() {
        let block = """
        ---
        title: "Hello: world"
        tags:
          - swift
          - 'mac'
        aliases:
        - one
        # a comment
        author:
          name: Ina
        draft: false
        ---
        """
        let pairs = FrontMatter.pairs(in: block)
        #expect(pairs.map(\.key) == ["title", "tags", "aliases", "author", "draft"])
        #expect(pairs.map(\.value) == ["Hello: world", "swift, mac", "one", "", "false"])
    }

    @Test func editorReadsOnlyALeadingFrontMatterBlock() {
        let editor = makeEditor()
        editor.loadContent("---\ntitle: Doc\n---\n\n# Heading\n")
        #expect(editor.frontMatterPairs.map { $0.key } == ["title"])
        editor.loadContent("# Heading\n\ntitle: not front matter\n")
        #expect(editor.frontMatterPairs.isEmpty)
    }

    /// The pairs come before the counts, and go when the front matter does.
    @Test func inspectorShowsThePairsFirst() {
        let inspector = InspectorViewController()
        _ = inspector.view
        inspector.setFrontMatter([("title", "Doc")])
        #expect(inspector.infoValues.first?.name == "title")
        #expect(inspector.infoValues.first?.value == "Doc")
        inspector.setFrontMatter([])
        #expect(inspector.infoValues.first?.name == "Words")
    }

    /// Front Matter and Count are one grid, so their name columns line up;
    /// replacing or clearing the pairs leaves Count's rows alone.
    @Test func sectionsShareOneGrid() {
        let inspector = InspectorViewController()
        _ = inspector.view
        #expect(inspector.infoGrid.numberOfColumns == 2)
        #expect(inspector.infoGrid.numberOfRows == 6)   // Count title + 5 fields
        inspector.setFrontMatter([("title", "Doc"), ("tags", "a, b")])
        #expect(inspector.infoGrid.numberOfRows == 9)
        inspector.setFrontMatter([("title", "Doc")])
        #expect(inspector.infoGrid.numberOfRows == 8)
        inspector.setFrontMatter([])
        #expect(inspector.infoGrid.numberOfRows == 6)
        #expect(inspector.infoValues.map(\.name) ==
                ["Words", "Characters", "Location", "Line", "Line Ending"])
    }
}
