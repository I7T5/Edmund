import AppKit

// MARK: - Spell Check
//
// AppKit's continuous checker runs over the raw markdown (storage ==
// rawSource), which trips it three ways. The first two are fixed by filtering
// its results (`filteredCheckingResults`) before they become marks:
//   - Math: `\mathrm` in `$…$` / `$$…$$` gets flagged, and under a rendered
//     formula the mark draws beneath the hidden source. Math spans are skipped.
//   - Inline enumerations: NSSpellChecker reads `a,b,c` / `x;y` / `i,ii,iii`
//     as ONE word and flags it. Such a token is re-checked part by part, so
//     only a genuinely misspelled part (`a,helo`) stays marked.
// The third is stale marks: restyles are attribute-only, so AppKit never
// re-checks a word it skipped while the caret sat in it — fixing `Helo` into
// `Hello` left the old mark, split around the new letter, until the next edit
// there. `recomposeDirty` calls `recheckSpelling` on every block it restyled.
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
    /// results; `sparing` also drops the misspelling touching that offset (the
    /// word still being typed).
    func filteredCheckingResults(_ results: [NSTextCheckingResult], orthography: NSOrthography?,
                                 sparing caret: Int?) -> [NSTextCheckingResult] {
        // An enumeration's parts are checked in the text's language: left to
        // guess from a lone `helo`, the checker finds some language that
        // accepts it.
        let language = orthography.map(\.dominantLanguage).flatMap { $0 == "und" ? nil : $0 }
            ?? NSSpellChecker.shared.language()
        var kept: [NSTextCheckingResult] = []
        for result in results {
            switch result.resultType {
            case .spelling:
                if let caret, result.range.location <= caret, caret <= result.range.upperBound { continue }
                guard !rangeIsInMath(result.range) else { continue }
                kept += misspelledParts(of: result.range, language: language).map {
                    NSTextCheckingResult.spellCheckingResult(range: $0)
                }
            case .grammar:
                if !rangeIsInMath(result.range) { kept.append(result) }
            default:
                kept.append(result)
            }
        }
        return kept
    }

    /// Re-checks spelling (and grammar, when on) over the given blocks and
    /// redraws their marks, one check per contiguous run so a caret jump from
    /// the top of the document to the bottom doesn't check everything between.
    ///
    /// Synchronous and marks set directly, rather than `checkText(in:)`: that
    /// delivers on a later run-loop pass (too late to spare the caret's word by
    /// the caret position it was checked at), and `super.handleTextCheckingResults`
    /// was measured not to mark anything for results handed to it directly.
    func recheckSpelling(blocks indices: IndexSet) {
        guard isContinuousSpellCheckingEnabled, !hasMarkedText(), let ts = textStorage else { return }
        var types = NSTextCheckingResult.CheckingType.spelling.rawValue
        if isGrammarCheckingEnabled { types |= NSTextCheckingResult.CheckingType.grammar.rawValue }
        let sel = selectedRange()
        let caret = sel.length == 0 ? sel.location : nil
        for run in indices.rangeView where run.lowerBound < blocks.count {
            let start = blocks[run.lowerBound].range.location
            let end = min(blocks[min(run.upperBound, blocks.count) - 1].range.upperBound, ts.length)
            // ponytail: a huge block (a long fence) would be re-checked whole on
            // every keystroke; skip it and leave it to AppKit's own pass. Check
            // just the caret's paragraph if big blocks ever need this too.
            guard end > start, end - start <= 20_000 else { continue }
            let range = NSRange(location: start, length: end - start)
            var orthography: NSOrthography?
            let results = NSSpellChecker.shared.check(
                string, range: range, types: types, options: nil,
                inSpellDocumentWithTag: spellCheckerDocumentTag,
                orthography: &orthography, wordCount: nil)
            setSpellingState(0, range: range)
            for result in filteredCheckingResults(results, orthography: orthography, sparing: caret) {
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

    /// Whether `range` touches a `$…$`/`$$…$$` span or a display-math block.
    func rangeIsInMath(_ range: NSRange) -> Bool {
        guard let idx = blockIndexForRawOffset(range.location) else { return false }
        let block = blocks[idx]
        if block.kind == .mathDisplay { return true }
        let local = NSRange(location: range.location - block.range.location, length: range.length)
        guard local.location >= 0 else { return false }
        return SyntaxHighlighter.parse(block.content, features: markdownFeatures).contains { span in
            guard case .math = span.kind else { return false }
            return NSIntersectionRange(span.fullRange, local).length > 0
        }
    }

    /// The misspelled pieces of a flagged token: the token itself, unless it
    /// is a `,`/`;`-joined enumeration, in which case each part is checked on
    /// its own and only the misspelled ones come back.
    func misspelledParts(of range: NSRange, language: String) -> [NSRange] {
        let ns = string as NSString
        guard range.location >= 0, NSMaxRange(range) <= ns.length else { return [range] }
        let word = ns.substring(with: range) as NSString
        let separators = CharacterSet(charactersIn: ",;")
        guard word.rangeOfCharacter(from: separators).location != NSNotFound else { return [range] }
        var parts: [NSRange] = []
        var start = 0
        for i in 0 ... word.length {
            guard i == word.length || separators.contains(Unicode.Scalar(word.character(at: i)) ?? " ") else { continue }
            if i > start {
                let part = word.substring(with: NSRange(location: start, length: i - start))
                let miss = NSSpellChecker.shared.checkSpelling(
                    of: part, startingAt: 0, language: language, wrap: false,
                    inSpellDocumentWithTag: spellCheckerDocumentTag, wordCount: nil)
                if miss.location != NSNotFound {
                    parts.append(NSRange(location: range.location + start + miss.location, length: miss.length))
                }
            }
            start = i + 1
        }
        return parts
    }
}
