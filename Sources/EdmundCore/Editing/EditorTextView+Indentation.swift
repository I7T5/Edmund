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
        // In a table, Tab steps to the next cell rather than indenting — and
        // is swallowed at the last cell rather than falling through, since a
        // literal tab in a row is never what was meant.
        if inlineTableCell != nil {
            stepTableCell(by: 1)
            return
        }
        guard let (startBlock, endBlock) = affectedListBlockRange() else {
            super.insertTab(sender)
            return
        }
        indentListBlocks(from: startBlock, to: endBlock)
    }

    public override func insertBacktab(_ sender: Any?) {
        if inlineTableCell != nil {
            stepTableCell(by: -1)
            return
        }
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

    // MARK: - Indent (Tab)

    private func indentListBlocks(from startBlock: Int, to endBlock: Int) {
        let sel = selectedRange()
        let rawStart = sel.location
        let rawEnd = sel.location + sel.length
        let indentLen = (indentUnit as NSString).length

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
                parts.append(indentUnit + block.content)
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
        let maxRemove = indentUnit.count

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
