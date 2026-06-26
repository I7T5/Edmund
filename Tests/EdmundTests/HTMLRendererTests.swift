import Testing
import Foundation
@testable import EdmundCore

// String-assertion tests for the HTML renderer: parse markdown → render → assert
// HTML. Pure logic, no AppKit/window needed.

@Suite("HTMLRenderer — core GFM")
struct HTMLRendererCoreTests {

    private func html(_ md: String) -> String { HTMLRenderer.render(markdown: md) }

    @Test("Headings render h1…h6")
    func headings() {
        #expect(html("# Title") == "<h1>Title</h1>")
        #expect(html("### Sub") == "<h3>Sub</h3>")
        #expect(html("###### Six") == "<h6>Six</h6>")
    }

    @Test("Paragraph wraps in <p>")
    func paragraph() {
        #expect(html("hello world") == "<p>hello world</p>")
    }

    @Test("Emphasis, strong, strikethrough, inline code")
    func inlineMarks() {
        #expect(html("*i*") == "<p><em>i</em></p>")
        #expect(html("**b**") == "<p><strong>b</strong></p>")
        #expect(html("~~s~~") == "<p><del>s</del></p>")
        #expect(html("`x`") == "<p><code>x</code></p>")
    }

    @Test("Fenced code block keeps language class and escapes content")
    func codeBlock() {
        let out = html("```swift\nlet x = a < b && c > d\n```")
        #expect(out.contains("<pre><code class=\"language-swift\">"))
        #expect(out.contains("a &lt; b &amp;&amp; c &gt; d"))
        #expect(!out.contains("a < b"))
    }

    @Test("Unordered, ordered, and task lists")
    func lists() {
        #expect(html("- a\n- b") == "<ul><li><p>a</p></li><li><p>b</p></li></ul>")
        #expect(html("1. a").hasPrefix("<ol>"))
        #expect(html("3. a\n4. b").hasPrefix("<ol start=\"3\">"))
        let task = html("- [ ] todo\n- [x] done")
        #expect(task.contains("<li class=\"task\"><span class=\"task-check task-check--unchecked\"><svg"))
        #expect(task.contains("<span class=\"task-check task-check--checked\"><svg"))
    }

    @Test("Table emits thead/tbody with per-column alignment")
    func table() {
        let out = html("| a | b | c |\n|:--|:-:|--:|\n| 1 | 2 | 3 |")
        #expect(out.contains("<table><thead><tr>"))
        #expect(out.contains("<th style=\"text-align:left\">a</th>"))
        #expect(out.contains("<th style=\"text-align:center\">b</th>"))
        #expect(out.contains("<th style=\"text-align:right\">c</th>"))
        #expect(out.contains("<tbody><tr><td style=\"text-align:left\">1</td>"))
    }

    @Test("Thematic break → <hr>")
    func thematicBreak() {
        #expect(html("---").contains("<hr>"))
    }

    @Test("External links keep their real href")
    func links() {
        #expect(html("[text](https://example.com)") == "<p><a href=\"https://example.com\">text</a></p>")
        #expect(html("[m](mailto:a@b.com)").contains("<a href=\"mailto:a@b.com\">"))
    }

    @Test("In-page anchor links keep their fragment href")
    func anchorLink() {
        #expect(html("[go](#section)").contains("<a href=\"#section\">go</a>"))
    }

    @Test("Relative/internal links route through the private link scheme")
    func internalLink() {
        let out = html("[other](notes/other.md)")
        #expect(out.contains("<a href=\"x-edmund-link:"))
        #expect(!out.contains("href=\"notes/other.md\""))
    }

    @Test("Code block wraps tokens in colored spans, escaping content")
    func codeTokens() {
        let out = html("```swift\nlet x = 1 // hi\n```")
        #expect(out.contains("<span class=\"tok-keyword\">let</span>"))
        #expect(out.contains("<span class=\"tok-number\">1</span>"))
        #expect(out.contains("<span class=\"tok-comment\">// hi</span>"))
    }

    @Test("Code token spans still escape special characters")
    func codeTokensEscape() {
        let out = html("```\na < b && c\n```")
        #expect(out.contains("a &lt; b &amp;&amp; c"))
        #expect(!out.contains("a < b"))
    }

    @Test("Image emits a placeholder carrying the raw source for the asset pass")
    func image() {
        let out = html("![alt text](pic.png)")
        #expect(out.contains("<img class=\"md-image\" data-src=\"pic.png\" alt=\"alt text\">"))
    }

    @Test("Wikilink renders as a private-scheme anchor with encoded target")
    func wikilink() {
        let out = html("see [[My Note#Heading]] here")
        #expect(out.contains("<a class=\"wikilink\" href=\"x-edmund-wiki:"))
        // `#` is percent-encoded so it isn't parsed as a URL fragment.
        #expect(!out.contains("x-edmund-wiki:My Note#Heading"))
        #expect(out.contains(">My Note#Heading</a>"))
    }

    @Test("Wikilink alias shows the alias as display text")
    func wikilinkAlias() {
        let out = html("[[Target|shown]]")
        #expect(out.contains(">shown</a>"))
    }

    @Test("Plain block quote stays a blockquote")
    func blockQuote() {
        #expect(html("> quoted") == "<blockquote><p>quoted</p></blockquote>")
    }
}

@Suite("HTMLRenderer — escaping & security")
struct HTMLRendererEscapingTests {

    private func html(_ md: String) -> String { HTMLRenderer.render(markdown: md) }

    @Test("Leaf text is HTML-escaped (no script injection)")
    func escapesText() {
        let out = html("a <script>alert(1)</script> & b")
        #expect(!out.contains("<script>"))
        #expect(out.contains("&lt;script&gt;"))
        #expect(out.contains("&amp;"))
    }

    @Test("Raw HTML block is escaped, not passed through")
    func escapesHTMLBlock() {
        let out = html("<div onclick=\"x\">hi</div>")
        #expect(!out.contains("<div onclick"))
        #expect(out.contains("&lt;div"))
    }
}

@Suite("HTMLRenderer — non-GFM inline")
struct HTMLRendererInlineTests {

    private func html(_ md: String) -> String { HTMLRenderer.render(markdown: md) }

    @Test("==highlight== → <mark>")
    func highlight() {
        #expect(html("a ==hi== b").contains("<mark>hi</mark>"))
    }

    @Test("Inline $math$ → placeholder span with escaped data-tex")
    func inlineMath() {
        let out = html("energy $E=mc^2$ here")
        #expect(out.contains("<span class=\"math-inline\" data-tex=\"E=mc^2\"></span>"))
    }

    @Test("Display $$math$$ → math-display div")
    func displayMath() {
        let out = html("$$\n\\int_0^1 x\\,dx\n$$")
        #expect(out.contains("<div class=\"math-display\" data-tex=\""))
        #expect(out.contains("\\int_0^1"))
    }

    @Test("Wikilink renders display text inside a routing anchor")
    func wikilink() {
        let out = html("see [[Note|the note]]")
        #expect(out.contains(">the note</a>"))
        #expect(out.contains("href=\"x-edmund-wiki:Note\""))
        #expect(!out.contains("[["))
    }

    @Test("Comment is hidden")
    func comment() {
        #expect(!html("before %%secret%% after").contains("secret"))
    }
}

@Suite("HTMLRenderer — callouts")
struct HTMLRendererCalloutTests {

    private func html(_ md: String) -> String { HTMLRenderer.render(markdown: md) }

    @Test("Known callout type → callout div with title and body")
    func basicCallout() {
        let out = html("> [!note]\n> Body text.")
        #expect(out.contains("<div class=\"callout callout-note\">"))
        #expect(out.contains("<div class=\"callout-title\">"))
        // Inline Lucide SVG (note → pencil), tinted by CSS via currentColor.
        #expect(out.contains("<span class=\"callout-icon\"><svg"))
        #expect(out.contains(LucideIcons.geometry["pencil"]!))
        #expect(!out.contains("data-symbol"))
        #expect(out.contains("<span class=\"callout-title-text\">Note</span>"))
        #expect(out.contains("<div class=\"callout-body\"><p>Body text.</p></div>"))
    }

    @Test("Custom title is used verbatim")
    func customTitle() {
        let out = html("> [!warning] Watch out here\n> Careful.")
        #expect(out.contains("callout callout-warning"))
        #expect(out.contains("<span class=\"callout-title-text\">Watch out here</span>"))
    }

    @Test("Unknown type stays a plain block quote")
    func unknownType() {
        let out = html("> [!bogus]\n> hi")
        #expect(out.hasPrefix("<blockquote>"))
        #expect(!out.contains("callout"))
    }
}
