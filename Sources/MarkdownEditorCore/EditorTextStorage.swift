import AppKit
import CoreText

/// A text storage subclass whose `fixAttributes` does font substitution only.
///
/// The editor explicitly manages every attribute on every character (custom
/// keys like `.blockDecoration` / `.fragmentOverlay` included), so the
/// framework's default attribute "fixing" has nothing useful to add — and
/// historically it stripped attributes the renderer depended on.
public class EditorTextStorage: NSTextStorage {
    private let backing = NSMutableAttributedString()

    /// The accumulated string mutation since the last consume, expressed as
    /// "this range of the OLD string was replaced, shifting lengths by
    /// `delta`". Multiple mutations coalesce into the conservative hull.
    /// This is the single funnel for all string edits (typing, paste, IME),
    /// so the incremental block parser can re-split only the affected lines.
    public struct PendingEdit {
        public var oldRange: NSRange
        public var delta: Int
    }
    public private(set) var pendingEdit: PendingEdit?

    /// Returns and clears the accumulated edit.
    public func consumePendingEdit() -> PendingEdit? {
        defer { pendingEdit = nil }
        return pendingEdit
    }

    /// Drops accumulated-edit tracking. Programmatic whole-document
    /// replacements (recompose after load/undo/indent) call this — they
    /// re-parse from scratch themselves.
    public func clearPendingEdit() {
        pendingEdit = nil
    }

    /// Coalesces a new edit (given in CURRENT-string coordinates) into the
    /// pending edit (kept in OLD-string coordinates).
    private func accumulateEdit(currentRange r: NSRange, delta d: Int) {
        guard var p = pendingEdit else {
            pendingEdit = PendingEdit(oldRange: r, delta: d)
            return
        }
        // Map the new edit's bounds back to old-string coordinates and take
        // the hull. Positions at/after the previous edit's replacement shift
        // back by the previous delta; the max() keeps positions inside or
        // before it clamped to the previous old range.
        let start = min(p.oldRange.location, r.location)
        let end = max(p.oldRange.upperBound, r.upperBound - p.delta)
        p.oldRange = NSRange(location: start, length: max(0, end - start))
        p.delta += d
        pendingEdit = p
    }

    override public var string: String { backing.string }

    override public func attributes(
        at location: Int, effectiveRange range: NSRangePointer?
    ) -> [NSAttributedString.Key: Any] {
        backing.attributes(at: location, effectiveRange: range)
    }

    override public func replaceCharacters(in range: NSRange, with str: String) {
        let delta = (str as NSString).length - range.length
        accumulateEdit(currentRange: range, delta: delta)
        backing.replaceCharacters(in: range, with: str)
        edited(.editedCharacters, range: range, changeInLength: delta)
    }

    override public func replaceCharacters(in range: NSRange, with attrString: NSAttributedString) {
        let delta = attrString.length - range.length
        accumulateEdit(currentRange: range, delta: delta)
        backing.replaceCharacters(in: range, with: attrString)
        edited([.editedCharacters, .editedAttributes], range: range,
               changeInLength: delta)
    }

    override public func setAttributes(
        _ attrs: [NSAttributedString.Key: Any]?, range: NSRange
    ) {
        backing.setAttributes(attrs, range: range)
        edited(.editedAttributes, range: range, changeInLength: 0)
    }

    override public func fixAttributes(in range: NSRange) {
        // We deliberately skip the framework's default attribute fixing — the
        // editor manages all attributes itself, and the default pass has a
        // history of stripping what the renderer depends on.
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
