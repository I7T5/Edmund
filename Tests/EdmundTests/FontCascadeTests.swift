import Testing
import AppKit
@testable import EdmundCore

/// Isolated UserDefaults for persistence round-trips (the repo's pattern).
private func isolatedDefaults() -> UserDefaults {
    let suite = "EdmundTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    return defaults
}

/// Pure classification tests for the per-script font cascade: which grapheme
/// cluster maps to which user-assignable script (or keeps the body font).
@Suite("Font cascade — script classification")
struct FontCascadeClassificationTests {

    @Test("Han ideographs classify as han")
    func han() {
        #expect(FontCascadeScript.classify("漢") == .han)
        #expect(FontCascadeScript.classify("字") == .han)
        #expect(FontCascadeScript.classify("々") == .han)      // U+3005 iteration mark
        #expect(FontCascadeScript.classify("㐀") == .han)      // U+3400 ext-A start
        #expect(FontCascadeScript.classify("𠀀") == .han)     // U+20000 supplementary plane
        #expect(FontCascadeScript.classify("豈") == .han)      // U+F900 compatibility ideograph
    }

    @Test("Kana classifies as kana")
    func kana() {
        #expect(FontCascadeScript.classify("あ") == .kana)     // hiragana
        #expect(FontCascadeScript.classify("ア") == .kana)     // katakana
        #expect(FontCascadeScript.classify("ｱ") == .kana)     // halfwidth katakana
        #expect(FontCascadeScript.classify("ㇰ") == .kana)     // katakana phonetic ext
    }

    @Test("Hangul classifies as hangul")
    func hangul() {
        #expect(FontCascadeScript.classify("한") == .hangul)   // syllable
        #expect(FontCascadeScript.classify("ᄒ") == .hangul)   // jamo
        #expect(FontCascadeScript.classify("ㄱ") == .hangul)   // compatibility jamo
    }

    @Test("Cyrillic classifies as cyrillic")
    func cyrillic() {
        #expect(FontCascadeScript.classify("Ж") == .cyrillic)
        #expect(FontCascadeScript.classify("я") == .cyrillic)
    }

    @Test("Greek classifies as greek")
    func greek() {
        #expect(FontCascadeScript.classify("Ω") == .greek)
        #expect(FontCascadeScript.classify("ἀ") == .greek)     // extended Greek
    }

    @Test("Arabic classifies as arabic")
    func arabic() {
        #expect(FontCascadeScript.classify("ع") == .arabic)
        #expect(FontCascadeScript.classify("ﷺ") == .arabic)    // presentation form
    }

    @Test("Hebrew classifies as hebrew")
    func hebrew() {
        #expect(FontCascadeScript.classify("ש") == .hebrew)
    }

    @Test("Thai classifies as thai")
    func thai() {
        #expect(FontCascadeScript.classify("ก") == .thai)
    }

    @Test("Emoji classify as emoji, including multi-scalar clusters")
    func emoji() {
        #expect(FontCascadeScript.classify("😀") == .emoji)
        #expect(FontCascadeScript.classify("👨‍👩‍👧‍👦") == .emoji)  // ZWJ sequence
        #expect(FontCascadeScript.classify("👍🏽") == .emoji)     // skin-tone modifier
        #expect(FontCascadeScript.classify("🇨🇳") == .emoji)    // regional indicators
        #expect(FontCascadeScript.classify("☀️") == .emoji)     // dingbat + VS16
    }

    @Test("Shared CJK punctuation keeps the body font")
    func cjkPunctuationIsNeutral() {
        // 、。「」 live in U+3000–303F, shared between Chinese and Japanese —
        // dragging them into a script font would restyle a mixed sentence's
        // punctuation against the body face.
        #expect(FontCascadeScript.classify("、") == nil)
        #expect(FontCascadeScript.classify("。") == nil)
        #expect(FontCascadeScript.classify("「") == nil)
        #expect(FontCascadeScript.classify("」") == nil)
    }

    @Test("Latin, digits, and ASCII emoji-likes keep the body font")
    func neutral() {
        #expect(FontCascadeScript.classify("a") == nil)
        #expect(FontCascadeScript.classify("Z") == nil)
        #expect(FontCascadeScript.classify("7") == nil)
        // ASCII #, *, 0-9 have Unicode isEmoji == true; they must NOT classify.
        #expect(FontCascadeScript.classify("#") == nil)
        #expect(FontCascadeScript.classify("*") == nil)
        #expect(FontCascadeScript.classify("0") == nil)
        #expect(FontCascadeScript.classify("é") == nil)        // accented Latin
        #expect(FontCascadeScript.classify("ß") == nil)
        #expect(FontCascadeScript.classify("—") == nil)        // em dash
        #expect(FontCascadeScript.classify(" ") == nil)
    }
}

/// Cascade persistence on EditorTheme: UserDefaults round-trip, unknown-key
/// tolerance, and the empty-default contract (empty map = legacy behavior).
@Suite("Font cascade — persistence")
struct FontCascadePersistenceTests {

    @Test("Default theme has an empty cascade")
    func defaultIsEmpty() {
        #expect(EditorTheme.default.fontCascade.isEmpty)
        #expect(EditorTheme.quickLook.fontCascade.isEmpty)
    }

    @Test("Absent key loads as an empty cascade")
    func absentKey() {
        let theme = EditorTheme.load(from: isolatedDefaults())
        #expect(theme.fontCascade.isEmpty)
    }

    @Test("Cascade survives a save/load round-trip")
    func roundTrip() {
        let defaults = isolatedDefaults()
        var theme = EditorTheme.default
        theme.fontCascade = [.han: "Songti SC", .emoji: "Apple Color Emoji"]
        theme.save(to: defaults)
        let loaded = EditorTheme.load(from: defaults)
        #expect(loaded.fontCascade == [.han: "Songti SC", .emoji: "Apple Color Emoji"])
        #expect(loaded == theme)
    }

    @Test("Unknown script keys are dropped on load")
    func unknownKeysDropped() {
        let defaults = isolatedDefaults()
        defaults.set(["han": "Songti SC", "klingon": "Klingon pIqaD"],
                     forKey: "EditorFontCascade")
        let loaded = EditorTheme.load(from: defaults)
        #expect(loaded.fontCascade == [.han: "Songti SC"])
    }

    @Test("Empty family names are dropped on load")
    func emptyFamilyDropped() {
        let defaults = isolatedDefaults()
        defaults.set(["han": ""], forKey: "EditorFontCascade")
        let loaded = EditorTheme.load(from: defaults)
        #expect(loaded.fontCascade.isEmpty)
    }
}

/// Editor behavior: the cascade reaches the text storage and steers font
/// substitution toward the user's chosen families. Modeled on
/// EmojiRenderingTests.renderedFont. Test families are picked from the
/// installed list at runtime (CI images vary); a test skips when its family
/// is absent.
@Suite("Font cascade — editor substitution")
@MainActor
struct FontCascadeEditorTests {

    /// A distinct installed family that covers Han, preferably one visually
    /// unlike the default body serif so the assertion means something.
    private func installedHanFamily() -> String? {
        twoHanFamilies()?.0
    }

    /// Two different installed Han-capable families (for body-vs-cascade
    /// disambiguation tests), or nil when the image has fewer than two.
    private func twoHanFamilies() -> (String, String)? {
        let families = NSFontManager.shared.availableFontFamilies
        let installed = ["Songti SC", "Hiragino Sans", "PingFang SC", "STSong", "STHeiti"]
            .filter { families.contains($0) }
        return installed.count >= 2 ? (installed[0], installed[1]) : nil
    }

    private func renderedFont(for needle: String, in editor: EditorTextView) -> NSFont? {
        let ts = editor.textStorage!
        let r = (ts.string as NSString).range(of: needle)
        guard r.location != NSNotFound else { return nil }
        return ts.attributes(at: r.location, effectiveRange: nil)[.font] as? NSFont
    }

    private func editorWithCascade(
        _ cascade: [FontCascadeScript: String], source: String
    ) -> EditorTextView {
        let editor = makeEditor()
        var theme = editor.theme
        theme.fontCascade = cascade
        editor.applyTheme(theme, persist: false)
        editor.loadContent(source)
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        editor.recompose(cursorInRaw: 0)
        return editor
    }

    @Test("applyTheme pushes a resolver into the storage; no cascade → nil")
    func resolverWiring() {
        let plain = makeEditor()
        #expect((plain.textStorage as? EditorTextStorage)?.cascadeResolver == nil)

        let cascaded = editorWithCascade([.han: "Songti SC"], source: "漢字")
        #expect((cascaded.textStorage as? EditorTextStorage)?.cascadeResolver != nil)
    }

    @Test("Han characters render in the user's chosen family")
    func hanUsesCascadeFont() throws {
        let family = try #require(installedHanFamily(), "no Han-capable family installed")
        let editor = editorWithCascade([.han: family], source: "漢字 test")
        let font = try #require(renderedFont(for: "漢", in: editor))
        #expect(font.familyName == family)
    }

    @Test("Latin in a mixed paragraph keeps the body font")
    func latinKeepsBodyFont() throws {
        let family = try #require(installedHanFamily(), "no Han-capable family installed")
        let editor = editorWithCascade([.han: family], source: "漢字abc")
        let font = try #require(renderedFont(for: "a", in: editor))
        #expect(font.fontName == editor.bodyFont.fontName)
        let hanFont = try #require(renderedFont(for: "漢", in: editor))
        #expect(hanFont.familyName == family)
    }

    @Test("Shared CJK punctuation is never re-faced by a Han cascade")
    func cjkPunctuationUnaffected() throws {
        // Deterministic setup: body = a Han-capable family (covers 、), the
        // cascade = a DIFFERENT Han-capable family. If 、。「」 were wrongly
        // classified as Han, the cascade would re-face them to family B.
        let (body, cascade) = try #require(twoHanFamilies())
        let editor = makeEditor()
        var theme = editor.theme
        theme.fontName = body
        theme.fontCascade = [.han: cascade]
        editor.applyTheme(theme, persist: false)
        editor.loadContent("漢、字")
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        editor.recompose(cursorInRaw: 0)
        let han = try #require(renderedFont(for: "漢", in: editor))
        #expect(han.familyName == cascade)
        let punct = try #require(renderedFont(for: "、", in: editor))
        #expect(punct.familyName == body)
    }

    @Test("Emoji entry is honored exactly")
    func emojiEntry() {
        let editor = editorWithCascade([.emoji: "Apple Color Emoji"], source: "hi 😀")
        guard let font = renderedFont(for: "😀", in: editor) else {
            Issue.record("emoji not found in storage")
            return
        }
        #expect(font.fontName == NSFont(name: "Apple Color Emoji", size: 16)?.fontName)
    }

    @Test("Emoji without an entry still gets the system fallback")
    func emojiFallbackWithoutEntry() throws {
        let family = try #require(installedHanFamily(), "no Han-capable family installed")
        let editor = editorWithCascade([.han: family], source: "hi 😀")
        let font = try #require(renderedFont(for: "😀", in: editor))
        // System fallback (Apple Color Emoji on stock macOS), not the Han font.
        #expect(font.familyName != family)
        #expect(font.fontName != editor.bodyFont.fontName)
    }

    @Test("Uninstalled family falls back to CoreText substitution")
    func uninstalledFamilyFallsBack() throws {
        let editor = editorWithCascade([.han: "No Such Family 2049"], source: "漢字")
        let font = try #require(renderedFont(for: "漢", in: editor))
        // Not the missing family, and not the body font (which can't draw 漢)
        // — some covering font chosen by CoreText.
        #expect(font.familyName != "No Such Family 2049")
        #expect(font.fontName != editor.bodyFont.fontName)
    }

    @Test("Bold Han renders in the cascade family; delimiters stay hidden")
    func boldHan() throws {
        let family = try #require(installedHanFamily(), "no Han-capable family installed")
        // Delimiter hiding applies to the NON-active block — park the caret in
        // a trailing block so the bold block's ** delimiters are hidden.
        let editor = editorWithCascade([.han: family], source: "**漢**\nother")
        activateBlock(1, in: editor)

        let base = editor.blocks[0].range.location
        // The ** delimiters keep the near-zero hidden font (the substitution
        // pass skips runs at ≤1pt before any cascade logic).
        let star = try #require(font(at: base, in: editor))
        #expect(star.pointSize < 1.0)

        let han = try #require(font(at: base + 2, in: editor))
        // Family is always asserted; the bold trait survives only when the
        // family ships a bold member (documented resolver limitation).
        #expect(han.familyName == family)
        #expect(han.pointSize == editor.bodyFont.pointSize)
    }

    @Test("Cascade wins over a body font that already covers Han")
    func cascadeBeatsCoveringBodyFont() throws {
        // Body = an installed Han-capable family; cascade = a DIFFERENT
        // installed Han-capable family. The explicit choice must win even
        // though the coverage fast path would otherwise pass.
        let (body, cascade) = try #require(twoHanFamilies())
        let editor = makeEditor()
        var theme = editor.theme
        theme.fontName = body
        theme.fontCascade = [.han: cascade]
        editor.applyTheme(theme, persist: false)
        editor.loadContent("漢字")
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        editor.recompose(cursorInRaw: 0)
        let font = try #require(renderedFont(for: "漢", in: editor))
        #expect(font.familyName == cascade)
    }
}
