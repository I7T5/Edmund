import AppKit
import EdmundCore

// MARK: - Format toolbar
//
// The window toolbar's formatting items. Every one of them drives the same
// `EditorTextView.format…` selector the menu bar drives, through the same
// nil-target responder-chain dispatch — there is deliberately no second
// implementation of any command, and no second place the storage invariant has
// to be upheld. Commands come from `FormatMenu`'s tables so a command defined
// once shows up in the menu bar, in Settings ▸ Key Bindings, and here.
//
// Default order (misc/plans/prompts/format-bar.md):
//   Format ▾ · Checklist · Table · Image ▾ · Link · (spacer) · View mode · Share
//
// `FormatToolbar` is an object rather than an enum because it has to *own* the
// icon-row buttons' action targets, which `NSControl.target` only holds weakly.

@MainActor
final class FormatToolbar: NSObject {

    static let format     = NSToolbarItem.Identifier("format")
    static let checklist  = NSToolbarItem.Identifier("checklist")
    static let table      = NSToolbarItem.Identifier("table")
    static let image      = NSToolbarItem.Identifier("image")
    static let link       = NSToolbarItem.Identifier("link")
    static let share      = NSToolbarItem.Identifier("share")

    private weak var document: Document?

    /// The Link item's button, so `DocumentWindow` can claim its secondary click
    /// for the Link/Wikilink menu (see the note there — a custom item cannot win
    /// that click by itself).
    private(set) weak var linkButton: NSView?

    init(document: Document) {
        self.document = document
        super.init()
    }

    /// The formatting group, centred in the window by `centeredItemIdentifiers`.
    static let centeredIdentifiers: Set<NSToolbarItem.Identifier> =
        [format, checklist, table, image, link]

    /// Just the view-mode button, right-aligned — the toolbar as it shipped. The
    /// formatting group stays *allowed*, so it can be dragged in from Customize
    /// Toolbar, but the default bar is bare.
    static func defaultIdentifiers(viewMode: NSToolbarItem.Identifier) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, viewMode]
    }

    static func allowedIdentifiers(viewMode: NSToolbarItem.Identifier) -> [NSToolbarItem.Identifier] {
        [format, checklist, table, image, link, share, viewMode, .space, .flexibleSpace]
    }

    /// Builds one of the formatting items, or nil if `id` isn't ours (the
    /// view-mode item stays with `Document`).
    func makeItem(_ id: NSToolbarItem.Identifier) -> NSToolbarItem? {
        switch id {
        case Self.format:
            let item = FormatButtonItem(itemIdentifier: id)
            item.label = "Format"
            item.toolTip = "Format"
            let button = NSButton(image: Self.symbol("textformat") ?? NSImage(),
                                  target: self, action: #selector(showFormatPopover(_:)))
            button.bezelStyle = .texturedRounded
            button.imagePosition = .imageOnly
            item.view = button
            formatButton = button
            return item
        case Self.image:
            return menuItem(id, label: "Image", symbol: "photo.on.rectangle",
                            menu: imagePopupMenu())
        case Self.checklist:
            return actionItem(id, label: "Checklist", symbol: "checklist",
                              action: #selector(EditorTextView.formatChecklist(_:)))
        case Self.table:
            return actionItem(id, label: "Table", symbol: "tablecells",
                              action: #selector(EditorTextView.formatTable(_:)))
        case Self.link:
            let item = FormatButtonItem(itemIdentifier: id)
            item.label = "Link"
            // No "right-click for Wikilink" hint: AppKit never advertises a
            // secondary-click menu in a tooltip (Safari's back button holds a
            // history menu and says only "Show the previous page"), and a tooltip
            // is seen only after hovering the thing whose menu you didn't know
            // about. Wikilink stays discoverable through the Format menu.
            item.toolTip = "Link"
            let button = NSButton(image: Self.symbol("link.badge.plus") ?? NSImage(),
                                  target: nil, action: #selector(EditorTextView.formatLink(_:)))
            button.bezelStyle = .texturedRounded
            button.imagePosition = .imageOnly
            item.view = button
            linkButton = button
            return item
        case Self.share:
            // AppKit's own share item: it owns the picker, the anchoring and the
            // standard icon, and asks the delegate below for what to share.
            let item = NSSharingServicePickerToolbarItem(itemIdentifier: id)
            item.label = "Share"
            item.toolTip = "Share this document"
            item.delegate = self
            return item
        default:
            return nil
        }
    }

    /// The Format item's button, so the popover has something to hang off.
    private weak var formatButton: NSView?
    private var formatPopover: NSPopover?

    /// Opens (or closes) the format panel. Rebuilt each time so the rows reflect
    /// the current caret and any shortcut changed in Settings ▸ Key Bindings.
    @objc func showFormatPopover(_ sender: Any?) {
        if let open = formatPopover, open.isShown { open.performClose(sender); return }
        guard let anchor = formatButton else { return }

        let popover = NSPopover()
        popover.behavior = .transient        // Esc + click-outside dismissal, free
        let controller = FormatPopoverController(iconRows: iconRowViews(),
                                                 items: Array(formatPopupMenu().items),
                                                 editor: document?.editor,
                                                 popover: popover)
        popover.contentViewController = controller
        formatPopover = popover
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
        controller.refresh()
    }

    /// The Link item's secondary-click menu: Link and Wikilink.
    func linkMenu() -> NSMenu {
        let menu = NSMenu(title: "Link")
        for cmd in FormatMenu.linkCommands where cmd.id != "format.image" {
            menu.addItem(cmd.makeItem())
        }
        return menu
    }

    // MARK: - Item construction

    /// A plain image item with a nil target: dispatch *and* validation both ride
    /// the responder chain to the focused editor, which is why these get their
    /// enabled state for free (see `EditorTextView.validateToolbarItem`).
    private func actionItem(_ id: NSToolbarItem.Identifier, label: String,
                            symbol: String, action: Selector) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: id)
        item.label = label
        item.toolTip = label
        item.image = Self.symbol(symbol)
        item.target = nil
        item.action = action
        // Without this a plain image item draws bare and never highlights under
        // the pointer, unlike the custom-view items either side of it — which is
        // what made Checklist and Table look dead next to Format and Link.
        item.isBordered = true
        return item
    }

    private func menuItem(_ id: NSToolbarItem.Identifier, label: String,
                          symbol: String, menu: NSMenu) -> NSToolbarItem {
        let item = FormatMenuToolbarItem(itemIdentifier: id)
        item.label = label
        item.toolTip = label
        item.image = Self.symbol(symbol)
        item.showsIndicator = true
        item.menu = menu
        return item
    }

    /// Action targets for the icon-row buttons — `NSControl.target` is weak.
    private var iconTargets: [FormatIconTarget] = []

    /// Point size per symbol, because SF Symbols do not share a bounding box: one
    /// common size renders `textformat` and `link.badge.plus` visibly larger than
    /// `checklist` and `tablecells`, which is what made the row read as ragged.
    ///
    /// The targets are Apple Notes', glyph for glyph. Both toolbars are 52pt tall,
    /// so the point sizes compare directly; Notes' drawn extents, measured off
    /// misc/frontend-refs/notes-toolbar-format-menu.png at 2x (traffic lights are
    /// a fixed 12pt, which gives the scale), are Aa 20.0, checklist 18.5, table
    /// 19.5, image 20.5, link 19.0. Each point size below is its target divided by
    /// what that symbol drew here at the default 15 — which put the photo glyph at
    /// 23.0pt, well over Notes'. Measure both sides the same way before touching
    /// these: an offscreen `NSImage` draw has a different baseline than a
    /// screenshot, so the two sets of numbers are not interchangeable.
    private static let symbolPointSizes: [String: CGFloat] = [
        "textformat": 14,                 // "Aa" is wide and short — 15 read oversized
        // Notes' own extents put these two at 18.5 and 19.5, but its toolbar
        // draws them against a taller bar; here they came out at 19.2 and 20.0
        // against 15.0–16.5 for everything else and read plainly oversized, so
        // they are matched to the rest of the row rather than to Notes.
        "checklist": 14,
        "tablecells": 14,
        "photo.on.rectangle": 13.5,
        "link.badge.plus": 13.5,
    ]

    static func symbol(_ name: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: symbolPointSizes[name] ?? 15,
                                           weight: .regular))
    }

    /// The format popup's icon rows are ordinary buttons inside a menu, not
    /// toolbar items, so they do need an explicit size.
    static func rowSymbol(_ name: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .regular))
    }

    // MARK: - Format popup

    /// Apple Notes-style: two rows of icon buttons, then the block commands as
    /// ordinary menu rows (which get dividers, hover, keyboard nav and live
    /// shortcut display for free — the reason this is an `NSMenu` and not a
    /// hand-built popover).
    ///
    /// Entirely flat: no submenus. Headings stop at 3 and callouts collapse to
    /// the single `> [!NOTE]` form. The full range stays in the menu bar's
    /// Format menu (H1–H6, 20 callout types) — this is the quick path, not a
    /// mirror of it.
    ///
    /// Checklist and Table are absent on purpose: they are their own toolbar
    /// items.
    /// The popover's two icon rows. Kept out of `formatPopupMenu()` on purpose:
    /// wrapping them in `NSMenuItem.view` (which the menu version needed) leaves
    /// AppKit owning the view, and re-parenting it into the popover's stack left
    /// it unmanaged — laid out at the container origin, i.e. drawn over the last
    /// row. They are plain views now.
    func iconRowViews() -> [NSStackView] {
        [iconRow(Self.inlineRow1), iconRow(Self.inlineRow2)]
    }

    func formatPopupMenu() -> NSMenu {
        let menu = NSMenu(title: "Format")
        for level in 1...3 { menu.addItem(headingRow(level)) }
        menu.addItem(FormatMenu.thematicBreakCommand.makeItem())
        for cmd in FormatMenu.listCommands where cmd.id != "format.checklist" {
            menu.addItem(cmd.makeItem())
        }
        menu.addItem(.separator())

        for cmd in FormatMenu.blockCommands where cmd.id != "format.table" {
            menu.addItem(cmd.makeItem())
        }
        menu.addItem(calloutRow())
        menu.addItem(FormatMenu.footnoteCommand.makeItem())
        return menu
    }

    /// A heading row. It is drawn at the weight it applies — see `titleFont(for:)`
    /// — the way Notes previews Title / Heading / Subheading.
    private func headingRow(_ level: Int) -> NSMenuItem {
        MenuCommand(id: "format.heading\(level)", submenu: "Heading",
                    title: "Heading \(level)",
                    action: #selector(EditorTextView.formatHeading(_:)),
                    tag: level).makeItem()
    }

    /// The single callout row, carrying the same Lucide glyph the editor draws in
    /// a NOTE callout's header — drawn monochrome so it sits with the other rows
    /// rather than announcing itself in the callout's blue.
    private func calloutRow() -> NSMenuItem {
        let item = MenuCommand(id: "format.callout.NOTE", submenu: "Alert / Callout",
                               title: "Alert / Callout",
                               action: #selector(EditorTextView.formatCallout(_:)),
                               representedObject: "NOTE").makeItem()
        // Template so the row can tint it white on the accent highlight, the way
        // it tints the checkmark and the text markers. 10pt because a Lucide
        // glyph fills its box: it draws 10pt of ink against the 9.2pt cap height
        // of the text markers beside it, where 13pt towered over them.
        let icon = Callout.icon(for: "note", color: .labelColor, pointSize: 10)
        icon?.isTemplate = true
        item.image = icon
        return item
    }

    /// The mini marker previewing what a row inserts. `FormatPopoverRow` draws it
    /// in a gutter of its own so `•`, `1.`, `▎`, `$` and the callout glyph all
    /// share a left edge however wide each one is — inline prefixes could not,
    /// since each shifted its own title. Code Block has no marker: it previews
    /// itself through the mono face of its title instead (see `titleFont`).
    static func marker(for item: NSMenuItem) -> String? {
        switch item.action {
        case #selector(EditorTextView.formatBulletedList(_:)): return "•"
        case #selector(EditorTextView.formatNumberedList(_:)): return "1."
        case #selector(EditorTextView.formatBlockQuote(_:)):   return "▎"
        case #selector(EditorTextView.formatMathBlock(_:)):    return "$"
        // The printer's footnote mark rather than the `[^1]` it inserts: that
        // preview measures 15pt against 7–9pt for every other marker, which is
        // both lopsided in a shared gutter and wide enough to reach the titles.
        case #selector(EditorTextView.formatFootnote(_:)):     return "†"
        default:                                               return nil
        }
    }

    /// The face a row's title is drawn in. Headings step down in size the way
    /// Notes previews Title / Heading / Subheading; Code Block is set in the mono
    /// face its content is typed in, which is what it previews instead of a
    /// marker.
    static func titleFont(for item: NSMenuItem) -> NSFont {
        let body = NSFont.menuFont(ofSize: 0)
        switch item.action {
        case #selector(EditorTextView.formatHeading(_:)):
            let sizes = [18.0, 15.5, 13.0]
            return .systemFont(ofSize: sizes[min(max(item.tag, 1), sizes.count) - 1],
                               weight: .semibold)
        case #selector(EditorTextView.formatCodeBlock(_:)):
            return .monospacedSystemFont(ofSize: body.pointSize - 1, weight: .regular)
        default:
            return body
        }
    }

    /// (SF Symbol, command id) for the popup's first row.
    private static let inlineRow1: [(String, String)] = [
        ("bold", "format.bold"),
        ("italic", "format.italic"),
        ("underline", "format.underline"),
        ("strikethrough", "format.strikethrough"),
        ("highlighter", "format.highlight"),
    ]

    /// …and its second row. There is no alignment control: a `<div align>`
    /// wrapper splits across blocks in Edit mode, so alignment cannot be shown
    /// faithfully, and Markdown has no alignment concept outside table columns.
    private static let inlineRow2: [(String, String)] = [
        ("chevron.left.forwardslash.chevron.right", "format.code"),
        // `pi` rather than `function`: ƒ(x) is far wider than every other glyph
        // in the grid, so the row read ragged.
        ("pi", "format.math"),
        ("textformat.subscript", "format.subscript"),
        ("textformat.superscript", "format.superscript"),
    ]

    /// The command a row button runs, looked up in the same tables the menu bar
    /// builds from — an icon whose id is not one of them has no state to show.
    static func action(for commandID: String) -> Selector? {
        FormatMenu.fontCommands.first { $0.id == commandID }?.action
    }

    /// Whether a popover row's own style is the one at the caret, so it can be
    /// checkmarked. Heading and callout are a which-one rather than a yes/no, so
    /// they come from their own accessors; everything else is a membership test
    /// in the set the format bar lights its chips from.
    static func isBlockActive(_ item: NSMenuItem,
                              actions: Set<Selector>,
                              headingLevel: Int?,
                              calloutType: String?) -> Bool {
        switch item.action {
        case #selector(EditorTextView.formatHeading(_:)):
            // Level 0 is Body, which the popover has no row for; a nil level
            // means the selected lines disagree, so nothing is ticked.
            return headingLevel != nil && headingLevel == item.tag
        case #selector(EditorTextView.formatCallout(_:)):
            return calloutType != nil
        case .some(let action):
            return actions.contains(action)
        case nil:
            return false
        }
    }

    private func iconRow(_ row: [(String, String)]) -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 2
        // No vertical inset: it sat between the last icon row and the divider
        // below it, so the gap there read wider than every other section gap.
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)
        // The popover lays its rows out with Auto Layout. Left on, the default
        // autoresizing frame puts this row at the container's origin — the
        // *bottom* in AppKit's unflipped coordinates — where it drew on top of
        // the last row.
        stack.translatesAutoresizingMaskIntoConstraints = false

        for (symbol, id) in row {
            guard let cmd = FormatMenu.fontCommands.first(where: { $0.id == id }) else { continue }
            let target = FormatIconTarget(action: cmd.action, styleID: id)
            iconTargets.append(target)

            let button = FormatIconButton(image: Self.rowSymbol(symbol) ?? NSImage(),
                                          target: target, action: #selector(FormatIconTarget.fire(_:)))
            button.isBordered = false          // our own hover/active background shows instead
            button.setButtonType(.momentaryChange)
            button.imagePosition = .imageOnly
            button.toolTip = cmd.title
            button.setAccessibilityLabel(cmd.title)
            // A mouse-first panel: arrow-key navigation was explicitly not wanted,
            // so nothing here joins the key view loop or draws a focus ring.
            button.focusRingType = .none
            button.refusesFirstResponder = true
            // Explicit metrics: an image-only borderless button has a slim
            // intrinsic size, which leaves the row cramped and its hover targets
            // overlapping. These give every icon the same square hit area.
            button.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                button.widthAnchor.constraint(equalToConstant: 28),
                button.heightAnchor.constraint(equalToConstant: 24),
            ])
            stack.addArrangedSubview(button)
        }
        return stack
    }

    // MARK: - Image popup

    /// Attach File… works today; the remaining sources are visible but disabled,
    /// so the finished shape of the feature is legible without pretending the
    /// pieces exist. See `ImageSource`.
    func imagePopupMenu() -> NSMenu {
        let menu = NSMenu(title: "Image")
        for source in ImageSource.allCases {
            if source == .camera { menu.addItem(.separator()) }
            let item = NSMenuItem(title: source.title,
                                  action: #selector(EditorTextView.formatAttachImage(_:)),
                                  keyEquivalent: "")
            item.isEnabled = source.isAvailable
            // A disabled placeholder must not dispatch if AppKit ever enables it.
            if !source.isAvailable { item.action = nil }
            menu.addItem(item)
        }
        return menu
    }
}

// MARK: - Share

extension FormatToolbar: NSSharingServicePickerToolbarItemDelegate {
    /// Shares the document's *file*, so the recipient gets a `.md` document
    /// rather than a wall of pasted text. An unsaved document has no file yet;
    /// returning nothing leaves the picker with no services to offer.
    func items(for pickerToolbarItem: NSSharingServicePickerToolbarItem) -> [Any] {
        document?.fileURL.map { [$0] } ?? []
    }
}

// MARK: - Supporting types

/// Forwards an icon-row button's click to the focused editor. A menu item's
/// custom view gets none of a real menu item's behaviour, so the menu is
/// dismissed by hand before the action is sent — otherwise the popup stays open
/// over the edit the user just made.
@MainActor
final class FormatIconTarget: NSObject {
    let action: Selector
    /// The `MenuCommand` id, used to look up which inline style this button
    /// reflects when the popup refreshes.
    let styleID: String

    /// Where to send the command. Set by the popover, which cannot rely on the
    /// responder chain: its content view can take first responder, unlike a
    /// menu, so a nil target may never reach the editor.
    weak var editor: EditorTextView?
    /// How to close the container once the command has fired.
    var dismiss: (() -> Void)?

    init(action: Selector, styleID: String) {
        self.action = action
        self.styleID = styleID
        super.init()
    }

    @objc func fire(_ sender: NSButton) {
        dismiss?()
        NSApp.sendAction(action, to: editor, from: sender)
    }
}

/// An icon-row button. A menu item's custom view gets none of a real row's
/// behaviour, so hover highlighting is drawn here by hand; `isActive` is the
/// same affordance for "this style is already on at the caret".
final class FormatIconButton: NSButton {
    var isActive = false { didSet { updateBackground() } }
    private var isHovered = false { didSet { updateBackground() } }
    private var tracking: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                  owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent)  { isHovered = false }

    /// The frame is the hover chip and the hit area, so it has to be exactly what
    /// the size constraints say. Left to AppKit a borderless image button insets
    /// its alignment rect from its frame by a bezel it never draws, and by a
    /// different amount per symbol: equal 24pt height constraints produced chips
    /// from 26 to 31pt tall, and left the grid's wrapper 12pt taller than its
    /// rows — which is where the extra gap above the first divider came from.
    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsets() }

    /// A disabled button must not look hoverable.
    override var isEnabled: Bool {
        didSet { if !isEnabled { isHovered = false } else { updateBackground() } }
    }

    /// Re-resolve the tint when the window flips between light and dark.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateBackground()
    }

    private func updateBackground() {
        wantsLayer = true
        layer?.cornerRadius = 5
        // See FormatPopoverRow: a dynamic colour resolves against the current
        // appearance, not this view's, and it resolves at `withAlphaComponent`
        // as well as at `.cgColor` — so the whole expression is pinned to ours.
        effectiveAppearance.performAsCurrentDrawingAppearance {
            // On is the accent at full strength, the way Notes fills an active
            // grid button with its yellow. Hover stays a wash: a hover that
            // looked identical to on would say the style had been applied.
            let color: NSColor? =
                !isEnabled ? nil
                : isActive ? .controlAccentColor
                : isHovered ? .controlAccentColor.withAlphaComponent(0.18)
                : nil
            layer?.backgroundColor = color?.cgColor
            contentTintColor = isActive && isEnabled ? .selectedMenuItemTextColor : .labelColor
        }
    }
}

/// `NSMenuToolbarItem` whose enabled state follows the editor: without this the
/// Format and Image popups stay live in Read mode, where nothing they contain
/// can run.
final class FormatMenuToolbarItem: NSMenuToolbarItem {
    override func validate() {
        isEnabled = (NSApp.target(forAction: #selector(EditorTextView.formatBold(_:)))
            as? EditorTextView)?
            .isFormattingActionEnabled(#selector(EditorTextView.formatBold(_:)),
                                       representedObject: nil) ?? false
    }
}

/// A toolbar item with a custom view. AppKit skips validation entirely for those,
/// so the enabled state is pushed onto the button by hand.
final class FormatButtonItem: NSToolbarItem {
    override func validate() {
        guard let action, let button = view as? NSButton else { return }
        // Only commands the editor runs are gated by the caret. The Format item
        // opens a popover — it is not a formatting action, nothing in the
        // responder chain answers it, and gating it here left it permanently
        // disabled. The popover disables its own inapplicable rows.
        guard EditorTextView.formattingActions.contains(action) else {
            button.isEnabled = true
            return
        }
        // `NSApp` is an implicitly-unwrapped optional and is genuinely nil in a
        // test process, so chain it rather than trusting the declaration.
        button.isEnabled = (NSApp?.target(forAction: action) as? EditorTextView)?
            .isFormattingActionEnabled(action, representedObject: nil) ?? false
    }
}

/// Where an attached image comes from. Only `.file` is wired up; the rest are
/// the extension points for Photos and Continuity Camera, which need a PhotoKit
/// dependency, an `NSPhotoLibraryUsageDescription`, and `NSServicesMenuRequestor`
/// plumbing respectively.
enum ImageSource: CaseIterable {
    case file, photos, camera, scan

    var title: String {
        switch self {
        case .file:   return "Attach File…"
        case .photos: return "Photos…"
        case .camera: return "Take Photo"
        case .scan:   return "Scan Documents"
        }
    }

    var isAvailable: Bool { self == .file }
}
