import AppKit

// MARK: - Code block copy button
//
// A copy affordance in the line numbers' slot, level with each fenced code
// block's opening fence — Edit mode's counterpart to the hover-revealed copy
// button Read mode draws on its code blocks. Clicking it puts the block's
// content (the lines between the fences) on the pasteboard.
//
// Everything about where and how it draws is the tables' `</>` button
// (EditorTextView+TableRawButton): the same slot, size and colour, the same
// hover reveal over the block's band, the same margin pass. Edit mode only —
// Source mode draws no code box for it to belong to.

extension EditorTextView {

    // MARK: - Geometry

    /// The button box (view coordinates) and its block index, for every fenced
    /// code block whose opening fence is in the laid-out viewport.
    func visibleCodeCopyButtons() -> [(rect: NSRect, blockIndex: Int)] {
        guard viewMode == .edit else { return [] }
        var fenceLines: [Int: Int] = [:]
        for (i, block) in blocks.enumerated() where block.kind == .fence {
            fenceLines[line(forOffset: block.range.location)] = i
        }
        guard !fenceLines.isEmpty else { return [] }

        let origin = textContainerOrigin
        let padding = textContainer?.lineFragmentPadding ?? 0
        let rightEdge = origin.x + padding - Self.lineNumberPadding
        let size = Self.tableRawButtonSize
        let trailing = lineNumberStyle.digitWidth
        var result: [(rect: NSRect, blockIndex: Int)] = []
        enumerateVisibleLineNumbers { line, capCenterY in
            guard let blockIndex = fenceLines[line] else { return }
            result.append((NSRect(x: rightEdge - trailing - size,
                                  y: origin.y + capCenterY - size / 2,
                                  width: size, height: size), blockIndex))
        }
        return result
    }

    /// The buttons actually on screen: hover reveals one, and one that was
    /// just clicked stays up for its "copied" flash even if the pointer left.
    func revealedCodeCopyButtons() -> [(rect: NSRect, blockIndex: Int)] {
        visibleCodeCopyButtons().filter {
            $0.blockIndex == hoveredCodeBlock || $0.blockIndex == copiedCodeBlock
        }
    }

    /// The text between the fences, with the closing fence dropped when the
    /// block has one. What the button copies.
    func fenceContent(blockIndex: Int) -> String {
        guard blockIndex < blocks.count, blocks[blockIndex].kind == .fence else { return "" }
        var lines = blocks[blockIndex].content.components(separatedBy: "\n")
        lines.removeFirst()
        if let last = lines.last, Self.isClosingFence(last) { lines.removeLast() }
        return lines.joined(separator: "\n")
    }

    /// A fence line: three or more backticks or tildes, nothing else after
    /// the optional indent.
    private static func isClosingFence(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let first = trimmed.first, first == "`" || first == "~" else { return false }
        return trimmed.count >= 3 && trimmed.allSatisfy { $0 == first }
    }

    // MARK: - Drawing

    /// How long the button stays filled after a copy, and how long the outline
    /// takes to cross-fade into the fill at the start of that.
    static let codeCopiedFlashDuration: TimeInterval = 1.2
    static let codeCopiedFadeDuration: TimeInterval = 0.2

    /// Draws the copy buttons, from the same `drawBackground(in:)` pass as the
    /// `</>` buttons and with their ink. A just-copied block's button keeps
    /// the hover background and cross-fades from the outline to the filled
    /// glyph, same ink — the "copied" acknowledgement.
    func drawCodeCopyButtons(in rect: NSRect) {
        let boxes = revealedCodeCopyButtons().filter { $0.rect.intersects(rect) }
        guard !boxes.isEmpty else { return }
        let dim: NSColor = isDarkAppearance ? syntaxDimColor : .secondaryLabelColor
        let config = NSImage.SymbolConfiguration(pointSize: Self.tableRawButtonSize, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [dim]))
        guard let outline = NSImage(systemSymbolName: "document.on.document",
                                    accessibilityDescription: "Copy code")?
                  .withSymbolConfiguration(config),
              let filled = NSImage(systemSymbolName: "document.on.document.fill",
                                   accessibilityDescription: "Copied")?
                  .withSymbolConfiguration(config)
        else { return }

        for (box, blockIndex) in boxes {
            let copied = blockIndex == copiedCodeBlock
            if codeCopyButtonHovered || copied {
                NSColor.quaternaryLabelColor.setFill()
                NSBezierPath(roundedRect: box.insetBy(dx: -3, dy: -3),
                             xRadius: 4, yRadius: 4).fill()
            }
            let fill: CGFloat = copied ? copiedCodeProgress : 0
            // The two glyphs share a footprint, so a plain alpha cross-fade
            // reads as the outline filling in.
            if fill < 1 { draw(outline, in: box, alpha: 1 - fill) }
            if fill > 0 { draw(filled, in: box, alpha: fill) }
        }
    }

    /// Fits a symbol in the box by its own aspect so it isn't squashed square.
    private func draw(_ image: NSImage, in box: NSRect, alpha: CGFloat) {
        let drawn = image.size
        let scale = min(box.width / drawn.width, box.height / drawn.height)
        let fitted = NSSize(width: drawn.width * scale, height: drawn.height * scale)
        image.draw(in: NSRect(x: box.midX - fitted.width / 2, y: box.midY - fitted.height / 2,
                              width: fitted.width, height: fitted.height),
                   from: .zero, operation: .sourceOver, fraction: alpha)
    }

    @objc private func stepCopiedFade(_ link: CADisplayLink) {
        copiedCodeProgress = min(1, copiedCodeProgress + CGFloat(link.duration / Self.codeCopiedFadeDuration))
        needsDisplay = true
        if copiedCodeProgress >= 1 {
            link.invalidate()
            copiedCodeLink = nil
        }
    }

    // MARK: - Pointer tracking

    private func codeCopyButtonHitBox(_ rect: NSRect) -> NSRect {
        rect.insetBy(dx: -4, dy: -4)
    }

    /// Recomputes which code block the pointer is over — the button's slot
    /// across to the right edge of the text column, spanning the block — and
    /// redraws if it changed. Called from `mouseMoved` beside the table hover.
    func updateCodeCopyHover(at point: NSPoint) {
        var block: Int?
        var onButton = false
        for (rect, blockIndex) in visibleCodeCopyButtons() {
            guard let range = blockRowsRect(blockIndex: blockIndex) else { continue }
            let band = NSRect(x: rect.minX, y: range.minY,
                              width: max(0, bounds.maxX - rect.minX), height: range.height)
            if codeCopyButtonHitBox(rect).contains(point) {
                block = blockIndex
                onButton = true
                break
            }
            if band.contains(point) { block = blockIndex }
        }
        guard block != hoveredCodeBlock || onButton != codeCopyButtonHovered else { return }
        hoveredCodeBlock = block
        codeCopyButtonHovered = onButton
        needsDisplay = true
    }

    /// The code block whose copy button is under a mouse event, if any.
    func codeCopyButtonHit(at event: NSEvent) -> Int? {
        let point = convert(event.locationInWindow, from: nil)
        return revealedCodeCopyButtons()
            .first { codeCopyButtonHitBox($0.rect).contains(point) }?.blockIndex
    }

    // MARK: - Activation

    /// Puts the block's content on the general pasteboard and flashes the
    /// button filled for `codeCopiedFlashDuration`.
    func copyCodeBlock(blockIndex: Int, to pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        pasteboard.setString(fenceContent(blockIndex: blockIndex), forType: .string)

        // A display link drives the fade-in (drawBackground has no layer to
        // animate), the way the find "pop" does; a work item ends the hold.
        copiedCodeBlockReset?.cancel()
        copiedCodeLink?.invalidate()
        copiedCodeBlock = blockIndex
        copiedCodeProgress = 0
        let link = displayLink(target: self, selector: #selector(stepCopiedFade))
        link.add(to: .main, forMode: .common)
        copiedCodeLink = link
        let reset = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.copiedCodeLink?.invalidate()
            self.copiedCodeLink = nil
            self.copiedCodeBlock = nil
            self.copiedCodeBlockReset = nil
            self.needsDisplay = true
        }
        copiedCodeBlockReset = reset
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.codeCopiedFlashDuration, execute: reset)
        needsDisplay = true
    }
}
