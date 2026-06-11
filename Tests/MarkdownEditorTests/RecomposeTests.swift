import Testing
import AppKit
@testable import MarkdownEditorCore

/// Edits that change block structure must re-style the whole document, not just
/// the active block — otherwise a neighbor whose meaning changed keeps stale
/// styling (the "recompose only renders part of the file" glitch).
@Suite("Recompose — structural edits")
struct RecomposeTests {

    @MainActor private func calloutBackground(_ ts: NSTextStorage, at i: Int) -> NSColor? {
        let ps = ts.attributes(at: i, effectiveRange: nil)[.paragraphStyle] as? NSParagraphStyle
        return ps?.textBlocks.first?.backgroundColor
    }

    @Test("Removing a callout marker clears the stale background on its former body")
    @MainActor func unmergeCalloutClearsBody() {
        let editor = makeEditor()
        editor.loadContent("> [!note]\n> body line")
        // Sanity: the body line starts out with the callout background.
        let ts = editor.textStorage!
        #expect(calloutBackground(ts, at: (editor.rawSource as NSString).range(of: "body").location) != nil)

        // Delete "[!note]" — the block un-merges (1 → 2 blocks) and "> body line"
        // is no longer part of a callout.
        let mk = (editor.rawSource as NSString).range(of: "[!note]")
        editor.setSelectedRange(NSRange(location: mk.location, length: 0))
        editor.insertText("", replacementRange: mk)

        let bodyLoc = (editor.textStorage!.string as NSString).range(of: "body").location
        #expect(calloutBackground(editor.textStorage!, at: bodyLoc) == nil)
    }

    @Test("Adding a callout marker styles the lines it absorbs")
    @MainActor func mergeCalloutStylesAbsorbed() {
        let editor = makeEditor()
        // Two plain quote lines (separate blocks, no callout background).
        editor.loadContent(">\n> absorbed")
        // Type the marker into the first line, making it a callout opener that
        // merges the second line in.
        let firstLineEnd = 1  // after ">"
        editor.setSelectedRange(NSRange(location: firstLineEnd, length: 0))
        editor.insertText(" [!note]", replacementRange: NSRange(location: firstLineEnd, length: 0))

        let ts = editor.textStorage!
        let absorbed = (ts.string as NSString).range(of: "absorbed").location
        #expect(calloutBackground(ts, at: absorbed) != nil)
    }
}
