import Testing
import Foundation
import AppKit
@testable import EdmundCore

// HTML tags in edit mode: every recognized tag is colored source (name red,
// brackets dimmed); a whitelist (u/kbd/mark/sub/sup) additionally renders its
// formatting when the caret is outside the token. Read mode is unchanged
// (HTML stays escaped).

@Suite("SyntaxHighlighter — HTML tags")
struct HTMLTagParseTests {

    private func kinds(_ text: String) -> [SyntaxHighlighter.Span.Kind] {
        SyntaxHighlighter.parse(text).map(\.kind)
    }

    @Test("Whitelisted pair → htmlFormat")
    func pair() {
        let spans = SyntaxHighlighter.parse("<u>hi</u>")
        let fmt = spans.first { if case .htmlFormat = $0.kind { return true }; return false }
        #expect(fmt != nil)
        #expect(fmt?.contentRange == NSRange(location: 3, length: 2))   // "hi"
        #expect(fmt?.delimiterRanges == [NSRange(location: 0, length: 3),   // <u>
                                         NSRange(location: 5, length: 4)])  // </u>
    }

    @Test("Unknown tag → htmlTag (colored only)")
    func unknown() {
        let spans = SyntaxHighlighter.parse("a <span> b")
        let tag = spans.first { if case .htmlTag = $0.kind { return true }; return false }
        #expect(tag?.contentRange == NSRange(location: 3, length: 4))   // "span"
        #expect(!spans.contains { if case .htmlFormat = $0.kind { return true }; return false })
    }

    @Test("Unpaired whitelist tag → htmlTag, not htmlFormat")
    func unpaired() {
        let k = kinds("<u> alone")
        #expect(k.contains { if case .htmlTag = $0 { return true }; return false })
        #expect(!k.contains { if case .htmlFormat = $0 { return true }; return false })
    }

    @Test("Escaped `\\<u\\>` is not an HTML tag")
    func escaped() {
        let k = kinds("\\<u\\>")
        #expect(!k.contains { if case .htmlTag = $0 { return true }; return false })
        #expect(!k.contains { if case .htmlFormat = $0 { return true }; return false })
    }

    @Test("No HTML tag inside inline code")
    func insideCode() {
        let k = kinds("`<u>x</u>`")
        #expect(!k.contains { if case .htmlTag = $0 { return true }; return false })
        #expect(!k.contains { if case .htmlFormat = $0 { return true }; return false })
    }
}

@Suite("Rendering — HTML tags")
@MainActor
struct HTMLTagRenderingTests {

    private func attr(_ key: NSAttributedString.Key, at i: Int, in s: NSAttributedString) -> Any? {
        guard i < s.length else { return nil }
        return s.attribute(key, at: i, effectiveRange: nil)
    }

    @Test("Unknown tag: name red, brackets dimmed")
    func coloredSource() {
        let editor = makeEditor()
        let styled = editor.styleBlock("a <span> b")
        #expect(attr(.foregroundColor, at: 3, in: styled) as? NSColor == editor.theme.mathOperatorColor)
        #expect(isDimmed(at: 2, in: styled))   // <
        #expect(isDimmed(at: 7, in: styled))   // >
    }

    @Test("Inactive pair: tags hidden, content rendered")
    func pairInactive() {
        let editor = makeEditor()
        let styled = editor.styleBlock("<u>hi</u>", cursorPosition: nil)
        #expect(isHidden(at: 0, in: styled))   // <u>
        #expect(isHidden(at: 5, in: styled))   // </u>
        #expect(attr(.underlineStyle, at: 3, in: styled) as? Int == NSUnderlineStyle.single.rawValue)
    }

    @Test("Active pair: tags shown (not hidden), content not underlined")
    func pairActive() {
        let editor = makeEditor()
        let styled = editor.styleBlock("<u>hi</u>", cursorPosition: 4)
        #expect(!isHidden(at: 0, in: styled))
        #expect(attr(.underlineStyle, at: 3, in: styled) == nil)
    }

    @Test("kbd, mark, sub, sup map to their attributes")
    func attributeMap() {
        let editor = makeEditor()

        let kbd = editor.styleBlock("<kbd>K</kbd>", cursorPosition: nil)
        #expect((attr(.font, at: 5, in: kbd) as? NSFont) == editor.inlineCodeFont)
        #expect(attr(.backgroundColor, at: 5, in: kbd) as? NSColor == editor.inlineCodeBackground)

        let mark = editor.styleBlock("<mark>M</mark>", cursorPosition: nil)
        #expect(attr(.backgroundColor, at: 6, in: mark) != nil)

        let sub = editor.styleBlock("<sub>2</sub>", cursorPosition: nil)
        #expect((attr(.baselineOffset, at: 5, in: sub) as? CGFloat ?? 0) < 0)

        let sup = editor.styleBlock("<sup>2</sup>", cursorPosition: nil)
        #expect((attr(.baselineOffset, at: 5, in: sup) as? CGFloat ?? 0) > 0)
    }

    @Test("Inner markdown still styles: <u>**b**</u>")
    func innerMarkdown() {
        let editor = makeEditor()
        let styled = editor.styleBlock("<u>**b**</u>", cursorPosition: nil)
        // 'b' is at offset 5 (after <u> and **).
        #expect(attr(.underlineStyle, at: 5, in: styled) as? Int == NSUnderlineStyle.single.rawValue)
        let f = attr(.font, at: 5, in: styled) as? NSFont
        #expect(f != nil && NSFontManager.shared.traits(of: f!).contains(.boldFontMask))
    }
}

@Suite("HTMLRenderer — whitelisted HTML passes through")
struct HTMLTagExportTests {

    private func html(_ md: String) -> String { HTMLRenderer.render(markdown: md) }

    @Test("Whitelisted tags render as real tags")
    func passesThrough() {
        #expect(html("<u>x</u>").contains("<u>x</u>"))
        #expect(html("<kbd>K</kbd>").contains("<kbd>K</kbd>"))
        #expect(html("<mark>m</mark>").contains("<mark>m</mark>"))
        #expect(html("H<sub>2</sub>O").contains("<sub>2</sub>"))
        #expect(html("x<sup>2</sup>").contains("<sup>2</sup>"))
    }

    @Test("Attributes are stripped (bare tag only)")
    func stripsAttributes() {
        let out = html("<u class=\"x\" onclick=\"y\">hi</u>")
        #expect(out.contains("<u>hi</u>"))
        #expect(!out.contains("class"))
        #expect(!out.contains("onclick"))
    }

    @Test("Inner markdown still renders inside a passed tag")
    func innerMarkdown() {
        #expect(html("<u>**b**</u>").contains("<u><strong>b</strong></u>"))
    }

    @Test("Non-whitelisted inline tag stays escaped")
    func unknownEscaped() {
        let out = html("a <span>x</span> b")
        #expect(out.contains("&lt;span&gt;"))
        #expect(!out.contains("<span>"))
    }

    @Test("A nested script inside a passed tag is still escaped")
    func nestedScriptEscaped() {
        let out = html("<u><script>alert(1)</script></u>")
        #expect(out.contains("<u>"))
        #expect(!out.contains("<script>"))
        #expect(out.contains("&lt;script&gt;"))
    }
}
