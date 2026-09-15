import Foundation

/// Pure text search over a document's raw source. No UI, no state — given a
/// needle and the haystack, returns the character ranges of every match.
///
/// The ranges are `NSRange` over the string's UTF-16 view, which is exactly the
/// index space the text storage uses (storage == rawSource, identity offsets),
/// so a match range maps straight onto the editor with no offset translation.
public enum FindEngine {

    /// Non-overlapping matches of `needle` in `haystack`, left to right.
    ///
    /// - `caseSensitive`: false (default) folds case via `.caseInsensitive`.
    /// - `wholeWord`: keeps only hits whose neighbouring characters are not
    ///   alphanumeric, so "cat" does not match inside "category".
    ///
    /// Empty needle → no matches.
    // ponytail: linear rescan of the whole document on every keystroke. Fine to
    // ~10⁵ chars; if large docs lag, debounce or search incrementally around the
    // viewport.
    public static func matches(of needle: String,
                               in haystack: String,
                               caseSensitive: Bool = false,
                               wholeWord: Bool = false) -> [NSRange] {
        guard !needle.isEmpty else { return [] }

        let hay = haystack as NSString
        let opts: NSString.CompareOptions = caseSensitive ? [] : [.caseInsensitive]
        var results: [NSRange] = []
        var searchStart = 0

        while searchStart < hay.length {
            let searchRange = NSRange(location: searchStart, length: hay.length - searchStart)
            let hit = hay.range(of: needle, options: opts, range: searchRange)
            if hit.location == NSNotFound { break }

            if !wholeWord || isWholeWord(hit, in: hay) {
                results.append(hit)
            }
            // Advance past this hit's start (by 1, not by length) so adjacent and
            // rejected-whole-word hits are still found; matches themselves never
            // overlap because the next accepted hit starts at or after hit.end.
            searchStart = max(hit.location + 1, hit.location + hit.length)
        }
        return results
    }

    /// A hit is a whole word when the characters immediately before and after it
    /// are not alphanumeric (or the hit sits at a document edge).
    private static func isWholeWord(_ hit: NSRange, in hay: NSString) -> Bool {
        let alnum = CharacterSet.alphanumerics
        if hit.location > 0 {
            let before = hay.substring(with: NSRange(location: hit.location - 1, length: 1))
            if before.rangeOfCharacter(from: alnum) != nil { return false }
        }
        let afterIndex = hit.location + hit.length
        if afterIndex < hay.length {
            let after = hay.substring(with: NSRange(location: afterIndex, length: 1))
            if after.rangeOfCharacter(from: alnum) != nil { return false }
        }
        return true
    }
}
