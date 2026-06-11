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

// MARK: - Full-Recompose Oracle
//
// The oracle is the reference for what the text storage's attributes should be
// after ANY sequence of edits/cursor moves: the document composed from scratch
// exactly the way full `recompose` does it. Incremental paths (dirty-set
// styling, lazy rendering) must always leave the storage attribute-equivalent
// to this composition. Comparison is structural: paragraph styles and
// attachments are compared component-wise because fresh compositions create
// fresh NSTextBlock / NSTextAttachment instances that never compare equal by
// pointer-based isEqual.

/// Composes the editor's document from scratch the way full `recompose` does:
/// base attributes everywhere, then per-block styling (cursor-aware for the
/// active block).
@MainActor
func expectedFullComposition(for editor: EditorTextView) -> NSAttributedString {
    let composed = NSMutableAttributedString(string: editor.rawSource,
                                             attributes: editor.baseAttributes)
    let cursorInRaw = editor.selectedRange().location
    for (i, block) in editor.blocks.enumerated() {
        guard block.range.upperBound <= composed.length else { continue }
        let cursorInBlock: Int? = (i == editor.activeBlockIndex)
            ? max(0, cursorInRaw - block.range.location) : nil
        let styled = editor.styleBlock(block.content, cursorPosition: cursorInBlock)
        styled.enumerateAttributes(
            in: NSRange(location: 0, length: styled.length), options: []
        ) { attrs, range, _ in
            let tsRange = NSRange(location: range.location + block.range.location,
                                  length: range.length)
            guard tsRange.upperBound <= composed.length else { return }
            composed.setAttributes(attrs, range: tsRange)
        }
    }
    return composed
}

/// Asserts the live text storage is attribute-equivalent to a from-scratch
/// full recompose. On mismatch, reports the first differing character with a
/// description of both attribute sets.
@MainActor
func assertMatchesFullRecomposeOracle(
    _ editor: EditorTextView,
    _ comment: Comment? = nil,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    guard let ts = editor.textStorage else {
        Issue.record("editor has no text storage", sourceLocation: sourceLocation)
        return
    }
    let expected = expectedFullComposition(for: editor)
    #expect(ts.string == expected.string,
            "storage string diverged from rawSource", sourceLocation: sourceLocation)

    let len = min(ts.length, expected.length)
    var i = 0
    while i < len {
        var rA = NSRange(); var rB = NSRange()
        let whole = NSRange(location: i, length: len - i)
        let a = expected.attributes(at: i, longestEffectiveRange: &rA, in: whole)
        let b = ts.attributes(at: i, longestEffectiveRange: &rB, in: whole)
        if let diff = attributeDifference(expected: a, actual: b) {
            let ctx = (ts.string as NSString).substring(
                with: NSRange(location: max(0, i - 10),
                              length: min(30, len - max(0, i - 10))))
            Issue.record(
                """
                Oracle mismatch at offset \(i) (near \(String(reflecting: ctx))): \(diff)\
                \(comment.map { " — \($0)" } ?? "")
                """,
                sourceLocation: sourceLocation)
            return
        }
        i = max(min(rA.upperBound, rB.upperBound), i + 1)
    }
}

/// Returns a human-readable description of the first differing attribute, or
/// nil when the two attribute dictionaries are equivalent.
func attributeDifference(
    expected: [NSAttributedString.Key: Any],
    actual: [NSAttributedString.Key: Any]
) -> String? {
    let keys = Set(expected.keys).union(actual.keys)
    for key in keys {
        let a = expected[key]
        let b = actual[key]
        switch (a, b) {
        case (nil, nil):
            continue
        case (nil, .some(let v)):
            return "\(key.rawValue): unexpected \(String(describing: v))"
        case (.some(let v), nil):
            return "\(key.rawValue): missing (expected \(String(describing: v)))"
        case (.some(let va), .some(let vb)):
            if let fa = va as? NSFont, let fb = vb as? NSFont {
                if fa.fontName != fb.fontName || abs(fa.pointSize - fb.pointSize) > 0.01 {
                    return "font: expected \(fa.fontName)@\(fa.pointSize), got \(fb.fontName)@\(fb.pointSize)"
                }
            } else if let pa = va as? NSParagraphStyle, let pb = vb as? NSParagraphStyle {
                if let diff = paragraphStyleDifference(pa, pb) {
                    return "paragraphStyle: \(diff)"
                }
            } else if let aa = va as? NSTextAttachment, let ab = vb as? NSTextAttachment {
                if String(describing: type(of: aa)) != String(describing: type(of: ab)) {
                    return "attachment class: \(type(of: aa)) vs \(type(of: ab))"
                }
                let ba = aa.bounds, bb = ab.bounds
                if abs(ba.width - bb.width) > 0.5 || abs(ba.height - bb.height) > 0.5
                    || abs(ba.origin.y - bb.origin.y) > 0.5 {
                    return "attachment bounds: \(ba) vs \(bb)"
                }
            } else if let oa = va as? NSObject, let ob = vb as? NSObject {
                if !oa.isEqual(ob) {
                    return "\(key.rawValue): \(oa) vs \(ob)"
                }
            }
        }
    }
    return nil
}

/// Component-wise paragraph style comparison. NSParagraphStyle.isEqual is
/// unusable here: embedded NSTextBlocks compare by identity, and every
/// composition creates fresh instances.
func paragraphStyleDifference(_ a: NSParagraphStyle, _ b: NSParagraphStyle) -> String? {
    func ne(_ x: CGFloat, _ y: CGFloat) -> Bool { abs(x - y) > 0.01 }
    if a.alignment != b.alignment { return "alignment \(a.alignment.rawValue) vs \(b.alignment.rawValue)" }
    if ne(a.lineSpacing, b.lineSpacing) { return "lineSpacing \(a.lineSpacing) vs \(b.lineSpacing)" }
    if ne(a.paragraphSpacing, b.paragraphSpacing) { return "paragraphSpacing \(a.paragraphSpacing) vs \(b.paragraphSpacing)" }
    if ne(a.paragraphSpacingBefore, b.paragraphSpacingBefore) { return "paragraphSpacingBefore \(a.paragraphSpacingBefore) vs \(b.paragraphSpacingBefore)" }
    if ne(a.headIndent, b.headIndent) { return "headIndent \(a.headIndent) vs \(b.headIndent)" }
    if ne(a.firstLineHeadIndent, b.firstLineHeadIndent) { return "firstLineHeadIndent \(a.firstLineHeadIndent) vs \(b.firstLineHeadIndent)" }
    if ne(a.tailIndent, b.tailIndent) { return "tailIndent \(a.tailIndent) vs \(b.tailIndent)" }
    if ne(a.minimumLineHeight, b.minimumLineHeight) { return "minimumLineHeight \(a.minimumLineHeight) vs \(b.minimumLineHeight)" }
    if ne(a.maximumLineHeight, b.maximumLineHeight) { return "maximumLineHeight \(a.maximumLineHeight) vs \(b.maximumLineHeight)" }
    if a.tabStops.count != b.tabStops.count { return "tabStops count \(a.tabStops.count) vs \(b.tabStops.count)" }
    for (ta, tb) in zip(a.tabStops, b.tabStops) where ne(ta.location, tb.location) {
        return "tabStop \(ta.location) vs \(tb.location)"
    }
    if a.textBlocks.count != b.textBlocks.count {
        return "textBlocks count \(a.textBlocks.count) vs \(b.textBlocks.count)"
    }
    for (ba, bb) in zip(a.textBlocks, b.textBlocks) {
        if let diff = textBlockDifference(ba, bb) { return diff }
    }
    return nil
}

func textBlockDifference(_ a: NSTextBlock, _ b: NSTextBlock) -> String? {
    if String(describing: type(of: a)) != String(describing: type(of: b)) {
        return "textBlock class \(type(of: a)) vs \(type(of: b))"
    }
    switch (a.backgroundColor, b.backgroundColor) {
    case (nil, nil): break
    case (let ca?, let cb?) where ca.isEqual(cb): break
    default: return "textBlock backgroundColor \(String(describing: a.backgroundColor)) vs \(String(describing: b.backgroundColor))"
    }
    let edges: [NSRectEdge] = [.minX, .minY, .maxX, .maxY]
    for layer in [NSTextBlock.Layer.padding, .border, .margin] {
        for edge in edges {
            let wa = a.width(for: layer, edge: edge)
            let wb = b.width(for: layer, edge: edge)
            if abs(wa - wb) > 0.01 {
                return "textBlock \(layer.rawValue)/\(edge.rawValue) width \(wa) vs \(wb)"
            }
        }
    }
    return nil
}

// MARK: - Large Document Generator

/// Deterministic RNG (splitmix64) so generated documents are reproducible
/// across runs and platforms.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Generates representative markdown of roughly the requested size: paragraphs
/// with inline styles, headings, lists (nested, checkboxes), quote runs,
/// callouts, tables, fenced code, display math, thematic breaks, blank lines.
func makeLargeMarkdown(approximateBytes: Int, seed: UInt64 = 0xC0FFEE) -> String {
    var rng = SeededGenerator(seed: seed)
    let words = ["alpha", "beta", "gamma", "delta", "lorem", "ipsum", "dolor",
                 "editor", "markdown", "render", "block", "cursor", "style",
                 "viewport", "layout", "anchor", "fragment", "glyph", "parse"]
    func sentence(_ n: Int) -> String {
        var parts: [String] = []
        for _ in 0..<n {
            var w = words.randomElement(using: &rng)!
            switch Int.random(in: 0..<20, using: &rng) {
            case 0: w = "**\(w)**"
            case 1: w = "*\(w)*"
            case 2: w = "`\(w)`"
            case 3: w = "[\(w)](https://example.com/\(w))"
            default: break
            }
            parts.append(w)
        }
        return parts.joined(separator: " ") + "."
    }

    var chunks: [String] = []
    var size = 0
    let calloutTypes = ["note", "tip", "warning", "important", "abstract", "bug"]
    while size < approximateBytes {
        let chunk: String
        switch Int.random(in: 0..<14, using: &rng) {
        case 0:
            chunk = "\(String(repeating: "#", count: Int.random(in: 1...4, using: &rng))) \(sentence(4))"
        case 1:
            let rows = (0..<Int.random(in: 2...4, using: &rng)).map { _ in
                "| \(words.randomElement(using: &rng)!) | \(words.randomElement(using: &rng)!) |"
            }
            chunk = ([rows[0], "| --- | --- |"] + rows.dropFirst()).joined(separator: "\n")
        case 2:
            let lines = (0..<Int.random(in: 2...5, using: &rng)).map { _ in
                "    let \(words.randomElement(using: &rng)!) = \(Int.random(in: 0..<100, using: &rng))"
            }
            chunk = (["```swift"] + lines + ["```"]).joined(separator: "\n")
        case 3:
            chunk = "$$\nx_{\(Int.random(in: 0..<9, using: &rng))} = \\frac{a}{b}\n$$"
        case 4:
            let body = (0..<Int.random(in: 1...3, using: &rng)).map { _ in "> \(sentence(6))" }
            chunk = (["> [!\(calloutTypes.randomElement(using: &rng)!)]"] + body).joined(separator: "\n")
        case 5:
            chunk = (0..<Int.random(in: 1...3, using: &rng))
                .map { _ in "> \(sentence(8))" }.joined(separator: "\n")
        case 6:
            chunk = (0..<Int.random(in: 2...5, using: &rng)).map { i -> String in
                let indent = String(repeating: "  ", count: Int.random(in: 0...2, using: &rng))
                let marker = Bool.random(using: &rng)
                    ? "- " : (Bool.random(using: &rng) ? "- [ ] " : "\(i + 1). ")
                return "\(indent)\(marker)\(sentence(5))"
            }.joined(separator: "\n")
        case 7:
            chunk = "---"
        default:
            chunk = sentence(Int.random(in: 10...40, using: &rng))
        }
        chunks.append(chunk)
        size += chunk.utf8.count + 2
    }
    return chunks.joined(separator: "\n\n")
}
