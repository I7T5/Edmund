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
        stack.alignment = .leading
        stack.spacing = 1
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 0, bottom: 6, right: 0)
        stack.translatesAutoresizingMaskIntoConstraints = false

        for row in iconRows { stack.addArrangedSubview(row) }
        if !iconRows.isEmpty { stack.addArrangedSubview(Self.separator()) }

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
        for row in stack.arrangedSubviews {
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        view = container
        view.frame = NSRect(x: 0, y: 0, width: 240, height: stack.fittingSize.height + 12)
    }

    private static func separator() -> NSView {
        let box = NSBox()
        box.boxType = .separator
        box.translatesAutoresizingMaskIntoConstraints = false
        box.heightAnchor.constraint(equalToConstant: 9).isActive = true
        return box
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
        let active = editor?.activeInlineStyles() ?? []
        let block = editor?.activeBlockStyle()

        for row in rows {
            let enabled = editor.map {
                $0.isFormattingActionEnabled(row.item.action ?? Selector(("noop")),
                                             representedObject: row.item.representedObject)
            } ?? false
            row.isEnabled = enabled
            row.isChecked = FormatToolbar.blockStyle(for: row.item).map { $0 == block } ?? false
        }

        for stack in iconRows {
            for case let button as FormatIconButton in stack.arrangedSubviews {
                guard let target = button.target as? FormatIconTarget else { continue }
                // Same explicit-editor reason as `fire`: the responder chain is
                // not reliable once the popover's view can take first responder.
                target.editor = editor
                target.dismiss = { [weak self] in self?.popover?.performClose(nil) }
                button.isActive = FormatToolbar.style(for: target.styleID).map(active.contains) ?? false
                button.isEnabled = editor?.isFormattingActionEnabled(
                    target.action, representedObject: nil) ?? false
                // An explicit contentTintColor defeats AppKit's disabled dimming.
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

    let item: NSMenuItem

    var isEnabled = true { didSet { updateAppearance() } }
    var isChecked = false { didSet { checkmark.isHidden = !isChecked } }

    private let onFire: (NSMenuItem) -> Void
    private let checkmark = NSImageView()
    private let iconView = NSImageView()
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
        checkmark.contentTintColor = .labelColor
        checkmark.isHidden = true

        iconView.image = item.image
        iconView.isHidden = item.image == nil

        if let attributed = item.attributedTitle {
            label.attributedStringValue = attributed
        } else {
            label.stringValue = item.title
            label.font = .menuFont(ofSize: 0)
        }

        let stack = NSStackView(views: [checkmark, iconView, label])
        stack.orientation = .horizontal
        stack.spacing = 5
        stack.alignment = .centerY
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 10, bottom: 4, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            // A fixed checkmark gutter keeps every title on the same left edge
            // whether or not its row is ticked.
            checkmark.widthAnchor.constraint(equalToConstant: 12),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
        ])

        setAccessibilityRole(.button)
        setAccessibilityLabel(item.title)
        setAccessibilityElement(true)
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
        wantsLayer = true
        layer?.cornerRadius = 5
        let hovering = isHovered && isEnabled
        // A dynamic colour resolves against whatever appearance is current, not
        // this view's — and it resolves at `withAlphaComponent` too, not only at
        // `.cgColor`, so the whole expression has to sit inside the block or the
        // tint comes out inverted (measured: black on a dark popover).
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = hovering
                ? NSColor.labelColor.withAlphaComponent(0.10).cgColor
                : nil
        }
        alphaValue = isEnabled ? 1.0 : 0.35
    }
}
