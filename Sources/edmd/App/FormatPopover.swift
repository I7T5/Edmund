import AppKit
import EdmundCore

// MARK: - Format popover
//
// The Format toolbar item opens this instead of a menu. It is a *view* over the
// same `NSMenuItem`s `FormatToolbar.formatPopupMenu()` builds — the items stay
// the source of truth for title, action, tag and representedObject, and this
// file only decides how they are drawn.
//
// Keeping the items matters for dispatch: `formatHeading` reads its level from
// `(sender as? NSMenuItem)?.tag` and `formatCallout` reads its type from
// `representedObject`. A row that sent itself as the sender would silently lose
// both, so each row forwards its item.
//
// Mouse-first by design: no ⌘-shortcut hints, no type-to-select, no arrow-key
// navigation. Esc and click-outside dismissal come free from `.transient`.

@MainActor
final class FormatPopoverController: NSViewController {

    /// Where commands are sent. A popover's content view can take first
    /// responder, so nil-target responder-chain dispatch — which is what the
    /// menu bar and the old menu-based popup rely on — is not safe here. The
    /// editor is captured explicitly instead.
    weak var editor: EditorTextView?

    private let items: [NSMenuItem]
    private let iconRows: [NSStackView]
    private var rows: [FormatPopoverRow] = []
    private weak var popover: NSPopover?

    /// The command rows, in display order. Exposed for tests.
    var commandRows: [FormatPopoverRow] { rows }

    init(iconRows: [NSStackView] = [], items: [NSMenuItem],
         editor: EditorTextView?, popover: NSPopover?) {
        self.iconRows = iconRows
        self.items = items
        self.editor = editor
        self.popover = popover
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() {
        let stack = NSStackView()
        stack.orientation = .vertical
        // Centred, so the icon grid — which keeps its own width — sits centred in
        // the popover while the command rows still span it edge to edge.
        stack.alignment = .centerX
        stack.spacing = 1
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 0, bottom: 6, right: 0)
        stack.translatesAutoresizingMaskIntoConstraints = false

        // One block, so the two icon rows share a left edge (centring them
        // individually would indent the shorter one) while the block as a whole
        // is centred in the popover by the outer stack's alignment.
        var grid: NSView?
        if !iconRows.isEmpty {
            // Without this each row stretches to the block's width, and a row's
            // trailing padding grows instead of the row keeping its own size.
            for row in iconRows { row.setHuggingPriority(.required, for: .horizontal) }
            let block = NSStackView(views: iconRows)
            block.orientation = .vertical
            block.alignment = .leading
            block.spacing = 4
            block.translatesAutoresizingMaskIntoConstraints = false
            stack.addArrangedSubview(block)
            stack.addArrangedSubview(Self.separator())
            grid = block
        }

        for item in items {
            if item.isSeparatorItem {
                stack.addArrangedSubview(Self.separator())
            } else {
                let row = FormatPopoverRow(item: item) { [weak self] in self?.fire($0) }
                rows.append(row)
                stack.addArrangedSubview(row)
            }
        }

        // Rows fill the popover's width so their hover highlight spans it.
        let container = NSView()
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
        for row in stack.arrangedSubviews where row !== grid {
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        view = container
        // Sized to the widest row — usually the icon grid — rather than a fixed
        // width, so the popover fits its content snugly the way Notes' does.
        // Exactly the fitting size: the stack's own edge insets are already in
        // it, and any padding added on top is slack the stack stretches to fill,
        // which the icon grid — the one band with no height of its own — absorbs
        // whole. That is where the extra gap above the first divider came from.
        view.frame = NSRect(x: 0, y: 0, width: ceil(stack.fittingSize.width),
                            height: stack.fittingSize.height)
    }

    /// Notes insets its dividers from the popover's sides rather than letting them
    /// run into the rounded corners — 13px each side on a 2x screenshot of
    /// misc/frontend-refs/notes-toolbar-format-menu.png, so 6.5pt.
    private static func separator() -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        let box = NSBox()
        box.boxType = .separator
        box.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(box)
        NSLayoutConstraint.activate([
            container.heightAnchor.constraint(equalToConstant: 9),
            box.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 6.5),
            box.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -6.5),
            box.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
        return container
    }

    private func fire(_ item: NSMenuItem) {
        popover?.performClose(nil)
        guard let action = item.action else { return }
        NSApp.sendAction(action, to: editor, from: item)
    }

    /// Re-reads the caret before each open: which inline styles are active, which
    /// block the caret is in, and what is runnable at all. Mirrors what
    /// `menuNeedsUpdate` did for the menu version.
    func refresh() {
        // One scan for the whole popover, not one per row: this is the same
        // delimiter pass the format bar lights its chips from, and it runs over
        // the selected lines every time either surface is refreshed.
        let active = editor?.activeFormattingActions() ?? []
        let headingLevel = editor?.activeHeadingLevel()
        let calloutType = editor?.activeCalloutType()

        for row in rows {
            let enabled = editor.map {
                $0.isFormattingActionEnabled(row.item.action ?? Selector(("noop")),
                                             representedObject: row.item.representedObject)
            } ?? false
            row.isEnabled = enabled
            row.isChecked = FormatToolbar.isBlockActive(row.item, actions: active,
                                                        headingLevel: headingLevel,
                                                        calloutType: calloutType)
        }

        for stack in iconRows {
            for case let button as FormatIconButton in stack.arrangedSubviews {
                guard let target = button.target as? FormatIconTarget else { continue }
                // Same explicit-editor reason as `fire`: the responder chain is
                // not reliable once the popover's view can take first responder.
                target.editor = editor
                target.dismiss = { [weak self] in self?.popover?.performClose(nil) }
                button.isActive = FormatToolbar.action(for: target.styleID).map(active.contains) ?? false
                button.isEnabled = editor?.isFormattingActionEnabled(
                    target.action, representedObject: nil) ?? false
                button.alphaValue = button.isEnabled ? 1.0 : 0.35
            }
        }
    }
}

// MARK: - One row

/// A popover row. `NSMenu` gave hover, highlighting and accessibility for free;
/// a popover's content is a plain view hierarchy, so each is done by hand here.
@MainActor
final class FormatPopoverRow: NSView {

    /// Uniform across every row. Exposed so the layout tests can assert it.
    static let rowHeight: CGFloat = 29

    /// The three columns, as offsets from the row's leading edge. Measured off
    /// Notes' own popup, whose checkmark ink starts at 19pt and whose markers sit
    /// at 37.5pt — scaled in to our narrower popover. A row with no marker puts
    /// its title on the marker edge, not the title edge: that is what Notes does,
    /// so "Subheading" and "• Bulleted List" start their glyphs at one mark.
    static let checkmarkX: CGFloat = 15
    static let markerX: CGFloat = 30
    static let titleX: CGFloat = 45

    let item: NSMenuItem

    var isEnabled = true { didSet { updateAppearance() } }
    /// Faded rather than hidden: a hidden view drops out of the stack, and with it
    /// the gutter that keeps every title on Notes' left edge, ticked or not.
    var isChecked = false { didSet { checkmark.alphaValue = isChecked ? 1 : 0 } }

    private let onFire: (NSMenuItem) -> Void
    /// The hover tint lives on its own inset view rather than on the row's layer,
    /// so it stops short of the popover's rounded sides the way the dividers do.
    /// Not private: the layout tests read its frame and tint.
    let highlight = NSView()
    private let checkmark = NSImageView()
    /// The callout row's glyph. Shares the marker gutter with `markerLabel` —
    /// no row has both.
    private let iconView = NSImageView()
    private let markerLabel = NSTextField(labelWithString: "")
    private let label = NSTextField(labelWithString: "")
    /// Not private so the offscreen render harness can exercise the hover look
    /// without synthesising mouse events.
    var isHovered = false { didSet { updateAppearance() } }
    private var tracking: NSTrackingArea?

    init(item: NSMenuItem, onFire: @escaping (NSMenuItem) -> Void) {
        self.item = item
        self.onFire = onFire
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        checkmark.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .semibold))
        checkmark.alphaValue = 0

        iconView.image = item.image
        iconView.isHidden = item.image == nil

        let body = NSFont.menuFont(ofSize: 0)
        if let marker = FormatToolbar.marker(for: item) {
            markerLabel.stringValue = marker
            // `$` is Markdown syntax, so it is shown in the face it is typed in.
            markerLabel.font = marker == "$"
                ? .monospacedSystemFont(ofSize: body.pointSize - 1, weight: .regular)
                : body
        }
        // A row with no marker of its own starts its title on the marker edge
        // rather than the title edge, so unmarked and marked rows share one
        // leading glyph column the way Notes' do.
        let titleX = FormatToolbar.marker(for: item) == nil && item.image == nil
            ? Self.markerX : Self.titleX
        markerLabel.isHidden = markerLabel.stringValue.isEmpty
        markerLabel.alignment = .left

        label.stringValue = item.title
        label.font = FormatToolbar.titleFont(for: item)
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.required, for: .horizontal)

        highlight.wantsLayer = true
        highlight.translatesAutoresizingMaskIntoConstraints = false
        addSubview(highlight)          // behind the content
        for column in [checkmark, iconView, markerLabel, label] as [NSView] {
            column.translatesAutoresizingMaskIntoConstraints = false
            addSubview(column)
        }

        NSLayoutConstraint.activate([
            highlight.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6.5),
            highlight.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6.5),
            highlight.topAnchor.constraint(equalTo: topAnchor, constant: 1),
            highlight.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1),
            // Every row is the same height whatever its font, so the heading
            // previews do not tower over the plain rows. Notes' rows measure a
            // uniform 58px on a 2x screenshot — 29pt — at the same 13pt menu font.
            heightAnchor.constraint(equalToConstant: Self.rowHeight),
            // Fixed columns rather than a stack: a stack would let each row's own
            // marker width decide where its title starts.
            checkmark.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.checkmarkX),
            checkmark.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.markerX),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            markerLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.markerX),
            markerLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: titleX),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
            // Plain centring is enough now that the title is a `font` + plain
            // string: the previous rows set an `attributedTitle`, which dropped
            // the cell into wrapping mode and gave the bigger heading previews
            // different vertical metrics from the 13pt rows. Cap-band centring
            // was tried on top and moved every label by under 0.5pt — below the
            // half-point the layout quantises to, so it changed nothing.
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        setAccessibilityRole(.button)
        setAccessibilityLabel(item.title)
        setAccessibilityElement(true)
        updateAppearance()
    }

    /// The row is one button. A text field consumes the click that lands on it
    /// and never passes it up, so the heading rows — whose labels are tall enough
    /// to cover almost the whole row — could not be clicked at all.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let superview else { return nil }
        return bounds.contains(convert(point, from: superview)) ? self : nil
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: Hover

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                  owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { if isEnabled { isHovered = true } }
    override func mouseExited(with event: NSEvent)  { isHovered = false }

    override func mouseUp(with event: NSEvent) {
        guard isEnabled else { return }
        onFire(item)
    }

    override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        onFire(item)
        return true
    }

    /// Re-resolve the tint when the window flips between light and dark.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateAppearance()
    }

    private func updateAppearance() {
        highlight.layer?.cornerRadius = 5
        let hovering = isHovered && isEnabled
        // A dynamic colour resolves against whatever appearance is current, not
        // this view's — and it resolves at `withAlphaComponent` too, not only at
        // `.cgColor`, so the whole expression has to sit inside the block or the
        // tint comes out inverted (measured: black on a dark popover).
        effectiveAppearance.performAsCurrentDrawingAppearance {
            // The system's own selection fill, not a hand-mixed accent: Notes
            // draws a hovered row exactly as it draws a selected one, so the
            // row's contents flip to the colour AppKit already defines for text
            // on that fill, in both appearances.
            highlight.layer?.backgroundColor = hovering
                ? NSColor.selectedContentBackgroundColor.cgColor : nil
            let foreground: NSColor = hovering ? .selectedMenuItemTextColor : .labelColor
            label.textColor = foreground
            checkmark.contentTintColor = foreground
            iconView.contentTintColor = foreground
            // The quote bar is a rule, not a character: greyed so it does not
            // read as part of the title — except on the accent, where grey muddies.
            markerLabel.textColor = !hovering && item.action == #selector(EditorTextView.formatBlockQuote(_:))
                ? .secondaryLabelColor
                : foreground
        }
        alphaValue = isEnabled ? 1.0 : 0.35
    }
}
