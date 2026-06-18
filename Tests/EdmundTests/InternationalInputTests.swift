import Testing
import AppKit
import CoreText
@testable import EdmundCore

/// International text and IME input. The body font (a Latin serif) lacks glyphs
/// for most non-Latin scripts, so display relies on font substitution (see
/// EditorTextStorage). Composition relies on `typingAttributes` never carrying
/// the hidden-delimiter font — otherwise IME marked text (Pinyin, Kana, Hangul,
/// etc.) would compose invisibly with zero width.
@Suite("International text & IME input")
struct InternationalInputTests {

    struct Script: Sendable, CustomStringConvertible {
        let name: String
        let sample: String
        var description: String { name }
    }

    static let scripts: [Script] = [
        Script(name: "Chinese (Simplified)", sample: "你好世界"),
        Script(name: "Japanese", sample: "こんにちは日本語"),
        Script(name: "Korean", sample: "안녕하세요"),
        Script(name: "Arabic", sample: "مرحبا"),
        Script(name: "Hindi (Devanagari)", sample: "नमस्ते"),
        Script(name: "Russian (Cyrillic)", sample: "Привет"),
        Script(name: "Greek", sample: "Ελληνικά"),
        Script(name: "Thai", sample: "สวัสดี"),
        Script(name: "Emoji (ZWJ)", sample: "😀👨‍👩‍👧‍👦"),
    ]

    private func fontCovers(_ s: String, _ font: NSFont) -> Bool {
        let chars = Array(s.utf16)
        var glyphs = [CGGlyph](repeating: 0, count: chars.count)
        return CTFontGetGlyphsForCharacters(font as CTFont, chars, &glyphs, chars.count)
    }

    /// Every composed-character sequence in `range` is drawn with a font that can
    /// actually render it (whether the body font or a substituted fallback).
    @MainActor
    private func allGraphemesCovered(_ range: NSRange, in attr: NSAttributedString) -> Bool {
        let ns = attr.string as NSString
        var i = range.location
        while i < range.upperBound {
            let g = ns.rangeOfComposedCharacterSequence(at: i)
            let gr = NSRange(location: g.location,
                             length: min(g.length, range.upperBound - g.location))
            let s = ns.substring(with: gr)
            guard let f = attr.attributes(at: gr.location, effectiveRange: nil)[.font] as? NSFont,
                  fontCovers(s, f) else { return false }
            i = gr.upperBound
        }
        return true
    }

    @Test("Text in any script is displayed with a covering font", arguments: scripts)
    @MainActor func displaySubstituted(_ script: Script) {
        let editor = makeEditor()
        editor.loadContent(script.sample + " ascii")
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        editor.recompose(cursorInRaw: 0)
        let ts = editor.textStorage!
        let r = (ts.string as NSString).range(of: script.sample)
        #expect(r.location != NSNotFound)
        #expect(allGraphemesCovered(r, in: ts))
    }

    @Test("IME marked text stays visible for any script", arguments: scripts)
    @MainActor func imeMarkedTextVisible(_ script: Script) {
        let editor = makeEditor()
        editor.loadContent("")
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        // Reproduce the bug's trigger: the caret inherited the hidden delimiter
        // font (near-zero size + clear color).
        editor.typingAttributes = [.font: editor.hiddenFont,
                                   .foregroundColor: NSColor.clear]

        // An IME marks the provisional composition string.
        editor.setMarkedText(script.sample,
                             selectedRange: NSRange(location: (script.sample as NSString).length, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
        let ts = editor.textStorage!
        let markRange = NSRange(location: 0, length: (script.sample as NSString).length)

        // Visible: a real (>1pt) font, not clear, and able to render the script.
        let markFont = ts.attributes(at: 0, effectiveRange: nil)[.font] as? NSFont
        #expect((markFont?.pointSize ?? 0) >= 1.0)
        let markColor = ts.attributes(at: 0, effectiveRange: nil)[.foregroundColor] as? NSColor
        #expect(markColor != NSColor.clear)
        #expect(allGraphemesCovered(markRange, in: ts))

        // Commit: the text is present and rendered with covering fonts.
        editor.insertText(script.sample, replacementRange: editor.markedRange())
        #expect(editor.rawSource == script.sample)
        let committed = (editor.textStorage!.string as NSString).range(of: script.sample)
        #expect(allGraphemesCovered(committed, in: editor.textStorage!))
    }
}
