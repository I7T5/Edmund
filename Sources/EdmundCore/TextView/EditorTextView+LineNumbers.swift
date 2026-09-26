import AppKit

// MARK: - Line numbers
//
// Source line numbers, off by default (Settings ▸ Edit ▸ Lines). Two placements
// share one walk over the visible lines:
//
//   - **Beside the content** (preferred): drawn in the reading column's own
//     margin on the text view's background pass. Reserves nothing, so the column
//     never moves, and the numbers stay next to the line they label at any
//     window width.
//   - **By the window edge**: a `LineNumberRulerView` on the scroll view. AppKit
//     owns the scroll sync and clipping, but it reserves width, so the centered
//     column re-centers when it comes up.
//
// The placement is not a setting. A wide content-width cap (or a narrow window,
// or a five-digit document) leaves no margin to draw in, and that is exactly
// when the gutter takes over — see `lineNumbersFitBesideContent`.
//
// Also here: `lineStarts`, the cached line-start table backing
// `line(forOffset:)` / `offset(forLine:)`, dropped on every `rawSource` write.
//
// Read mode is unaffected — it hides the whole scroll view, ruler included. So
// is printing: the ruler isn't part of the text view, and the in-margin numbers
// draw only for the on-screen viewport.

extension EditorTextView {

    // MARK: Line-start table

    /// UTF-16 offset of each line's first character, `lineStarts[0] == 0`. Built
    /// lazily and dropped by `rawSource`'s `didSet`, which turns line ↔ offset
    /// lookups into a binary search: the gutter does one per fragment per
    /// redraw, and the status bar one per keystroke. Both were linear scans of
    /// the whole document before.
    ///
    /// A document ending in a newline gets a final entry equal to its length —
    /// the empty last line, matching how the editor counts lines everywhere.
    var lineStarts: [Int] {
        if let lineStartsCache { return lineStartsCache }
        var starts = [0]
        var offset = 0
        for unit in rawSource.utf16 {
            offset += 1
            if unit == 0x000A { starts.append(offset) }
        }
        lineStartsCache = starts
        return starts
    }

    /// 1-indexed source line containing character `offset` (counts "\n" only —
    /// matches swift-markdown's SourceLocation convention; no CRLF handling,
    /// same as the rest of the pipeline). An offset past the end reports the
    /// last line; a negative one reports line 1.
    public func line(forOffset offset: Int) -> Int {
        let starts = lineStarts
        let target = max(0, offset)
        // Largest index whose start is still <= target.
        var low = 0
        var high = starts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if starts[mid] <= target { low = mid } else { high = mid - 1 }
        }
        return low + 1
    }

    /// Character offset of the start of 1-indexed `line`, clamped to the
    /// document (line < 1 → 0; past the last line → start of the last line).
    public func offset(forLine line: Int) -> Int {
        let starts = lineStarts
        guard line > 1 else { return 0 }
        guard line <= starts.count else { return starts[starts.count - 1] }
        return starts[line - 1]
    }

    // MARK: Shared drawing pieces

    /// Ink for the line numbers: a step dimmer than `syntaxDimColor`, the same
    /// relationship the rules have to the markers (see `darkRuleGray`). Numbers
    /// are chrome behind chrome — always on screen, never read in sequence — so
    /// they sit below the dim tier rather than in it.
    var lineNumberColor: NSColor {
        isDarkAppearance ? Self.darkRuleGray : .quaternaryLabelColor
    }

    /// How the numbers are inked, plus the two metrics both placements need.
    struct LineNumberStyle {
        let attributes: [NSAttributedString.Key: Any]
        /// Lines the selection touches are inked as body text, so they read as a
        /// position rather than as chrome.
        let currentAttributes: [NSAttributedString.Key: Any]
        /// 1-indexed line spans the selection covers — the caret's own line when
        /// there is no range. Kept as ranges, not a set: selecting a million-line
        /// document shouldn't build a million-element set on every redraw.
        let selectedLines: [ClosedRange<Int>]
        /// Distance from the top `draw(at:)` expects down to the middle of a
        /// digit's cap band. Numbers are centered on the text's cap band rather
        /// than sat on its baseline, so they read level beside any size; the
        /// digit's *ink* has to do the centering, since the box `draw(at:)` lays
        /// out is far taller than the figures inside it (20 pt for a 14 pt face)
        /// and centering the box leaves every number riding high.
        let digitCenterFromTop: CGFloat
        /// One digit's advance. The face's figures are tabular (see
        /// `lineNumberFont`), so this holds for all ten and a label's width is
        /// just its length — no need to measure each number.
        let digitWidth: CGFloat

        /// Body ink for the selected lines, chrome ink for the rest.
        func attributed(_ line: Int) -> [NSAttributedString.Key: Any] {
            selectedLines.contains { $0.contains(line) } ? currentAttributes : attributes
        }
    }

    /// The face for line numbers: Avenir Next Condensed, the one CotEditor uses
    /// for the same job. Narrow, so it takes little of the margin it has to fit
    /// in, and a UI face rather than a code face, so the numbers read as chrome
    /// instead of as more content.
    ///
    /// It is **not** monospaced — the letters are proportional. Its *figures*
    /// are tabular: every digit carries the same advance. That is the property
    /// the drawing leans on, and the only one it needs — it right-aligns each
    /// label from a single measured digit width (`LineNumberStyle.digitWidth`)
    /// rather than measuring every number.
    ///
    /// Falls back to the system's monospaced-digit face, which has the same
    /// guarantee, if the family is ever missing.
    static func lineNumberFont(ofSize size: CGFloat) -> NSFont {
        NSFont(name: "AvenirNextCondensed-Regular", size: size)
            ?? .monospacedDigitSystemFont(ofSize: size, weight: .regular)
    }

    /// Sized to the theme's monospace face — the code size, not the body size,
    /// so the numbers stay chrome-scaled while still following the editor's zoom.
    var lineNumberFont: NSFont {
        Self.lineNumberFont(ofSize: theme.monospaceFont().pointSize)
    }

    var lineNumberStyle: LineNumberStyle {
        let font = lineNumberFont
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: lineNumberColor
        ]
        let digit = NSAttributedString(string: "0", attributes: attributes)
        return LineNumberStyle(
            attributes: attributes,
            currentAttributes: [.font: font, .foregroundColor: foregroundColor],
            selectedLines: selectedLineSpans,
            digitCenterFromTop: digit.size().height + font.descender - font.capHeight / 2,
            digitWidth: digit.size().width)
    }

    /// The 1-indexed line spans the selection covers, one per selected range
    /// (NSTextView allows several).
    var selectedLineSpans: [ClosedRange<Int>] {
        selectedRanges.map { value in
            let range = value.rangeValue
            let first = line(forOffset: range.location)
            // A selection ending exactly at a line start stops short of that
            // line, so measure the last character it actually covers.
            let last = range.length > 0 ? line(forOffset: range.upperBound - 1) : first
            return first...max(first, last)
        }
    }

    /// Repaints the numbers after the caret may have changed line. Only the
    /// current line's ink changes, but which line that is isn't known until the
    /// draw, so mark the whole strip the numbers occupy — never the text.
    func invalidateLineNumbers() {
        guard showLineNumbers else { return }
        if let lineNumberRuler {
            lineNumberRuler.needsDisplay = true
        } else {
            let visible = visibleRect
            setNeedsDisplay(NSRect(x: 0, y: visible.minY,
                                   width: textContainerOrigin.x,
                                   height: visible.height))
        }
    }

    /// Everything the margin chrome (line numbers, `</>` buttons, copy buttons,
    /// table handles) draws from, computed in **one** pass and shared by every
    /// piece in the same draw or hover update. Before this existed each piece
    /// recomputed it: every `drawBackground` did ~6 viewport fragment walks and
    /// ~3 full block-list scans, and `mouseMoved` redid them at event rate.
    struct MarginChromeGeometry {
        /// One entry per visible source line, from the single viewport walk:
        /// the line number and its cap-band centre (see
        /// `enumerateVisibleLineNumbers`).
        var visibleLines: [(line: Int, capCenterY: CGFloat)] = []
        /// Table header line → block index, for the tables intersecting the
        /// laid-out viewport. A button only ever lands on a visible header
        /// row, so blocks outside the viewport can't contribute one.
        var tableHeaders: [Int: Int] = [:]
        /// Opening-fence line → block index, for the code blocks intersecting
        /// the viewport (Edit mode only, matching `visibleCodeCopyButtons`).
        var fenceLines: [Int: Int] = [:]
        /// The active cell's row and column pills — `tableHandles()`, computed
        /// once so the `</>` button's pill dodge and the handles' own draw
        /// don't each enumerate the table's fragments.
        var handles: [TableHandle] = []
    }

    /// Builds the shared `MarginChromeGeometry`. Cheap to call once per pass:
    /// one viewport walk, one block scan bounded to the viewport, one handles
    /// computation — instead of each consumer paying for its own.
    func marginChromeGeometry(includeLineNumbers: Bool = false) -> MarginChromeGeometry {
        var geometry = MarginChromeGeometry()
        geometry.handles = tableHandles()
        guard let tlm = textLayoutManager,
              let viewport = tlm.textViewportLayoutController.viewportRange
        else { return geometry }
        let docStart = tlm.documentRange.location
        let lo = tlm.offset(from: docStart, to: viewport.location)
        let hi = tlm.offset(from: docStart, to: viewport.endLocation)
        guard lo >= 0, hi > lo else { return geometry }
        // Only blocks overlapping the laid-out viewport can put chrome on
        // screen, so the scan tracks what's visible rather than the whole
        // document.
        for (i, block) in blocks.enumerated()
        where block.range.location < hi && block.range.upperBound > lo {
            switch block.kind {
            case .table:
                geometry.tableHeaders[line(forOffset: block.range.location)] = i
            case .fence where viewMode == .edit:
                geometry.fenceLines[line(forOffset: block.range.location)] = i
            default:
                break
            }
        }
        // Hover needs line positions only for visible table or copy buttons.
        guard includeLineNumbers || !geometry.tableHeaders.isEmpty
            || !geometry.fenceLines.isEmpty else { return geometry }
        enumerateVisibleLineNumbers { line, capCenterY in
            geometry.visibleLines.append((line, capCenterY))
        }
        return geometry
    }

    /// Calls `body` once per visible source line, with its 1-indexed number and
    /// the vertical extent of its **first** visual line in text-container
    /// coordinates (so a wrapped line is numbered once, against its top line).
    /// The number's own cap band is centered on it — see
    /// `LineNumberStyle.digitCenterFromTop`.
    ///
    /// Walks the viewport the text view has *already* laid out. Forcing layout
    /// instead (`.ensuresLayout`, or enumerating from the document start)
    /// re-enters the viewport layout controller mid-draw, which blanks the text
    /// view — and on a large document it would lay out the whole thing, the trap
    /// `lineRect(forCharacterAt:)` documents.
    func enumerateVisibleLineNumbers(_ body: (_ line: Int, _ capCenterY: CGFloat) -> Void) {
        guard let tlm = textLayoutManager,
              let viewport = tlm.textViewportLayoutController.viewportRange
        else { return }
        let bottom = visibleRect.maxY - textContainerOrigin.y
        // Lines shorter than this are hidden by rendering (a table's separator
        // row, some delimiters — 0.01 pt `hiddenFont`). They still hold a line
        // number, but drawing it would stack it on the neighbor's, so the
        // visible sequence is allowed to skip.
        let minimumDrawnHeight = bodyFont.pointSize / 2
        var lastLine = 0

        tlm.enumerateTextLayoutFragments(from: viewport.location,
                                         options: []) { fragment in
            let frame = fragment.layoutFragmentFrame
            guard frame.minY <= bottom else { return false }
            guard let firstLine = fragment.textLineFragments.first else { return true }

            let offset = tlm.offset(from: tlm.documentRange.location,
                                    to: fragment.rangeInElement.location)
            let line = self.line(forOffset: offset)
            // A paragraph is normally one fragment, but don't repeat a number if
            // TextKit ever splits one — the first fragment owns the line.
            guard line != lastLine,
                  firstLine.typographicBounds.height >= minimumDrawnHeight
            else { return true }
            lastLine = line

            // Center on the text's *cap band*, not on the line fragment's box:
            // the box carries leading and paragraph spacing, so centering in it
            // rides high. Take the tallest cap on the line so a heading centers
            // against its own size — and read it off the line's own attributes
            // rather than the storage, where a list item's first character is
            // the 0.01 pt hidden font and would report no cap at all. Walk the
            // font *runs* and stop at the first one big enough to carry the
            // cap band: a paragraph is normally a single run and a list item's
            // hidden font is a one-character run before it, so this reads one
            // or two runs where the old full-length enumeration read every run
            // in the paragraph — per fragment, per call.
            let bounds = firstLine.typographicBounds
            let baseline = frame.minY + bounds.minY + firstLine.glyphOrigin.y
            let text = firstLine.attributedString
            var cap: CGFloat = 0
            var index = 0
            while index < text.length, cap < bodyFont.capHeight {
                var run = NSRange()
                guard let font = text.attribute(.font, at: index,
                                                effectiveRange: &run) as? NSFont,
                      run.length > 0 else { break }
                cap = max(cap, font.capHeight)
                index = run.upperBound
            }
            body(line, baseline - (cap > 0 ? cap : self.bodyFont.capHeight) / 2)
            return true
        }
    }

    /// Space between the numbers and what they sit beside.
    static let lineNumberPadding: CGFloat = 8

    /// Left inset the in-margin numbers need to fit: the document's widest
    /// number, the character of air after it, and the padding before the text.
    ///
    /// Deliberately *not* a floor under `updateContentInset`. Reserving it would
    /// stop the reading column from stretching to the full content-width cap,
    /// and the cap winning is the point — so when the margin can't hold the
    /// numbers they step aside instead.
    var lineNumbersRequiredInset: CGFloat {
        let digits = LineNumberRulerView.digitCount(lineStarts.count)
        let padding = textContainer?.lineFragmentPadding ?? 0
        return lineNumberStyle.digitWidth * CGFloat(digits + 1)
            + Self.lineNumberPadding - padding
    }

    /// Whether the reading column's margin can hold the numbers. This one test
    /// picks the placement: true draws them beside the text, false puts up the
    /// window-edge gutter instead. It moves with the content-width cap (a wide
    /// cap leaves no margin), the window width, and the document's digit count.
    ///
    /// The switch can't oscillate. The gutter reserves width, so turning it on
    /// only ever shrinks the margin — a document that didn't fit still doesn't,
    /// and one that fits without the gutter fits all the more once it's gone.
    ///
    /// The margin is recomputed from the cap rather than read off
    /// `textContainerOrigin`, which is only correct once `updateContentInset`
    /// has run at least once. Reading the live inset made a freshly built editor
    /// see a zero margin, decide nothing fit, and put up a gutter it then had to
    /// take down — a transient that showed up as an installed ruler in tests.
    var lineNumbersFitBesideContent: Bool {
        Self.horizontalInset(viewWidth: bounds.width,
                             maxContentWidth: maxContentWidthPoints)
            >= lineNumbersRequiredInset
    }

    // MARK: In-margin numbers (the default placement)

    /// Draws the numbers in the reading column's left margin, right-aligned just
    /// short of the text. Called from `drawBackground(in:)` — they occupy margin
    /// the text never uses, so nothing has to move to make room. Takes the
    /// pass's shared `MarginChromeGeometry` so the numbers ride the same single
    /// viewport walk as the rest of the margin chrome; nil builds a fresh one
    /// (the click/test paths).
    func drawLineNumbersBesideContent(in rect: NSRect,
                                      chrome: MarginChromeGeometry? = nil) {
        let style = lineNumberStyle
        let origin = textContainerOrigin
        // The column's text starts a `lineFragmentPadding` inside the container.
        let padding = textContainer?.lineFragmentPadding ?? 0
        let rightEdge = origin.x + padding - Self.lineNumberPadding

        // Nothing reserves this margin — the content-width cap owns it, so the
        // column always stretches to the full cap and the numbers give way when
        // what's left can't hold them. They aren't lost when they do: the same
        // test puts the window-edge gutter up instead.
        // ponytail: all or none, never just the ones that fit, so the column
        // can't go ragged with `9` drawn and `100` missing.
        guard lineNumbersFitBesideContent else { return }
        let chrome = chrome ?? marginChromeGeometry(includeLineNumbers: true)

        // A revealed `</>` button stands in the slot of its table's header-row
        // number. One slot, one occupant — so that row's number gives way while
        // the button shows, rather than the two overdrawing each other.
        let covered = linesCoveredByTableRawButtons(using: chrome)

        for (line, capCenterY) in chrome.visibleLines {
            guard !covered.contains(line) else { continue }
            let label = NSAttributedString(string: "\(line)", attributes: style.attributed(line))
            // dev: Add one-char space between content and line number
            let x = rightEdge - style.digitWidth * CGFloat(label.length + 1)
            let y = origin.y + capCenterY - style.digitCenterFromTop
            guard rect.intersects(NSRect(x: x, y: y, width: rightEdge - x,
                                         height: 2 * style.digitCenterFromTop)) else { continue }
            label.draw(at: NSPoint(x: x, y: y))
        }
    }

    // MARK: Gutter install / remove

    /// Installs or removes the window-edge gutter. Only that placement uses a
    /// ruler; the in-margin default draws itself. A no-op until the view is
    /// inside a scroll view — Document configures the editor before adding it to
    /// one, so `viewDidMoveToSuperview` replays this.
    /// Re-checks the placement after a layout change, landing any actual switch
    /// on the next runloop pass.
    ///
    /// The deferral is not optional. `updateContentInset` runs inside
    /// `setFrameSize`, and adding or removing a ruler re-tiles the scroll view —
    /// mutating it from inside its own layout crashed the whole test process on
    /// macOS 14 (SIGSEGV; CI caught what six clean local runs on macOS 15 did
    /// not). It's the same constraint that keeps `ruleThickness` off the draw
    /// path, one layer up.
    ///
    /// Nothing is scheduled unless the placement actually has to change, so the
    /// common path is two cheap reads.
    func scheduleLineNumberPlacementUpdate() {
        guard enclosingScrollView != nil else { return }
        let wantsGutter = showLineNumbers && !lineNumbersFitBesideContent
        guard wantsGutter != (lineNumberRuler != nil),
              !lineNumberPlacementUpdateScheduled else { return }

        lineNumberPlacementUpdateScheduled = true
        RunLoop.main.perform { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.lineNumberPlacementUpdateScheduled = false
                self.updateLineNumberRuler()
            }
        }
    }

    /// Puts the gutter up (or takes it down) to match `lineNumbersFitBesideContent`.
    ///
    /// Call this only from outside a layout pass — `showLineNumbers`,
    /// `viewDidMoveToSuperview`, or the scheduled hop above. `lineNumberRuler`
    /// is assigned *before* the scroll view is told about it, and cleared before
    /// the removal, because showing or hiding a ruler resizes the document view
    /// synchronously and re-enters through `setFrameSize`; assigning afterwards
    /// would let that re-entrant call see nil and build a second ruler.
    func updateLineNumberRuler() {
        guard let scrollView = enclosingScrollView else { return }
        if showLineNumbers && !lineNumbersFitBesideContent {
            guard lineNumberRuler == nil else { return }
            let ruler = LineNumberRulerView(scrollView: scrollView, editor: self)
            lineNumberRuler = ruler
            scrollView.verticalRulerView = ruler
            scrollView.hasVerticalRuler = true
            scrollView.rulersVisible = true
        } else {
            guard lineNumberRuler != nil else { return }
            lineNumberRuler = nil
            scrollView.rulersVisible = false
            scrollView.hasVerticalRuler = false
            scrollView.verticalRulerView = nil
        }
        needsDisplay = true
    }

    public override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        updateLineNumberRuler()
    }
}

/// The window-edge line-number gutter. Numbers are dimmed, monospaced, and
/// right-aligned; nothing separates the gutter from the text but space — no
/// rule, and the same background, so the two read as one surface.
final class LineNumberRulerView: NSRulerView {

    /// Never narrower than this many digits, so the gutter doesn't twitch as a
    /// short document crosses 9 → 10 lines.
    private static let minimumDigits = 3

    private var editor: EditorTextView? { clientView as? EditorTextView }

    init(scrollView: NSScrollView, editor: EditorTextView) {
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        // Against the macOS 14 SDK `clipsToBounds` defaults to false, and the
        // rect handed to `drawHashMarksAndLabels` is wider than the gutter — so
        // without this the background fill paints over the whole scroll view and
        // the document goes blank.
        clipsToBounds = true
        clientView = editor
        ruleThickness = Self.thickness(digits: Self.minimumDigits,
                                       font: editor.lineNumberFont)
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Gutter width for a number of digits, from the monospace font's own digit
    /// advance.
    @MainActor static func thickness(digits: Int, font: NSFont) -> CGFloat {
        let digitWidth = ("0" as NSString).size(withAttributes: [.font: font]).width
        return CGFloat(max(digits, minimumDigits)) * digitWidth
            + 2 * EditorTextView.lineNumberPadding
    }

    /// Digits needed to write `count`.
    static func digitCount(_ count: Int) -> Int {
        var digits = 1
        var remaining = count
        while remaining >= 10 { remaining /= 10; digits += 1 }
        return digits
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let editor else { return }

        // The scroll view draws no background and, in dark mode, the editor
        // paints its own #292929 — so match it here, or the window's gray shows
        // through and the gutter reads as a separate panel.
        editor.editorBackgroundColor.setFill()
        rect.fill()

        let style = editor.lineNumberStyle
        let needed = Self.thickness(digits: Self.digitCount(editor.lineStarts.count),
                                    font: editor.lineNumberFont)
        if abs(needed - ruleThickness) > 0.5 {
            // Re-tiles the scroll view, which can't happen mid-draw — land it on
            // the next runloop pass instead.
            RunLoop.main.perform { [weak self] in
                MainActor.assumeIsolated { self?.ruleThickness = needed }
            }
        }

        // Fragment baselines are in text-container space; the ruler's own space
        // is offset from the text view's by both views' geometry.
        let rulerOffsetY = convert(NSPoint.zero, from: editor).y
            + editor.textContainerOrigin.y
        let rightEdge = ruleThickness - EditorTextView.lineNumberPadding

        editor.enumerateVisibleLineNumbers { line, capCenterY in
            let label = NSAttributedString(string: "\(line)",
                                           attributes: style.attributed(line))
            label.draw(at: NSPoint(x: rightEdge - style.digitWidth * CGFloat(label.length),
                                   y: rulerOffsetY + capCenterY - style.digitCenterFromTop))
        }
    }
}
