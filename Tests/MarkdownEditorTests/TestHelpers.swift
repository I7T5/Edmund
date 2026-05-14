import Testing
import AppKit
@testable import MarkdownEditorCore

// MARK: - Editor Construction

/// Creates an EditorTextView with a proper text system chain,
/// mirroring the setup in main.swift.
@MainActor
func makeEditor() -> EditorTextView {
    let textStorage = NSTextStorage()
    let layoutManager = NSLayoutManager()
    textStorage.addLayoutManager(layoutManager)
    let textContainer = NSTextContainer(
        size: NSSize(width: 500, height: CGFloat.greatestFiniteMagnitude)
    )
    textContainer.widthTracksTextView = true
    layoutManager.addTextContainer(textContainer)
    return EditorTextView(
        frame: NSRect(x: 0, y: 0, width: 500, height: 300),
        textContainer: textContainer
    )
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
