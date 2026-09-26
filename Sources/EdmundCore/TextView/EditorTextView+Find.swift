import AppKit

/// Implemented by the app-side find controller (edmd's FindController). The
/// editor forwards menu/keyboard find commands here so EdmundCore stays
/// unaware of the concrete controller — same decoupling as
/// `contextFontMenuProvider`.
@MainActor public protocol EditorFindHandling: AnyObject {
    /// ⌘F / ⌥⌘F. Both *toggle*: the requested bar opens, or closes if it is
    /// already the one showing.
    func editorToggleFind(replace: Bool)
    func editorFindNext()
    func editorFindPrevious()
    func editorHideFind()
}

private extension NSRect {
    /// Scales the rect about its own centre.
    func scaled(by s: CGFloat) -> NSRect {
        NSRect(x: midX - width * s / 2, y: midY - height * s / 2,
               width: width * s, height: height * s)
    }
}

extension EditorTextView {

    // MARK: - Match state

    /// Replaces the current match set and requests a redraw. Draw-only — never
    /// touches storage or the selection, so it can't perturb the edit/recompose
    /// pipeline or the storage == rawSource invariant.
    public func setFindMatches(_ matches: [NSRange], current: Int?) {
        findMatches = matches
        currentMatchIndex = current
        findActive = true
        needsDisplay = true
    }

    /// Clears find highlighting (bar closed).
    public func clearFindMatches() {
        guard findActive || !findMatches.isEmpty else { return }
        findMatches = []
        currentMatchIndex = nil
        findActive = false
        stopEmphasis()
        needsDisplay = true
    }

    /// Reveals the match at `index` without moving the caret (a selection change
    /// would trigger the active-block-renders-raw recompose). Already-visible
    /// matches don't move the viewport; otherwise the match's line goes to the
    /// top, so a document jump lands the hit predictably rather than at an edge.
    /// Also fires the pop animation on the freshly-focused match.
    public func revealFindMatch(_ index: Int) {
        guard findMatches.indices.contains(index) else { return }
        let range = findMatches[index]
        let origin = enclosingScrollView?.contentView.bounds.origin ?? .zero
        if !rangeIsVisible(range, forViewportOrigin: origin) {
            scrollCharacterToTop(range.location)
        }
        emphasize(range)
    }

    // MARK: - Highlight drawing

    /// Paints a grey background behind every match (CotEditor-style), plus a
    /// yellow "pop" box on the match just navigated to: a rounded rect a touch
    /// larger than the text that swells slightly and fades out. Draw-only, on the
    /// background pass (behind the glyphs, so the text stays legible through the
    /// pop) and bounded to the laid-out viewport so many scattered hits don't
    /// force whole-document layout on every frame.
    public override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        // One geometry pass shared by every piece of margin chrome below: the
        // visible lines, the viewport's tables and code blocks, and the active
        // cell's handles. Each used to recompute this itself — several viewport
        // fragment walks and full block-list scans per redraw.
        let chrome = marginChromeGeometry(includeLineNumbers: showLineNumbers)
        // Line numbers in the column's margin ride this same pass (they are
        // beside the text, never under it). See EditorTextView+LineNumbers.
        // Whether they actually fit — and so whether the gutter has them
        // instead — is decided inside.
        if showLineNumbers { drawLineNumbersBesideContent(in: rect, chrome: chrome) }
        // The tables' `</>` raw-editing buttons ride the same margin pass, and
        // step left of the numbers when both are in it. See
        // EditorTextView+TableRawButton.
        drawTableRawButtons(in: rect, chrome: chrome)
        drawCodeCopyButtons(in: rect, chrome: chrome)
        // A wrapped table cell's real characters are hidden at ~zero width, so
        // AppKit's caret and highlight land nowhere near the text the user sees
        // — the cell draws its own. Same pass, same reason: behind the glyphs.
        // See EditorTextView+TableCellCaret.
        drawWrappedCellChrome(in: rect)
        // The active cell's row and column handles, and the outline around
        // whichever cell a table context menu is acting on.
        // See EditorTextView+TableHandles.
        drawTableHandles(in: rect, chrome: chrome)
        guard findActive, !findMatches.isEmpty, let tlm = textLayoutManager else { return }

        let visible = viewportCharRange(tlm)
        // Layout-fragment frames are in text-container space; the view offsets
        // them by textContainerOrigin (which also carries the content-width
        // centering). Translate to draw in view coordinates.
        let origin = textContainerOrigin

        // Grey resting background for every visible match.
        NSColor.unemphasizedSelectedTextBackgroundColor.setFill()
        for match in findMatches {
            if let visible, NSIntersectionRange(visible, match).length == 0 { continue }
            guard let tr = blockTextRange(match, tlm) else { continue }
            tlm.enumerateTextSegments(in: tr, type: .highlight, options: []) { _, frame, _, _ in
                let r = frame.offsetBy(dx: origin.x, dy: origin.y)
                if r.intersects(rect) { r.fill() }
                return true
            }
        }

        // Pop box over the emphasised match (Preview-style): springs in from a
        // larger scale with a bouncy overshoot, holds, then fades out. The box
        // hugs the match text, so it's naturally variable-length.
        guard let em = emphasisRange, emphasisProgress < 1,
              let tr = blockTextRange(em, tlm) else { return }
        let elapsed = emphasisProgress * Self.emphasisDuration
        let scale = elapsed < Self.emphasisSpring
            ? Self.startScale + (1 - Self.startScale) * easeOutBack(elapsed / Self.emphasisSpring)
            : 1
        let alpha = elapsed < Self.emphasisHold
            ? 1
            : max(0, 1 - (elapsed - Self.emphasisHold) / Self.emphasisFade)

        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.35 * alpha)   // fades with the box
        shadow.shadowOffset = NSSize(width: 0, height: -1.5)                   // flipped view: downward
        shadow.shadowBlurRadius = 4
        shadow.set()
        NSColor.findHighlightColor.withAlphaComponent(alpha).setFill()
        tlm.enumerateTextSegments(in: tr, type: .highlight, options: []) { _, frame, _, _ in
            // Base box hugs the text (2pt padding); scale it about its centre.
            let base = frame.offsetBy(dx: origin.x, dy: origin.y).insetBy(dx: -2, dy: -2)
            let box = base.scaled(by: scale)
            if box.intersects(rect) {
                NSBezierPath(roundedRect: box, xRadius: 4, yRadius: 4).fill()
            }
            return true
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    /// Overshooting ease (0→1, briefly passing 1) — the source of the bounce.
    private func easeOutBack(_ t: CGFloat) -> CGFloat {
        let c1: CGFloat = 1.70158, c3 = c1 + 1
        let u = t - 1
        return 1 + c3 * u * u * u + c1 * u * u
    }

    // MARK: - Pop animation

    /// The box springs in over `emphasisSpring` (from `startScale` down to 1,
    /// overshooting for the bounce), stays full until `emphasisHold`, then fades
    /// over `emphasisFade`. `emphasisSpring` must be ≤ `emphasisHold`.
    private static let emphasisSpring: CFTimeInterval = 0.35
    private static let emphasisHold: CFTimeInterval = 0.6
    private static let emphasisFade: CFTimeInterval = 0.1
    private static let startScale: CGFloat = 1.6
    private static var emphasisDuration: CFTimeInterval { emphasisHold + emphasisFade }

    /// Starts (or restarts) the pop on `range`, driven by a display link so it
    /// stays smooth without a manual timer.
    private func emphasize(_ range: NSRange) {
        emphasisLink?.invalidate()
        emphasisRange = range
        emphasisProgress = 0
        let link = displayLink(target: self, selector: #selector(stepEmphasis))
        link.add(to: .main, forMode: .common)
        emphasisLink = link
        needsDisplay = true
    }

    private func stopEmphasis() {
        emphasisLink?.invalidate()
        emphasisLink = nil
        emphasisRange = nil
        emphasisProgress = 0
    }

    @objc private func stepEmphasis(_ link: CADisplayLink) {
        // targetTimestamp - duration ≈ link start on the first tick; use the
        // link's own clock so pauses/dropped frames stay in sync.
        emphasisProgress = min(1, emphasisProgress + CGFloat(link.duration / Self.emphasisDuration))
        needsDisplay = true
        if emphasisProgress >= 1 { stopEmphasis(); needsDisplay = true }
    }

    /// The character range currently laid out in the viewport, or nil if
    /// unavailable (fall back to enumerating all matches).
    private func viewportCharRange(_ tlm: NSTextLayoutManager) -> NSRange? {
        guard let vp = tlm.textViewportLayoutController.viewportRange else { return nil }
        let docStart = tlm.documentRange.location
        let lo = tlm.offset(from: docStart, to: vp.location)
        let hi = tlm.offset(from: docStart, to: vp.endLocation)
        guard lo >= 0, hi >= lo else { return nil }
        return NSRange(location: lo, length: hi - lo)
    }

    // MARK: - Menu / keyboard actions
    // Only implemented here, so in Reading mode (webview is first responder)
    // these gray out automatically — no explicit validation needed.

    @objc public func showFindBar(_ sender: Any?)      { findHandler?.editorToggleFind(replace: false) }
    @objc public func showFindReplaceBar(_ sender: Any?) { findHandler?.editorToggleFind(replace: true) }
    @objc public func findNext(_ sender: Any?)         { findHandler?.editorFindNext() }
    @objc public func findPrevious(_ sender: Any?)     { findHandler?.editorFindPrevious() }
    @objc public func hideFindBar(_ sender: Any?)      { findHandler?.editorHideFind() }
}
