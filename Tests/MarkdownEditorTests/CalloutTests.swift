import Testing
import Foundation
@testable import MarkdownEditorCore

@Suite("Callout — marker parsing")
struct CalloutMarkerTests {

    @Test("Parses [!note] into component ranges, lowercased")
    func basic() {
        let m = Callout.parseMarker("[!note]")
        #expect(m?.type == "note")
        #expect(m?.openBracket == NSRange(location: 0, length: 2))   // "[!"
        #expect(m?.typeRange == NSRange(location: 2, length: 4))     // "note"
        #expect(m?.closeBracket == NSRange(location: 6, length: 1))  // "]"
    }

    @Test("Type matching is case-insensitive")
    func caseInsensitive() {
        #expect(Callout.parseMarker("[!NOTE]")?.type == "note")
        #expect(Callout.parseMarker("[!Tip]")?.type == "tip")
        #expect(Callout.parseMarker("[!WARNING] title")?.type == "warning")
    }

    @Test("Allows leading whitespace before the marker")
    func leadingWhitespace() {
        let m = Callout.parseMarker("  [!caution]")
        #expect(m?.type == "caution")
        #expect(m?.openBracket.location == 2)
    }

    @Test("Rejects non-markers")
    func rejects() {
        #expect(Callout.parseMarker("not a callout") == nil)
        #expect(Callout.parseMarker("[!]") == nil)            // empty type
        #expect(Callout.parseMarker("[!note") == nil)         // no closing bracket
        #expect(Callout.parseMarker("text [!note]") == nil)   // not at the start
    }
}

@Suite("Callout — style registry")
struct CalloutStyleTests {

    @Test("GitHub's five types resolve, case-insensitively")
    func known() {
        #expect(Callout.style(for: "note") != nil)
        #expect(Callout.style(for: "TIP") != nil)
        #expect(Callout.style(for: "Important") != nil)
        #expect(Callout.style(for: "warning") != nil)
        #expect(Callout.style(for: "caution") != nil)
    }

    @Test("Unknown types are not callouts")
    func unknown() {
        #expect(Callout.style(for: "bogus") == nil)
    }

    @Test("Overrides win and can add custom types (customization-ready)")
    func overrides() {
        let custom = CalloutStyle(symbolName: "star.fill", colorHex: "#123456")
        #expect(Callout.style(for: "FAQ", overrides: ["faq": custom]) == custom)
        #expect(Callout.style(for: "note", overrides: ["note": custom]) == custom)
    }
}
