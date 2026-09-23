import AppKit

// MARK: - TextKit 2 Support
//
// The editor runs on TextKit 2 (NSTextLayoutManager): layout is viewport-based
// — the system only lays out what's on screen, which is what makes large
// documents tractable. The hard rule that follows: never touch
// `NSTextView.layoutManager` or store NSTextBlock/NSTextTable attributes —
// either silently switches the view back to TextKit 1 for good.
//
// Two custom attributes drive a custom layout fragment:
//
// - `.blockDecoration` (paragraph-level): callout boxes, quote bars, table
//   borders, thematic-break rules. Fragment frames tile vertically, so
//   per-paragraph drawing renders a multi-line quote run as one continuous
//   box/bar.
// - `.fragmentOverlay` (character-level): images drawn at a character's
//   position — callout header (icon + title), rendered math, list bullets and
//   checkboxes. TextKit 1 rendered `.attachment` over any character; TextKit 2
//   only honors attachments on U+FFFC, which the storage==rawSource invariant
//   forbids. Instead the anchor character is hidden, `.kern` reserves the
//   image's advance width (the same trick the table renderer uses for column
//   alignment), and the fragment draws the image at the anchor's position.
// - `.tableCellWraps` (paragraph-level): a table cell too wide for its column
//   can't wrap in place — TextKit 2 only wraps a whole paragraph at the
//   container's edge, it has no notion of an independent per-cell flow region
//   (that's what NSTextTable/NSTextBlock exist for, and they're banned). So an
//   overflowing cell's real characters are hidden, and its styled text is laid
//   out separately in a small detached text stack sized to the column's
//   width; the fragment draws the resulting lines stacked at the cell's x.

//
// The attribute value types live in TextKit2Attributes.swift; the fragment
// that draws them in DecoratedTextLayoutFragment.swift.

// MARK: - Fragment Vending

extension EditorTextView: NSTextLayoutManagerDelegate {
    public nonisolated func textLayoutManager(
        _ textLayoutManager: NSTextLayoutManager,
        textLayoutFragmentFor location: NSTextLocation,
        in textElement: NSTextElement
    ) -> NSTextLayoutFragment {
        guard let paragraph = textElement as? NSTextParagraph,
              paragraph.attributedString.length > 0 else {
            return NSTextLayoutFragment(textElement: textElement,
                                        range: textElement.elementRange)
        }
        let str = paragraph.attributedString
        let decoValue = str.attribute(.blockDecoration, at: 0, effectiveRange: nil)
        let decorations: [BlockDecoration]
        if let list = decoValue as? BlockDecorationList {
            decorations = list.decorations
        } else if let single = decoValue as? BlockDecoration {
            decorations = [single]
        } else {
            decorations = []
        }
        var overlays: [(offset: Int, overlay: FragmentOverlay)] = []
        str.enumerateAttribute(.fragmentOverlay,
                               in: NSRange(location: 0, length: str.length),
                               options: []) { value, range, _ in
            if let overlay = value as? FragmentOverlay {
                overlays.append((range.location, overlay))
            }
        }
        let cellWrapsValue = str.attribute(.tableCellWraps, at: 0, effectiveRange: nil)
        let cellWraps = (cellWrapsValue as? TableCellWrapList)?.wraps ?? []
        let codeBlockLabelValue = str.attribute(.codeBlockLabel, at: 0, effectiveRange: nil) as? String
        let codeBlockLabelAnchorValue = str.attribute(.codeBlockLabelAnchor, at: 0, effectiveRange: nil) as? String
        // A plain fragment suffices only when there's nothing to draw over the
        // text and antialiasing is on (the default); otherwise vend the custom
        // fragment so its draw can disable antialiasing. (A `.codeBlockLabel`
        // line always also carries the box decoration, so it needs no extra
        // clause here.)
        let invisibles = self.invisibles
        // Read only when the setting is on, so a list-heavy document keeps the
        // plain fast path with guides off (the default).
        let listGuides = showListIndentGuides
            ? (str.attribute(.listGuides, at: 0, effectiveRange: nil) as? [CGFloat] ?? [])
            : []
        // Focus mode dims from inside the fragment's own draw, so while it is on
        // every paragraph needs the custom fragment — a plain one has no draw to
        // hook. (Vending one costs nothing here: with no decorations, overlays
        // or cell wraps its init does no work.) Only this plain ↔ decorated
        // swap needs the re-vend a `refreshOverdraw()` forces; whether a
        // decorated fragment actually dims is read live from `owner`, so
        // turning the mode *off* takes effect on the next redraw.
        let focusMode = self.focusMode
        guard !decorations.isEmpty || !overlays.isEmpty || !cellWraps.isEmpty || !textAntialias
                || (invisibles?.drawsAnything ?? false) || !listGuides.isEmpty || focusMode
        else {
            return NSTextLayoutFragment(textElement: textElement,
                                        range: textElement.elementRange)
        }
        return DecoratedTextLayoutFragment(textElement: textElement,
                                           range: textElement.elementRange,
                                           decorations: decorations,
                                           overlays: overlays,
                                           cellWraps: cellWraps,
                                           antialias: textAntialias,
                                           codeBlockLabel: codeBlockLabelValue,
                                           codeBlockLabelAnchor: codeBlockLabelAnchorValue,
                                           codeBlockLabelFont: codeBlockLabelFont,
                                           invisibles: invisibles,
                                           listGuides: listGuides,
                                           owner: self)
    }
}

// MARK: - Overlay Application

extension EditorTextView {
    /// Renders `overlay` at `anchor` (a single character): hides the anchor
    /// glyph, reserves the image's advance width with kern so following text
    /// flows around it, and stores the overlay for the layout fragment to draw.
    ///
    /// The kern is capped just short of the full line width: a full-width
    /// image/equation (the common case — anything wider than the column gets
    /// scaled to exactly fill it) would otherwise reserve 100% of the line,
    /// leaving zero room for the hidden markdown text that follows the anchor
    /// on the same line. TextKit then force-wraps that hidden run onto a new
    /// line fragment — and since `minimumLineHeight` (reserveLineHeight) is a
    /// paragraph-wide property applying to every line fragment, that phantom
    /// wrapped line also inflates to the overlay's full height, doubling the
    /// reserved space below the image. The slack is comfortably larger than
    /// any realistic hidden-text width (near-zero at `hiddenFont`'s size).
    func applyOverlay(_ overlay: FragmentOverlay, anchor: NSRange,
                      in result: NSMutableAttributedString) {
        guard anchor.upperBound <= result.length else { return }
        let kernSlack: CGFloat = 8
        let kernWidth = min(overlay.bounds.width, max(0, availableContentWidth - kernSlack))
        result.addAttribute(.font, value: hiddenFont, range: anchor)
        result.addAttribute(.foregroundColor, value: NSColor.clear, range: anchor)
        result.addAttribute(.kern, value: kernWidth, range: anchor)
        result.addAttribute(.fragmentOverlay, value: overlay, range: anchor)
    }

    /// Reserves vertical room for an overlay taller than the text line that
    /// carries it. A `FragmentOverlay` only reserves horizontal advance (kern),
    /// so — unlike the old `NSTextAttachment`, which grew its line fragment —
    /// a tall image (inline math scaled to a heading, a big inline integral)
    /// would otherwise overlap the lines around it.
    ///
    /// Reserves `ascent` (the part above the baseline) as the paragraph's
    /// `minimumLineHeight` and folds `descent` (the part below) into its trailing
    /// `paragraphSpacing`. Reserving the *full* height as `minimumLineHeight`
    /// instead pins the baseline at the box bottom — so the descent hangs below
    /// the line and overlaps the paragraph below (a lone integral's tail landing
    /// on the next line). This mirrors the display-math reservation in
    /// `displayMathParagraphStyle`. An image overlay has descent 0, so it keeps
    /// its previous behavior (all height reserved as line height).
    func reserveLineHeight(ascent: CGFloat, descent: CGFloat, forOverlayAt location: Int,
                           in result: NSMutableAttributedString) {
        guard location < result.length else { return }
        let ns = result.string as NSString
        // The enclosing paragraph (between newlines): both are paragraph
        // attributes, and for the heading/inline cases the math sits on a single
        // line, so this grows exactly the line that needs it.
        let para = ns.paragraphRange(for: NSRange(location: location, length: 0))
        let base = (result.attribute(.paragraphStyle, at: location, effectiveRange: nil)
            as? NSParagraphStyle) ?? bodyParagraphStyle
        guard ascent > base.minimumLineHeight || descent > base.paragraphSpacing else { return }
        let ps = (base.mutableCopy() as! NSMutableParagraphStyle)
        ps.minimumLineHeight = max(base.minimumLineHeight, ascent)
        ps.paragraphSpacing = max(base.paragraphSpacing, descent)
        result.addAttribute(.paragraphStyle, value: ps, range: para)
    }
}

// MARK: - Stack Construction

public extension EditorTextView {
    /// Builds the TextKit 2 text system chain and returns the wired editor:
    ///   EditorTextStorage → NSTextContentStorage → NSTextLayoutManager
    ///   → NSTextContainer → EditorTextView
    static func makeTextKit2(frame: NSRect, containerSize: NSSize) -> EditorTextView {
        let contentStorage = NSTextContentStorage()
        contentStorage.textStorage = EditorTextStorage()

        let layoutManager = NSTextLayoutManager()
        contentStorage.addTextLayoutManager(layoutManager)

        let container = NSTextContainer(size: containerSize)
        container.widthTracksTextView = true
        layoutManager.textContainer = container

        return EditorTextView(frame: frame, textContainer: container)
    }
}
