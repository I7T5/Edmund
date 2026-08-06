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

    /// Pointer is over the control.
    var isHovered = false { didSet { if isHovered != oldValue { refresh() } } }

    /// The formatting this control applies is in effect at the selection.
    var isActive = false { didSet { if isActive != oldValue { refresh() } } }

    private let chip = CALayer()
    private unowned let host: NSView

    init(host: NSView) {
        self.host = host
        host.wantsLayer = true
        chip.cornerRadius = 4
        chip.cornerCurve = .continuous
        // Behind the control's own drawing, never over the glyph.
        host.layer?.insertSublayer(chip, at: 0)
    }

    /// Called from the host's `layout()`; the chip tracks the whole control.
    func layoutChip() {
        // No implicit fade as the control moves during a resize.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        chip.frame = host.bounds
        CATransaction.commit()
    }

    /// Re-resolves the fill. Semantic colours are stored as `cgColor`, which is
    /// a snapshot that does not follow a light/dark switch, so this has to run
    /// again on an appearance change — same trap as the bar's hairline.
    func refresh() {
        host.effectiveAppearance.performAsCurrentDrawingAppearance {
            chip.backgroundColor = fill?.cgColor
        }
    }

    /// Active wins over hover: the chip is the on-state indicator first, and a
    /// pointer passing over it must not read as switching it off.
    private var fill: NSColor? {
        if isActive { return .unemphasizedSelectedContentBackgroundColor }
        if isHovered { return .quaternaryLabelColor }
        return nil
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
        trackingAreas.forEach(removeTrackingArea)
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
        trackingAreas.forEach(removeTrackingArea)
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
