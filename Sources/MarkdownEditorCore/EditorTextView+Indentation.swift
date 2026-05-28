import AppKit

// MARK: - Tab / Shift-Tab List Indentation

extension EditorTextView {

    private static let listLineRegex = try! NSRegularExpression(pattern: #"^\s*(?:[-*+]|\d+\.)\s"#)
    static let indentUnit = "  "  // 2 spaces

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
        let rawStart = displayOffsetToRawOffset(sel.location)
        let rawEnd = displayOffsetToRawOffset(sel.location + sel.length)

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
        let rawStart = displayOffsetToRawOffset(sel.location)
        let rawEnd = displayOffsetToRawOffset(sel.location + sel.length)
        let indentLen = (Self.indentUnit as NSString).length

        // Record undo
        undoStack.append(UndoSnapshot(rawSource: rawSource, cursorInRaw: rawStart))
        redoStack.removeAll()
        lastEditType = .other
        lastEditBlockIndex = nil

        // Build new rawSource
        var parts: [String] = []
        for (i, block) in blocks.enumerated() {
            if i >= startBlock && i <= endBlock {
                parts.append(Self.indentUnit + block.content)
            } else {
                parts.append(block.content)
            }
        }
        rawSource = parts.joined(separator: blockSeparator)

        // Cursor in startBlock shifts by 1 indent; rawEnd in endBlock
        // shifts by (endBlock - startBlock + 1) indents (one per block).
        let newRawStart = rawStart + indentLen
        let newRawEnd = rawEnd + indentLen * (endBlock - startBlock + 1)

        blocks = BlockParser.parse(rawSource, previous: blocks)

        if sel.length > 0 {
            let newSel = NSRange(location: newRawStart, length: newRawEnd - newRawStart)
            recompose(cursorInRaw: newRawStart, selectionInRaw: newSel)
        } else {
            recompose(cursorInRaw: newRawStart)
        }
        document?.updateChangeCount(.changeDone)
    }

    // MARK: - Dedent (Shift-Tab)

    private func dedentListBlocks(from startBlock: Int, to endBlock: Int) {
        let sel = selectedRange()
        let rawStart = displayOffsetToRawOffset(sel.location)
        let rawEnd = displayOffsetToRawOffset(sel.location + sel.length)
        let maxRemove = (Self.indentUnit as NSString).length

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
        rawSource = parts.joined(separator: blockSeparator)

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

        blocks = BlockParser.parse(rawSource, previous: blocks)

        if sel.length > 0 {
            let newSel = NSRange(location: newRawStart,
                                 length: max(0, newRawEnd - newRawStart))
            recompose(cursorInRaw: newRawStart, selectionInRaw: newSel)
        } else {
            recompose(cursorInRaw: newRawStart)
        }
        document?.updateChangeCount(.changeDone)
    }
}
