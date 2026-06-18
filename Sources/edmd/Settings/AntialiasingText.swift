import SwiftUI
import AppKit

/// A label that previews a font by drawing its name in that font, with optional
/// antialiasing control — the bezeled font-display field used in the Appearance
/// settings (mirrors CotEditor's `AntialiasingText`).
struct AntialiasingText: NSViewRepresentable {
    private var text: String
    private var antialiasDisabled = false
    private var font: NSFont?

    init(_ text: String) {
        self.text = text
    }

    func makeNSView(context: Context) -> NSTextField {
        let nsView = AntialiasingTextField(string: text)
        nsView.isEditable = false
        nsView.isSelectable = false
        nsView.alignment = .center
        nsView.lineBreakMode = .byTruncatingMiddle
        nsView.allowsExpansionToolTips = true
        nsView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // Pin a fixed, stable height so a 16pt preview fits with a little
        // breathing room. (Deriving it from `frame.height` collapses the field —
        // the frame is zero-height before Auto Layout has sized it.)
        nsView.heightAnchor.constraint(equalToConstant: 24).isActive = true

        return nsView
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        nsView.stringValue = text
        nsView.font = font
        (nsView as? AntialiasingTextField)?.antialiasDisabled = antialiasDisabled
    }

    /// Sets whether antialiasing is disabled when drawing the text.
    func antialiasDisabled(_ disabled: Bool = true) -> Self {
        var view = self
        view.antialiasDisabled = disabled
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
