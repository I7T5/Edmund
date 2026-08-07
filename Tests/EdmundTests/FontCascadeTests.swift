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
