import AppKit

// MARK: - Spell Check
//
// AppKit's continuous checker runs over the raw markdown (storage ==
// rawSource), which trips it three ways. The first two are fixed by filtering
// its results (`filteredCheckingResults`) before they become marks, and the
// same filter steers the Spelling and Grammar panel (`checkSpelling`) so the
// panel never stops on something the text doesn't underline:
//   - Math: `\mathrm` in `$…$` / `$$…$$` gets flagged, and under a rendered
//     formula the mark draws beneath the hidden source. Math spans are skipped.
//   - Inline enumerations: NSSpellChecker reads `a,b,c` / `x;y` / `i,ii,iii`
//     as ONE word and flags it. A token of short (≤ 3-letter) parts is
//     re-checked part by part; longer parts (`Hello,world`) are a missing
//     space, a real typo, and stay marked whole.
// The third is stale marks: restyles are attribute-only, so AppKit never
// re-checks a word it skipped while the caret sat in it — fixing `Helo` into
// `Hello` left the old mark, split around the new letter, until the next edit
// there. Every restyle and caret move re-checks what it touched
// (`recheckSpelling`); only an edit spares the word being typed, as AppKit
// does — a misspelled word you click into keeps its mark.
extension EditorTextView {

    /// AppKit's own (asynchronous) checking pass delivers here.
    public override func handleTextCheckingResults(
        _ results: [NSTextCheckingResult], forRange range: NSRange,
        types checkingTypes: NSTextCheckingTypes, options: [NSSpellChecker.OptionKey: Any],
        orthography: NSOrthography, wordCount: Int
    ) {
        super.handleTextCheckingResults(filteredCheckingResults(results, orthography: orthography,
                                                                sparing: nil),
                                        forRange: range, types: checkingTypes,
                                        options: options, orthography: orthography,
                                        wordCount: wordCount)
    }

    /// Drops math and enumeration false positives from spelling/grammar
    /// results; `sparing` also drops the misspelling and the grammar issue
    /// touching that offset (the word and sentence still being typed).
    func filteredCheckingResults(_ results: [NSTextCheckingResult], orthography: NSOrthography?,
                                 sparing caret: Int?) -> [NSTextCheckingResult] {
        let language = enumerationLanguage(orthography)
        var mathByBlock: [Int: [NSRange]] = [:]
        func inMath(_ range: NSRange) -> Bool {
            guard let idx = blockIndexForRawOffset(range.location) else { return false }
            if mathByBlock[idx] == nil { mathByBlock[idx] = mathRanges(inBlock: idx) }
            return mathByBlock[idx]!.contains { NSIntersectionRange($0, range).length > 0 }
        }
        func touchesCaret(_ range: NSRange) -> Bool {
            guard let caret else { return false }
            return range.location <= caret && caret <= range.upperBound
        }
        var kept: [NSTextCheckingResult] = []
        for result in results {
            switch result.resultType {
            case .spelling:
                guard !touchesCaret(result.range), !inMath(result.range) else { continue }
                kept += (enumerationMisspellings(of: result.range, language: language) ?? [result.range])
                    .map { NSTextCheckingResult.spellCheckingResult(range: $0) }
            case .grammar:
                if !touchesCaret(result.range), !inMath(result.range) { kept.append(result) }
            default:
                kept.append(result)
            }
        }
        return kept
    }

    /// Re-checks spelling (and grammar, when on) over the given blocks and
    /// redraws their marks, one check per contiguous run so a caret jump from
    /// the top of the document to the bottom doesn't check everything between.
    /// `sparingCaret` is for the edit path: leave the word being typed alone.
    ///
    /// Synchronous and marks set directly, rather than `checkText(in:)`: that
    /// delivers on a later run-loop pass (too late to spare the caret's word by
    /// the caret position it was checked at), and `super.handleTextCheckingResults`
    /// was measured not to mark anything for results handed to it directly.
    func recheckSpelling(blocks indices: IndexSet, sparingCaret: Bool = false) {
        guard isContinuousSpellCheckingEnabled, !hasMarkedText(), let ts = textStorage else { return }
        var types = NSTextCheckingResult.CheckingType.spelling.rawValue
        if isGrammarCheckingEnabled { types |= NSTextCheckingResult.CheckingType.grammar.rawValue }
        let sel = selectedRange()
        let caret = sel.length == 0 ? sel.location : nil
        for run in indices.rangeView where run.lowerBound < blocks.count {
            let start = blocks[run.lowerBound].range.location
            let end = min(blocks[min(run.upperBound, blocks.count) - 1].range.upperBound, ts.length)
            guard end > start else { continue }
            var range = NSRange(location: start, length: end - start)
            // This runs on the main thread per keystroke, so a long block (a
            // big fence or table) is narrowed to the caret's line and anything
            // else is left to AppKit's own background pass.
            // ponytail: fixed cap; per-line diffing if lines themselves get huge.
            if range.length > 2_000 {
                guard let caret, NSLocationInRange(caret, range) || caret == range.upperBound else { continue }
                range = NSIntersectionRange((string as NSString).paragraphRange(for: NSRange(location: caret, length: 0)), range)
                guard range.length > 0 else { continue }
            }
            var orthography: NSOrthography?
            let results = NSSpellChecker.shared.check(
                string, range: range, types: types, options: nil,
                inSpellDocumentWithTag: spellCheckerDocumentTag,
                orthography: &orthography, wordCount: nil)
            setSpellingState(0, range: range)
            for result in filteredCheckingResults(results, orthography: orthography,
                                                  sparing: sparingCaret ? caret : nil) {
                switch result.resultType {
                case .spelling:
                    setSpellingState(NSAttributedString.SpellingState.spelling.rawValue, range: result.range)
                case .grammar:
                    for detail in result.grammarDetails ?? [] {
                        guard let r = detail[NSGrammarRange] as? NSRange else { continue }
                        setSpellingState(NSAttributedString.SpellingState.grammar.rawValue,
                                         range: NSRange(location: result.range.location + r.location, length: r.length))
                    }
                default:
                    break
                }
            }
        }
    }

    // MARK: Spelling and Grammar panel

    /// Check Document Now / the panel's Find Next. AppKit walks the text with
    /// NSSpellChecker directly, never through `handleTextCheckingResults`, so
    /// filter its hit here: step past math and fine enumerations, narrow an
    /// enumeration to its misspelled part.
    public override func checkSpelling(_ sender: Any?) {
        var skipped = Set<Int>()
        while true {
            super.checkSpelling(sender)
            let hit = selectedRange()
            guard hit.length > 0 else { return }
            if let shown = panelHit(hit) {
                if shown != hit {
                    setSelectedRange(shown)
                    scrollRangeToVisible(shown)
                    NSSpellChecker.shared.updateSpellingPanel(
                        withMisspelledWord: (string as NSString).substring(with: shown))
                }
                return
            }
            // Wrapped back to a hit already skipped: only false positives remain.
            guard skipped.insert(hit.location).inserted else { break }
        }
        setSelectedRange(NSRange(location: selectedRange().location, length: 0))
        NSSpellChecker.shared.updateSpellingPanel(withMisspelledWord: "")
    }

    /// Show Spelling and Grammar selects the next misspelling itself; send a
    /// filtered one on to `checkSpelling`.
    public override func showGuessPanel(_ sender: Any?) {
        super.showGuessPanel(sender)
        let hit = selectedRange()
        if hit.length > 0, panelHit(hit) != hit { checkSpelling(sender) }
    }

    /// What the panel should show for AppKit's `hit`: the hit, its misspelled
    /// enumeration part, or nil when the filter drops it.
    private func panelHit(_ hit: NSRange) -> NSRange? {
        guard let idx = blockIndexForRawOffset(hit.location),
              !mathRanges(inBlock: idx).contains(where: { NSIntersectionRange($0, hit).length > 0 })
        else { return nil }
        guard let parts = enumerationMisspellings(of: hit, language: enumerationLanguage(nil)) else { return hit }
        return parts.first
    }

    // MARK: Helpers

    /// Absolute ranges of block `idx`'s math: its `$…$`/`$$…$$` spans, or the
    /// whole block for a display-math block.
    func mathRanges(inBlock idx: Int) -> [NSRange] {
        guard idx < blocks.count else { return [] }
        let block = blocks[idx]
        if block.kind == .mathDisplay { return [block.range] }
        return SyntaxHighlighter.parse(block.content, features: markdownFeatures).compactMap { span in
            guard case .math = span.kind else { return nil }
            return NSRange(location: block.range.location + span.fullRange.location, length: span.fullRange.length)
        }
    }

    /// The language an enumeration's parts are checked in: the user's fixed
    /// choice, or under "Automatic by Language" the text's — left to guess
    /// from a lone `helo`, the checker finds some language that accepts it.
    private func enumerationLanguage(_ orthography: NSOrthography?) -> String {
        let checker = NSSpellChecker.shared
        guard checker.automaticallyIdentifiesLanguages else { return checker.language() }
        return orthography.map(\.dominantLanguage).flatMap { $0 == "und" ? nil : $0 } ?? checker.language()
    }

    /// For a flagged `,`/`;`-joined token of short parts (`a,b,c`,
    /// `i,ii,iii`): the misspelled parts, empty when all are fine. nil when the
    /// token isn't such an enumeration — including `Hello,world`, whose long
    /// parts mean a missing space, which should stay flagged.
    func enumerationMisspellings(of range: NSRange, language: String) -> [NSRange]? {
        let ns = string as NSString
        guard range.location >= 0, NSMaxRange(range) <= ns.length else { return nil }
        let word = ns.substring(with: range)
        guard word.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else { return nil }
        let parts = word.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "," || $0 == ";" })
        guard parts.count > 1, parts.allSatisfy({ $0.utf16.count <= 3 }) else { return nil }
        var misses: [NSRange] = []
        var offset = range.location
        for part in parts {
            let length = part.utf16.count
            if length > 0 {
                let miss = NSSpellChecker.shared.checkSpelling(
                    of: String(part), startingAt: 0, language: language, wrap: false,
                    inSpellDocumentWithTag: spellCheckerDocumentTag, wordCount: nil)
                if miss.location != NSNotFound {
                    misses.append(NSRange(location: offset + miss.location, length: miss.length))
                }
            }
            offset += length + 1   // + the separator
        }
        return misses
    }
}
