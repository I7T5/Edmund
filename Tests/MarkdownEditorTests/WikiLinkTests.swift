import Testing
import AppKit
@testable import MarkdownEditorCore

@Suite("Wikilinks")
@MainActor
struct WikiLinkTests {

    private func wiki(_ spans: [SyntaxHighlighter.Span]) -> SyntaxHighlighter.Span? {
        spans.first { if case .wikilink = $0.kind { return true }; return false }
    }

    @Test("Plain [[Note]] parses with the whole name as display + target")
    func plain() {
        let spans = SyntaxHighlighter.parse("see [[My Note]] here")
        let w = wiki(spans)
        #expect(w != nil)
        if case .wikilink(let target) = w!.kind { #expect(target == "My Note") }
        let ns = "see [[My Note]] here" as NSString
        #expect(ns.substring(with: w!.contentRange) == "My Note")
    }

    @Test("[[Note|Alias]] shows only the alias; target is the note")
    func alias() {
        let src = "[[My Note|click me]]"
        let w = wiki(SyntaxHighlighter.parse(src))!
        if case .wikilink(let target) = w.kind { #expect(target == "My Note") }
        #expect((src as NSString).substring(with: w.contentRange) == "click me")
    }

    @Test("[[Note#Heading]] keeps the heading in the target")
    func heading() {
        let w = wiki(SyntaxHighlighter.parse("[[Note#Section]]"))!
        if case .wikilink(let target) = w.kind { #expect(target == "Note#Section") }
    }

    @Test("Rendered wikilink hides the brackets and accents the display text")
    func rendered() {
        let editor = makeEditor()
        let st = editor.styleBlock("go to [[Target|label]] now", cursorPosition: nil)
        let s = st.string as NSString
        // Brackets + "Target|" are hidden.
        #expect(isHidden(at: s.range(of: "[[").location, in: st))
        #expect(isHidden(at: s.range(of: "Target").location, in: st))
        #expect(isHidden(at: s.range(of: "]]").location, in: st))
        // The display "label" is accented and carries the wiki target.
        let labelLoc = s.range(of: "label").location
        #expect(!isHidden(at: labelLoc, in: st))
        let color = st.attribute(.foregroundColor, at: labelLoc, effectiveRange: nil) as? NSColor
        #expect(color == editor.accentColor)
        let target = st.attribute(.editorWikiTarget, at: labelLoc, effectiveRange: nil) as? String
        #expect(target == "Target")
    }

    @Test("Active wikilink reveals the raw brackets (dimmed, not hidden)")
    func active() {
        let editor = makeEditor()
        let st = editor.styleBlock("[[Note]]", cursorPosition: 3)
        #expect(!isHidden(at: 0, in: st))   // "[[" shown (dimmed) while editing
        #expect(st.string == "[[Note]]")
    }

    @Test("Wikilink content is opaque: inner markdown is not parsed")
    func opaque() {
        let spans = SyntaxHighlighter.parse("[[a **b** c]]")
        #expect(!spans.contains { if case .bold = $0.kind { return true }; return false })
    }

    @Test("resolveWikiFile finds a sibling .md relative to the opened file")
    func resolvesSibling() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wikivault-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let home = dir.appendingPathComponent("Home.md")
        let target = dir.appendingPathComponent("Target Note.md")
        try "home".write(to: home, atomically: true, encoding: .utf8)
        try "target".write(to: target, atomically: true, encoding: .utf8)

        let editor = makeEditor()
        let doc = NSDocument()
        doc.fileURL = home
        editor.document = doc

        // Obsidian wikilinks omit the .md extension; regular links include it.
        #expect(editor.resolveLinkedFile("Target Note")?.standardizedFileURL == target.standardizedFileURL)
        #expect(editor.resolveLinkedFile("Target Note.md")?.standardizedFileURL == target.standardizedFileURL)
        #expect(editor.resolveLinkedFile("Missing Note") == nil)
    }

    @Test("splitHeading separates path and the deepest heading component")
    func splitsHeading() {
        #expect(EditorTextView.splitHeading("Note#Section").path == "Note")
        #expect(EditorTextView.splitHeading("Note#Section").heading == "Section")
        #expect(EditorTextView.splitHeading("Note#H1#H2").heading == "H2")   // deepest
        #expect(EditorTextView.splitHeading("#OnlyHeading").path == "")
        #expect(EditorTextView.splitHeading("#OnlyHeading").heading == "OnlyHeading")
        #expect(EditorTextView.splitHeading("JustAPath").heading == nil)
    }

    @Test("Regular [](#heading) link scrolls to the heading in this document")
    func regularAnchorScrolls() {
        let editor = makeEditor()
        editor.loadContent("# Top\n\n[jump](#Details)\n\n## Details\n\nbody")
        editor.followLinkDestination("#Details")
        let detailsLoc = (editor.rawSource as NSString).range(of: "## Details").location
        #expect(editor.selectedRange().location == detailsLoc)
    }

    @Test("Regular link anchor percent-decodes the path")
    func percentDecodedHeading() {
        let editor = makeEditor()
        editor.loadContent("# Top\n\n## My Section\n\nbody")
        editor.followLinkDestination("#My%20Section")
        let loc = (editor.rawSource as NSString).range(of: "## My Section").location
        #expect(editor.selectedRange().location == loc)
    }

    @Test("scrollToHeading finds the matching heading block")
    func headingNavigation() {
        let editor = makeEditor()
        editor.loadContent("# Intro\n\nbody\n\n## Details\n\nmore")
        editor.scrollToHeading("Details")
        // The caret moved to the start of the "## Details" block.
        let detailsLoc = (editor.rawSource as NSString).range(of: "## Details").location
        #expect(editor.selectedRange().location == detailsLoc)
    }
}
