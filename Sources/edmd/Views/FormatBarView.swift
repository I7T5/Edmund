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
    static let barHeight: CGFloat = 28
    override var preferredHeight: CGFloat { Self.barHeight }

    /// The borderless controls' footprint. Comfortably above the 20pt the HIG
    /// asks for a pointer target even at this size.
    private static let controlWidth: CGFloat = 22
    private static let controlHeight: CGFloat = 18

    /// Height of the hairline between two buttons of the same group — a little
    /// shorter than the buttons, the way Mail draws it.
    private static let dividerHeight: CGFloat = 13

    /// One bar control and everything needed to keep it in sync.
    ///
    /// `item` is a private, unregistered menu item carrying the control's
    /// selector — the input `EditorTextView.validateMenuItem` needs. Never
    /// installed in a menu; it exists only so a button's *enabled* state follows
    /// the Format menu's own gate (Reading mode, Markdown-feature toggles) with
    /// no new public API.
    private struct BarControl {
        let button: NSButton
        let chip: BarControlChip
        let item: NSMenuItem
    }
    private var commandItems: [BarControl] = []

    /// Each pulldown's menu, by the action its items carry. The heading and
    /// callout pulldowns apply one of a set of mutually exclusive things, so
    /// their state is a checkmark on the member in effect rather than a chip.
    private var pullDownMenus: [Selector: NSMenu] = [:]

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        buildUI()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Re-runs the Format menu's validation for every control. The gate reads
    /// only `viewMode` and `markdownFeatures`, so this is needed on show, on
    /// view-mode change and when settings change — never per keystroke.
    func refreshEnabledState(editor: EditorTextView) {
        for control in commandItems {
            control.button.isEnabled = editor.validateMenuItem(control.item)
        }
    }

    /// Lights the controls whose formatting is in effect where the caret or
    /// selection currently sits. Runs on every selection change and every edit,
    /// so it stays a delimiter scan of the selected lines and nothing more.
    ///
    /// The pulldowns and Thematic Break never light: their selectors are not
    /// ones `activeFormattingActions()` reports, so this needs no special case.
    func refreshActiveState(editor: EditorTextView) {
        #if DEBUG
        // Chips can't be driven by a pointer from a headless harness, so this
        // lights every one of them — the only way to check that they share a
        // size without moving the maintainer's mouse.
        if UserDefaults.standard.bool(forKey: "debug.formatBarAllActive") {
            for control in commandItems { control.chip.isActive = true }
            return
        }
        #endif
        let active = editor.activeFormattingActions()
        for control in commandItems {
            control.chip.isActive = control.item.action.map(active.contains) ?? false
        }
        refreshPullDownState(editor: editor)
    }

    /// Ticks the heading level and callout type the caret is currently in.
    ///
    /// Items with no action are skipped: that is the hidden item 0 carrying the
    /// button's icon, and its tag of 0 would otherwise read as "Body".
    private func refreshPullDownState(editor: EditorTextView) {
        if let menu = pullDownMenus[#selector(EditorTextView.formatHeading(_:))] {
            let level = editor.activeHeadingLevel()
            for item in menu.items where item.action != nil {
                item.state = item.tag == level ? .on : .off
            }
        }
        if let menu = pullDownMenus[#selector(EditorTextView.formatCallout(_:))] {
            let type = editor.activeCalloutType()
            for item in menu.items where item.action != nil {
                let itemType = (item.representedObject as? String)?.lowercased()
                item.state = itemType != nil && itemType == type ? .on : .off
            }
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
            if i < groups.count - 1 { stack.setCustomSpacing(14, after: group) }
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

    /// One control group: the buttons run together with a hairline between each
    /// adjacent pair, so the group reads as a single segmented unit. Group
    /// boundaries get no divider — the wider spacing on the top-level stack is
    /// what separates those, which is how Mail's bar is drawn.
    private func makeGroup(_ views: [NSView]) -> NSStackView {
        var arranged: [NSView] = []
        var dividers: [NSView] = []
        for (i, view) in views.enumerated() {
            if i > 0 {
                let divider = Self.makeDivider()
                dividers.append(divider)
                arranged.append(divider)
            }
            arranged.append(view)
        }
        let group = FormatBarGroupView(views: arranged)
        group.orientation = .horizontal
        // Tight: the divider is the separation, so the buttons only need enough
        // room that a chip doesn't crowd it.
        group.spacing = 4
        group.alignment = .centerY
        // Same order as `views`, so the group can pair each divider with the two
        // controls it sits between.
        group.adopt(chips: views.compactMap(Self.chip(of:)), dividers: dividers)
        return group
    }

    /// The chip belonging to a bar control. The two control kinds carry one each
    /// but share no type that exposes it.
    private static func chip(of view: NSView) -> BarControlChip? {
        (view as? FormatBarButton)?.chip ?? (view as? FormatBarPopUpButton)?.chip
    }

    /// `NSBox` in separator mode rather than a layer-backed view: it is the
    /// stock hairline and it tracks light/dark on its own, so there is no
    /// `cgColor` snapshot to refresh on an appearance change.
    private static func makeDivider() -> NSView {
        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            divider.widthAnchor.constraint(equalToConstant: 1),
            divider.heightAnchor.constraint(equalToConstant: dividerHeight),
        ])
        return divider
    }

    private func makeButton(symbol name: String, title: String,
                            action: Selector) -> FormatBarButton {
        let button = FormatBarButton(image: Self.symbol(name, desc: title) ?? NSImage(),
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
        register(button, chip: button.chip, action: action, title: title)
        return button
    }

    private func makePullDown(symbol name: String, title: String,
                              menu: NSMenu, action: Selector) -> FormatBarPopUpButton {
        let pop = FormatBarPopUpButton(frame: .zero, pullsDown: true)
        pop.menu = menu
        pop.bezelStyle = .accessoryBarAction
        pop.isBordered = false
        pop.refusesFirstResponder = true
        pop.setAccessibilityLabel(title)
        pop.toolTip = title
        // Kept so `refreshPullDownState` can tick the member currently in
        // effect. The checkmark reports the caret, never the last thing picked
        // — nothing here records that.
        pullDownMenus[action] = menu
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
        // Height only. A pull-down draws its disclosure arrow *beside* the
        // image, so pinning it to a plain button's width crushed the arrow into
        // the glyph; let the cell ask for the width it needs.
        pop.heightAnchor.constraint(equalToConstant: Self.controlHeight).isActive = true
        register(pop, chip: pop.chip, action: action, title: title)
        return pop
    }

    /// The chip is passed in rather than read off the control: the two control
    /// kinds carry one each but share no type that exposes it.
    private func register(_ button: NSButton, chip: BarControlChip,
                          action: Selector, title: String) {
        commandItems.append(BarControl(
            button: button, chip: chip,
            item: NSMenuItem(title: title, action: action, keyEquivalent: "")))
    }

    private static func symbol(_ name: String, desc: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: desc)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12, weight: .regular))
    }
}
