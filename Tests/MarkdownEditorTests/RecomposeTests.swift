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

    @Test("Equal-count multi-block replacement restyles the middle block")
    @MainActor func equalCountMiddleBlockRestyled() {
        // A selection spanning three blocks replaced by three different blocks
        // keeps the count unchanged — the case the old count-change heuristic
        // missed entirely: only the active block got restyled, leaving the
        // middle replacement block with stale attributes.
        let editor = makeEditor()
        editor.loadContent("aaaa\nbbbb\ncccc")
        // Select from inside "aaaa" to inside "cccc" and replace with text
        // whose middle line is a heading.
        let sel = NSRange(location: 2, length: 10)   // "aa\nbbbb\ncc"
        editor.setSelectedRange(sel)
        editor.insertText("XX\n# Head\nYY", replacementRange: sel)

        #expect(editor.blocks.count == 3)
        let headLoc = (editor.rawSource as NSString).range(of: "Head").location
        let headFont = font(at: headLoc, in: editor)
        #expect((headFont?.pointSize ?? 0) > editor.bodyFont.pointSize,
                "middle block must be restyled as a heading")
        assertMatchesFullRecomposeOracle(editor)
    }

    @Test("Enter inside a callout restyles both halves")
    @MainActor func enterSplitInsideCallout() {
        let editor = makeEditor()
        editor.loadContent("> [!note]\n> hi there\n\ntail")
        // Cursor inside "hi there", split the quote run.
        let cut = (editor.rawSource as NSString).range(of: " there").location
        editor.setSelectedRange(NSRange(location: cut, length: 0))
        editor.recompose(cursorInRaw: cut)
        pressEnter(in: editor)

        // "> [!note]\n> hi" stays a callout; " there" is now a plain paragraph
        // outside it and must carry no callout background.
        let ts = editor.textStorage!
        let thereLoc = (ts.string as NSString).range(of: "there").location
        #expect(calloutBackground(ts, at: thereLoc) == nil)
        assertMatchesFullRecomposeOracle(editor)
    }

    @Test("Heading toggle next to a callout leaves the callout intact")
    @MainActor func headingToggleNextToCallout() {
        let editor = makeEditor()
        editor.loadContent("title\n> [!note]\n> body")
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        editor.recompose(cursorInRaw: 0)
        editor.insertText("# ", replacementRange: NSRange(location: 0, length: 0))

        let ts = editor.textStorage!
        let bodyLoc = (ts.string as NSString).range(of: "body").location
        #expect(calloutBackground(ts, at: bodyLoc) != nil)
        assertMatchesFullRecomposeOracle(editor)
    }

    @Test("Theme change restyles in place without replacing the storage")
    @MainActor func themeChangeAttributeOnly() {
        let editor = makeEditor()
        editor.loadContent("# Head\n\nbody text")
        var theme = editor.theme
        theme.fontSize += 4
        editor.applyTheme(theme)
        #expect(editor.textStorage!.string == editor.rawSource)
        assertMatchesFullRecomposeOracle(editor)
    }
}
