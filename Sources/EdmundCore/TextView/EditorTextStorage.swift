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

    /// The user's per-script font choices, pushed from the editor's theme.
    /// nil when the theme has no cascade entries — the substitution pass is
    /// then byte-identical to its pre-cascade behavior. Read from the
    /// nonisolated fixAttributes; only ever written on the main thread
    /// (theme application), same as every other storage-adjacent knob.
    public var cascadeResolver: FontCascadeResolver?

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
        // (range, attribute key, value) — most fixes are `.font`; synthesized
        // bold adds a `.strokeWidth` on the same range for families with no
        // bold member (see the resolver).
        var fixes: [(NSRange, NSAttributedString.Key, Any)] = []

        backing.enumerateAttribute(.font, in: range, options: []) { value, runRange, _ in
            // Skip the tiny hidden-delimiter font — those chars are invisible
            // and are plain ASCII delimiters the base font already covers.
            guard let font = value as? NSFont, font.pointSize > 1.0 else { return }

            // With a cascade configured, check for user-assigned scripts
            // BEFORE the coverage fast path: an explicit per-script choice
            // must win even when the body font happens to cover the script
            // (e.g. a CJK-capable serif as body). The pre-scan skips all of
            // this for runs that can't contain a cascade script — pure
            // Latin/digit/punct runs cost one integer pass, no clustering.
            //
            // Monospace runs are excluded: a 漢 inside code must keep the
            // monospace columnar look (falling back to a system CJK face), not
            // be dragged into the user's script cascade (a serif Han would
            // break the code font's rhythm). Read mode's --mono-font stack has
            // no cascade either, so excluding them keeps Edit and Read in step.
            var cascadeFixes: [(NSRange, NSFont)] = []
            // The ranges a cascade fix covers, so the generic pass below can
            // skip them in O(1) instead of re-scanning cascadeFixes per
            // sequence (which was O(N²) on a long Han run).
            var cascadeSkip = IndexSet()
            if let resolver = cascadeResolver,
               !font.fontDescriptor.symbolicTraits.contains(.monoSpace),
               runMayContainCascadeScript(ns, in: runRange) {
                var i = runRange.location
                let end = runRange.upperBound
                while i < end {
                    let seq = ns.rangeOfComposedCharacterSequence(at: i)
                    let seqRange = NSRange(location: seq.location,
                                           length: min(seq.length, end - seq.location))
                    if let script = FontCascadeScript.classify(ns.substring(with: seqRange)),
                       let (cascadeFont, synthesizedBold) = resolver.font(for: script, like: font),
                       cascadeFont.fontName != font.fontName {
                        cascadeFixes.append((seqRange, cascadeFont))
                        cascadeSkip.insert(seqRange.location)
                        // A family with no bold member (e.g. STSong) returns
                        // the plain face from every macOS mechanism; the
                        // stroke makes the bold read as bold — what Read mode's
                        // WebKit synthesizes for the same @font-face.
                        if synthesizedBold {
                            fixes.append((seqRange, .strokeWidth, NSNumber(value: -3.0)))
                        }
                    }
                    i = seqRange.upperBound
                }
                if !cascadeFixes.isEmpty {
                    for (r, f) in cascadeFixes {
                        fixes.append((r, .font, f))
                    }
                    // Cascade substitutions overwrite whatever the generic
                    // pass would compute below — the generic pass skips
                    // these sequences outright (see below).
                }
            }

            // Fast path: does the font cover the whole run? When a cascade
            // pass ran above, the run's stored font may already be a cascade
            // font from an earlier fix; coverage is measured against it all
            // the same, so the fast path stays valid.
            let runChars = Array(ns.substring(with: runRange).utf16)
            var runGlyphs = [CGGlyph](repeating: 0, count: runChars.count)
            if CTFontGetGlyphsForCharacters(font as CTFont, runChars, &runGlyphs, runChars.count) {
                return
            }

            // Substitute per composed-character sequence so we never split a
            // grapheme (emoji ZWJ sequences, skin-tone modifiers, é, …).
            // A sequence the cascade pass already assigned is skipped: the
            // user's explicit choice outranks the generic CoreText fallback,
            // which would otherwise re-cover the same range and (applied
            // later, in the same fix list) silently overwrite the cascade.
            var i = runRange.location
            let end = runRange.upperBound
            while i < end {
                let seq = ns.rangeOfComposedCharacterSequence(at: i)
                let seqRange = NSRange(location: seq.location,
                                       length: min(seq.length, end - seq.location))
                if cascadeSkip.contains(seqRange.location) {
                    i = seqRange.upperBound
                    continue
                }
                let seqStr = ns.substring(with: seqRange)
                let seqChars = Array(seqStr.utf16)
                var seqGlyphs = [CGGlyph](repeating: 0, count: seqChars.count)
                let covered = CTFontGetGlyphsForCharacters(
                    font as CTFont, seqChars, &seqGlyphs, seqChars.count)
                if !covered {
                    let substitute = CTFontCreateForString(
                        font as CTFont, seqStr as CFString,
                        CFRange(location: 0, length: seqChars.count)) as NSFont
                    fixes.append((seqRange, .font, substitute))
                }
                i = seqRange.upperBound
            }
        }

        for (r, key, value) in fixes {
            backing.addAttribute(key, value: value, range: r)
        }
    }

    /// Cheap UTF-16 pre-scan: can any scalar in this run belong to a cascade
    /// script? Every cascade route lives at U+00A9 or above (or in
    /// supplementary planes, reachable only via surrogate pairs): the script
    /// ranges start at U+0370 (Greek), and the lowest scalar `classify` can
    /// route to `.emoji` is U+00A9 © (isEmoji == true, and first in the
    /// emoji CSS range). So a run entirely below U+00A9 — ASCII Latin,
    /// digits, whitespace, common punctuation — skips classification.
    ///
    /// The bound was once 0x0300 ("all scripts live at U+0300+"): true of
    /// the script ranges, false of the classifier — ©/® sat below it, so
    /// Edit kept the body font for a "© 2026" line while Read's @font-face
    /// (unicode-range lists U+A9 first) painted the emoji family.
    private func runMayContainCascadeScript(_ ns: NSString, in range: NSRange) -> Bool {
        var i = range.location
        let end = range.upperBound
        while i < end {
            let unit = ns.character(at: i)
            if unit >= 0xA9 || (unit >= 0xD800 && unit <= 0xDBFF) { return true }
            i += 1
        }
        return false
    }
}
