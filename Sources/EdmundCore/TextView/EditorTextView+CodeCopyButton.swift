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
        let size = codeCopyButtonSize
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

    /// The `</>` button's square — already scaled with the code size, which
    /// the zoom (⌘= / ⌘- / ⌘0) changes, so the glyph keeps its size against
    /// the text it sits beside.
    var codeCopyButtonSize: CGFloat { tableRawButtonSize }

    // MARK: - Drawing

    /// The "copied" acknowledgement, one timeline driven by a display link
    /// (`copiedCodeProgress` 0…1 over `codeCopiedFlashDuration`), in seconds:
    /// on the click the glyph is filled and the background blinks — both at
    /// once, no ramp, the hover fill is already there under the pointer —
    /// the blink eases out (by 0.45), the filled glyph holds, then fades back
    /// to the outline (0.9–1.2).
    static let codeCopiedFlashDuration: TimeInterval = 1.2
    static let codeCopiedBlinkOut: ClosedRange<TimeInterval> = 0...0.45
    static let codeCopiedFillOut: ClosedRange<TimeInterval> = 0.9...1.2

    /// 0…1 across `range`, clamped.
    private static func ramp(_ t: TimeInterval, over range: ClosedRange<TimeInterval>) -> CGFloat {
        CGFloat(min(1, max(0, (t - range.lowerBound) / (range.upperBound - range.lowerBound))))
    }

    /// How filled the glyph is at `progress`: full from the click, fading
    /// back at the end.
    static func copiedFillAlpha(at progress: CGFloat) -> CGFloat {
        1 - ramp(TimeInterval(progress) * codeCopiedFlashDuration, over: codeCopiedFillOut)
    }

    /// Alpha of the background blink at `progress`: full from the click, a
    /// quadratic ease-out to nothing.
    static func copiedPulseAlpha(at progress: CGFloat) -> CGFloat {
        let out = 1 - ramp(TimeInterval(progress) * codeCopiedFlashDuration, over: codeCopiedBlinkOut)
        return out * out
    }

    /// Draws the copy buttons, from the same `drawBackground(in:)` pass as the
    /// `</>` buttons and with their ink.
    func drawCodeCopyButtons(in rect: NSRect) {
        let boxes = revealedCodeCopyButtons().filter { $0.rect.intersects(rect) }
        guard !boxes.isEmpty else { return }
        let dim: NSColor = isDarkAppearance ? syntaxDimColor : .secondaryLabelColor
        let config = NSImage.SymbolConfiguration(pointSize: codeCopyButtonSize, weight: .regular)
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
            let pad = box.insetBy(dx: -3, dy: -3)
            let fill: CGFloat = copied ? Self.copiedFillAlpha(at: copiedCodeProgress) : 0
            // The hover background stays with the filled glyph — the copied
            // state keeps it up (and fades it out with the fill) even after
            // the pointer has left.
            let background: CGFloat = codeCopyButtonHovered ? 1 : fill
            if background > 0 {
                // Context alpha, not `withAlphaComponent`: the semantic colour's
                // own alpha is the tint, and this scales it rather than replaces it.
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current?.cgContext.setAlpha(background)
                NSColor.quaternaryLabelColor.setFill()
                NSBezierPath(roundedRect: pad, xRadius: 4, yRadius: 4).fill()
                NSGraphicsContext.restoreGraphicsState()
            }
            if copied {
                // Two tiers above the hover fill, so it reads over it.
                NSColor.secondaryLabelColor
                    .withAlphaComponent(0.35 * Self.copiedPulseAlpha(at: copiedCodeProgress)).setFill()
                NSBezierPath(roundedRect: pad, xRadius: 4, yRadius: 4).fill()
            }
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

    @objc private func stepCopiedFlash(_ link: CADisplayLink) {
        copiedCodeProgress = min(1, copiedCodeProgress + CGFloat(link.duration / Self.codeCopiedFlashDuration))
        needsDisplay = true
        if copiedCodeProgress >= 1 { endCopiedFlash() }
    }

    /// Back to the resting button. The link's own end, and the tests'.
    func endCopiedFlash() {
        copiedCodeLink?.invalidate()
        copiedCodeLink = nil
        copiedCodeBlock = nil
        copiedCodeProgress = 0
        needsDisplay = true
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

    /// Puts the block's content on the general pasteboard and runs the
    /// "copied" flash.
    func copyCodeBlock(blockIndex: Int, to pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        pasteboard.setString(fenceContent(blockIndex: blockIndex), forType: .string)

        // A display link drives the whole flash (drawBackground has no layer
        // to animate), the way the find "pop" does.
        copiedCodeLink?.invalidate()
        copiedCodeBlock = blockIndex
        copiedCodeProgress = 0
        let link = displayLink(target: self, selector: #selector(stepCopiedFlash))
        link.add(to: .main, forMode: .common)
        copiedCodeLink = link
        needsDisplay = true
    }
}
