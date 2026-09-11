import SwiftUI
import AppKit

/// A label that previews a font by drawing its name in that font, with optional
/// antialiasing control — the bezeled font-display field used in the Appearance
/// settings (mirrors CotEditor's `AntialiasingText`).
struct AntialiasingText: NSViewRepresentable {
    private var text: String
    private var antialiasDisabled = false
    private var font: NSFont?
    private var alignment: NSTextAlignment = .center
    private var clickThrough = false
    private var isPlain = false

    init(_ text: String) {
        self.text = text
    }

    func makeNSView(context: Context) -> NSTextField {
        let nsView = AntialiasingTextField(string: text)
        nsView.isEditable = false
        nsView.isSelectable = false
        nsView.lineBreakMode = .byTruncatingMiddle
        nsView.allowsExpansionToolTips = true
        nsView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // Pin a fixed, stable height so a 16pt preview fits with a little
        // breathing room. (Deriving it from `frame.height` collapses the field —
        // the frame is zero-height before Auto Layout has sized it.) A plain
        // field lives in a 20pt list row and draws at 12pt, so it takes less.
        nsView.heightAnchor.constraint(equalToConstant: isPlain ? 18 : 24).isActive = true

        return nsView
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        nsView.stringValue = text
        nsView.font = font
        nsView.alignment = alignment
        (nsView as? AntialiasingTextField)?.antialiasDisabled = antialiasDisabled
        (nsView as? AntialiasingTextField)?.clickThrough = clickThrough
        // Only ever written when opting OUT of the bezel. `NSTextField(string:)`
        // comes up bezeled, and `isBordered = true` is not the same thing — it
        // is the flat square border — so writing it on the default path turned
        // the font rows' fields into something they had never been.
        if isPlain {
            nsView.isBordered = false
            nsView.drawsBackground = false
        }
    }

    /// Sets whether antialiasing is disabled when drawing the text.
    func antialiasDisabled(_ disabled: Bool = true) -> Self {
        var view = self
        view.antialiasDisabled = disabled
        return view
    }

    /// Puts the field's own text baseline on the row's, for a label beside it
    /// under `.firstTextBaseline`.
    ///
    /// It has to be said here, in SwiftUI: a representable carries no text
    /// baseline of its own, so `.firstTextBaseline` falls back to the view's
    /// bottom edge and the label sits a few points low. Overriding the NSView's
    /// `firstBaselineOffsetFromTop` does nothing — SwiftUI never asks a
    /// representable for it (verified: the override was never called).
    ///
    /// The arithmetic mirrors `CenteringTextFieldCell.titleRect`, which is what
    /// actually draws the title: centered in the field, so the baseline lands an
    /// ascender below the top of that centered line box.
    /// Measured out here, not in the closure: an alignment guide's closure is
    /// `@Sendable`, so it cannot reach the view's own main-actor state (nor
    /// carry an NSFont across). Two CGFloats are all the arithmetic needs.
    func baselineAligned() -> some View {
        let metrics: (titleHeight: CGFloat, ascender: CGFloat)? = font.map {
            (NSAttributedString(string: text, attributes: [.font: $0]).size().height,
             $0.ascender)
        }
        return alignmentGuide(.firstTextBaseline) { dimensions in
            guard let metrics else { return dimensions[.firstTextBaseline] }
            let top = ((dimensions.height - metrics.titleHeight) / 2).rounded(.up)
            return top + metrics.ascender
        }
    }

    /// Drops the bezel and background. The font rows keep theirs — a bezeled
    /// field is what the Appearance pane has always shown there — but inside the
    /// script list the box's own border already frames the column, and a second
    /// one around each sample reads as an editable field, which it is not.
    func plain(_ plain: Bool = true) -> Self {
        var view = self
        view.isPlain = plain
        return view
    }

    /// Lets clicks fall through to whatever is behind the field. For the script
    /// rows, which wrap this in a Button: an AppKit view that hit-tests to
    /// itself eats every click before SwiftUI sees it. Off by default, so the
    /// font rows keep their hover tooltip for a truncated name.
    func clickThrough(_ passes: Bool = true) -> Self {
        var view = self
        view.clickThrough = passes
        return view
    }

    /// Sets the text alignment. Centered by default — the font rows draw the
    /// preview in a fixed-width field of its own — but a column in a list reads
    /// as a column only when its values start on one edge.
    func alignment(_ alignment: NSTextAlignment) -> Self {
        var view = self
        view.alignment = alignment
        return view
    }

    /// Sets the font to preview the text in.
    func font(nsFont font: NSFont?) -> Self {
        var view = self
        view.font = font
        return view
    }
}

private final class AntialiasingTextField: NSTextField {
    var antialiasDisabled = false {
        didSet { needsDisplay = true }
    }

    override static var cellClass: AnyClass? {
        get { CenteringTextFieldCell.self }
        set { _ = newValue }
    }

    /// See `AntialiasingText.clickThrough()`. Only the rows that sit inside a
    /// Button turn this on; elsewhere the field keeps its own hit region so
    /// `allowsExpansionToolTips` can show a truncated name on hover.
    var clickThrough = false

    override func hitTest(_ point: NSPoint) -> NSView? {
        clickThrough ? nil : super.hitTest(point)
    }

    override func draw(_ dirtyRect: NSRect) {
        if antialiasDisabled {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current?.shouldAntialias = false
        }
        super.draw(dirtyRect)
        if antialiasDisabled {
            NSGraphicsContext.restoreGraphicsState()
        }
    }
}

private final class CenteringTextFieldCell: NSTextFieldCell {
    override func titleRect(forBounds rect: NSRect) -> NSRect {
        var titleRect = super.titleRect(forBounds: rect)
        let titleSize = attributedStringValue.size()
        titleRect.origin.y = (rect.minY + (rect.height - titleSize.height) / 2).rounded(.up)
        titleRect.size.height = rect.height - titleRect.origin.y
        return titleRect
    }

    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
        attributedStringValue.draw(in: titleRect(forBounds: cellFrame))
    }
}
