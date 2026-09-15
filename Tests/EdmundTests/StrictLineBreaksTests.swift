import Testing
import Foundation
@testable import EdmundCore

// Strict line breaks (Edit ▸ Lines). On (Markdown default): a single source
// newline is a soft break and collapses. Off: it renders as a literal <br>.

@Suite("HTMLRenderer — strict line breaks")
struct StrictLineBreaksTests {

    private func html(_ md: String, strict: Bool) -> String {
        HTMLRenderer.render(markdown: md, options: ReadRenderOptions(strictLineBreaks: strict))
    }

    @Test("Soft break collapses when strict (Markdown default)")
    func softBreakStrict() {
        #expect(!html("a\nb", strict: true).contains("<br>"))
    }

    @Test("Soft break becomes a literal <br> when strict is off")
    func softBreakLoose() {
        #expect(html("a\nb", strict: false).contains("a<br>"))
    }

    @Test("Explicit hard break (two trailing spaces) stays a <br> in both modes")
    func hardBreakUnaffected() {
        #expect(html("a  \nb", strict: true).contains("<br>"))
        #expect(html("a  \nb", strict: false).contains("<br>"))
    }
}
