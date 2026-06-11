import AppKit

// MARK: - TextKit 2 Support
//
// The editor runs on TextKit 2 (NSTextLayoutManager): layout is viewport-based
// — the system only lays out what's on screen, which is what makes large
// documents tractable. The hard rule that follows: never touch
// `NSTextView.layoutManager` or store NSTextBlock/NSTextTable attributes —
// either silently switches the view back to TextKit 1 for good.
//
// Block decorations (callout boxes, quote bars, table borders, thematic
// breaks) that used to be NSTextBlock subclasses are now drawn by a custom
// NSTextLayoutFragment: styling stores a `.blockDecoration` attribute on the
// paragraph, and the layout-manager delegate vends a DecoratedTextLayoutFragment
// for paragraphs that carry one. Backgrounds tile per paragraph fragment, so a
// multi-line quote run still renders as one continuous box/bar.

public extension NSAttributedString.Key {
    /// Paragraph-level decoration drawn behind the text by
    /// `DecoratedTextLayoutFragment`. Value: `BlockDecoration`.
    static let blockDecoration = NSAttributedString.Key("MarkdownEditor.blockDecoration")
}

/// Value object describing what to draw behind a decorated paragraph.
/// Reference type (NSObject) so it lives in attributed strings; value
/// equality so attribute-run merging and the test oracle behave.
public final class BlockDecoration: NSObject, @unchecked Sendable {

    public enum Kind: Equatable {
        /// Filled box across the fragment (callouts), with optional borders.
        case box(background: NSColor, borderColor: NSColor?,
                 borderEdges: CalloutStyle.Edges, borderWidth: CGFloat)
        /// Vertical bar at the fragment's left edge (plain block quotes).
        case leftBar(color: NSColor, width: CGFloat)
        /// Table-row chrome: vertical column borders (x offsets measured from
        /// the row's left inset), and a horizontal rule through the separator
        /// row. `width` is the table's full width.
        case tableRow(columnXOffsets: [CGFloat], width: CGFloat,
                      leftInset: CGFloat, separator: Bool)
        /// Horizontal hairline centered in the fragment (thematic break).
        case horizontalRule(color: NSColor)
    }

    public let kind: Kind

    public init(_ kind: Kind) {
        self.kind = kind
    }

    public override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? BlockDecoration else { return false }
        return kind == other.kind
    }

    public override var hash: Int {
        switch kind {
        case .box: return 1
        case .leftBar: return 2
        case .tableRow: return 3
        case .horizontalRule: return 4
        }
    }
}

/// Layout fragment that draws its paragraph's `BlockDecoration` behind the
/// text. Fragment frames tile vertically, so per-paragraph drawing of the
/// same box/bar renders as one continuous shape across a multi-line block.
final class DecoratedTextLayoutFragment: NSTextLayoutFragment {

    let decoration: BlockDecoration

    init(textElement: NSTextElement, range: NSTextRange?, decoration: BlockDecoration) {
        self.decoration = decoration
        super.init(textElement: textElement, range: range)
    }

    required init?(coder: NSCoder) {
        fatalError("DecoratedTextLayoutFragment does not support coding")
    }

    override var renderingSurfaceBounds: CGRect {
        // The decoration spans the full fragment, which can be wider than the
        // text's own surface bounds (e.g. a box behind a short line).
        CGRect(origin: .zero, size: layoutFragmentFrame.size)
            .union(super.renderingSurfaceBounds)
    }

    override func draw(at point: CGPoint, in context: CGContext) {
        context.saveGState()
        // Fragment-local (0,0) maps to `point` in the context.
        let frame = CGRect(origin: point, size: layoutFragmentFrame.size)

        switch decoration.kind {
        case .box(let background, let borderColor, let edges, let borderWidth):
            context.setFillColor(background.cgColor)
            context.fill(frame)
            if let borderColor, !edges.isEmpty {
                context.setFillColor(borderColor.cgColor)
                if edges.contains(.left) {
                    context.fill(CGRect(x: frame.minX, y: frame.minY,
                                        width: borderWidth, height: frame.height))
                }
                if edges.contains(.right) {
                    context.fill(CGRect(x: frame.maxX - borderWidth, y: frame.minY,
                                        width: borderWidth, height: frame.height))
                }
                if edges.contains(.top) {
                    context.fill(CGRect(x: frame.minX, y: frame.minY,
                                        width: frame.width, height: borderWidth))
                }
                if edges.contains(.bottom) {
                    context.fill(CGRect(x: frame.minX, y: frame.maxY - borderWidth,
                                        width: frame.width, height: borderWidth))
                }
            }

        case .leftBar(let color, let width):
            context.setFillColor(color.cgColor)
            context.fill(CGRect(x: frame.minX, y: frame.minY,
                                width: width, height: frame.height))

        case .tableRow(let xOffsets, let width, let leftInset, let separator):
            context.setStrokeColor(NSColor.separatorColor.cgColor)
            context.setLineWidth(1)
            for x in xOffsets {
                let lineX = round(frame.minX + leftInset + x) + 0.5
                context.move(to: CGPoint(x: lineX, y: frame.minY))
                context.addLine(to: CGPoint(x: lineX, y: frame.maxY))
            }
            if separator {
                let y = round(frame.midY) + 0.5
                context.move(to: CGPoint(x: frame.minX, y: y))
                context.addLine(to: CGPoint(x: frame.minX + width, y: y))
            }
            context.strokePath()

        case .horizontalRule(let color):
            context.setStrokeColor(color.cgColor)
            context.setLineWidth(1)
            let y = round(frame.midY) + 0.5
            context.move(to: CGPoint(x: frame.minX, y: y))
            context.addLine(to: CGPoint(x: frame.maxX, y: y))
            context.strokePath()
        }

        context.restoreGState()
        super.draw(at: point, in: context)
    }
}

// MARK: - Fragment Vending

extension EditorTextView: NSTextLayoutManagerDelegate {
    public nonisolated func textLayoutManager(
        _ textLayoutManager: NSTextLayoutManager,
        textLayoutFragmentFor location: NSTextLocation,
        in textElement: NSTextElement
    ) -> NSTextLayoutFragment {
        if let paragraph = textElement as? NSTextParagraph,
           paragraph.attributedString.length > 0,
           let decoration = paragraph.attributedString.attribute(
               .blockDecoration, at: 0, effectiveRange: nil) as? BlockDecoration {
            return DecoratedTextLayoutFragment(textElement: textElement,
                                               range: textElement.elementRange,
                                               decoration: decoration)
        }
        return NSTextLayoutFragment(textElement: textElement,
                                    range: textElement.elementRange)
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
