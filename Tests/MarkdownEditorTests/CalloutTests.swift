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

@Suite("Callout — title")
struct CalloutTitleTests {

    @Test("No custom title → capitalized type (note/NOTE both render Note)")
    func capitalized() {
        // parseMarker lowercases the type, so both `[!note]` and `[!NOTE]`
        // arrive here as "note".
        #expect(Callout.title(type: "note", customTitle: "") == "Note")
        #expect(Callout.title(type: "warning", customTitle: "   ") == "Warning")
    }

    @Test("Custom title is used verbatim (trimmed), preserving case")
    func customTitle() {
        #expect(Callout.title(type: "note", customTitle: " My Title ") == "My Title")
        #expect(Callout.title(type: "tip", customTitle: "DON'T") == "DON'T")
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

    @Test("GitHub types use the requested SF Symbols")
    func githubIcons() {
        #expect(Callout.style(for: "note")?.symbolName == "pencil.line")
        #expect(Callout.style(for: "tip")?.symbolName == "lightbulb.max")
        #expect(Callout.style(for: "important")?.symbolName == "exclamationmark.bubble")
        #expect(Callout.style(for: "warning")?.symbolName == "exclamationmark.triangle")
        #expect(Callout.style(for: "caution")?.symbolName == "exclamationmark.octagon")
    }

    @Test("Obsidian's default types and aliases all resolve")
    func obsidianTypes() {
        let types = ["abstract", "summary", "tldr", "info", "todo", "success", "check",
                     "done", "question", "help", "faq", "failure", "fail", "missing",
                     "danger", "error", "bug", "example", "quote", "cite", "hint", "attention"]
        for t in types { #expect(Callout.style(for: t) != nil, "expected '\(t)' to resolve") }
    }

    @Test("Aliases share their primary type's style")
    func aliases() {
        #expect(Callout.style(for: "summary") == Callout.style(for: "abstract"))
        #expect(Callout.style(for: "done") == Callout.style(for: "success"))
        #expect(Callout.style(for: "error") == Callout.style(for: "danger"))
        #expect(Callout.style(for: "cite") == Callout.style(for: "quote"))
    }

    @Test("Callouts have no border by default (background only)")
    func noBorderByDefault() {
        #expect(Callout.style(for: "note")?.borderEdges == [])
    }

    @Test("Overrides win and can add custom types (customization-ready)")
    func overrides() {
        let custom = CalloutStyle(symbolName: "star.fill", colorHex: "#123456")
        #expect(Callout.style(for: "FAQ", overrides: ["faq": custom]) == custom)
        #expect(Callout.style(for: "note", overrides: ["note": custom]) == custom)
    }

    @Test("Color resolution picks the dark accent under a dark appearance")
    func darkResolution() {
        let note = Callout.defaultStyles["note"]!
        #expect(note.accentHex(dark: false) == "#0969DA")
        #expect(note.accentHex(dark: true) == "#1F6FEB")
        // Border falls back to the (appearance-specific) accent when unset.
        #expect(note.resolvedBorderHex(dark: true) == "#1F6FEB")
        // No explicit background by default → renderer derives one from the accent.
        #expect(note.explicitBackgroundHex(dark: false) == nil)
    }

    @Test("Customizable fields are honored")
    func customFields() {
        let s = CalloutStyle(symbolName: "x", colorHex: "#111111",
                             borderColorHex: "#222222",
                             backgroundColorHex: "#333333",
                             borderEdges: [.left, .top], borderWidth: 5)
        #expect(s.resolvedBorderHex(dark: false) == "#222222")
        #expect(s.explicitBackgroundHex(dark: false) == "#333333")
        #expect(s.borderEdges.contains(.top))
        #expect(s.borderWidth == 5)
    }
}
