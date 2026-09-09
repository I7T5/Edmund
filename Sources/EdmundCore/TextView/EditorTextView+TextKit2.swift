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

public extension NSAttributedString.Key {
    /// Paragraph-level decoration drawn behind the text by
    /// `DecoratedTextLayoutFragment`. Value: `BlockDecoration`.
    static let blockDecoration = NSAttributedString.Key("MarkdownEditor.blockDecoration")
    /// Character-level image drawn at the character's position by
    /// `DecoratedTextLayoutFragment`. Value: `FragmentOverlay`. The styling
    /// code pairs it with a hidden anchor glyph plus `.kern` for layout space.
    static let fragmentOverlay = NSAttributedString.Key("MarkdownEditor.fragmentOverlay")
    /// A table row's overflowing cells, wrapped and drawn by
    /// `DecoratedTextLayoutFragment`. Value: `TableCellWrapList`.
    static let tableCellWraps = NSAttributedString.Key("MarkdownEditor.tableCellWraps")
    /// Marks a fenced code block's opening fence line — the fragment that
    /// shaves the box's top padding. Value: the display language `String`
    /// ("" for a fence naming no language; a plain `String` so the oracle
    /// tests' structural comparison of independent `styleBlock` runs
    /// compares by value for free).
    static let codeBlockLabel = NSAttributedString.Key("MarkdownEditor.codeBlockLabel")
    /// Marks the block's *second* line (the row under the opening fence) as
    /// the one whose fragment paints the language label, reaching *up* into
    /// the fence row's area. Drawing from the fence fragment itself would
    /// clip: with a 10pt top gap the label's ink extends past the short
    /// fence fragment's bottom, and the next row's box fill paints over it.
    /// The second row draws after that fill, so nothing overpaints the
    /// label. Value: the non-empty display language `String`.
    static let codeBlockLabelAnchor = NSAttributedString.Key("MarkdownEditor.codeBlockLabelAnchor")
    /// A nested list item's indent-guide columns — one x per *ancestor* level,
    /// measured from the text container's left edge (the same space the
    /// paragraph's head indents live in). Value: `[CGFloat]`, absent at depth 0.
    /// Written whether or not the setting is on, so toggling the guides needs a
    /// re-vend (`refreshOverdraw`) rather than a whole-document restyle.
    static let listGuides = NSAttributedString.Key("MarkdownEditor.listGuides")
}

/// Value object describing what to draw behind a decorated paragraph.
/// Reference type (NSObject) so it lives in attributed strings; value
/// equality so attribute-run merging and the test oracle behave.
public final class BlockDecoration: NSObject, @unchecked Sendable {

    public enum Kind: Equatable {
        /// Filled box across the text column (callouts), with optional borders.
        /// `bottomPad` extends the fill/border below the fragment's text frame —
        /// TextKit 2 does not include trailing `paragraphSpacing` in the
        /// fragment height, so a callout's last line carries the bottom padding
        /// here (and a matching paragraphSpacing pushes the next block clear).
        case box(background: NSColor, borderColor: NSColor?,
                 borderEdges: CalloutStyle.Edges, borderWidth: CGFloat,
                 bottomPad: CGFloat)
        /// Vertical bar just left of the paragraph's text (plain block quotes).
        case leftBar(color: NSColor, width: CGFloat)
        /// Table-row chrome: vertical column borders at text-relative x
        /// offsets, and a horizontal rule through the separator row. `width`
        /// is the table's full width; `leftInset` the text's inset from the
        /// table's left edge. `bottomBorder` draws a full-width line at this
        /// row's bottom edge — the grid line between data rows (the header/
        /// separator boundary already gets its line from `separator`).
        /// `topInset` holds the borders off the top of the fragment, which the
        /// header row uses to reserve the band its column handle sits in
        /// (see EditorTextView+TableHandles) — without it the verticals would
        /// run up through the handle.
        case tableRow(columnXOffsets: [CGFloat], width: CGFloat,
                      leftInset: CGFloat, separator: Bool, bottomBorder: Bool,
                      topInset: CGFloat)
        /// Horizontal hairline across the text column, drawn `centerOffset`
        /// points below the fragment's vertical center. The offset compensates
        /// for adjacent text sitting at its baseline (low in its line box), so
        /// the rule looks equidistant from the text above and below rather
        /// than hugging the line above it.
        case horizontalRule(color: NSColor, centerOffset: CGFloat)
    }

    public let kind: Kind
    /// For `.box`: horizontal inset (points) from the text column's left and
    /// right edges, non-zero for a box nested inside another box (e.g. a
    /// callout inside a callout), so the inner box sits within the outer one.
    /// For `.leftBar`: rightward shift (points) from the outermost bar
    /// position — one `quoteMarkerWidth` per nesting level, mirroring the
    /// hidden `> ` marker that indents the text, so each nested quote's bar
    /// (e.g. `> > text`) sits just left of its own level's text. Absolute per
    /// level: the same level's bar lands at the same x on every line, which
    /// keeps stacked bars tiling into continuous columns. Ignored by other
    /// kinds.
    public let inset: CGFloat
    /// For `.leftBar`: start the bar at the first line's glyph top (baseline
    /// minus ascender) instead of the fragment top. The line box carries its
    /// extra spacing (lineSpacing) *above* the glyphs, so a bar over the full
    /// fragment pokes past the text. Set only on a quote run's first line —
    /// interior lines must fill the whole fragment so consecutive lines' bars
    /// tile without gaps. Ignored by other kinds.
    public let hugsTextTop: Bool

    public init(_ kind: Kind, inset: CGFloat = 0, hugsTextTop: Bool = false) {
        self.kind = kind
        self.inset = inset
        self.hugsTextTop = hugsTextTop
    }

    public override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? BlockDecoration else { return false }
        return kind == other.kind && inset == other.inset
            && hugsTextTop == other.hugsTextTop
    }

    public override var hash: Int {
        var hasher = Hasher()
        switch kind {
        case .box(let background, let borderColor, let borderEdges,
                  let borderWidth, let bottomPad):
            hasher.combine(1)
            hasher.combine(background)
            hasher.combine(borderColor)
            hasher.combine(borderEdges.rawValue)
            hasher.combine(borderWidth)
            hasher.combine(bottomPad)
        case .leftBar(let color, let width):
            hasher.combine(2)
            hasher.combine(color)
            hasher.combine(width)
        case .tableRow(let offsets, let width, let leftInset,
                       let separator, let bottomBorder, let topInset):
            hasher.combine(3)
            hasher.combine(offsets)
            hasher.combine(width)
            hasher.combine(leftInset)
            hasher.combine(topInset)
            hasher.combine(separator)
            hasher.combine(bottomBorder)
        case .horizontalRule(let color, let centerOffset):
            hasher.combine(4)
            hasher.combine(color)
            hasher.combine(centerOffset)
        }
        hasher.combine(inset)
        hasher.combine(hugsTextTop)
        return hasher.finalize()
    }
}

/// An ordered stack of decorations drawn behind one paragraph, outermost
/// first. Used when nesting puts more than one box/bar on the same line — e.g.
/// a callout's outer box plus an inner nested callout's box. A single
/// decoration still uses a bare `BlockDecoration`; the fragment reads either.
public final class BlockDecorationList: NSObject, @unchecked Sendable {
    public let decorations: [BlockDecoration]

    public init(_ decorations: [BlockDecoration]) {
        self.decorations = decorations
    }

    public override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? BlockDecorationList else { return false }
        return decorations == other.decorations
    }

    public override var hash: Int {
        var hasher = Hasher()
        for decoration in decorations {
            hasher.combine(decoration)
        }
        return hasher.finalize()
    }
}

/// An image or stroked vector path drawn at a character's laid-out position,
/// with attachment-style bounds: `bounds.origin.y` is the drawing's bottom
/// relative to the text baseline (negative descends below it).
///
/// The path form exists because of a TextKit 2 wedge: drawing an *image* on a
/// wrapping, multi-line layout fragment collapses that fragment's layout to a
/// single line, while drawing a *shape* does not (see
/// docs/investigations/archives/callout-title-wrap-investigation.md). Overlays that can share a line
/// with wrapping text (the custom-callout-title icon) must use the path form.
public final class FragmentOverlay: NSObject, @unchecked Sendable {
    public let image: NSImage?
    /// Stroked path in bounds-local coordinates (y-down, origin at the
    /// bounds' top-left), pre-scaled to the bounds size.
    public let path: CGPath?
    public let pathColor: NSColor?
    public let pathLineWidth: CGFloat
    public let bounds: CGRect
    private let cachedHash: Int

    public init(image: NSImage, bounds: CGRect) {
        self.image = image
        self.path = nil
        self.pathColor = nil
        self.pathLineWidth = 0
        self.bounds = bounds
        var hasher = Hasher()
        hasher.combine(ObjectIdentifier(image))
        Self.combine(bounds, into: &hasher)
        self.cachedHash = hasher.finalize()
        super.init()
    }

    public init(path: CGPath, color: NSColor, lineWidth: CGFloat, bounds: CGRect) {
        let frozenPath = path.copy() ?? path
        self.image = nil
        self.path = frozenPath
        self.pathColor = color
        self.pathLineWidth = lineWidth
        self.bounds = bounds
        var hasher = Hasher()
        Self.combine(frozenPath, into: &hasher)
        hasher.combine(color)
        hasher.combine(lineWidth)
        Self.combine(bounds, into: &hasher)
        self.cachedHash = hasher.finalize()
        super.init()
    }

    public override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? FragmentOverlay else { return false }
        return other.image === image && other.path == path
            && other.pathColor == pathColor && other.pathLineWidth == pathLineWidth
            && other.bounds == bounds
    }

    public override var hash: Int { cachedHash }

    private static func combine(_ bounds: CGRect, into hasher: inout Hasher) {
        hasher.combine(bounds.origin.x)
        hasher.combine(bounds.origin.y)
        hasher.combine(bounds.width)
        hasher.combine(bounds.height)
    }

    /// `CGPath.hashValue` is always zero on current macOS, so hash the same
    /// structural elements that Core Graphics uses for path equality.
    private static func combine(_ path: CGPath, into hasher: inout Hasher) {
        path.applyWithBlock { elementPointer in
            let element = elementPointer.pointee
            hasher.combine(element.type.rawValue)
            let pointCount: Int
            switch element.type {
            case .moveToPoint, .addLineToPoint:
                pointCount = 1
            case .addQuadCurveToPoint:
                pointCount = 2
            case .addCurveToPoint:
                pointCount = 3
            case .closeSubpath:
                pointCount = 0
            @unknown default:
                pointCount = 0
            }
            for index in 0..<pointCount {
                hasher.combine(element.points[index].x)
                hasher.combine(element.points[index].y)
            }
        }
    }
}

/// A table cell too wide for its column: its real characters are hidden, and
/// this holds what to draw instead. `x` is text-relative (same coordinate
/// space as `BlockDecoration.tableRow`'s `columnXOffsets`) — the cell's
/// content start. `contentWidth` is the column's clamped content width (the
/// width the cell's text must wrap within). `align` is the column's declared
/// alignment, applied per drawn line. `charStart` is the cell's first character
/// as an offset within its row's paragraph, which is what maps a click inside
/// the drawn text back to a real character (see `cellWrapCharacterIndex`).
public final class TableCellWrap: NSObject, @unchecked Sendable {
    public let styled: NSAttributedString
    public let x: CGFloat
    public let contentWidth: CGFloat
    public let align: ColumnAlign
    public let charStart: Int
    private let cachedHash: Int

    public init(styled: NSAttributedString, x: CGFloat, contentWidth: CGFloat,
                align: ColumnAlign = .left, charStart: Int = 0) {
        let frozenStyled = styled.copy() as! NSAttributedString
        self.styled = frozenStyled
        self.x = x
        self.contentWidth = contentWidth
        self.align = align
        self.charStart = charStart
        var hasher = Hasher()
        Self.combine(frozenStyled, into: &hasher)
        hasher.combine(x)
        hasher.combine(contentWidth)
        hasher.combine(align)
        hasher.combine(charStart)
        self.cachedHash = hasher.finalize()
    }

    public override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? TableCellWrap else { return false }
        return other.styled.isEqual(to: styled)
            && other.x == x && other.contentWidth == contentWidth
            && other.align == align && other.charStart == charStart
    }

    public override var hash: Int { cachedHash }

    private static func combine(
        _ styled: NSAttributedString,
        into hasher: inout Hasher
    ) {
        hasher.combine(styled.string)
        styled.enumerateAttributes(
            in: NSRange(location: 0, length: styled.length)
        ) { attributes, range, _ in
            hasher.combine(range.location)
            hasher.combine(range.length)
            for key in attributes.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
                hasher.combine(key.rawValue)
                if let object = attributes[key] as? NSObject {
                    hasher.combine(object.hash)
                } else {
                    hasher.combine(String(reflecting: attributes[key]))
                }
            }
        }
    }
}

/// How far one line of a wrapped cell shifts inside its column for the column's
/// alignment. Trailing whitespace is left out of the line's visual width — a
/// wrapped line ends with the space it broke on, and counting it would hang a
/// right-aligned line a space past its column edge.
func cellWrapLineOffset(_ line: NSTextLineFragment,
                        contentWidth: CGFloat,
                        align: ColumnAlign) -> CGFloat {
    guard align != .left else { return 0 }
    let text = line.attributedString.attributedSubstring(from: line.characterRange)
    let trimmed = (text.string as NSString)
        .rangeOfCharacter(from: CharacterSet.whitespacesAndNewlines.inverted, options: .backwards)
    guard trimmed.location != NSNotFound else { return 0 }
    let visible = text.attributedSubstring(
        from: NSRange(location: 0, length: trimmed.upperBound)).size().width
    let slack = contentWidth - visible
    guard slack > 0 else { return 0 }
    return align == .center ? (slack / 2).rounded() : slack
}

/// A table row's overflowing cells, one `TableCellWrap` per overflowing cell.
public final class TableCellWrapList: NSObject, @unchecked Sendable {
    public let wraps: [TableCellWrap]

    public init(_ wraps: [TableCellWrap]) {
        self.wraps = wraps
    }

    public override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? TableCellWrapList else { return false }
        return wraps == other.wraps
    }

    public override var hash: Int {
        var hasher = Hasher()
        for wrap in wraps {
            hasher.combine(wrap)
        }
        return hasher.finalize()
    }
}

/// Layout fragment that draws its paragraph's `BlockDecoration` behind the
/// text and any `FragmentOverlay` images at their characters' positions.
final class DecoratedTextLayoutFragment: NSTextLayoutFragment {

    /// Decorations drawn behind the paragraph, outermost first.
    let decorations: [BlockDecoration]
    /// Paragraph-relative anchor offsets and their overlays.
    let overlays: [(offset: Int, overlay: FragmentOverlay)]
    /// Whether the text is antialiased (editor-wide setting).
    let antialias: Bool
    /// Each overflowing cell's x and pre-laid-out lines, from a detached
    /// scratch text stack sized to the column's content width. The stack
    /// itself is retained (`scratchStacks`) so the line fragments stay valid.
    private let resolvedCellWraps: [(wrap: TableCellWrap, lines: [NSTextLineFragment])]
    private let scratchStacks: [(NSTextContentStorage, NSTextLayoutManager, NSTextContainer)]

    /// A fenced code block's display language, present only on the block's
    /// opening fence line ("" for a fence naming no language). Non-nil marks
    /// this as a code box's top fragment — drives the top-padding shave.
    let codeBlockLabel: String?
    /// The non-empty display language on the block's second row — the
    /// fragment that paints the label, reaching up over the fence row
    /// (see `.codeBlockLabelAnchor`).
    let codeBlockLabelAnchor: String?
    /// The label's font — a smaller cut of the editor's monospace font,
    /// handed over at vend time (the fragment has no theme access).
    let codeBlockLabelFont: NSFont

    /// Whitespace-mark config, or nil when invisibles are off. Drawn over the
    /// real glyphs after `super.draw` — see EditorTextView+Invisibles.
    let invisibles: InvisiblesConfig?

    /// Indent-guide columns for a nested list item, container-relative; empty
    /// when the item is top-level or the setting is off. Drawn under the text.
    let listGuides: [CGFloat]

    /// The editor that vended this fragment, for the settings its draw reads
    /// *live* rather than capturing (`focusMode`). Weak — the layout manager
    /// outlives no editor, but a fragment must never keep one alive.
    /// See EditorTextView+FocusMode.
    weak var owner: EditorTextView?

    init(textElement: NSTextElement, range: NSTextRange?,
         decorations: [BlockDecoration],
         overlays: [(offset: Int, overlay: FragmentOverlay)],
         cellWraps: [TableCellWrap],
         antialias: Bool,
         codeBlockLabel: String? = nil,
         codeBlockLabelAnchor: String? = nil,
         codeBlockLabelFont: NSFont = .monospacedSystemFont(ofSize: 10, weight: .regular),
         invisibles: InvisiblesConfig? = nil,
         listGuides: [CGFloat] = [],
         owner: EditorTextView? = nil) {
        self.listGuides = listGuides
        self.owner = owner
        self.decorations = decorations
        self.overlays = overlays
        self.antialias = antialias
        self.codeBlockLabel = codeBlockLabel
        self.codeBlockLabelAnchor = codeBlockLabelAnchor
        self.codeBlockLabelFont = codeBlockLabelFont
        self.invisibles = invisibles
        var resolved: [(wrap: TableCellWrap, lines: [NSTextLineFragment])] = []
        var stacks: [(NSTextContentStorage, NSTextLayoutManager, NSTextContainer)] = []
        for wrap in cellWraps {
            let contentStorage = NSTextContentStorage()
            contentStorage.textStorage = NSTextStorage(attributedString: wrap.styled)
            let layoutManager = NSTextLayoutManager()
            contentStorage.addTextLayoutManager(layoutManager)
            let container = NSTextContainer(
                size: NSSize(width: max(1, wrap.contentWidth), height: .greatestFiniteMagnitude))
            container.lineFragmentPadding = 0
            layoutManager.textContainer = container
            var lines: [NSTextLineFragment] = []
            layoutManager.enumerateTextLayoutFragments(
                from: layoutManager.documentRange.location, options: [.ensuresLayout]
            ) { frag in
                lines.append(contentsOf: frag.textLineFragments)
                return true
            }
            resolved.append((wrap, lines))
            stacks.append((contentStorage, layoutManager, container))
        }
        self.resolvedCellWraps = resolved
        self.scratchStacks = stacks
        super.init(textElement: textElement, range: range)
    }

    /// Where a wrapped cell's first line starts, relative to the fragment's
    /// top: the row's own line box does not start at the fragment's edge (the
    /// row paragraph reserves `paragraphSpacingBefore` above it), and a wrapped
    /// cell has to sit on that same line, not above it.
    private var cellWrapTopInset: CGFloat {
        textLineFragments.first?.typographicBounds.minY ?? 0
    }

    /// The paragraph-relative character index under `point` (fragment
    /// coordinates) when it lands on a wrapped cell's drawn text, else nil.
    ///
    /// The cell's real characters are hidden at ~zero advance and one of them
    /// carries the column's whole kern pad, so the layout manager's own
    /// hit-testing maps every point in the cell to that single character. The
    /// scratch layout holds the very characters the document has (styling never
    /// changes characters — storage == rawSource), so resolving the point
    /// against it instead is exact.
    func cellWrapCharacterIndex(for point: CGPoint) -> Int? {
        for (wrap, lines) in resolvedCellWraps {
            guard point.x >= wrap.x, point.x <= wrap.x + wrap.contentWidth,
                  !lines.isEmpty else { continue }
            var top = cellWrapTopInset
            for (li, line) in lines.enumerated() {
                let height = line.typographicBounds.height
                // Past the last line means the click was in the row's bottom
                // padding — that still belongs to the last line.
                guard point.y < top + height || li == lines.count - 1 else {
                    top += height
                    continue
                }
                let dx = cellWrapLineOffset(line, contentWidth: wrap.contentWidth, align: wrap.align)
                // The line's own bounds carry the scratch container's stacking
                // offset; only its x matters here, so probe at its own midY.
                let local = CGPoint(x: point.x - wrap.x - dx, y: line.typographicBounds.midY)
                let index = line.characterIndex(for: local)
                guard index >= 0 else { return nil }
                return wrap.charStart + index
            }
        }
        return nil
    }

    /// The inverse of `cellWrapCharacterIndex`: fragment-local rects covering
    /// the part of `range` (paragraph-relative) that falls inside a wrapped
    /// cell's drawn text, one rect per visual line it spans. A zero-length
    /// range yields the caret's single zero-width rect. Empty when the range
    /// touches no wrapped cell, which is every row whose cells all fit.
    ///
    /// Both line-fragment index APIs count in the scratch string's own
    /// coordinates, not the line's (verified: `characterIndex(for:)` at the
    /// left edge of the second line returns that line's first index, not 0),
    /// so `charStart` is the only shift needed either way.
    func cellWrapRects(forParagraphRange range: NSRange) -> [CGRect] {
        for (wrap, lines) in resolvedCellWraps where !lines.isEmpty {
            let cell = NSRange(location: wrap.charStart, length: wrap.styled.length)
            // A caret sitting on either edge belongs to the cell; a selection
            // has to actually overlap it.
            let local: NSRange
            if range.length == 0 {
                guard range.location >= cell.location,
                      range.location <= cell.upperBound else { continue }
                local = NSRange(location: range.location - wrap.charStart, length: 0)
            } else {
                let hit = NSIntersectionRange(range, cell)
                guard hit.length > 0 else { continue }
                local = NSRange(location: hit.location - wrap.charStart, length: hit.length)
            }

            var rects: [CGRect] = []
            var top = cellWrapTopInset
            for line in lines {
                let height = line.typographicBounds.height
                let lineRange = line.characterRange
                let dx = cellWrapLineOffset(line, contentWidth: wrap.contentWidth,
                                            align: wrap.align)
                defer { top += height }
                if local.length == 0 {
                    // The caret goes on the first line that can hold it, which
                    // at a soft break is the line it broke *from* — the same
                    // line a click at that point would have resolved to.
                    guard local.location < lineRange.upperBound
                            || line === lines.last else { continue }
                    let x = line.locationForCharacter(
                        at: min(local.location, lineRange.upperBound)).x
                    return [CGRect(x: wrap.x + dx + x, y: top, width: 0, height: height)]
                }
                let hit = NSIntersectionRange(local, lineRange)
                guard hit.length > 0 else { continue }
                let from = line.locationForCharacter(at: hit.location).x
                let to = line.locationForCharacter(at: hit.upperBound).x
                rects.append(CGRect(x: wrap.x + dx + from, y: top,
                                    width: to - from, height: height))
            }
            if !rects.isEmpty { return rects }
        }
        return []
    }

    /// The paragraph offset one visual line up (`-1`) or down (`+1`) from
    /// `offset`, inside the wrapped cell holding it. Nil when the offset is not
    /// in a wrapped cell or the move would leave it — the caller then hands the
    /// key back to ordinary vertical movement, which walks to the row above or
    /// below.
    func cellWrapOffset(fromParagraphOffset offset: Int, lineDelta: Int) -> Int? {
        for (wrap, lines) in resolvedCellWraps where !lines.isEmpty {
            let cell = NSRange(location: wrap.charStart, length: wrap.styled.length)
            guard offset >= cell.location, offset <= cell.upperBound else { continue }
            let local = offset - wrap.charStart
            guard let index = lines.firstIndex(where: {
                local < $0.characterRange.upperBound
            }) ?? (lines.indices.last) else { return nil }
            let target = index + lineDelta
            guard lines.indices.contains(target) else { return nil }
            let here = lines[index], there = lines[target]
            // Alignment shifts each line independently, so the x has to be
            // taken back out of the source line's shift and into the target's.
            let dxHere = cellWrapLineOffset(here, contentWidth: wrap.contentWidth,
                                            align: wrap.align)
            let dxThere = cellWrapLineOffset(there, contentWidth: wrap.contentWidth,
                                             align: wrap.align)
            let x = here.locationForCharacter(
                at: min(local, here.characterRange.upperBound)).x
            let hit = there.characterIndex(
                for: CGPoint(x: x + dxHere - dxThere, y: there.typographicBounds.midY))
            guard hit >= 0 else { return nil }
            return wrap.charStart + hit
        }
        return nil
    }

    /// Extra row height needed to fit the tallest wrapped cell, beyond the
    /// row's natural (single-line) height.
    private var tableRowExtraHeight: CGFloat {
        guard !resolvedCellWraps.isEmpty else { return 0 }
        let tallest = resolvedCellWraps
            .map { $0.lines.reduce(0) { $0 + $1.typographicBounds.height } }
            .max() ?? 0
        return max(0, tallest - super.layoutFragmentFrame.height)
    }

    required init?(coder: NSCoder) {
        fatalError("DecoratedTextLayoutFragment does not support coding")
    }

    /// Fragment-local x of the text container's left edge. The fragment's
    /// frame hugs the laid-out text, so container x = 0 sits at -frame.minX.
    private var containerLeft: CGFloat { -layoutFragmentFrame.minX }

    private var containerWidth: CGFloat {
        textLayoutManager?.textContainer?.size.width ?? layoutFragmentFrame.width
    }

    /// A box decoration's `bottomPad` grows the fragment's own frame (not just
    /// its drawing): TextKit 2 leaves trailing `paragraphSpacing` out of the
    /// fragment, so padding added that way is dead space — clicks there miss the
    /// text. Making the fragment frame taller means the line fragments stay
    /// anchored at the top, the extra height is genuine clickable space below
    /// the last line, the next block tiles clear of it, and the box (drawn over
    /// the full frame height) covers it. Mirrors how the header's raised
    /// minimumLineHeight makes the top padding clickable text space.
    ///
    /// Padding is *summed* across stacked boxes: when a nested callout is the
    /// last line of its parent, the line needs the nested box's bottom padding
    /// *and* the parent's below it (see `draw`), so both fit.
    private var boxBottomPad: CGFloat {
        decorations.reduce(0) { acc, deco in
            if case .box(_, _, _, _, let bottomPad) = deco.kind { return acc + bottomPad }
            return acc
        }
    }

    /// Height to actually paint a filled decoration (box / left bar) over,
    /// which is *not* always the full frame height. When a callout or quote is
    /// the last block AND the document ends with a newline, TextKit 2 folds the
    /// document's final empty line into this (the preceding) layout fragment
    /// instead of giving it its own fragment — it shows up as a trailing
    /// zero-length line fragment. Painting the decoration over the full frame
    /// then floods the callout color onto that trailing empty line (the
    /// "extra colored line at the bottom" bug). Detect the absorbed empty line
    /// and stop the fill at the last real content line plus the box's bottom
    /// padding.
    var decorationDrawHeight: CGFloat {
        let full = layoutFragmentFrame.height
        let lines = textLineFragments
        guard lines.count > 1, let last = lines.last,
              last.characterRange.length == 0 else { return full }
        // Bottom of the last line that actually holds text (fragment-local).
        let contentBottom = lines.dropLast().map { $0.typographicBounds.maxY }.max() ?? 0
        // `super` frame excludes our bottomPad; its extent past the content is
        // exactly the absorbed empty line. Remove that, keep the bottomPad.
        let emptyLineHeight = max(0, super.layoutFragmentFrame.height - contentBottom)
        return max(0, full - emptyLineHeight)
    }

    override var layoutFragmentFrame: CGRect {
        var frame = super.layoutFragmentFrame
        // A row is never both a box and a table row, so at most one of these
        // two is ever nonzero.
        frame.size.height += boxBottomPad + tableRowExtraHeight
        return frame
    }

    override var renderingSurfaceBounds: CGRect {
        var bounds = super.renderingSurfaceBounds
        let frame = layoutFragmentFrame
        if !decorations.isEmpty {
            bounds = bounds.union(CGRect(x: containerLeft - 4, y: 0,
                                         width: containerWidth + 8, height: frame.height))
        }
        // Guides sit left of the item's text, outside the text-hugging frame.
        if !listGuides.isEmpty {
            bounds = bounds.union(CGRect(x: containerLeft, y: 0,
                                         width: containerWidth, height: frame.height))
        }
        for (offset, overlay) in overlays {
            if let rect = overlayRect(anchorOffset: offset, overlay: overlay) {
                bounds = bounds.union(rect.insetBy(dx: -2, dy: -2))
            }
        }
        // The language label sits at the container's right edge, far outside
        // this (short, invisible) fence line's own text frame.
        if let rect = codeBlockLabelRect() {
            bounds = bounds.union(rect.insetBy(dx: -2, dy: -2))
        }
        // The line-ending mark (¬) sits just past the last glyph — give it room.
        if invisibles != nil {
            let frame = layoutFragmentFrame
            bounds = bounds.union(CGRect(x: containerLeft, y: 0,
                                         width: containerWidth + 12, height: frame.height))
        }
        return bounds
    }

    override func draw(at point: CGPoint, in context: CGContext) {
        // Focus mode fades this whole fragment — text, boxes, bars, overlays —
        // as one group. See EditorTextView+FocusMode.
        let dimming = beginFocusDim(in: context)
        defer { endFocusDim(dimming, in: context) }
        context.saveGState()
        drawListGuides(at: point, in: context)
        // Decorations are stacked outermost-first. Each box stops short of the
        // fragment bottom by the padding of the boxes drawn before it, so an
        // outer box's bottom padding stays visible *below* an inner nested box
        // (e.g. the parent callout's padding under a nested callout) instead of
        // being covered by it.
        var precedingBottomPad: CGFloat = 0
        for (index, decoration) in decorations.enumerated() {
            let topInset = index == decorations.count - 1 ? codeBoxTopShave : 0
            drawDecoration(decoration, at: point, in: context,
                           bottomInset: precedingBottomPad, topInset: topInset)
            if case .box(_, _, _, _, let bottomPad) = decoration.kind {
                precedingBottomPad += bottomPad
            }
        }
        context.restoreGState()
        context.saveGState()
        context.setShouldAntialias(antialias)
        super.draw(at: point, in: context)
        context.restoreGState()
        for (offset, overlay) in overlays {
            guard let rect = overlayRect(anchorOffset: offset, overlay: overlay) else { continue }
            let drawRect = rect.offsetBy(dx: point.x, dy: point.y)
            if let image = overlay.image {
                // Draw the (resolution-independent) NSImage into the flipped context,
                // so it rasterizes at the screen's backing scale — crisp on Retina,
                // and positioned precisely. (Converting to a CGImage first would bake
                // it at 1×, then upscale: soft, and quantized a pixel low.) The math
                // image carries a small transparent inset, so the flipped draw can't
                // clip a descender at the image edge.
                let nsContext = NSGraphicsContext(cgContext: context, flipped: true)
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = nsContext
                image.draw(in: deviceAligned(drawRect, in: context), from: .zero,
                           operation: .sourceOver,
                           fraction: 1, respectFlipped: true, hints: nil)
                NSGraphicsContext.restoreGraphicsState()
            } else if let path = overlay.path, let color = overlay.pathColor {
                // Stroke the vector path directly in CG — never rasterize it to
                // an image first: an image drawn on a multi-line fragment wedges
                // its layout to one line (see the FragmentOverlay note). Path
                // coords are bounds-local and y-down, matching this flipped
                // context, so a translate places them.
                context.saveGState()
                context.translateBy(x: drawRect.minX, y: drawRect.minY)
                context.addPath(path)
                context.setStrokeColor(color.cgColor)
                context.setLineWidth(overlay.pathLineWidth)
                context.setLineCap(.round)
                context.setLineJoin(.round)
                context.strokePath()
                context.restoreGState()
            }
        }
        // Overflowing table cells: the real characters are hidden, so draw
        // each cell's pre-wrapped lines here instead, stacked top-down at the
        // cell's column x, each line shifted for the column's alignment.
        for (wrap, lines) in resolvedCellWraps {
            var y = point.y + cellWrapTopInset
            for line in lines {
                let dx = cellWrapLineOffset(line, contentWidth: wrap.contentWidth, align: wrap.align)
                line.draw(at: CGPoint(x: point.x + wrap.x + dx, y: y), in: context)
                y += line.typographicBounds.height
            }
        }
        drawCodeBlockLabel(at: point, in: context)
        drawInvisibles(at: point, in: context)
    }

    /// The excess of this row's glyph cap-top gap (baseline minus capHeight)
    /// over its descender-bottom remainder — the ink asymmetry within one
    /// monospace row. All the block's rows (fences included) share the mono
    /// font, so any row's own first line yields the block-wide value.
    private var codeRowInkGapExcess: CGFloat {
        guard let line = textLineFragments.first,
              line.characterRange.length > 0,
              let font = line.attributedString.attribute(
                  .font, at: line.characterRange.location, effectiveRange: nil) as? NSFont
        else { return 0 }
        let capTopGap = line.glyphOrigin.y - font.capHeight
        // font.descender is negative; glyph ink ends at baseline - descender.
        let bottomGap = line.typographicBounds.height - (line.glyphOrigin.y - font.descender)
        return max(0, capTopGap - bottomGap)
    }

    /// How far below this fragment's top the code box's top edge sits — only
    /// nonzero on a code block's opening fence line (the box's top fragment).
    /// Evens out the box's visible top vs bottom padding, which is otherwise
    /// top-heavy by two asymmetries the closing fence row doesn't mirror:
    /// the lineSpacing TextKit stacks *above* each row's glyphs
    /// (typographicBounds.minY), and the glyph ink gap
    /// (`codeRowInkGapExcess`). Both are shaved so the ink-to-box distances
    /// match.
    private var codeBoxTopShave: CGFloat {
        guard codeBlockLabel != nil, let line = textLineFragments.first else { return 0 }
        return max(0, line.typographicBounds.minY) + codeRowInkGapExcess
    }

    /// Fragment-local rect (y-down, origin at this fragment's top-left) for
    /// the language label: pinned to the code box's top-right corner with the
    /// same 10pt gap on top as on the right — mirroring Read mode's
    /// absolutely-positioned label. Computed on the block's *second* row
    /// (negative y, reaching up over the fence row; see
    /// `.codeBlockLabelAnchor` for why the fence fragment can't draw it).
    /// Nil when this fragment isn't the label row.
    func codeBlockLabelRect() -> CGRect? {
        guard let label = codeBlockLabelAnchor, !label.isEmpty,
              let line = textLineFragments.first else { return nil }
        let size = (label as NSString).size(withAttributes: [.font: codeBlockLabelFont])
        let inset: CGFloat = 10
        // Box top, in this fragment's coords: one fence row above, i.e. the
        // fence row's glyph-row height less the shave's ink-gap part. The
        // fence row shares this row's mono metrics, so its own line stands in.
        let boxTop = -(line.typographicBounds.height - codeRowInkGapExcess)
        // Align the label's ink top (not its line-box top) to the 10pt gap.
        let inkTopBearing = max(0, codeBlockLabelFont.ascender - codeBlockLabelFont.capHeight)
        return CGRect(x: containerLeft + containerWidth - ceil(size.width) - inset,
                      y: boxTop + inset - inkTopBearing,
                      width: ceil(size.width), height: ceil(size.height))
    }

    /// Paints the language label at `codeBlockLabelRect()` — direct
    /// `NSAttributedString` drawing, not an `NSImage`, so this stays outside
    /// the proven image-wedge mechanism (an image on a wrapping fragment
    /// wedges its layout to one line; see FragmentOverlay).
    private func drawCodeBlockLabel(at point: CGPoint, in context: CGContext) {
        guard let label = codeBlockLabelAnchor, let rect = codeBlockLabelRect() else { return }
        let drawRect = rect.offsetBy(dx: point.x, dy: point.y)
        let nsContext = NSGraphicsContext(cgContext: context, flipped: true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = nsContext
        NSAttributedString(string: label, attributes: [
            .font: codeBlockLabelFont, .foregroundColor: NSColor.secondaryLabelColor,
        ]).draw(at: drawRect.origin)
        NSGraphicsContext.restoreGraphicsState()
    }

    /// `rect` with its origin moved to the nearest whole device pixel, leaving
    /// its size alone. An overlay is anchored to a text baseline (and display
    /// math to a centered x), so its origin is essentially never pixel-aligned —
    /// and a bitmap blitted to a fractional device offset gets resampled, which
    /// spread the same ink over ~39% more device pixels and made equations look
    /// bolder in Edit mode than in Read mode. Rounding happens in *device* space,
    /// not user space, because a scrolled clip view can leave the CTM's own
    /// translation on a fraction of a point.
    private func deviceAligned(_ rect: CGRect, in context: CGContext) -> CGRect {
        var device = context.convertToDeviceSpace(rect.origin)
        device.x.round()
        device.y.round()
        return CGRect(origin: context.convertToUserSpace(device), size: rect.size)
    }

    /// Fragment-local rect for an overlay image, anchored to the character at
    /// the given paragraph-relative offset.
    private func overlayRect(anchorOffset: Int, overlay: FragmentOverlay) -> CGRect? {
        guard let line = textLineFragments.first(where: {
            NSLocationInRange(anchorOffset, $0.characterRange)
        }) ?? textLineFragments.last else { return nil }
        let anchorX = line.typographicBounds.minX
            + line.locationForCharacter(at: anchorOffset).x
        // Baseline (flipped coords): the line's glyph origin sits at its
        // typographic origin plus the ascent-derived glyph origin.
        let baselineY = line.typographicBounds.minY + line.glyphOrigin.y
        return CGRect(x: anchorX + overlay.bounds.minX,
                      y: baselineY - overlay.bounds.height - overlay.bounds.minY,
                      width: overlay.bounds.width,
                      height: overlay.bounds.height)
    }

    /// Fragment-local y of the first line's glyph top (baseline minus the
    /// line's font ascender). The line box can hold extra space above the
    /// glyphs (lineSpacing lands there), which a text-hugging bar skips.
    private var firstLineGlyphTop: CGFloat? {
        guard let line = textLineFragments.first,
              line.characterRange.length > 0,
              let font = line.attributedString.attribute(
                  .font, at: line.characterRange.location, effectiveRange: nil) as? NSFont
        else { return nil }
        return line.typographicBounds.minY + line.glyphOrigin.y - font.ascender
    }

    /// The gray for editor chrome drawn as thin lines (table borders, list
    /// indent guides). In dark mode `separatorColor` is ~10% ink and all but
    /// vanishes, so use the shared marker gray there; light mode keeps
    /// `separatorColor`. Read mode's `--table-border` matches.
    private var chromeLineColor: NSColor {
        NSAppearance.currentDrawing().bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? EditorTextView.darkRuleGray : NSColor.separatorColor
    }

    /// Vertical hairlines marking a list item's indent columns, drawn under the
    /// text. Offsets are container-relative, so they land on the same columns as
    /// the markers no matter how this item's own first line is indented (an
    /// ordered or active marker shifts `point.x`, which is the *text* start —
    /// hence `containerLeft` rather than `point.x` alone). They are measured
    /// from the container's text origin, which sits `lineFragmentPadding` in
    /// from its left edge — the same origin the paragraph's head indents use.
    ///
    /// All but the last offset are the item's ancestor columns, spanning its
    /// whole height: consecutive list items tile with no gap (list paragraphs
    /// carry no paragraph spacing), so the per-fragment fills read as one
    /// continuous line down a nested run. Height is `decorationDrawHeight`, not
    /// the raw frame, so a list at the end of the document doesn't paint a stub
    /// over the absorbed trailing empty line.
    ///
    /// The last offset is the item's *own* column, drawn only from its second
    /// line down — a wrapped continuation line then stays visibly tied to its
    /// own bullet, while the first line leaves room for the marker itself.
    private func drawListGuides(at point: CGPoint, in context: CGContext) {
        guard !listGuides.isEmpty else { return }
        // Filled at exactly one device pixel rather than stroked, for the same
        // reason as the table's column borders — see `.tableRow`.
        let scale = max(1, abs(context.convertToDeviceSpace(CGSize(width: 1, height: 1)).width))
        let hairline = 1 / scale
        let padding = textLayoutManager?.textContainer?.lineFragmentPadding ?? 0
        let originX = point.x + containerLeft + padding
        let height = decorationDrawHeight
        context.setFillColor(chromeLineColor.cgColor)

        func fill(_ offset: CGFloat, from top: CGFloat) {
            guard height > top else { return }
            let lineX = (((originX + offset) * scale).rounded()) / scale
            context.fill(CGRect(x: lineX, y: point.y + top,
                                width: hairline, height: height - top))
        }

        for offset in listGuides.dropLast() { fill(offset, from: 0) }
        // Second *real* line: a trailing zero-length line is the document's
        // final empty line absorbed into this fragment, not a wrapped line.
        if let wrapped = textLineFragments.filter({ $0.characterRange.length > 0 })
            .dropFirst().first, let own = listGuides.last {
            fill(own, from: wrapped.typographicBounds.minY)
        }
    }

    private func drawDecoration(_ decoration: BlockDecoration, at point: CGPoint,
                                in context: CGContext, bottomInset: CGFloat = 0,
                                topInset: CGFloat = 0) {
        let frame = layoutFragmentFrame
        // Filled decorations (box, bar) stop above an absorbed trailing empty
        // line; center-line decorations (rule, table) still use the full frame.
        let fillHeight = decorationDrawHeight
        // Fragment-local rect spanning the full text column for this fragment.
        let columnRect = CGRect(x: point.x + containerLeft, y: point.y,
                                width: containerWidth, height: fillHeight)

        switch decoration.kind {
        case .box(let background, let borderColor, let edges, let borderWidth, _):
            // The fragment frame already includes any box bottomPad (see
            // layoutFragmentFrame), so columnRect covers the padded area. A
            // nested box insets symmetrically so it sits within its parent box,
            // and stops `bottomInset` short of the frame bottom so the enclosing
            // box's padding shows below it.
            var columnRect = decoration.inset > 0
                ? columnRect.insetBy(dx: decoration.inset, dy: 0)
                : columnRect
            columnRect.size.height -= bottomInset + topInset
            columnRect.origin.y += topInset
            context.setFillColor(background.cgColor)
            context.fill(columnRect)
            if let borderColor, !edges.isEmpty {
                context.setFillColor(borderColor.cgColor)
                if edges.contains(.left) {
                    context.fill(CGRect(x: columnRect.minX, y: columnRect.minY,
                                        width: borderWidth, height: columnRect.height))
                }
                if edges.contains(.right) {
                    context.fill(CGRect(x: columnRect.maxX - borderWidth, y: columnRect.minY,
                                        width: borderWidth, height: columnRect.height))
                }
                if edges.contains(.top) {
                    context.fill(CGRect(x: columnRect.minX, y: columnRect.minY,
                                        width: columnRect.width, height: borderWidth))
                }
                if edges.contains(.bottom) {
                    context.fill(CGRect(x: columnRect.minX, y: columnRect.maxY - borderWidth,
                                        width: columnRect.width, height: borderWidth))
                }
            }

        case .leftBar(let color, let width):
            // The bar sits immediately left of the text (the paragraph style
            // insets the text by the bar's width) — or `inset` further right,
            // for a nested quote's bar next to its own level's text.
            var barTop = point.y
            var barHeight = fillHeight
            if decoration.hugsTextTop, let glyphTop = firstLineGlyphTop {
                barTop += glyphTop
                barHeight -= glyphTop
            }
            context.setFillColor(color.cgColor)
            context.fill(CGRect(x: point.x - width + decoration.inset, y: barTop,
                                width: width, height: barHeight))

        case .tableRow(let xOffsets, let width, let leftInset, let separator,
                       let bottomBorder, let topInset):
            // Offsets are text-relative; the fragment's origin is the text start.
            let borderColor = chromeLineColor
            // Column borders are FILLED at exactly one device pixel rather than
            // stroked: a 1pt stroke straddling a pixel boundary lands on two
            // device rows on a Retina display, which made the verticals read
            // twice as heavy as the row rules beside them.
            // `ctm.a` reports the user-space transform only (1 even on Retina);
            // converting a unit size into device space gives the real backing scale.
            let scale = max(1, abs(context.convertToDeviceSpace(CGSize(width: 1, height: 1)).width))
            let hairline = 1 / scale
            context.setFillColor(borderColor.cgColor)
            // The table is closed on all four sides, like Notes': the two outer
            // verticals join the column borders, and the header carries the top
            // rule the way the last row carries the bottom one. A closed grid is
            // also what lets a cell-selection box stand on a real line wherever
            // it is drawn, rather than floating at an open edge.
            for x in [0] + xOffsets + [width - leftInset] {
                let lineX = (((point.x + x - (x == 0 ? leftInset : 0)) * scale).rounded()) / scale
                context.fill(CGRect(x: lineX, y: point.y + topInset,
                                    width: hairline, height: frame.height - topInset))
            }
            // Filled at one device pixel, exactly like the column borders above
            // — a 1pt stroke is two device rows on a Retina display, which is
            // what made the row rules read twice the weight of the verticals
            // they meet. The whole grid is one hairline now.
            func rule(atY y: CGFloat) {
                let lineY = ((y * scale).rounded()) / scale
                context.fill(CGRect(x: point.x - leftInset, y: lineY,
                                    width: width, height: hairline))
            }
            // `topInset` is reserved only by the header row, so it also says
            // which row owns the table's top edge.
            if topInset > 0 { rule(atY: point.y + topInset) }
            if separator { rule(atY: point.y + frame.height / 2) }
            // Inside the drawing row, not below it: the row beneath repaints on
            // its own (a caret move restyles one row and dirties only its
            // rect), and it would erase a line it knows nothing about — the row
            // that owns the line never being asked to draw it again.
            if bottomBorder { rule(atY: point.y + frame.height - hairline) }

        case .horizontalRule(let color, let centerOffset):
            // Filled at a fixed 3 device pixels (1.5pt on Retina) rather than
            // stroked at 1pt: a section divider wants a little more presence
            // than a table gridline, and filling keeps the edges crisp.
            let scale = max(1, abs(context.convertToDeviceSpace(CGSize(width: 1, height: 1)).width))
            let thickness = 3 / scale
            let y = ((point.y + frame.height / 2 + centerOffset) * scale).rounded() / scale
            context.setFillColor(color.cgColor)
            context.fill(CGRect(x: columnRect.minX, y: y,
                                width: columnRect.maxX - columnRect.minX, height: thickness))
        }
    }
}

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
