import AppKit

// MARK: - Display Composition & Coordinate Mapping

extension EditorTextView {

    // MARK: - Display Composition
    //
    // Text storage content = rawSource, always.
    // Styling is attribute-only; the string never changes during recompose.

    func recompose(cursorInRaw: Int, selectionInRaw: NSRange? = nil) {
        isUpdating = true

        activeBlockIndex = blockIndexForRawOffset(cursorInRaw)

        // Build styled attributed string from rawSource.
        // The string content IS rawSource — no delimiter stripping.
        let composed = NSMutableAttributedString(string: rawSource, attributes: baseAttributes)

        for (i, block) in blocks.enumerated() {
            guard block.range.upperBound <= composed.length else { continue }

            // Cursor position within this block (nil for non-active blocks)
            let cursorInBlock: Int?
            if i == activeBlockIndex {
                cursorInBlock = max(0, cursorInRaw - block.range.location)
            } else {
                cursorInBlock = nil
            }

            let styled = styleBlock(block.content, cursorPosition: cursorInBlock)

            // Apply attributes from the styled block onto the composed string
            styled.enumerateAttributes(
                in: NSRange(location: 0, length: styled.length), options: []
            ) { attrs, range, _ in
                let tsRange = NSRange(
                    location: range.location + block.range.location,
                    length: range.length
                )
                guard tsRange.upperBound <= composed.length else { return }
                composed.setAttributes(attrs, range: tsRange)
            }
        }

        let fullRange = NSRange(location: 0, length: textStorage!.length)
        textStorage?.beginEditing()
        textStorage?.replaceCharacters(in: fullRange, with: composed)
        textStorage?.endEditing()

        // displayRanges = block ranges (identity mapping)
        displayRanges = blocks.map { $0.range }

        // Cursor placement: display offset = raw offset (identity)
        if let rawSel = selectionInRaw, rawSel.length > 0 {
            let len = textStorage!.length
            let displaySel = NSRange(
                location: min(rawSel.location, len),
                length: max(0, min(rawSel.upperBound, len) - min(rawSel.location, len))
            )
            setSelectedRange(displaySel)
        } else {
            let clamped = min(cursorInRaw, textStorage!.length)
            setSelectedRange(NSRange(location: clamped, length: 0))
        }

        typingAttributes = baseAttributes

        isUpdating = false
    }

    /// Recalculates displayRanges from current blocks.
    /// With word-level rendering, display ranges = raw block ranges.
    func recalcDisplayRanges() {
        displayRanges = blocks.map { $0.range }
    }

    // MARK: - Coordinate Mapping
    //
    // With text storage = rawSource, display offset = raw offset (identity).

    func blockIndexForRawOffset(_ rawOffset: Int) -> Int? {
        for (i, block) in blocks.enumerated() {
            if rawOffset >= block.range.location && rawOffset <= block.range.upperBound {
                return i
            }
        }
        return blocks.isEmpty ? nil : blocks.count - 1
    }

    func displayOffsetToRawOffset(_ displayOffset: Int) -> Int {
        return displayOffset
    }

    func rawOffsetToDisplayOffset(_ rawOffset: Int) -> Int {
        return rawOffset
    }

    func displayRangeToRawRange(_ displayRange: NSRange) -> NSRange {
        return displayRange
    }
}
