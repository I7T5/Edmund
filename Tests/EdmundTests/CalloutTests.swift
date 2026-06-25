import Testing
import Foundation
@testable import EdmundCore

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

    @Test("Built-in types use the expected Lucide icons")
    func builtinIcons() {
        #expect(Callout.style(for: "note")?.iconName == "pencil")
        #expect(Callout.style(for: "tip")?.iconName == "flame")
        #expect(Callout.style(for: "important")?.iconName == "message-square-warning")
        #expect(Callout.style(for: "warning")?.iconName == "triangle-alert")
        #expect(Callout.style(for: "caution")?.iconName == "octagon-alert")
        #expect(Callout.style(for: "todo")?.iconName == "circle-dashed")
        #expect(Callout.style(for: "success")?.iconName == "check")
        #expect(Callout.style(for: "failure")?.iconName == "x")
    }

    @Test("Every built-in callout icon id has vendored Lucide geometry")
    func everyIconResolves() {
        for (type, style) in Callout.defaultStyles {
            #expect(LucideIcons.geometry[style.iconName] != nil,
                    "callout '\(type)' uses unknown icon '\(style.iconName)'")
        }
    }

    @Test("note matches info's color; tip matches abstract's; warning aliases match warning")
    func colorGroupings() {
        #expect(Callout.style(for: "note")?.colorHex == Callout.style(for: "info")?.colorHex)
        #expect(Callout.style(for: "tip")?.colorHex == Callout.style(for: "abstract")?.colorHex)
        #expect(Callout.style(for: "warning")?.colorHex == Callout.style(for: "question")?.colorHex)
        #expect(Callout.style(for: "attention")?.colorHex == Callout.style(for: "warning")?.colorHex)
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
        let custom = CalloutStyle(iconName: "star", colorHex: "#123456")
        #expect(Callout.style(for: "FAQ", overrides: ["faq": custom]) == custom)
        #expect(Callout.style(for: "note", overrides: ["note": custom]) == custom)
    }

    @Test("Color resolution picks the dark accent under a dark appearance")
    func darkResolution() {
        let important = Callout.defaultStyles["important"]!
        #expect(important.accentHex(dark: false) == "#8250DF")
        #expect(important.accentHex(dark: true) == "#A371F7")
        // Border falls back to the (appearance-specific) accent when unset.
        #expect(important.resolvedBorderHex(dark: true) == "#A371F7")
        // No explicit background by default → renderer derives one from the accent.
        #expect(important.explicitBackgroundHex(dark: false) == nil)
        // A type with no dark variant falls back to its light accent.
        let note = Callout.defaultStyles["note"]!
        #expect(note.accentHex(dark: true) == note.colorHex)
    }

    @Test("Customizable fields are honored")
    func customFields() {
        let s = CalloutStyle(iconName: "x", colorHex: "#111111",
                             borderColorHex: "#222222",
                             backgroundColorHex: "#333333",
                             borderEdges: [.left, .top], borderWidth: 5)
        #expect(s.resolvedBorderHex(dark: false) == "#222222")
        #expect(s.explicitBackgroundHex(dark: false) == "#333333")
        #expect(s.borderEdges.contains(.top))
        #expect(s.borderWidth == 5)
    }
}
