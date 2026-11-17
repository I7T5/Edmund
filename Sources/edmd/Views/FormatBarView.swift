import AppKit
import EdmundCore

// MARK: - Format bar

/// The always-available formatting button bar across the top of the editor,
/// modelled on Apple Mail's format bar. A dumb view: every control's action is
/// a nil-target `EditorTextView` `format…` action, so a click routes through
/// the responder chain to the focused editor exactly like a Format-menu item.
/// The pulldowns are `NSPopUpButton`s in `.pullDown` mode whose menu items
/// have a nil target and their own action — selecting one sends the action up
/// the responder chain *with the `NSMenuItem` as sender*, which is what
/// `formatHeading` (reads `tag`) and `formatCallout` (reads `representedObject`)
/// need.
final class FormatBarView: ChromeBarView, NSMenuDelegate {

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

    /// One tint for every glyph on the bar. Left to AppKit, a borderless
    /// button's template draws at secondary-label grey while a pulldown's item-0
    /// image and arrow draw near full label colour, so the pulldowns read
    /// heavier than the buttons beside them.
    private static let glyphTint: NSColor = .secondaryLabelColor

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
    /// The pulldowns and Table never light: their selectors are not ones
    /// `activeFormattingActions()` reports, so this needs no special case.
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
    /// Only the level items are ticked — by selector, not "has an action": the
    /// hidden item 0 carrying the button's icon has none, and the Increment /
    /// Decrement items at the foot of the menu have their own actions and a
    /// tag of 0, which would otherwise read as "Body".
    private func refreshPullDownState(editor: EditorTextView) {
        if let menu = pullDownMenus[#selector(EditorTextView.formatHeading(_:))] {
            let level = editor.activeHeadingLevel()
            for item in menu.items where item.action == #selector(EditorTextView.formatHeading(_:)) {
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
            // Last because these insert content rather than restyle the
            // selection; Table before Image, as in the window toolbar.
            makeGroup([
                makeButton(symbol: "tablecells", title: "Table",
                           action: #selector(EditorTextView.formatTable(_:))),
                makePullDown(symbol: "photo.on.rectangle", title: "Image",
                             menu: FormatToolbar.imagePopupMenu(),
                             action: #selector(EditorTextView.formatAttachImage(_:))),
            ]),
        ]

        self.groups = groups
        overflowButton = makeOverflowButton()

        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        // A hidden group is detached (the default) and takes its spacing with
        // it, so the gap after the last visible group is the one before `»`.
        for group in groups {
            stack.addArrangedSubview(group)
            stack.setCustomSpacing(Self.groupSpacing, after: group)
        }
        stack.addArrangedSubview(overflowButton)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        // Centred whether or not anything overflows: `updateOverflow` keeps the
        // stack narrower than the bar, so centring never clips a control.
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    // MARK: - Overflow

    /// Gap between groups, and between the last visible group and `»`.
    private static let groupSpacing: CGFloat = 14
    /// Space kept clear at each end of the bar.
    private static let edgeMargin: CGFloat = 8

    /// The control groups, leading to trailing.
    private(set) var groups: [NSStackView] = []
    /// `»`, shown when some groups don't fit. Its menu is rebuilt each time it
    /// opens (`menuNeedsUpdate`).
    private(set) var overflowButton: NSPopUpButton!
    /// How many groups, from the leading end, are on the bar.
    private(set) var visibleGroupCount = Int.max

    /// Measured once: nothing on the bar changes size.
    private lazy var groupWidths: [CGFloat] = groups.map(\.fittingSize.width)
    private lazy var overflowWidth: CGFloat = overflowButton.fittingSize.width

    override func layout() {
        super.layout()
        updateOverflow()
    }

    /// When the groups don't fit, whole groups move from the trailing end into
    /// the `»` menu, as `NSToolbar` does with its items. Trailing goes first:
    /// Table and Image are also in the window toolbar, and the inline styles at
    /// the leading end are the most used.
    private func updateOverflow() {
        let available = bounds.width - 2 * Self.edgeMargin
        func width(_ count: Int, overflow: Bool) -> CGFloat {
            let shown = groupWidths.prefix(count).reduce(0, +)
                + Self.groupSpacing * CGFloat(max(count - 1, 0))
            guard overflow else { return shown }
            return shown + (count > 0 ? Self.groupSpacing : 0) + overflowWidth
        }
        var count = groups.count
        if width(count, overflow: false) > available {
            count -= 1
            while count > 0, width(count, overflow: true) > available { count -= 1 }
        }
        guard count != visibleGroupCount else { return }
        visibleGroupCount = count
        for (i, group) in groups.enumerated() { group.isHidden = i >= count }
        overflowButton.isHidden = count == groups.count
    }

    /// A stock `NSPopUpButton`, not `FormatBarPopUpButton`: no hover chip, as
    /// Preview's toolbar `»` has none. The pull-down cell keeps a leading inset
    /// for a title, so a chip sat lopsided around the glyph (9.5pt left, 4.5pt
    /// right); a hand-placed `NSMenu.popUp` fixed that but opened the menu in
    /// the wrong place. Native is right on the menu, and without a chip the
    /// inset doesn't show.
    private func makeOverflowButton() -> NSPopUpButton {
        let pop = NSPopUpButton(frame: .zero, pullsDown: true)
        let menu = NSMenu(title: "More")
        menu.delegate = self
        // See `makePullDown`: a pull-down shows its icon through a hidden item 0.
        let display = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        display.image = Self.symbol("chevron.right.2", desc: "More")
        display.isHidden = true
        menu.addItem(display)
        pop.menu = menu
        pop.bezelStyle = .accessoryBarAction
        pop.isBordered = false
        // `»` already says "more"; an arrow beside it read as `»▾`. NSToolbar's
        // overflow shows the chevron alone.
        (pop.cell as? NSPopUpButtonCell)?.arrowPosition = .noArrow
        pop.contentTintColor = Self.glyphTint
        pop.refusesFirstResponder = true
        pop.setAccessibilityLabel("More Formatting")
        pop.toolTip = "More Formatting"
        pop.heightAnchor.constraint(equalToConstant: Self.controlHeight).isActive = true
        pop.isHidden = true
        return pop
    }

    /// The hidden groups as menu items, in bar order, a separator between
    /// groups. A button becomes an item, ticked when its chip is lit; a pulldown
    /// becomes a submenu of copies of its own items, carrying the heading and
    /// callout ticks `refreshPullDownState` set. Nil targets throughout, so the
    /// items validate and dispatch through the responder chain like the bar.
    func menuNeedsUpdate(_ menu: NSMenu) {
        while menu.items.count > 1 { menu.removeItem(at: 1) }
        for group in groups.dropFirst(min(visibleGroupCount, groups.count)) {
            if menu.items.count > 1 { menu.addItem(.separator()) }
            for view in group.arrangedSubviews {
                if let pop = view as? FormatBarPopUpButton, let source = pop.menu {
                    let item = NSMenuItem(title: pop.toolTip ?? "", action: nil, keyEquivalent: "")
                    let submenu = NSMenu(title: item.title)
                    for member in source.items where !member.isHidden {
                        if let copy = member.copy() as? NSMenuItem { submenu.addItem(copy) }
                    }
                    item.submenu = submenu
                    menu.addItem(item)
                } else if let button = view as? FormatBarButton {
                    let item = NSMenuItem(title: button.toolTip ?? "", action: button.action,
                                          keyEquivalent: "")
                    item.state = button.chip.isActive ? .on : .off
                    menu.addItem(item)
                }
            }
        }
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
        group.adopt(chips: views.compactMap { Self.chip(of: $0) }, dividers: dividers)
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
        button.contentTintColor = Self.glyphTint
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
        pop.contentTintColor = Self.glyphTint
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
