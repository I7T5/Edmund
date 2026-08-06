import AppKit
import EdmundCore

// MARK: - Format bar

/// The always-available formatting button bar across the top of the editor,
/// modelled on Apple Mail's format bar. A dumb view: every control's action is
/// a nil-target `EditorTextView` `format…` action, so a click routes through
/// the responder chain to the focused editor exactly like a Format-menu item.
/// The two pulldowns are `NSPopUpButton`s in `.pullDown` mode whose menu items
/// have a nil target and their own action — selecting one sends the action up
/// the responder chain *with the `NSMenuItem` as sender*, which is what
/// `formatHeading` (reads `tag`) and `formatCallout` (reads `representedObject`)
/// need.
final class FormatBarView: ChromeBarView {

    /// The bar's fixed height. The accessory-bar buttons sit smaller than the
    /// strip; `preferredHeight` drives the editor's top inset.
    static let barHeight: CGFloat = 32
    override var preferredHeight: CGFloat { Self.barHeight }

    /// The borderless controls' footprint — the same size the `.accessoryBarAction`
    /// bezel gave them, so dropping the border doesn't shrink the hit area.
    private static let controlWidth: CGFloat = 24
    private static let controlHeight: CGFloat = 20

    /// Each control paired with a private, unregistered menu item carrying its
    /// selector — the input `EditorTextView.validateMenuItem` needs. Never
    /// installed in a menu; exists only so a button's enabled state follows the
    /// Format menu's own gate (Reading mode, Markdown-feature toggles) with no
    /// new public API.
    private var commandItems: [(button: NSButton, item: NSMenuItem)] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        buildUI()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Re-runs the Format menu's validation for every control. The gate reads
    /// only `viewMode` and `markdownFeatures`, so this is needed on show, on
    /// view-mode change and when settings change — never per keystroke.
    func refreshEnabledState(editor: EditorTextView) {
        for (button, item) in commandItems {
            button.isEnabled = editor.validateMenuItem(item)
        }
    }

    // MARK: - Build

    private func buildUI() {
        let groups = [
            makeGroup([
                makePullDown(symbol: "textformat.size", title: "Heading",
                             menu: FormatMenu.headingMenu(),
                             action: #selector(EditorTextView.formatHeading(_:))),
                makeButton(symbol: "minus", title: "Thematic Break",
                           action: #selector(EditorTextView.formatThematicBreak(_:))),
            ]),
            makeGroup([
                makeButton(symbol: "bold", title: "Bold",
                           action: #selector(EditorTextView.formatBold(_:))),
                makeButton(symbol: "italic", title: "Italic",
                           action: #selector(EditorTextView.formatItalic(_:))),
                makeButton(symbol: "underline", title: "Underline",
                           action: #selector(EditorTextView.formatUnderline(_:))),
                makeButton(symbol: "strikethrough", title: "Strikethrough",
                           action: #selector(EditorTextView.formatStrikethrough(_:))),
                makeButton(symbol: "textformat.subscript", title: "Subscript",
                           action: #selector(EditorTextView.formatSubscript(_:))),
                makeButton(symbol: "textformat.superscript", title: "Superscript",
                           action: #selector(EditorTextView.formatSuperscript(_:))),
            ]),
            makeGroup([
                makeButton(symbol: "highlighter", title: "Highlight",
                           action: #selector(EditorTextView.formatHighlight(_:))),
            ]),
            makeGroup([
                makeButton(symbol: "list.bullet", title: "Bulleted List",
                           action: #selector(EditorTextView.formatBulletedList(_:))),
                makeButton(symbol: "list.number", title: "Numbered List",
                           action: #selector(EditorTextView.formatNumberedList(_:))),
                makeButton(symbol: "checklist", title: "Checklist",
                           action: #selector(EditorTextView.formatChecklist(_:))),
            ]),
            makeGroup([
                makeButton(symbol: "quote.closing", title: "Block Quote",
                           action: #selector(EditorTextView.formatBlockQuote(_:))),
                makePullDown(symbol: "quote.bubble", title: "Alert / Callout",
                             menu: FormatMenu.calloutMenu(),
                             action: #selector(EditorTextView.formatCallout(_:))),
            ]),
        ]

        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        for (i, group) in groups.enumerated() {
            stack.addArrangedSubview(group)
            if i < groups.count - 1 { stack.setCustomSpacing(16, after: group) }
        }
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        // Centred, so a narrow window clips the same reachable band on both
        // sides rather than shoving the leading controls off-screen.
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    /// One control group: a sub-stack with the tight within-group spacing. The
    /// wider between-group spacing is set on the top-level stack instead.
    private func makeGroup(_ views: [NSView]) -> NSStackView {
        let group = NSStackView(views: views)
        group.orientation = .horizontal
        group.spacing = 4
        group.alignment = .centerY
        return group
    }

    private func makeButton(symbol name: String, title: String,
                            action: Selector, tint: NSColor? = nil) -> NSButton {
        let button = NSButton(image: Self.symbol(name, desc: title) ?? NSImage(),
                              target: nil, action: action)
        button.bezelStyle = .accessoryBarAction
        button.isBordered = false
        button.imagePosition = .imageOnly
        // Borderless sheds the bezel's padding, collapsing the intrinsic size to
        // the bare glyph; pin the footprint to match the old bordered buttons —
        // same hit area, no border.
        button.widthAnchor.constraint(equalToConstant: Self.controlWidth).isActive = true
        button.heightAnchor.constraint(equalToConstant: Self.controlHeight).isActive = true
        // Out of the key-view loop entirely: `FindBarView` opts the whole
        // window out of autorecalculating its key-view loop, so a Tab chain
        // that included these buttons would fight that hand-managed chain.
        button.refusesFirstResponder = true
        button.setAccessibilityLabel(title)
        button.toolTip = title
        if let tint { button.contentTintColor = tint }
        register(button, action: action, title: title)
        return button
    }

    private func makePullDown(symbol name: String, title: String,
                              menu: NSMenu, action: Selector) -> NSPopUpButton {
        let pop = NSPopUpButton(frame: .zero, pullsDown: true)
        pop.menu = menu
        pop.bezelStyle = .accessoryBarAction
        pop.isBordered = false
        pop.refusesFirstResponder = true
        pop.setAccessibilityLabel(title)
        pop.toolTip = title
        // Never mark a selection in the open menu: the bar tracks no state, so a
        // checkmark on the last-picked item would misread as "this is the
        // caret's level".
        for item in menu.items { item.onStateImage = nil }
        if let image = Self.symbol(name, desc: title) {
            // A pull-down's cell ignores the button's own `image` — only the
            // arrow draws — so the icon rides on a hidden display item 0, which
            // the button shows but the open menu skips. Item 0 stays put:
            // pull-downs keep displaying it no matter what the user picks.
            let display = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            display.image = image
            display.isHidden = true
            display.onStateImage = nil
            menu.insertItem(display, at: 0)
        }
        pop.widthAnchor.constraint(equalToConstant: Self.controlWidth).isActive = true
        pop.heightAnchor.constraint(equalToConstant: Self.controlHeight).isActive = true
        register(pop, action: action, title: title)
        return pop
    }

    private func register(_ button: NSButton, action: Selector, title: String) {
        commandItems.append((button: button,
                             item: NSMenuItem(title: title, action: action, keyEquivalent: "")))
    }

    private static func symbol(_ name: String, desc: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: desc)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .regular))
    }
}
