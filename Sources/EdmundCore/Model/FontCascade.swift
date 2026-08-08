import AppKit
import Foundation

/// The fixed, curated set of scripts the user can assign a dedicated font to.
/// Han is shared by Chinese and Japanese, so there is one entry for it; kana
/// gets its own so Japanese text can still be distinguished.
public enum FontCascadeScript: String, CaseIterable, Codable, Sendable {
    case han, kana, hangul, cyrillic, greek, arabic, hebrew, thai, emoji

    /// Display label for the Settings pane (hardcoded English, per repo norm).
    public var label: String {
        switch self {
        case .han: return "Chinese (Han)"
        case .kana: return "Japanese (Kana)"
        case .hangul: return "Korean (Hangul)"
        case .cyrillic: return "Cyrillic"
        case .greek: return "Greek"
        case .arabic: return "Arabic"
        case .hebrew: return "Hebrew"
        case .thai: return "Thai"
        case .emoji: return "Emoji"
        }
    }

    /// Sample string drawn in the candidate font in the Settings preview.
    public var sample: String {
        switch self {
        case .han: return "漢字"
        case .kana: return "あいう"
        case .hangul: return "한글"
        case .cyrillic: return "Язык"
        case .greek: return "Ελληνικά"
        case .arabic: return "العربية"
        case .hebrew: return "עברית"
        case .thai: return "ไทย"
        case .emoji: return "😀"
        }
    }

    /// CSS `unicode-range` value matching the classifier's ranges for this
    /// script. Single source for Read mode's per-script @font-face blocks
    /// (HTMLTheme); keep in sync with `classify(_:)` below.
    public var cssUnicodeRange: String {
        switch self {
        case .han:
            return "U+3005, U+3400-4DBF, U+4E00-9FFF, U+F900-FAFF, U+20000-2A6DF"
        case .kana:
            return "U+3040-309F, U+30A0-30FF, U+31F0-31FF, U+FF66-FF9D"
        case .hangul:
            return "U+1100-11FF, U+3130-318F, U+A960-A97F, U+AC00-D7AF, U+D7B0-D7FF"
        case .cyrillic:
            return "U+0400-052F, U+2DE0-2DFF, U+A640-A69F"
        case .greek:
            return "U+0370-03FF, U+1F00-1FFF"
        case .arabic:
            return "U+0600-06FF, U+0750-077F, U+08A0-08FF, U+FB50-FDFF, U+FE70-FEFF"
        case .hebrew:
            return "U+0590-05FF, U+FB1D-FB4F"
        case .thai:
            return "U+0E00-0E7F"
        case .emoji:
            // Emoji defy a tidy range table (base blocks + presentation
            // selectors + keycap/reserved). DERIVED from the same `isEmoji`
            // predicate `classify` uses — a hand-written block list drifted
            // from the classifier (U+2192 → isEmoji == false but was listed;
            // U+2122 ™ is isEmoji but wasn't), so Edit and Read painted
            // different fonts for the same character. The @font-face only
            // needs to win on the cluster's base scalar; this is the exact
            // set of scalars the classifier routes to `.emoji`.
            return Self.emojiUnicodeRange
        }
    }

    /// The union of `isEmoji` scalar ranges (U+0080 and up — the classifier
    /// routes only non-ASCII to `.emoji`), formatted as a CSS `unicode-range`
    /// list. Computed once from the same predicate `classify(_:)` uses so the
    /// Read-mode @font-face can never diverge from the editor's classifier.
    private static let emojiUnicodeRange: String = {
        var ranges: [(start: UInt32, end: UInt32)] = []
        var inRange = false
        var start: UInt32 = 0, end: UInt32 = 0
        for value in 0x80...0x10FFFF {
            // Skip surrogates — not scalar values; Unicode.Scalar(init:) traps on them.
            if (0xD800...0xDFFF).contains(UInt32(value)) { continue }
            let isEmoji = Unicode.Scalar(UInt32(value))!.properties.isEmoji
            if isEmoji && !inRange { inRange = true; start = UInt32(value) }
            if isEmoji { end = UInt32(value) }
            if !isEmoji && inRange {
                ranges.append((start, end))
                inRange = false
            }
        }
        if inRange { ranges.append((start, end)) }
        return ranges.map { range in
            range.start == range.end
                ? "U+\(String(format: "%X", range.start))"
                : "U+\(String(format: "%X", range.start))-U+\(String(format: "%X", range.end))"
        }.joined(separator: ", ")
    }()

    /// Classifies one composed-character sequence (grapheme cluster) to a
    /// cascade script, or nil when the sequence should keep the body font
    /// (Latin, digits, whitespace, and shared/neutral punctuation such as
    /// CJK 、。「」 — those must not be dragged into a script face or a mixed
    /// sentence's punctuation would restyle against the body font).
    public static func classify(_ cluster: String) -> FontCascadeScript? {
        // First base scalar: skip combining/modifier machinery (variation
        // selectors, ZWJ, emoji skin tones, combining marks) so sequences like
        // ☀️ or é classify by their base character.
        //
        // The keycap enclosure (U+20E3) is scanned in a separate full pass: a
        // keycap cluster is ASCII + U+FE0F + U+20E3, and the base loop breaks
        // on the ASCII base before it would ever reach the enclosure. Detecting
        // it in that loop left `hasKeycap` permanently false and "1️⃣" silently
        // falling through to nil instead of the user's Emoji font.
        var base: Unicode.Scalar?
        for scalar in cluster.unicodeScalars {
            if isModifier(scalar) { continue }
            base = scalar
            break
        }
        guard let b = base else { return nil }

        // A keycap cluster's base is ASCII (1/#/*) — the enclosure makes it emoji.
        if cluster.unicodeScalars.contains(where: { $0.value == 0x20E3 }) { return .emoji }

        // Emoji first: ASCII 0-9, #, * all have isEmoji == true, so require a
        // non-ASCII scalar. Dingbats (U+2600–27BF etc.) with emoji presentation
        // land here too — they belong to the user's Emoji entry.
        if b.value >= 0x80, b.properties.isEmoji { return .emoji }

        let v = b.value
        switch v {
        case 0x3040...0x309F, 0x30A0...0x30FF, 0x31F0...0x31FF, 0xFF66...0xFF9D:
            return .kana
        case 0xAC00...0xD7AF, 0x1100...0x11FF, 0x3130...0x318F, 0xA960...0xA97F, 0xD7B0...0xD7FF:
            return .hangul
        case 0x0400...0x052F, 0x2DE0...0x2DFF, 0xA640...0xA69F:
            return .cyrillic
        case 0x0370...0x03FF, 0x1F00...0x1FFF:
            return .greek
        case 0x0600...0x06FF, 0x0750...0x077F, 0x08A0...0x08FF, 0xFB50...0xFDFF, 0xFE70...0xFEFF:
            return .arabic
        case 0x0590...0x05FF, 0xFB1D...0xFB4F:
            return .hebrew
        case 0x0E00...0x0E7F:
            return .thai
        case 0x3005, 0x4E00...0x9FFF, 0x3400...0x4DBF, 0xF900...0xFAFF, 0x20000...0x2A6DF:
            return .han
        default:
            return nil
        }
    }

    /// Scalars that never decide a cluster's script: variation selectors,
    /// ZWJ, emoji skin-tone modifiers, and combining marks. Emoji modifiers
    /// are isEmoji themselves — skipping them lets 👍🏽 classify on 👍.
    private static func isModifier(_ s: Unicode.Scalar) -> Bool {
        if s.value == 0x200D { return true }                        // ZWJ
        if (0xFE00...0xFE0F).contains(s.value) { return true }      // variation selectors
        if (0x1F3FB...0x1F3FF).contains(s.value) { return true }    // emoji modifiers
        if (0xE0100...0xE01EF).contains(s.value) { return true }    // supplementary VS
        switch s.properties.generalCategory {
        case .nonspacingMark, .spacingMark, .enclosingMark: return true
        default: return false
        }
    }
}

/// Resolves the user's per-script font choices to cached NSFonts at the run's
/// point size and traits. EditorTextStorage holds one (nil when the theme has
/// no cascade entries), so the font-substitution pass can consult the user's
/// explicit choice before CoreText's own fallback.
///
/// Deliberately NOT @MainActor: NSTextStorage.fixAttributes is a nonisolated
/// override, and the storage class carries no actor. All real use is
/// main-thread (AppKit text system), so the unsynchronized cache is fine.
public final class FontCascadeResolver {

    /// script → macOS font family name, as persisted in the theme.
    public let families: [FontCascadeScript: String]

    /// (script, point size, bold, italic) → resolved font (+ whether its bold
    /// had to be stroke-synthesized). One instance per theme application,
    /// reused across all blocks — the same attribute-interner discipline as
    /// EditorTextView's cached body/mono fonts.
    private var cache: [CacheKey: (font: NSFont, synthesizedBold: Bool)] = [:]

    private struct CacheKey: Hashable {
        let script: FontCascadeScript
        let size: CGFloat
        let bold: Bool
        let italic: Bool
    }

    /// nil when the cascade is empty — callers keep a nil resolver in that
    /// case, and the substitution pass is byte-identical to pre-cascade.
    public init?(cascade: [FontCascadeScript: String]) {
        guard !cascade.isEmpty else { return nil }
        families = cascade
    }

    /// The user's font for `script` at `base`'s size, or nil when the script
    /// has no entry or its family is not installed — nil means the caller
    /// falls back to the regular CoreText substitution (`CTFontCreateForString`).
    /// The persisted entry is kept either way: the font may be reinstalled.
    ///
    /// `synthesizedBold` is true when the family has no bold member and the
    /// font is plain — the caller is expected to add a `.strokeWidth` attribute
    /// so the bold reads as bold despite the missing face (what Read mode's
    /// WebKit synthesizes for the same @font-face). Pre-cascade, CoreText
    /// resolved a bold CJK fallback member for a bold base font; for a
    /// bold-less family like STSong every macOS mechanism (NSFontManager,
    /// CTFontCreateCopyWithSymbolicTraits, descriptor traits) returns the plain
    /// face, so without the stroke the cascade would render script bold as
    /// regular — a regression against both pre-cascade behavior and Read mode.
    public func font(for script: FontCascadeScript, like base: NSFont) -> (font: NSFont, synthesizedBold: Bool)? {
        guard let family = families[script] else { return nil }
        let baseTraits = base.fontDescriptor.symbolicTraits
        let bold = baseTraits.contains(.bold)
        let italic = baseTraits.contains(.italic)
        let key = CacheKey(script: script, size: base.pointSize, bold: bold, italic: italic)
        if let cached = cache[key] { return cached }

        guard var resolved = NSFont(name: family, size: base.pointSize) else { return nil }
        if bold {
            resolved = NSFontManager.shared.convert(resolved, toHaveTrait: .boldFontMask)
        }
        if italic {
            resolved = NSFontManager.shared.convert(resolved, toHaveTrait: .italicFontMask)
        }
        // The conversion asks for the closest matching face; a family with no
        // bold member returns the plain face (verified: STSong, the only
        // common bold-less CJK cascade choice). Signal that so the caller can
        // stroke-synthesize rather than render regular.
        let synthesizedBold = bold && !resolved.fontDescriptor.symbolicTraits.contains(.bold)
        let result = (resolved, synthesizedBold)
        cache[key] = result
        return result
    }
}
