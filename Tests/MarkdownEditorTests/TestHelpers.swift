import Testing
import AppKit
@testable import MarkdownEditorCore

// MARK: - Editor Construction

/// Creates an EditorTextView with a proper text system chain,
/// mirroring the setup in main.swift.
@MainActor
func makeEditor() -> EditorTextView {
    let textStorage = EditorTextStorage()
    let layoutManager = NSLayoutManager()
    textStorage.addLayoutManager(layoutManager)
    let textContainer = NSTextContainer(
        size: NSSize(width: 500, height: CGFloat.greatestFiniteMagnitude)
    )
    textContainer.widthTracksTextView = true
    layoutManager.addTextContainer(textContainer)
    let editor = EditorTextView(
        frame: NSRect(x: 0, y: 0, width: 500, height: 300),
        textContainer: textContainer
    )
    // Isolate theme persistence. EditorTextView loads/saves its theme via
    // UserDefaults; without isolation, tests that call `applyTheme` write font
    // sizes into the shared `.standard` domain, and under parallel execution
    // those leak into other editors (this caused the math fit-width flake).
    // Give each editor its own empty domain.
    let suite = "MarkdownEditorTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    editor.themeDefaults = defaults
    editor.theme = .load(from: defaults)
    return editor
}

// MARK: - Input Simulation

/// Simulate typing a string character-by-character through the full
/// NSTextView pipeline (shouldChangeText → insert → didChangeText).
@MainActor
func type(_ text: String, into editor: EditorTextView) {
    for ch in text {
        editor.insertText(String(ch), replacementRange: NSRange(location: NSNotFound, length: 0))
    }
}

/// Simulate typing a string as a single paste operation.
@MainActor
func paste(_ text: String, into editor: EditorTextView) {
    editor.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
}

/// Simulate pressing Enter (inserts a newline).
@MainActor
func pressEnter(in editor: EditorTextView) {
    editor.insertText("\n", replacementRange: NSRange(location: NSNotFound, length: 0))
}

/// Simulate pressing Backspace (delete backward).
@MainActor
func pressBackspace(in editor: EditorTextView) {
    let sel = editor.selectedRange()
    if sel.length > 0 {
        editor.insertText("", replacementRange: sel)
    } else if sel.location > 0 {
        let deleteRange = NSRange(location: sel.location - 1, length: 1)
        editor.insertText("", replacementRange: deleteRange)
    }
}

// MARK: - Display Inspection

/// Returns the text storage string for a specific block's display range.
@MainActor
func displayText(for blockIndex: Int, in editor: EditorTextView) -> String {
    guard blockIndex < editor.displayRanges.count else { return "" }
    let range = editor.displayRanges[blockIndex]
    let ts = editor.textStorage!
    guard range.upperBound <= ts.length else { return "" }
    return (ts.string as NSString).substring(with: range)
}

/// Returns all attributes at a given offset in the text storage.
@MainActor
func attrs(at offset: Int, in editor: EditorTextView) -> [NSAttributedString.Key: Any] {
    let ts = editor.textStorage!
    guard offset < ts.length else { return [:] }
    return ts.attributes(at: offset, effectiveRange: nil)
}

/// Returns the font at a given offset in the text storage.
@MainActor
func font(at offset: Int, in editor: EditorTextView) -> NSFont? {
    attrs(at: offset, in: editor)[.font] as? NSFont
}

/// Returns the foreground color at a given offset in the text storage.
@MainActor
func fgColor(at offset: Int, in editor: EditorTextView) -> NSColor? {
    attrs(at: offset, in: editor)[.foregroundColor] as? NSColor
}

/// Switches the active block by placing the cursor at the start of a block
/// and recomposing.
@MainActor
func activateBlock(_ index: Int, in editor: EditorTextView) {
    guard index < editor.blocks.count else { return }
    let rawOffset = editor.blocks[index].range.location
    editor.recompose(cursorInRaw: rawOffset)
}

/// Returns true if the character at `offset` has hidden delimiter attributes
/// (near-zero font size and clear color).
@MainActor
func isHidden(at offset: Int, in result: NSAttributedString) -> Bool {
    guard offset < result.length else { return false }
    let a = result.attributes(at: offset, effectiveRange: nil)
    guard let f = a[.font] as? NSFont else { return false }
    guard let c = a[.foregroundColor] as? NSColor else { return false }
    return f.pointSize < 1.0 && c == NSColor.clear
}

/// Returns true if the character at `offset` is invisible but preserves its width
/// (foreground color is clear, font size is NOT shrunk). Used for blockquote `> ` delimiters.
@MainActor
func isInvisible(at offset: Int, in result: NSAttributedString) -> Bool {
    guard offset < result.length else { return false }
    let a = result.attributes(at: offset, effectiveRange: nil)
    guard let c = a[.foregroundColor] as? NSColor else { return false }
    guard c == NSColor.clear else { return false }
    // Font should NOT be tiny (width is preserved)
    if let f = a[.font] as? NSFont { return f.pointSize >= 1.0 }
    return true
}

/// Returns true if the character at `offset` is dimmed (tertiary label color).
@MainActor
func isDimmed(at offset: Int, in result: NSAttributedString) -> Bool {
    guard offset < result.length else { return false }
    let a = result.attributes(at: offset, effectiveRange: nil)
    guard let c = a[.foregroundColor] as? NSColor else { return false }
    return c == NSColor.tertiaryLabelColor
}
