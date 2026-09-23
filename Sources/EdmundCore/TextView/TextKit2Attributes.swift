import AppKit

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
