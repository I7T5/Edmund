import AppKit

// MARK: - Tab / Shift-Tab List Indentation
//
// Tab / Shift-Tab change the nesting of list items by adding or removing one
// indent unit of leading whitespace. They apply to every list block the
// selection touches (so a whole sub-list can be indented at once) and only kick
// in on list lines — elsewhere Tab inserts a literal tab as usual.

extension EditorTextView {

    private static let listLineRegex = try! NSRegularExpression(pattern: #"^\s*(?:[-*+]|\d+\.)\s"#)
    /// One level of indentation, from the Edit ▸ Editing settings: a tab, or
    /// `indentWidth` spaces. The width is clamped so a bad stored value can
    /// never yield an empty unit (which would make Tab a no-op).
    var indentUnit: String {
        indentUsesTabs ? "\t" : String(repeating: " ", count: min(max(indentWidth, 1), 8))
    }

    /// Guesses a document's indent style from its leading whitespace, for the
    /// Edit ▸ "Detect and learn indent style on document opening" setting.
    /// Returns nil when nothing is indented (so the current settings stand).
    /// Tabs vs spaces is decided by the majority of indented lines; the width is
    /// the smallest space-indent step seen, clamped to 1...8.
    // ponytail: min-step heuristic, no fenced-code exclusion — good enough for v1.
    // Upgrade path if it proves eager: histogram the indent deltas so a stray
    // alignment space doesn't drag the width down, and skip code fences.
    public static func detectIndent(in text: String) -> (usesTabs: Bool, width: Int)? {
        var tabLed = 0
        var spaceCounts: [Int] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            guard let first = line.first, first == " " || first == "\t",
                  line.contains(where: { !$0.isWhitespace }) else { continue }
            if first == "\t" {
                tabLed += 1
            } else {
                spaceCounts.append(line.prefix { $0 == " " }.count)
            }
        }
        guard tabLed + spaceCounts.count > 0 else { return nil }
        if tabLed >= spaceCounts.count { return (true, 4) }   // width unused for tabs
        return (false, min(max(spaceCounts.min() ?? 4, 1), 8))
    }

    /// Returns true if the line looks like a markdown list item
    /// (optionally indented): `- `, `* `, `+ `, `1. `, etc.
    func isListLine(_ line: String) -> Bool {
        let range = NSRange(location: 0, length: (line as NSString).length)
        return Self.listLineRegex.firstMatch(in: line, range: range) != nil
    }

    // MARK: - Key Overrides

    public override func insertTab(_ sender: Any?) {
        guard let (startBlock, endBlock) = affectedListBlockRange() else {
            super.insertTab(sender)
            return
        }
        indentListBlocks(from: startBlock, to: endBlock)
    }

    public override func insertBacktab(_ sender: Any?) {
        guard let (startBlock, endBlock) = affectedListBlockRange() else {
            return
        }
        dedentListBlocks(from: startBlock, to: endBlock)
    }

    // MARK: - Block Range Detection

    /// Returns the inclusive range of block indices covered by the current
    /// selection, but only if every covered block is a list line.
    private func affectedListBlockRange() -> (Int, Int)? {
        let sel = selectedRange()
        let rawStart = sel.location
        let rawEnd = sel.location + sel.length

        guard let startIdx = blockIndexForRawOffset(rawStart),
              var endIdx = blockIndexForRawOffset(rawEnd) else {
            return nil
        }

        // If the selection end lands exactly on the first character of a
        // block, that block isn't meaningfully selected — exclude it.
        if sel.length > 0 && endIdx > startIdx && endIdx < blocks.count
            && rawEnd == blocks[endIdx].range.location {
            endIdx -= 1
        }

        for i in startIdx...endIdx {
            guard i < blocks.count, isListLine(blocks[i].content) else {
                return nil
            }
        }

        return (startIdx, endIdx)
    }

    // MARK: - Nesting Columns
    //
    // A fixed `indentUnit` is not always enough to nest. CommonMark starts a
    // child list only at (or past) the parent item's *content* column — 2 for
    // "- ", 3 for "2. ", 4 for "10. " — so the default 2-space unit under an
    // ordered marker writes a sibling, not a child. The editor derives depth
    // from leading whitespace and draws that as nested anyway, while Read mode
    // (and GitHub, and pandoc) parse it flat. Pad Tab out to the previous
    // sibling's content column so the bytes mean what the editor draws.
    //
    // ponytail: this fixes what Tab writes, not how depth is read back.
    // `listDepth` is still `columns / listIndentUnit`, which can't model a
    // required indent that varies by marker width — so a document that mixes
    // 2-column bullet nesting with 3-column ordered nesting can still have a
    // deep item drawn one level off. Upgrade path if that shows up in a real
    // document: derive depth by walking preceding list lines with a column
    // stack instead of dividing.

    /// Marker plus the spaces after it — everything before an item's content.
    /// Spaces-indented lines only; tab-indented ones are handled by the callers.
    private static let listContentColumnRegex =
        try! NSRegularExpression(pattern: #"^ *(?:[-*+]|\d{1,9}[.)])( +)"#)

    private func leadingSpaces(_ line: String) -> Int {
        line.prefix(while: { $0 == " " }).count
    }

    /// Column where `line`'s content starts — where CommonMark requires a child
    /// list to begin — or nil if it isn't a spaces-indented list line. More than
    /// four spaces after the marker open an indented code block inside the item
    /// rather than widening it, so the run counts for at most four.
    private func listContentColumn(_ line: String) -> Int? {
        let ns = line as NSString
        guard let m = Self.listContentColumnRegex.firstMatch(
            in: line, range: NSRange(location: 0, length: ns.length)) else { return nil }
        let spaces = m.range(at: 1).length
        return m.range.length - spaces + min(spaces, 4)
    }

    /// Content column of the list line the block at `index` would become a child
    /// of when indented — its nearest preceding sibling at the same column. nil
    /// when there is none, so there is nothing to nest under and `indentUnit`
    /// stands.
    private func nestingTargetColumn(before index: Int) -> Int? {
        let content = blocks[index].content
        guard !content.hasPrefix("\t") else { return nil }
        let cols = leadingSpaces(content)
        var i = index - 1
        while i >= 0 {
            let line = blocks[i].content
            guard isListLine(line), !line.hasPrefix("\t") else { return nil }
            let c = leadingSpaces(line)
            if c < cols { return nil }              // that's the parent, not a sibling
            if c == cols { return listContentColumn(line) }
            i -= 1                                  // deeper: a nephew, keep looking
        }
        return nil
    }

    /// The whitespace one Tab prepends to every block in the affected range.
    /// One string for the whole range, so relative nesting inside it is kept.
    private func indentString(from startBlock: Int) -> String {
        guard !indentUsesTabs,
              let target = nestingTargetColumn(before: startBlock) else { return indentUnit }
        let cols = leadingSpaces(blocks[startBlock].content)
        return String(repeating: " ", count: max(indentUnit.count, target - cols))
    }

    /// Columns one Shift-Tab strips, mirroring `indentString(from:)`: back to
    /// the nearest shallower list line's column, so a padded indent undoes
    /// cleanly instead of leaving an orphan space — which would drag the
    /// document-wide `listIndentUnit` down to 1 and re-depth every list.
    private func dedentColumns(from startBlock: Int) -> Int {
        let content = blocks[startBlock].content
        guard !content.hasPrefix("\t") else { return indentUnit.count }
        let cols = leadingSpaces(content)
        guard cols > 0 else { return indentUnit.count }
        var i = startBlock - 1
        while i >= 0 {
            let line = blocks[i].content
            guard isListLine(line), !line.hasPrefix("\t") else { break }
            let c = leadingSpaces(line)
            if c < cols { return cols - c }
            i -= 1
        }
        // Nothing shallower to return to, so there was no padding to mirror:
        // step by the plain unit, as a ragged/orphan indent always has.
        return indentUnit.count
    }

    // MARK: - Indent (Tab)

    private func indentListBlocks(from startBlock: Int, to endBlock: Int) {
        let sel = selectedRange()
        let rawStart = sel.location
        let rawEnd = sel.location + sel.length
        let indent = indentString(from: startBlock)
        let indentLen = (indent as NSString).length

        // The pre-edit storage span covering exactly the affected blocks; only
        // this is replaced so layout above/below — and the viewport — is kept.
        let oldRange = NSRange(
            location: blocks[startBlock].range.location,
            length: blocks[endBlock].range.upperBound - blocks[startBlock].range.location)

        // Record undo
        undoStack.append(UndoSnapshot(rawSource: rawSource, cursorInRaw: rawStart))
        redoStack.removeAll()
        lastEditType = .other
        lastEditBlockIndex = nil

        // Build new rawSource
        var parts: [String] = []
        for (i, block) in blocks.enumerated() {
            if i >= startBlock && i <= endBlock {
                parts.append(indent + block.content)
            } else {
                parts.append(block.content)
            }
        }
        let newText = parts[startBlock...endBlock].joined(separator: blockSeparator)
        let oldIndentUnit = listIndentUnit
        rawSource = parts.joined(separator: blockSeparator)
        rebuildListIndentState()
        rebuildLinkDefState()

        // Cursor in startBlock shifts by 1 indent; rawEnd in endBlock
        // shifts by (endBlock - startBlock + 1) indents (one per block).
        let newRawStart = rawStart + indentLen
        let newRawEnd = rawEnd + indentLen * (endBlock - startBlock + 1)

        blocks = BlockParser.parse(rawSource, previous: blocks, features: markdownFeatures)

        let selInRaw = sel.length > 0
            ? NSRange(location: newRawStart, length: newRawEnd - newRawStart) : nil
        stabilizingViewport {
            recomposeReplacing(oldRange: oldRange, with: newText,
                               dirty: indentDirtySet(startBlock, endBlock,
                                                     unitChanged: listIndentUnit != oldIndentUnit),
                               cursorInRaw: newRawStart, selectionInRaw: selInRaw)
        }
        // The indented blocks changed depth: they may now belong to a
        // different ordered run (or start a new one), and the old depth's
        // remaining siblings lost a member — both need renumbering.
        renumberOrderedListRunsIfNeeded(touching: startBlock..<(endBlock + 1),
                                        depthChanged: Set(startBlock...endBlock))
        document?.updateChangeCount(.changeDone)
    }

    /// Blocks to restyle for an indent/dedent: the directly-edited span, plus —
    /// when the document-global list indent unit moved — every list block,
    /// whose rendered indentation is derived from that unit.
    private func indentDirtySet(_ startBlock: Int, _ endBlock: Int,
                                unitChanged: Bool) -> IndexSet {
        var dirty = IndexSet(integersIn: startBlock...min(endBlock, blocks.count - 1))
        if unitChanged {
            for (i, block) in blocks.enumerated() where block.kind == .listItem {
                dirty.insert(i)
            }
        }
        return dirty
    }

    // MARK: - Dedent (Shift-Tab)

    private func dedentListBlocks(from startBlock: Int, to endBlock: Int) {
        let sel = selectedRange()
        let rawStart = sel.location
        let rawEnd = sel.location + sel.length
        let maxRemove = dedentColumns(from: startBlock)

        // Compute how many leading whitespace characters to strip from each block.
        var removed: [Int] = Array(repeating: 0, count: blocks.count)
        for i in startBlock...endBlock {
            let content = blocks[i].content
            if content.hasPrefix("\t") {
                removed[i] = 1
            } else {
                let leading = content.prefix(while: { $0 == " " }).count
                removed[i] = min(leading, maxRemove)
            }
        }

        let totalRemoved = removed[startBlock...endBlock].reduce(0, +)
        guard totalRemoved > 0 else { return }

        // The pre-edit storage span covering exactly the affected blocks; only
        // this is replaced so layout above/below — and the viewport — is kept.
        let oldRange = NSRange(
            location: blocks[startBlock].range.location,
            length: blocks[endBlock].range.upperBound - blocks[startBlock].range.location)

        // Record undo
        undoStack.append(UndoSnapshot(rawSource: rawSource, cursorInRaw: rawStart))
        redoStack.removeAll()
        lastEditType = .other
        lastEditBlockIndex = nil

        // Build new rawSource
        var parts: [String] = []
        for (i, block) in blocks.enumerated() {
            if i >= startBlock && i <= endBlock {
                parts.append(String(block.content.dropFirst(removed[i])))
            } else {
                parts.append(block.content)
            }
        }
        let newText = parts[startBlock...endBlock].joined(separator: blockSeparator)
        let oldIndentUnit = listIndentUnit
        rawSource = parts.joined(separator: blockSeparator)
        rebuildListIndentState()
        rebuildLinkDefState()

        // Adjust rawStart (in startBlock).  No blocks before startBlock
        // were modified, so its start position is unchanged.
        let startOff = rawStart - blocks[startBlock].range.location
        let newRawStart = blocks[startBlock].range.location
            + max(0, startOff - removed[startBlock])

        // Adjust rawEnd (in endBlock).  Every indented block before
        // endBlock shifted its start position left.
        var cumulativeBefore = 0
        for i in startBlock..<endBlock {
            cumulativeBefore += removed[i]
        }
        let endBlockNewStart = blocks[endBlock].range.location - cumulativeBefore
        let endOff = rawEnd - blocks[endBlock].range.location
        let newRawEnd = endBlockNewStart + max(0, endOff - removed[endBlock])

        blocks = BlockParser.parse(rawSource, previous: blocks, features: markdownFeatures)

        let selInRaw = sel.length > 0
            ? NSRange(location: newRawStart, length: max(0, newRawEnd - newRawStart)) : nil
        stabilizingViewport {
            recomposeReplacing(oldRange: oldRange, with: newText,
                               dirty: indentDirtySet(startBlock, endBlock,
                                                     unitChanged: listIndentUnit != oldIndentUnit),
                               cursorInRaw: newRawStart, selectionInRaw: selInRaw)
        }
        // The dedented blocks changed depth: they may now belong to a
        // different ordered run (or merge into an existing one), and the
        // old depth's remaining siblings lost a member — both need renumbering.
        renumberOrderedListRunsIfNeeded(touching: startBlock..<(endBlock + 1),
                                        depthChanged: Set(startBlock...endBlock))
        document?.updateChangeCount(.changeDone)
    }
}
