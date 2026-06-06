import AppKit
import CoreText

/// A text storage subclass that preserves `.attachment` attributes on
/// any character, not just the object replacement character (\u{FFFC}).
///
/// Standard NSTextStorage strips attachments from non-FFFC characters
/// during `fixAttributes`. This subclass skips attribute fixing since
/// the editor explicitly manages all attributes for every character.
public class EditorTextStorage: NSTextStorage {
    private let backing = NSMutableAttributedString()

    override public var string: String { backing.string }

    override public func attributes(
        at location: Int, effectiveRange range: NSRangePointer?
    ) -> [NSAttributedString.Key: Any] {
        backing.attributes(at: location, effectiveRange: range)
    }

    override public func replaceCharacters(in range: NSRange, with str: String) {
        backing.replaceCharacters(in: range, with: str)
        edited(.editedCharacters, range: range,
               changeInLength: (str as NSString).length - range.length)
    }

    override public func replaceCharacters(in range: NSRange, with attrString: NSAttributedString) {
        backing.replaceCharacters(in: range, with: attrString)
        edited([.editedCharacters, .editedAttributes], range: range,
               changeInLength: attrString.length - range.length)
    }

    override public func setAttributes(
        _ attrs: [NSAttributedString.Key: Any]?, range: NSRange
    ) {
        backing.setAttributes(attrs, range: range)
        edited(.editedAttributes, range: range, changeInLength: 0)
    }

    override public func fixAttributes(in range: NSRange) {
        // We deliberately skip the framework's default attribute fixing because
        // it strips .attachment from non-FFFC characters — and the editor places
        // marker icons (bullet dot, checkbox circle, math image) on real
        // characters like "-", "[", "$".
        //
        // But one part of fixing is still needed: font substitution. The body
        // font (a serif/mono) has no glyphs for emoji, CJK, etc.; without
        // substitution those render as missing-glyph boxes. So we do font
        // fixing ourselves, leaving every other attribute (attachments included)
        // untouched.
        fixFontSubstitution(in: range)
    }

    /// Replaces the font on any character the run's font cannot render with a
    /// fallback font that can (e.g. Apple Color Emoji), preserving the original
    /// size. Substitutions are computed first, then applied, so we never mutate
    /// the attribute we're enumerating mid-pass.
    private func fixFontSubstitution(in range: NSRange) {
        guard range.length > 0, range.upperBound <= backing.length else { return }
        let ns = backing.string as NSString
        var fixes: [(NSRange, NSFont)] = []

        backing.enumerateAttribute(.font, in: range, options: []) { value, runRange, _ in
            // Skip the tiny hidden-delimiter font — those chars are invisible
            // and are plain ASCII delimiters the base font already covers.
            guard let font = value as? NSFont, font.pointSize > 1.0 else { return }

            // Fast path: does the font cover the whole run?
            let runChars = Array(ns.substring(with: runRange).utf16)
            var runGlyphs = [CGGlyph](repeating: 0, count: runChars.count)
            if CTFontGetGlyphsForCharacters(font as CTFont, runChars, &runGlyphs, runChars.count) {
                return
            }

            // Substitute per composed-character sequence so we never split a
            // grapheme (emoji ZWJ sequences, skin-tone modifiers, é, …).
            var i = runRange.location
            let end = runRange.upperBound
            while i < end {
                let seq = ns.rangeOfComposedCharacterSequence(at: i)
                let seqRange = NSRange(location: seq.location,
                                       length: min(seq.length, end - seq.location))
                let seqStr = ns.substring(with: seqRange)
                let seqChars = Array(seqStr.utf16)
                var seqGlyphs = [CGGlyph](repeating: 0, count: seqChars.count)
                let covered = CTFontGetGlyphsForCharacters(
                    font as CTFont, seqChars, &seqGlyphs, seqChars.count)
                if !covered {
                    let substitute = CTFontCreateForString(
                        font as CTFont, seqStr as CFString,
                        CFRange(location: 0, length: seqChars.count)) as NSFont
                    fixes.append((seqRange, substitute))
                }
                i = seqRange.upperBound
            }
        }

        for (r, f) in fixes {
            backing.addAttribute(.font, value: f, range: r)
        }
    }
}
