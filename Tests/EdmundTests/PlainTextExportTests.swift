import Testing
@testable import EdmundCore

@Suite("Plain text export")
struct PlainTextExportTests {

    private func plain(_ md: String) -> String { PlainTextExport.text(markdown: md) }

    @Test("Prose without syntax passes through line for line")
    func proseUnchanged() {
        #expect(plain("Just words.\n\nA second\nparagraph.") == "Just words.\n\nA second\nparagraph.\n")
    }

    @Test("Inline syntax is removed, the words kept")
    func inlineSyntax() {
        #expect(plain("**b** *i* `c` ==h== ~~s~~ x\\*y <u>u</u> $E=mc^2$ [[note|Alias]] [[Plain]]")
                == "b i c h s x*y u E=mc^2 Alias Plain\n")
    }

    @Test("Headings keep their text, not their hashes")
    func headings() {
        #expect(plain("# One\n\n### Three") == "One\n\nThree\n")
    }

    @Test("Links keep where they point, unless the text already says it")
    func links() {
        #expect(plain("[site](https://x.org)") == "site (https://x.org)\n")
        #expect(plain("[https://x.org](https://x.org)") == "https://x.org\n")
        #expect(plain("<https://x.org>") == "https://x.org\n")
        #expect(plain("[back up](#intro)") == "back up\n")
    }

    @Test("Reference links resolve against a definition elsewhere in the document")
    func referenceLinks() {
        #expect(plain("See [docs][d].\n\n[d]: https://d.org") == "See docs (https://d.org).\n\n[d]: https://d.org\n")
    }

    @Test("Images leave their alt text; an image without one leaves nothing, not a gap")
    func images() {
        #expect(plain("A ![cat photo](cat.png) here") == "A cat photo here\n")
        #expect(plain("<img src=\"p.png\" alt=\"a diagram\"> above") == "a diagram above\n")
        #expect(plain("before\n\n![](pasted.png)\n\nafter") == "before\n\nafter\n")
    }

    @Test("Lists keep nesting and numbering; bullets become •, tasks ☐/☑")
    func lists() {
        #expect(plain("- one\n    - nested\n* star\n1. first\n2) second\n- [ ] todo\n- [x] done")
                == "• one\n    • nested\n• star\n1. first\n2) second\n☐ todo\n☑ done\n")
    }

    @Test("Tables become aligned grids with their cells' syntax stripped")
    func tables() {
        let md = "| Name | **Qty** |\n| --- | ---: |\n| Apples | 3 |\n| Kiwis *green* | 12 |"
        #expect(plain(md) == """
            | Name        | Qty |
            | ----------- | --: |
            | Apples      | 3   |
            | Kiwis green | 12  |

            """)
    }

    @Test("An escaped pipe in a cell stays escaped so the grid holds")
    func tablePipe() {
        #expect(plain("| a | b |\n| --- | --- |\n| x \\| y | z |")
                == "| a      | b   |\n| ------ | --- |\n| x \\| y | z   |\n")
    }

    @Test("Quotes keep '> '; a callout shows its title, not its [!type]")
    func quotesAndCallouts() {
        #expect(plain("> quoted **line**") == "> quoted line\n")
        #expect(plain("> [!warning] Mind the gap\n> Body.") == "> Mind the gap\n> Body.\n")
        #expect(plain("> [!tip]\n> Body.") == "> Tip\n> Body.\n")
        #expect(plain("> [!faq]- Folded\n> Body.") == "> Folded\n> Body.\n")
    }

    @Test("Code keeps its content; fences go")
    func code() {
        #expect(plain("```swift\nlet x = 1\n```") == "let x = 1\n")
        #expect(plain("    indented = true") == "    indented = true\n")
    }

    @Test("Display math keeps its TeX without the $$ lines")
    func displayMath() {
        #expect(plain("Before\n\n$$\na^2 + b^2 = c^2\n$$\n\nAfter") == "Before\n\na^2 + b^2 = c^2\n\nAfter\n")
    }

    @Test("What Read mode hides is dropped: comments, front matter, block refs")
    func hidden() {
        #expect(plain("---\ntitle: x\n---\n\nBody %%note to self%% text ^ref1") == "Body  text\n")
    }

    @Test("Footnotes read [1] at the reference and the definition")
    func footnotes() {
        #expect(plain("Claim[^1].\n\n[^1]: Source.") == "Claim[1].\n\n[1] Source.\n")
    }

    @Test("Raw HTML blocks keep their text; markup-only lines and style bodies go")
    func htmlBlock() {
        #expect(plain("Intro\n\n<div align=\"center\">\n<!-- hi -->\n<b>Centered</b>\n</div>")
                == "Intro\n\nCentered\n")
        #expect(plain("<style>\np { color: red }\n</style>\n\nText") == "Text\n")
    }

    @Test("Rules stay as ---")
    func rules() {
        #expect(plain("a\n\n---\n\nb") == "a\n\n---\n\nb\n")
    }
}
