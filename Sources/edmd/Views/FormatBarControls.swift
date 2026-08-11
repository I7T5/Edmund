import AppKit

// MARK: - Format bar control chrome
//
// The rounded chip that appears behind a bar control on hover and stays put
// while the formatting under the caret is in effect — the accessory-bar idiom
// Mail uses. AppKit has no borderless button style that does this, so it is
// drawn here.

/// The chip itself. A helper object rather than a base class because the two
/// control kinds cannot share one: `NSPopUpButton` is already an `NSButton`, so
/// a common superclass would have to be `NSButton` and the pulldown could not
/// inherit from it.
@MainActor
final class BarControlChip {

    /// One size for every chip on the bar, pulldowns included. Deliberately not
    /// the control's own bounds: those follow each symbol's intrinsic size, and
    /// letting the chip track them made the highlighter's 23.5pt tall and the
    /// callout pulldown's 17pt — the same affordance in a dozen sizes.
    static let height: CGFloat = 20

    /// Horizontal breathing room inside the control, so a chip cannot reach the
    /// group's dividers even before the adjacent one is hidden.
    private static let insetX: CGFloat = 1

    /// Pointer is over the control.
    var isHovered = false { didSet { if isHovered != oldValue { refresh() } } }

    /// The formatting this control applies is in effect at the selection.
    var isActive = false { didSet { if isActive != oldValue { refresh() } } }

    /// Told to the owning group so it can re-run its divider rule.
    var onChange: (() -> Void)?

    private let chip = CALayer()
    private unowned let host: NSView

    init(host: NSView) {
        self.host = host
        host.wantsLayer = true
        chip.cornerRadius = 5
        chip.cornerCurve = .continuous
        // Behind the control's own drawing, never over the glyph.
        host.layer?.insertSublayer(chip, at: 0)
    }

    /// Called from the host's `layout()`. Centred on the *bar*, not on the
    /// control.
    ///
    /// Centring on the control looked equivalent and was not: the controls do
    /// not all share a height, and each one centred inside its own frame put
    /// its chip a pixel or two off its neighbour's. Worse, they were off in the
    /// same direction — 3.0pt of bar above the chip against 4.5pt below. Taking
    /// the centre line from the bar means every chip on it resolves to one
    /// vertical position, and the gap above equals the gap below by
    /// construction.
    func layoutChip() {
        // No implicit fade as the control moves during a resize.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        chip.frame = NSRect(x: Self.insetX, y: chipOriginY,
                            width: max(0, host.bounds.width - Self.insetX * 2),
                            height: Self.height)
        CATransaction.commit()
    }

    /// The chip's bottom edge in the host's coordinates, placed so the chip
    /// straddles the bar's centre line. Falls back to centring on the control
    /// before the view is in a bar.
    private var chipOriginY: CGFloat {
        var bar: NSView? = host.superview
        while let candidate = bar, !(candidate is ChromeBarView) { bar = candidate.superview }
        guard let chrome = bar as? ChromeBarView else {
            return ((host.bounds.height - Self.height) / 2).rounded()
        }
        let centre = host.convert(NSPoint(x: 0, y: chrome.interior.midY), from: chrome)
        return centre.y - Self.height / 2
    }

    /// Re-resolves the fill. Semantic colours are stored as `cgColor`, which is
    /// a snapshot that does not follow a light/dark switch, so this has to run
    /// again on an appearance change — same trap as the bar's hairline.
    func refresh() {
        host.effectiveAppearance.performAsCurrentDrawingAppearance {
            chip.backgroundColor = fill?.cgColor
        }
        onChange?()
    }

    /// Active wins over hover: the chip is the on-state indicator first, and a
    /// pointer passing over it must not read as switching it off.
    private var fill: NSColor? {
        if isActive { return .unemphasizedSelectedContentBackgroundColor }
        if isHovered { return .quaternaryLabelColor }
        return nil
    }
}

// MARK: - Group

/// One group of bar controls: the buttons run together with a hairline between
/// each adjacent pair.
///
/// The group owns the rule that a divider disappears while either of the two
/// controls it separates is *on*. That is how Mail draws it — look at its
/// alignment group, where the divider beside the selected button is simply
/// absent.
///
/// Hover deliberately does not do this. A divider vanishing under the pointer
/// made the group twitch as it moved along the row, and the chip does not need
/// the room: it is inset inside its control and the group's spacing keeps it
/// clear of the hairlines on its own.
final class FormatBarGroupView: NSStackView {

    /// Members and dividers in visual order: `dividers[i]` sits between
    /// `chips[i]` and `chips[i + 1]`.
    private var chips: [BarControlChip] = []
    private var dividers: [NSView] = []

    func adopt(chips: [BarControlChip], dividers: [NSView]) {
        self.chips = chips
        self.dividers = dividers
        for chip in chips { chip.onChange = { [weak self] in self?.updateDividers() } }
        updateDividers()
    }

    /// A hidden arranged subview is removed from an `NSStackView`'s layout, so
    /// the buttons would close up and shuffle sideways every time a chip
    /// appeared. `alphaValue` keeps the divider in the layout and only stops it
    /// drawing.
    private func updateDividers() {
        // Every divider sits between two controls, so anything else means the
        // two arrays were built out of step — leave them all showing rather
        // than index past the end.
        guard chips.count == dividers.count + 1 else { return }
        for (i, divider) in dividers.enumerated() {
            let touchesOn = chips[i].isActive || chips[i + 1].isActive
            divider.alphaValue = touchesOn ? 0 : 1
        }
    }
}

// MARK: - Hover plumbing
//
// Identical in both controls below. Kept as duplicated overrides rather than
// hoisted somewhere clever: it is six lines, and the alternative is a wrapper
// view between the stack and every control.

/// A plain format-bar button: symbol only, with the hover/active chip.
final class FormatBarButton: NSButton {
    private(set) lazy var chip = BarControlChip(host: self)

    override func layout() {
        super.layout()
        chip.layoutChip()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        // Spelled out rather than `forEach(removeTrackingArea)`: an unapplied
        // method reference is inferred as throwing under Swift 6.0 (Xcode 16.2,
        // what CI builds with), which rejects it inside a non-throwing override.
        trackingAreas.forEach { removeTrackingArea($0) }
        // `.inVisibleRect` keeps the area correct as the bar resizes without
        // recomputing the rect here.
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.mouseEnteredAndExited, .activeInKeyWindow,
                                                 .inVisibleRect],
                                       owner: self))
    }

    override func mouseEntered(with event: NSEvent) { chip.isHovered = true }
    override func mouseExited(with event: NSEvent) { chip.isHovered = false }

    /// The pointer cannot exit a view that is removed from the screen, so a bar
    /// hidden mid-hover would come back still wearing the chip.
    override func viewDidHide() {
        super.viewDidHide()
        chip.isHovered = false
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        chip.refresh()
    }
}

/// A format-bar pulldown (heading, callout). Hover only — a pulldown applies
/// several different things, so there is no single state for it to be in.
final class FormatBarPopUpButton: NSPopUpButton {
    private(set) lazy var chip = BarControlChip(host: self)

    override func layout() {
        super.layout()
        chip.layoutChip()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.mouseEnteredAndExited, .activeInKeyWindow,
                                                 .inVisibleRect],
                                       owner: self))
    }

    override func mouseEntered(with event: NSEvent) { chip.isHovered = true }
    override func mouseExited(with event: NSEvent) { chip.isHovered = false }

    override func viewDidHide() {
        super.viewDidHide()
        chip.isHovered = false
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        chip.refresh()
    }
}
