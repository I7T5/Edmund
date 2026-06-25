import Testing
import AppKit
@testable import EdmundCore

@Suite("DocumentHTML — assembly & asset inlining")
@MainActor
struct DocumentHTMLTests {

    private func doc(_ md: String, dark: Bool = false) -> String {
        DocumentHTML.full(markdown: md, theme: .default,
                          callouts: Callout.defaultStyles, dark: dark)
    }

    @Test("Wraps body in a full self-contained document")
    func wrapper() {
        let out = doc("# Hi")
        #expect(out.hasPrefix("<!DOCTYPE html>"))
        #expect(out.contains("<style>"))
        #expect(out.contains("<div class=\"page\"><h1>Hi</h1></div>"))
    }

    @Test("Callout icon placeholder becomes an inlined PNG data URI")
    func calloutIcon() {
        let out = doc("> [!note]\n> body")
        #expect(!out.contains("data-symbol"))   // placeholder consumed
        #expect(out.contains("<span class=\"callout-icon\"><img src=\"data:image/png;base64,"))
    }

    @Test("Inline math placeholder becomes an inlined image with baseline align")
    func inlineMath() {
        let out = doc("value $x^2$ here")
        #expect(!out.contains("data-tex"))
        #expect(out.contains("<img class=\"math math-inline\""))
        #expect(out.contains("vertical-align:"))
        #expect(out.contains("src=\"data:image/png;base64,"))
    }

    @Test("Display math placeholder becomes a centered image")
    func displayMath() {
        let out = doc("$$\nx^2\n$$")
        #expect(out.contains("<div class=\"math-display\"><img class=\"math\""))
        #expect(out.contains("src=\"data:image/png;base64,"))
    }

    @Test("Unparseable math falls back to showing the source")
    func mathFallback() {
        let out = doc("bad $\\frac{$ math")
        #expect(out.contains("<code>\\frac{</code>"))
    }
}
