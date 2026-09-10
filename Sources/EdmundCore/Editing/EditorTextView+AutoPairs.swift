import AppKit

// MARK: - Auto-closing brackets and quotes
//
// Typing an opening bracket or quote inserts its closing partner and leaves the
// caret between the two; typing a closing character that is already sitting to
// the right of the caret steps over it instead of inserting a second one.
// Deleting an opening character while its partner still sits next to it removes
// both. Gated by `autoCloseBracketsEnabled` (Settings ▸ Edit ▸ Editing).
//
// Everything goes through `super.insertText`, so the edit takes the normal
// pipeline (shouldChangeText → undo record → didChangeText → resync). The caret
// is nudged left only *after* that returns: `didChangeText` re-asserts the caret
// to the edit's end point while it runs (see EditorTextView+EditFlow), so
// setting the selection any earlier would be overwritten.

extension EditorTextView {

    /// Opening character → its closing partner.
    private static let autoPairs: [Character: Character] = [
        "(": ")", "[": "]", "{": "}", "\"": "\"", "'": "'", "`": "`",
    ]

    /// Characters that can be "typed over" when they already sit at the caret.
    private static let autoPairClosers: Set<Character> = [")", "]", "}", "\"", "'", "`"]

    /// Quote-like pairs, where the opener and closer are the same character.
    /// These need the extra word-boundary checks below (an apostrophe inside
    /// `don't` must not sprout a partner).
    private static let symmetricPairs: Set<Character> = ["\"", "'", "`"]

    public override func insertText(_ string: Any, replacementRange: NSRange) {
        guard autoCloseBracketsEnabled,
              // While an IME is composing, the provisional text runs through
              // here too — never rewrite it.
              !hasMarkedText(),
              let text = Self.plainText(string),
              text.count == 1,
              let ch = text.first
        else {
            super.insertText(string, replacementRange: replacementRange)
            return
        }

        // NSNotFound means "use the current selection" (the ordinary typing case).
        let target = replacementRange.location == NSNotFound ? selectedRange() : replacementRange
        guard target.length == 0 else {
            super.insertText(string, replacementRange: replacementRange)
            return
        }

        // Type-over: the closer we'd have inserted is already there.
        if Self.autoPairClosers.contains(ch), character(at: target.location) == ch {
            setSelectedRange(NSRange(location: target.location + 1, length: 0))
            return
        }

        guard let closer = Self.autoPairs[ch], shouldAutoClose(ch, at: target.location) else {
            super.insertText(string, replacementRange: replacementRange)
            return
        }

        super.insertText(text + String(closer), replacementRange: replacementRange)
        // Land between the pair. `didChangeText` has already run and parked the
        // caret after the closer.
        let between = target.location + 1
        if between <= (textStorage?.length ?? 0) {
            setSelectedRange(NSRange(location: between, length: 0))
        }
    }

    /// Deleting an opening character takes its closing partner with it, but only
    /// while the two are still adjacent — the state auto-closing just left behind.
    /// Once anything sits between them the pair is ordinary text and the closer
    /// stays put.
    public override func deleteBackward(_ sender: Any?) {
        let target = selectedRange()
        guard autoCloseBracketsEnabled,
              !hasMarkedText(),
              target.length == 0,
              let opener = character(at: target.location - 1),
              let closer = Self.autoPairs[opener],
              character(at: target.location) == closer
        else {
            super.deleteBackward(sender)
            return
        }

        // Drop the closer with AppKit's own forward delete, then let the normal
        // backward delete take the opener. Selecting both and deleting the
        // selection in one go looks tidier but crashes: NSTextView's
        // post-edit `updateFontPanel` re-reads the selection we just set, which
        // by then runs past the end of the shrunken storage
        // (NSMutableRLEArray … Out of bounds).
        super.deleteForward(sender)
        super.deleteBackward(sender)
    }

    /// Whether typing `ch` at `location` should bring a closing partner along.
    private func shouldAutoClose(_ ch: Character, at location: Int) -> Bool {
        // Never auto-close directly before a word: the user is typing around
        // existing text (`(` before `foo` should not orphan a `)` mid-word).
        if let next = character(at: location), next.isLetter || next.isNumber { return false }

        // A quote or backtick right after a word character is almost always an
        // apostrophe or a closing mark, not the start of a pair — `don't`,
        // `it's`, a closing `` ` `` after inline code.
        if Self.symmetricPairs.contains(ch),
           let prev = character(at: location - 1),
           prev.isLetter || prev.isNumber {
            return false
        }
        return true
    }

    /// The character at `offset` in the storage, or nil when out of bounds.
    /// Offsets are storage offsets, which are raw-source offsets (storage ==
    /// rawSource — see docs/ARCHITECTURE.md).
    private func character(at offset: Int) -> Character? {
        guard let storage = textStorage, offset >= 0, offset < storage.length else { return nil }
        let unit = (storage.string as NSString).character(at: offset)
        guard let scalar = Unicode.Scalar(unit) else { return nil }
        return Character(scalar)
    }

    /// `insertText` takes `Any`: a String, NSString, or NSAttributedString.
    private static func plainText(_ string: Any) -> String? {
        switch string {
        case let s as String: return s
        case let s as NSAttributedString: return s.string
        default: return nil
        }
    }
}
