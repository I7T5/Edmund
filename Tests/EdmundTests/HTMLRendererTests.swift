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
        #expect(task.contains("<li class=\"task\"><input type=\"checkbox\" disabled>"))
        #expect(task.contains("<input type=\"checkbox\" disabled checked>"))
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

    @Test("Links render as <a href>")
    func links() {
        #expect(html("[text](https://example.com)") == "<p><a href=\"https://example.com\">text</a></p>")
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

    @Test("Wikilink renders display text (routing deferred)")
    func wikilink() {
        #expect(html("see [[Note|the note]]").contains("the note"))
        #expect(!html("see [[Note|the note]]").contains("[["))
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
        #expect(out.contains("data-symbol=\"pencil.tip\""))
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
