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
        // `.withinWindow`, not `.behindWindow`: behind-window blending samples
        // what is behind the *window* — the desktop — so the bar tracked the
        // wallpaper instead of the chrome. It looked right only because this
        // wallpaper happens to be near the light-mode chrome colour; in dark
        // mode the bar measured 40 levels lighter than the toolbar above it.
        blendingMode = .withinWindow
        // Follows the window, so the bar dims with the toolbar when the window
        // stops being key. `.active` pinned it bright on inactive windows.
        state = .followsWindowActiveState

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
