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
        #expect(html("# Title") == "<h1 id=\"edmund-l1\">Title</h1>")
        #expect(html("### Sub") == "<h3 id=\"edmund-l1\">Sub</h3>")
        #expect(html("###### Six") == "<h6 id=\"edmund-l1\">Six</h6>")
    }

    @Test("Setext headings render h1/h2")
    func setextHeadings() {
        #expect(html("Title\n===") == "<h1 id=\"edmund-l1\">Title</h1>")
        #expect(html("Title\n---") == "<h2 id=\"edmund-l1\">Title</h2>")
    }

    @Test("Paragraph wraps in <p>")
    func paragraph() {
        #expect(html("hello world") == "<p id=\"edmund-l1\">hello world</p>")
    }

    @Test("Emphasis, strong, strikethrough, inline code")
    func inlineMarks() {
        #expect(html("*i*") == "<p id=\"edmund-l1\"><em>i</em></p>")
        #expect(html("**b**") == "<p id=\"edmund-l1\"><strong>b</strong></p>")
        #expect(html("~~s~~") == "<p id=\"edmund-l1\"><del>s</del></p>")
        #expect(html("`x`") == "<p id=\"edmund-l1\"><code>x</code></p>")
    }

    @Test("Fenced code block keeps language class and escapes content")
    func codeBlock() {
        let out = html("```swift\nlet x = a < b && c > d\n```")
        // The anchor id now lands on the wrapping div (first opening tag).
        #expect(out.contains("<div id=\"edmund-l1\" class=\"code-block-wrap\">"))
        #expect(out.contains("<pre><code class=\"language-swift\">"))
        #expect(out.contains("a &lt; b &amp;&amp; c &gt; d"))
        #expect(!out.contains("a < b"))
    }

    @Test("Code block carries a hover-revealed icon copy button with a base64 payload")
    func codeBlockCopyButton() {
        let out = html("```swift\nlet x = 1\n```")
        #expect(out.contains("class=\"code-copy-btn code-copy-icon\""))
        #expect(out.contains("<svg"))                      // icon-only, no text label
        // href = x-edmund-copy:<percent-encoded base64 of the code>.
        let b64 = Data("let x = 1".utf8).base64EncodedString()
        let encoded = b64.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? b64
        #expect(out.contains("href=\"x-edmund-copy:\(encoded)\""))
        // Indented blocks get the same wrapper + button.
        let indented = html("    let y = 2")
        #expect(indented.contains("code-copy-btn"))
    }

    @Test("Unordered, ordered, and task lists")
    func lists() {
        // A tight list (GFM §5.3): no <p> wrapper inside items.
        #expect(html("- a\n- b") == "<ul id=\"edmund-l1\"><li>a</li><li>b</li></ul>")
        #expect(html("1. a").hasPrefix("<ol id=\"edmund-l1\">"))
        #expect(html("3. a\n4. b").hasPrefix("<ol id=\"edmund-l1\" start=\"3\">"))
        let task = html("- [ ] todo\n- [x] done")
        // The box is a link (the read view intercepts the scheme) that keeps
        // the `.task-check` classes, so the CSS still reaches it as a child.
        #expect(task.contains("<li class=\"task\"><a href=\"x-edmund-task:1\" "
                              + "class=\"task-check task-check--unchecked\"><svg"))
        #expect(task.contains("<a href=\"x-edmund-task:2\" class=\"task-check task-check--checked\"><svg"))
    }

    /// The checkbox link carries the item's line in the *document's* numbering,
    /// including nested items — the editor flips that line.
    @Test("A nested task's checkbox link names its own source line")
    func nestedTaskLine() {
        let out = html("intro\n\n- a\n  - [ ] deep")
        #expect(out.contains("href=\"x-edmund-task:4\""))
    }

    /// Front matter and block `%%` comments are cut out before parsing, so
    /// swift-markdown's lines are short by what was cut; anchors and checkbox
    /// links have to be in source lines or a click lands on the wrong item.
    @Test("Anchors and checkbox links count lines the strips removed")
    func lineNumbersSurviveStripping() {
        let fm = html("---\ntitle: x\n---\n\n- [ ] first")
        #expect(fm.contains("<ul id=\"edmund-l5\">"))
        #expect(fm.contains("href=\"x-edmund-task:5\""))

        let comment = html("para\n\n%%\nhidden\n%%\n\n- [ ] after")
        #expect(comment.contains("id=\"edmund-l1\">para"))
        #expect(comment.contains("href=\"x-edmund-task:7\""))

        // Both at once: the comment's line is reported after the front matter
        // was already cut, and the two offsets add up.
        let both = html("---\nt: 1\n---\n\n%%\nhidden\n%%\n\n- [x] last")
        #expect(both.contains("href=\"x-edmund-task:9\""))
    }

    @Test("A loose list (blank line between items) keeps <p> wrappers")
    func looseList() {
        let out = html("- a\n\n- b")
        #expect(out.contains("<li><p>a</p></li>"))
        #expect(out.contains("<li><p>b</p></li>"))
    }

    @Test("A multi-block item with a blank gap makes the whole list loose")
    func looseByMultiBlockItem() {
        let out = html("- a\n\n  second\n- b")
        #expect(out.contains("<p>a</p>"))
        #expect(out.contains("<p>second</p>"))
        #expect(out.contains("<li><p>b</p></li>"))
    }

    @Test("Nested loose list gets <p>; the tight outer list doesn't")
    func mixedNesting() {
        let out = html("- a\n  - x\n\n  - y\n- b")
        #expect(out.contains("<li><p>x</p></li>"))
        #expect(out.contains("<p>y</p>"))
        #expect(!out.contains("<p>a</p>"))
        #expect(out.contains("<li>b</li>"))
    }

    @Test("Link title renders as an escaped title attribute")
    func linkTitle() {
        #expect(html("[x](https://example.com \"hi there\")")
            == "<p id=\"edmund-l1\"><a href=\"https://example.com\" title=\"hi there\">x</a></p>")
        #expect(html("[x](https://example.com \"a & b\")").contains("title=\"a &amp; b\""))
        let internalLink = html("[o](other.md \"note\")")
        #expect(internalLink.contains("<a href=\"x-edmund-link:"))
        #expect(internalLink.contains("title=\"note\""))
    }

    @Test("Table emits thead/tbody with per-column alignment")
    func table() {
        let out = html("| a | b | c |\n|:--|:-:|--:|\n| 1 | 2 | 3 |")
        #expect(out.contains("<div id=\"edmund-l1\" class=\"table-wrap\"><table><thead><tr>"))
        #expect(out.contains("</tbody></table></div>"))
        #expect(out.contains("<th style=\"text-align:left\">a</th>"))
        #expect(out.contains("<th style=\"text-align:center\">b</th>"))
        #expect(out.contains("<th style=\"text-align:right\">c</th>"))
        #expect(out.contains("<tbody><tr><td style=\"text-align:left\">1</td>"))
    }

    @Test("Thematic break → <hr>")
    func thematicBreak() {
        #expect(html("---").contains("<hr id=\"edmund-l1\">"))
    }

    @Test("External links keep their real href")
    func links() {
        #expect(html("[text](https://example.com)") == "<p id=\"edmund-l1\"><a href=\"https://example.com\">text</a></p>")
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
        #expect(html("> quoted") == "<blockquote id=\"edmund-l1\"><p>quoted</p></blockquote>")
    }
}

@Suite("HTMLRenderer — escaping & security")
struct HTMLRendererEscapingTests {

    private func html(_ md: String) -> String { HTMLRenderer.render(markdown: md) }

    @Test("Inline <script> is tagfiltered (no script injection)")
    func escapesText() {
        let out = html("a <script>alert(1)</script> & b")
        #expect(!out.contains("<script"))
        #expect(out.contains("&lt;script>alert(1)&lt;/script>"))
        #expect(out.contains("&amp;"))
    }

    @Test("Raw HTML block passes through with event handlers stripped")
    func blockPassthroughHardened() {
        let out = html("<div onclick=\"x\">hi</div>")
        #expect(out.contains("<div id=\"edmund-l1\">hi</div>"))
        #expect(!out.contains("onclick"))
    }
}

@Suite("HTMLRenderer — GFM raw HTML, tagfilter & hardening")
struct HTMLRendererRawHTMLTests {

    private func html(_ md: String) -> String { HTMLRenderer.render(markdown: md) }

    // GFM §6.11 spec example: only the leading `<` of a disallowed tag becomes
    // `&lt;` (the `>` stays literal); everything else passes through raw.
    @Test("Tagfilter spec example: disallowed tags get &lt;, others pass")
    func tagfilterSpecExample() {
        let out = html("<strong> <title> <style> <em>\n\n<blockquote>\n  <xmp> is disallowed.  <XMP> is also disallowed.\n</blockquote>")
        #expect(out.contains("<strong> &lt;title> &lt;style> <em>"))
        #expect(out.contains("&lt;xmp>"))
        #expect(out.contains("&lt;XMP>"))
        #expect(out.contains("<blockquote id=\"edmund-l3\">"))
    }

    @Test("HTML block passes through raw; markdown inside is NOT rendered")
    func blockPassthroughRaw() {
        let out = html("<div>\n*hello*\n</div>")
        #expect(out.contains("<div id=\"edmund-l1\">\n*hello*\n</div>"))
        #expect(!out.contains("<em>"))
    }

    @Test("A <script> block is tagfiltered, content inert")
    func scriptBlockTagfiltered() {
        let out = html("<script>\nalert(1)\n</script>")
        #expect(!out.contains("<script"))
        #expect(out.contains("&lt;script>"))
        #expect(out.contains("alert(1)"))
    }

    @Test("javascript: href is neutralized")
    func jsHrefNeutralized() {
        let out = html("<a href=\"javascript:alert(1)\">x</a>")
        #expect(!out.lowercased().contains("javascript:"))
        #expect(out.contains("<a href="))
    }

    @Test("vbscript: action and single-quoted onmouseover are hardened")
    func moreHardening() {
        let out = html("<form action=\"vbscript:evil()\"><span onmouseover='x()'>t</span></form>")
        #expect(!out.lowercased().contains("vbscript:"))
        #expect(!out.contains("onmouseover"))
    }

    @Test("An <img> inside an HTML block becomes the asset-pass placeholder")
    func blockInteriorImg() {
        let out = html("<div><img src=\"cat.png\" alt=\"c\"></div>")
        #expect(out.contains("<div id=\"edmund-l1\">"))
        #expect(out.contains("<img class=\"md-image\" data-src=\"cat.png\""))
    }

    @Test("A raw <table> block passes through")
    func tableBlock() {
        let out = html("<table><tr><td>x</td></tr></table>")
        #expect(out.contains("<table id=\"edmund-l1\"><tr><td>x</td></tr></table>"))
    }

    @Test("A single-quoted <img src> still becomes the asset-pass placeholder")
    func singleQuotedImgRead() {
        let out = html("pic <img src='cat.png'> x")
        #expect(out.contains("data-src=\"cat.png\""))
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
        #expect(out.contains("<div id=\"edmund-l1\" class=\"math-display\" data-tex=\""))
        #expect(out.contains("\\int_0^1"))
    }


    // Single-line `$$…$$` owning its paragraph — the shape used in test.md.
    @Test("Single-line $$math$$ paragraph → math-display div, not inline span")
    func singleLineDisplayMath() {
        let out = html("$$f(x)=a_nx^n+a_1x+a_0$$")
        #expect(out.contains("class=\"math-display\""))
        #expect(!out.contains("math-display-inline"))
    }

    // Read-mode parity with the editor's list-item block math: a `$$…$$` that is
    // the whole content of a list item renders as a display-math block inside the
    // <li> (swift-markdown lazy-continues the item's following lines into one
    // paragraph, and visitParagraph emits the math-display div for it).
    @Test("Display $$math$$ inside a list item → math-display div in the <li>")
    func listDisplayMath() {
        let out = html("1. $$\n\\int_0^1 x\\,dx\n$$")
        #expect(out.contains("<li>"))
        #expect(out.contains("class=\"math-display\""))
        #expect(out.contains("\\int_0^1"))
    }

    // A `$$…$$` inside inline code is literal source, not a display-math block.
    // Regression: visitParagraph used to promote any paragraph containing a
    // `$$…$$` span to a math block, blanking the surrounding text.
    @Test("$$…$$ inside inline code renders verbatim, not as a math block")
    func dollarsInInlineCodeAreVerbatim() {
        let out = html("Inline code `$$a+b$$` should be verbatim.")
        #expect(!out.contains("math-display"))
        #expect(out.contains("<code>$$a+b$$</code>"))
        #expect(out.contains("should be verbatim"))       // surrounding text kept
    }

    // A `$$…$$` amid prose keeps the surrounding text and renders the math
    // inline in display mode (matching the editor), not as a block that blanks
    // the paragraph.
    @Test("$$…$$ amid prose renders inline display math, keeps the text")
    func dollarsAmidProseRenderInline() {
        let out = html("before $$\\int_0^1 x$$ after")
        #expect(!out.contains("class=\"math-display\""))   // not a block div
        #expect(out.contains("math-display-inline"))        // inline display math
        #expect(out.contains("\\int_0^1"))
        #expect(out.contains("before"))
        #expect(out.contains("after"))
    }

    @Test("$$…$$ in a list item alongside prose renders inline, not as a block")
    func dollarsInListItemWithProse() {
        let out = html("- First $$\\int_0^1 x$$")
        #expect(out.contains("<li>"))
        #expect(out.contains("math-display-inline"))
        #expect(!out.contains("class=\"math-display\""))
        #expect(out.contains("First"))
    }

    // Regression: LaTeX environments carry `\\` row separators. swift-markdown's
    // Text nodes have Markdown backslash-escapes collapsed (`\\`→`\`), so the tex
    // must be recovered from the raw source or `\begin{cases}`/`\begin{aligned}`
    // arrive mangled. (misc/bug-repros/math-env-read-mode.png)
    @Test("Inline environment keeps its `\\\\` row separators in data-tex")
    func inlineEnvironmentRowSeparators() {
        let out = html("matrix $I_{ij}=\\begin{cases} 1 & i=j \\\\ 0 & i\\neq j \\end{cases}$ ok")
        #expect(out.contains("<span class=\"math-inline\" data-tex=\""))
        #expect(out.contains("\\begin{cases}"))
        #expect(out.contains("\\\\ 0"))          // the `\\` survived (not collapsed to `\`)
        #expect(out.contains("\\end{cases}"))
    }

    @Test("Display environment keeps its `\\\\` row separators in data-tex")
    func displayEnvironmentRowSeparators() {
        let out = html("$$\n\\begin{aligned} \\pi &= 3 \\\\ e &= 2 \\end{aligned}\n$$")
        #expect(out.contains("<div id=\"edmund-l1\" class=\"math-display\" data-tex=\""))
        #expect(out.contains("\\begin{aligned}"))
        #expect(out.contains("\\\\ e"))          // the `\\` survived
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

    @Test("Inline HTML comment is hidden, not literal text")
    func inlineHTMLComment() {
        let out = html("before <!-- secret --> after")
        #expect(!out.contains("secret"))
        #expect(out.contains("before"))
        #expect(out.contains("after"))
    }

    @Test("Block-level HTML comment is hidden")
    func blockHTMLComment() {
        #expect(!html("para\n\n<!-- secret -->\n\nend").contains("secret"))
    }

    @Test("Inline <img> emits the asset-pass placeholder with declared dimensions")
    func inlineImgTag() {
        let out = html("pic <img src=\"cat.png\" alt=\"a cat\" width=\"120\" height=\"80\"> here")
        #expect(out.contains("<img class=\"md-image\" data-src=\"cat.png\" alt=\"a cat\" width=\"120\" height=\"80\">"))
    }

    @Test("Block-level <img> line emits the placeholder too")
    func blockImgTag() {
        let out = html("<img src=\"cat.png\">")
        #expect(out.contains("<img class=\"md-image\" data-src=\"cat.png\" alt=\"\">"))
    }

    @Test("An <img> without a src passes through raw (no placeholder)")
    func imgWithoutSrc() {
        let out = html("x <img width=\"9\"> y")
        #expect(!out.contains("md-image"))
        #expect(out.contains("<img width=\"9\">"))
    }

    @Test("Bare www autolink renders as a real anchor")
    func wwwAutolink() {
        let out = html("visit www.example.com now")
        #expect(out.contains("<a href=\"http://www.example.com\">www.example.com</a>"))
    }

    @Test("Email autolink renders as a mailto anchor")
    func emailAutolink() {
        let out = html("mail foo@bar.example.com please")
        #expect(out.contains("<a href=\"mailto:foo@bar.example.com\">foo@bar.example.com</a>"))
    }

    @Test("Autolink trailing punctuation stays outside the anchor")
    func autolinkTrim() {
        let out = html("see www.example.com.")
        #expect(out.contains("<a href=\"http://www.example.com\">www.example.com</a>."))
    }

    @Test("No autolink inside inline code")
    func autolinkNotInCode() {
        let out = html("`www.example.com`")
        #expect(!out.contains("<a href"))
    }

    @Test("A real [x](url) link is untouched; a bare URL beside it links")
    func autolinkBesideRealLink() {
        let out = html("[x](http://a.example.com) http://b.example.com")
        #expect(out.contains(">x</a>"))
        #expect(out.contains("<a href=\"http://b.example.com\">http://b.example.com</a>"))
    }
}

@Suite("HTMLRenderer — footnotes")
struct HTMLRendererFootnoteTests {

    private func html(_ md: String) -> String { HTMLRenderer.render(markdown: md) }

    @Test("Reference becomes a superscript link; raw [^id] doesn't leak into the page")
    func reference() {
        let out = html("Hello world.[^1]\n\n[^1]: a note")
        #expect(out.contains("<sup id=\"fnref-1\" class=\"footnote-ref\"><a href=\"#fn-1\">1</a></sup>"))
        #expect(!out.contains("[^1]"))
    }

    @Test("Definition moves to a bottom section with a backlink, not rendered in place")
    func definitionMovesToBottom() {
        let out = html("See.[^1]\n\n[^1]: the note text\n\nMore content.")
        #expect(!out.contains("<p>[^1]"))
        #expect(out.contains("<hr class=\"footnotes-sep\"><ol class=\"footnotes\">"))
        #expect(out.contains("<li id=\"fn-1\">the note text <a href=\"#fnref-1\" class=\"footnote-backref\">↩</a></li>"))
        // The unrelated paragraph after the definition still renders normally.
        #expect(out.contains("<p id=\"edmund-l5\">More content.</p>"))
    }

    @Test("Definition body keeps its inline markdown formatting")
    func definitionBodyKeepsFormatting() {
        let out = html("See.[^1]\n\n[^1]: has **bold** text")
        #expect(out.contains("<li id=\"fn-1\">has <strong>bold</strong> text"))
    }

    @Test("No footnotes: no bottom section emitted")
    func noFootnotesNoSection() {
        #expect(!html("plain paragraph, no notes").contains("footnotes-sep"))
    }

    @Test("Document produced by the Format-menu Insert Footnote command renders correctly in Read mode")
    @MainActor func viaFormatMenuCommand() {
        let editor = makeEditor()
        editor.loadContent("Hello world.")
        editor.formatFootnote(nil)
        editor.insertText("This is the note.", replacementRange: editor.selectedRange())
        let out = html(editor.rawSource)
        #expect(out.contains("<sup id=\"fnref-1\" class=\"footnote-ref\"><a href=\"#fn-1\">1</a></sup>"))
        #expect(out.contains("<li id=\"fn-1\">This is the note."))
        #expect(!out.contains("[^1]"))
    }
}

@Suite("HTMLRenderer — callouts")
struct HTMLRendererCalloutTests {

    private func html(_ md: String) -> String { HTMLRenderer.render(markdown: md) }

    @Test("Known callout type → callout div with title and body")
    func basicCallout() {
        let out = html("> [!note]\n> Body text.")
        #expect(out.contains("<div id=\"edmund-l1\" class=\"callout callout-note\">"))
        #expect(out.contains("<div class=\"callout-title\">"))
        // Inline Lucide SVG (note → pencil), tinted by CSS via currentColor.
        #expect(out.contains("<span class=\"callout-icon\"><svg"))
        #expect(out.contains(LucideIcons.geometry["pencil"]!))
        #expect(!out.contains("data-symbol"))
        #expect(out.contains("<span class=\"callout-title-text\">Note</span>"))
        #expect(out.contains("<div class=\"callout-body\"><p id=\"edmund-l1\">Body text.</p></div>"))
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
        #expect(out.hasPrefix("<blockquote id=\"edmund-l1\">"))
        #expect(!out.contains("callout"))
    }

    // Callouts are strict in BOTH modes: a bare (lazy) line after a callout body
    // does NOT join the callout — it renders as a sibling, matching edit-mode
    // block segmentation (BlockParser keeps callouts strict; see
    // BlockquoteLazyContinuationTests.calloutStaysStrict for the edit side).
    @Test("A lazy line after a callout renders as a sibling, not in the body")
    func calloutBodyStrict() {
        let out = html("> [!note]\n> body\nlazy")
        #expect(out.contains("<div class=\"callout-body\"><p id=\"edmund-l1\">body</p></div>"))
        // `lazy` sits after the callout div closes, not inside the body.
        #expect(out.contains("</div></div><p id=\"edmund-l1\">lazy</p>"))
        #expect(!out.contains("body\nlazy"))
    }

    @Test("GFM ex.228 tail: `> y` after a lazy line is a sibling quote, not the callout")
    func calloutLazyTailWithQuote() {
        let out = html("> [!note]\n> body\nlazy\n> y")
        #expect(out.contains("<div class=\"callout-body\"><p id=\"edmund-l1\">body</p></div>"))
        #expect(out.contains("<p id=\"edmund-l1\">lazy</p>"))
        #expect(out.contains("<blockquote id=\"edmund-l2\"><p>y</p></blockquote>"))
        // Exactly one callout — the second `> y` was not pulled into it.
        #expect(out.components(separatedBy: "class=\"callout ").count == 2)
    }

    @Test("A fully `>`-prefixed callout body is unchanged (no lazy split)")
    func calloutFullyQuotedUnchanged() {
        let out = html("> [!note]\n> a\n> b")
        #expect(out.contains("<div class=\"callout-body\"><p id=\"edmund-l1\">a\nb</p></div>"))
        #expect(!out.contains("</div></div><p>"))
    }
}

@Suite("HTMLRenderer — Read-mode source-line anchors")
struct HTMLRendererAnchorTests {

    private func html(_ md: String, preserveBlankLines: Bool) -> String {
        HTMLRenderer.render(markdown: md, options: ReadRenderOptions(preserveBlankLines: preserveBlankLines))
    }

    @Test("Each top-level block gets an id anchored to its starting source line")
    func topLevelBlocksAnchored() {
        let md = "# H\n\npara one\nline two\n\n- a\n- b\n"
        for preserveBlankLines in [true, false] {
            let out = html(md, preserveBlankLines: preserveBlankLines)
            #expect(out.contains("<h1 id=\"edmund-l1\">H</h1>"))
            #expect(out.contains("<p id=\"edmund-l3\">para one\nline two</p>"))
            #expect(out.contains("<ul id=\"edmund-l6\">"))
        }
    }

    @Test("A footnote-definition first block renders empty and doesn't crash; the next block still gets its id")
    func emptyFirstBlockSkipped() {
        let out = html("[^1]: note\n\npara\n", preserveBlankLines: true)
        #expect(out.contains("<p id=\"edmund-l3\">para</p>"))
    }

    @Test("topLevelBlockSpans reports each block's start/end source line")
    func topLevelBlockSpans() {
        let spans = ReadModeAnchors.topLevelBlockSpans(for: "# H\n\npara one\nline two\n\n- a\n- b\n")
        #expect(spans.count == 3)
        #expect(spans[0].startLine == 1 && spans[0].endLine == 1)
        #expect(spans[1].startLine == 3 && spans[1].endLine == 4)
        #expect(spans[2].startLine == 6 && spans[2].endLine == 7)
    }
}
