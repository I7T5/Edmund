import AppKit

// MARK: - Shared chrome bar base

/// A top bar that reads as window chrome: the titlebar material the toolbar
/// uses, plus a hairline along the bottom edge matching the toolbar separator.
/// Shared by the find bar and the format bar.
class ChromeBarView: NSVisualEffectView {

    /// The hairline along the bottom edge, matching the toolbar's separator so
    /// the bar reads as window chrome. A subview, not a `draw(_:)` override:
    /// `NSVisualEffectView` renders its material through layers and never calls
    /// through to a custom `draw`. Pinned to the bottom.
    private let bottomBorder = NSView()

    /// The bar's height for its active state (drives the content inset).
    /// `fittingSize` already carries the layout's top/bottom insets.
    var preferredHeight: CGFloat {
        layoutSubtreeIfNeeded()
        return fittingSize.height
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        material = .titlebar
        // `.withinWindow` would sample the editor content behind the bar
        // (frosted-white over text), which reads as a floating panel instead
        // of window chrome. `.behindWindow` samples the window backdrop the
        // way the titlebar/toolbar does, so the bar matches them.
        blendingMode = .behindWindow
        state = .active

        bottomBorder.wantsLayer = true
        bottomBorder.layer?.backgroundColor = NSColor.separatorColor.cgColor
        bottomBorder.translatesAutoresizingMaskIntoConstraints = false
        addSubview(bottomBorder)
        NSLayoutConstraint.activate([
            bottomBorder.leadingAnchor.constraint(equalTo: leadingAnchor),
            bottomBorder.trailingAnchor.constraint(equalTo: trailingAnchor),
            bottomBorder.bottomAnchor.constraint(equalTo: bottomAnchor),
            bottomBorder.heightAnchor.constraint(equalToConstant: 1 / (NSScreen.main?.backingScaleFactor ?? 2)),
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Keeps the hairline's colour correct across a light/dark switch — a
    /// `cgColor` snapshot doesn't follow the appearance on its own.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance {
            bottomBorder.layer?.backgroundColor = NSColor.separatorColor.cgColor
        }
    }
}
