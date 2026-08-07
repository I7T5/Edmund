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
            // selectors + keycap/reserved). List the base emoji blocks; the
            // @font-face only needs to win on the cluster's base scalar.
            return "U+2190-21FF, U+2300-23FF, U+2460-24FF, U+25A0-25FF, U+2600-27BF, U+2B00-2BFF, U+1F000-1FAFF"
        }
    }

    /// Classifies one composed-character sequence (grapheme cluster) to a
    /// cascade script, or nil when the sequence should keep the body font
    /// (Latin, digits, whitespace, and shared/neutral punctuation such as
    /// CJK 、。「」 — those must not be dragged into a script face or a mixed
    /// sentence's punctuation would restyle against the body font).
    public static func classify(_ cluster: String) -> FontCascadeScript? {
        // First base scalar: skip combining/modifier machinery (variation
        // selectors, ZWJ, emoji skin tones, combining marks) so sequences like
        // ☀️ or é classify by their base character.
        var base: Unicode.Scalar?
        var hasKeycap = false
        for scalar in cluster.unicodeScalars {
            if scalar.value == 0x20E3 { hasKeycap = true; continue }  // keycap enclosure
            if isModifier(scalar) { continue }
            base = scalar
            break
        }
        guard let b = base else { return hasKeycap ? .emoji : nil }

        // A keycap cluster's base is ASCII (1/#/*) — the enclosure makes it emoji.
        if hasKeycap { return .emoji }

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

    /// (script, point size, bold, italic) → resolved font. One instance per theme
    /// application, reused across all blocks — the same attribute-interner
    /// discipline as EditorTextView's cached body/mono fonts.
    private var cache: [CacheKey: NSFont] = [:]

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
    public func font(for script: FontCascadeScript, like base: NSFont) -> NSFont? {
        guard let family = families[script] else { return nil }
        let baseTraits = base.fontDescriptor.symbolicTraits
        let bold = baseTraits.contains(.bold)
        let italic = baseTraits.contains(.italic)
        let key = CacheKey(script: script, size: base.pointSize, bold: bold, italic: italic)
        if let cached = cache[key] { return cached }

        guard var resolved = NSFont(name: family, size: base.pointSize) else { return nil }
        // KNOWN LIMITATION: families without a bold/italic member render
        // unstyled (NSFont has no synthetic bolding like CoreText's fallback
        // chain does). The user's chosen family still wins over CoreText's
        // fallback family — a bold 漢 in Songti stays Songti, just not bold.
        if bold {
            resolved = NSFontManager.shared.convert(resolved, toHaveTrait: .boldFontMask)
        }
        if italic {
            resolved = NSFontManager.shared.convert(resolved, toHaveTrait: .italicFontMask)
        }
        cache[key] = resolved
        return resolved
    }
}
