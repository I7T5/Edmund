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

    /// The "copied" acknowledgement, in seconds — SF Symbols' off-up Replace
    /// ("emphasizes the next state"): on the click the copy glyph and the hover
    /// fill fade out fast (0–0.1) and a semibold `checkmark` Appears (scaling
    /// up); it holds, Disappears (scaling down) at `codeCopiedRelease`, and
    /// the glyph and fill fade back together as fast (1.4–1.5). The checkmark
    /// keeps the glyph's ink, not the accent: the accent means interactive or
    /// selected here (links, checked tasks, the caret), and HIG Color asks not
    /// to use one colour for two meanings.
    /// The checkmark's motion is the system's own (and its Reduce Motion
    /// fallback), played by a transient image view over the button —
    /// `drawBackground` has no layer to animate. That view only ever holds
    /// the checkmark: a Replace inside one view recolours the outgoing symbol
    /// with the incoming one's ink, and a copy glyph handed between the view
    /// and `drawBackground` doesn't render identically. A display link times
    /// the rest (`copiedCodeProgress` 0…1 over `codeCopiedFlashDuration`).
    static let codeCopiedFlashDuration: TimeInterval = 1.55
    static let codeCopiedRelease: TimeInterval = 1.3
    static let codeCopiedFadeOut: ClosedRange<TimeInterval> = 0...0.1
    static let codeCopiedFadeIn: ClosedRange<TimeInterval> = 1.4...1.5

    /// 0…1 across `range`, clamped.
    private static func ramp(_ t: TimeInterval, over range: ClosedRange<TimeInterval>) -> CGFloat {
        CGFloat(min(1, max(0, (t - range.lowerBound) / (range.upperBound - range.lowerBound))))
    }

    /// Alpha of the copy glyph and the hover fill at `progress`: out fast from
    /// the click, back once the checkmark has Disappeared.
    static func copiedChromeAlpha(at progress: CGFloat) -> CGFloat {
        let t = TimeInterval(progress) * codeCopiedFlashDuration
        return max(1 - ramp(t, over: codeCopiedFadeOut), ramp(t, over: codeCopiedFadeIn))
    }

    /// The button's symbol at `pointSize`, in the `</>` ink unless a colour is given.
    private func codeCopySymbol(_ name: String, pointSize: CGFloat, color: NSColor? = nil,
                                weight: NSFont.Weight = .regular) -> NSImage? {
        let ink: NSColor = color ?? (isDarkAppearance ? syntaxDimColor : .secondaryLabelColor)
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
                .applying(.init(paletteColors: [ink])))
    }

    /// The point size at which the copy glyph fits the button's square. The
    /// glyph is rendered at that size, not scaled down to it: SF Symbols
    /// thickens strokes at small sizes, so a scaled-down glyph comes out
    /// thinner and lighter than the flash's image view renders it, and the
    /// hand-off between the two would jump.
    private var codeCopyGlyphPointSize: CGFloat {
        let size = codeCopyButtonSize
        guard let full = codeCopySymbol("document.on.document", pointSize: size) else { return size }
        return size * min(size / full.size.width, size / full.size.height)
    }

    /// Draws the copy buttons, from the same `drawBackground(in:)` pass as the
    /// `</>` buttons and with their ink.
    func drawCodeCopyButtons(in rect: NSRect) {
        let boxes = revealedCodeCopyButtons().filter { $0.rect.intersects(rect) }
        guard !boxes.isEmpty,
              let copy = codeCopySymbol("document.on.document", pointSize: codeCopyGlyphPointSize)
        else { return }

        for (box, blockIndex) in boxes {
            let chrome = blockIndex == copiedCodeBlock ? Self.copiedChromeAlpha(at: copiedCodeProgress) : 1
            guard chrome > 0 else { continue }
            if codeCopyButtonHovered {
                // Context alpha, not `withAlphaComponent`: the semantic colour's
                // own alpha is the tint, and this scales it rather than replaces it.
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current?.cgContext.setAlpha(chrome)
                NSColor.quaternaryLabelColor.setFill()
                NSBezierPath(roundedRect: box.insetBy(dx: -3, dy: -3), xRadius: 4, yRadius: 4).fill()
                NSGraphicsContext.restoreGraphicsState()
            }
            draw(copy, centredIn: box, alpha: chrome)
        }
    }

    /// Draws a symbol at its own size, centred in the box. `respectFlipped`:
    /// the text view is flipped, and unlike the one-argument `draw(in:)` this
    /// overload would otherwise paint the symbol upside down.
    private func draw(_ image: NSImage, centredIn box: NSRect, alpha: CGFloat) {
        let size = image.size
        image.draw(in: NSRect(x: box.midX - size.width / 2, y: box.midY - size.height / 2,
                              width: size.width, height: size.height),
                   from: .zero, operation: .sourceOver, fraction: alpha,
                   respectFlipped: true, hints: nil)
    }

    @objc private func stepCopiedFlash(_ link: CADisplayLink) {
        let release = CGFloat(Self.codeCopiedRelease / Self.codeCopiedFlashDuration)
        let before = copiedCodeProgress
        copiedCodeProgress = min(1, copiedCodeProgress + CGFloat(link.duration / Self.codeCopiedFlashDuration))
        if before < release, copiedCodeProgress >= release {
            copiedGlyphView?.addSymbolEffect(.disappear.down)
        }
        needsDisplay = true
        if copiedCodeProgress >= 1 { endCopiedFlash() }
    }

    /// Back to the resting button. The link's own end, and the tests'.
    func endCopiedFlash() {
        copiedCodeLink?.invalidate()
        copiedCodeLink = nil
        copiedGlyphView?.removeFromSuperview()
        copiedGlyphView = nil
        copiedCodeBlock = nil
        copiedCodeProgress = 0
        needsDisplay = true
    }

    // MARK: - Pointer tracking

    func codeCopyButtonHitBox(_ rect: NSRect) -> NSRect {
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
        refreshHoverButtonToolTips()
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

        endCopiedFlash()
        copiedCodeBlock = blockIndex
        // The glyph's own ink, semibold: a lone stroke has far less ink than
        // the two stacked pages, and a stronger colour read as too loud.
        if let box = visibleCodeCopyButtons().first(where: { $0.blockIndex == blockIndex })?.rect,
           let check = codeCopySymbol("checkmark", pointSize: codeCopyGlyphPointSize, weight: .semibold) {
            // Twice the box, centred on it: room for the Appear's overshoot
            // without clipping.
            let view = CopiedGlyphView(frame: box.insetBy(dx: -box.width / 2, dy: -box.height / 2))
            view.imageScaling = .scaleNone
            view.image = check
            view.addSymbolEffect(.disappear, animated: false)
            addSubview(view)
            view.addSymbolEffect(.appear.up)
            copiedGlyphView = view
        }

        // A display link times the flash, the way the find "pop" does.
        let link = displayLink(target: self, selector: #selector(stepCopiedFlash))
        link.add(to: .main, forMode: .common)
        copiedCodeLink = link
        needsDisplay = true
    }
}

/// The "copied" checkmark over the copy button, while the flash plays its
/// Appear and Disappear. Invisible to the pointer and to VoiceOver — the
/// button underneath is drawn, and the text view takes its clicks.
final class CopiedGlyphView: NSImageView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
