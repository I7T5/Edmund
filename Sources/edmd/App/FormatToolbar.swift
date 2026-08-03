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
// `FormatToolbar` is an object rather than an enum because it has to *own*
// things AppKit only holds weakly: the menu delegates that rebuild the popups on
// open, and the icon-row buttons' action targets.

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

    static func defaultIdentifiers(viewMode: NSToolbarItem.Identifier) -> [NSToolbarItem.Identifier] {
        [format, checklist, table, image, link, .flexibleSpace, viewMode, share]
    }

    static func allowedIdentifiers(viewMode: NSToolbarItem.Identifier) -> [NSToolbarItem.Identifier] {
        [format, checklist, table, image, link, share, viewMode, .space, .flexibleSpace]
    }

    /// Builds one of the formatting items, or nil if `id` isn't ours (the
    /// view-mode item stays with `Document`).
    func makeItem(_ id: NSToolbarItem.Identifier) -> NSToolbarItem? {
        switch id {
        case Self.format:
            return menuItem(id, label: "Format", symbol: "textformat",
                            menu: formatPopupMenu())
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
            item.toolTip = "Link (right-click for Wikilink)"
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
        return item
    }

    private func menuItem(_ id: NSToolbarItem.Identifier, label: String,
                          symbol: String, menu: NSMenu) -> NSToolbarItem {
        let item = FormatMenuToolbarItem(itemIdentifier: id)
        item.label = label
        item.toolTip = label
        item.image = Self.symbol(symbol)
        item.showsIndicator = true
        menu.delegate = self
        item.menu = menu
        menus.append(menu)
        return item
    }

    /// Menus we own. `NSMenu.delegate` is weak and `NSMenuToolbarItem` does not
    /// keep the delegate alive, so the popups would stop rebuilding without this.
    private var menus: [NSMenu] = []

    /// Action targets for the icon-row buttons — `NSControl.target` is weak.
    private var iconTargets: [FormatIconTarget] = []

    /// One point size for every toolbar glyph, chosen to match the item AppKit
    /// builds itself (the share item). Both extremes were measured and are
    /// wrong: at 13pt our glyphs sit visibly smaller than share, and at their
    /// *natural* size `checklist` and `tablecells` overshoot it — SF Symbols
    /// carry different intrinsic boxes, so only a common point size makes the
    /// row read as one set.
    static func symbol(_ name: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 15, weight: .regular))
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
    func formatPopupMenu() -> NSMenu {
        let menu = NSMenu(title: "Format")
        menu.addItem(iconRowItem(Self.inlineRow1))
        menu.addItem(iconRowItem(Self.inlineRow2))
        menu.addItem(.separator())

        for level in 1...3 { menu.addItem(headingRow(level)) }
        menu.addItem(FormatMenu.thematicBreakCommand.makeItem())
        for cmd in FormatMenu.listCommands where cmd.id != "format.checklist" {
            menu.addItem(marked(cmd.makeItem()))
        }
        menu.addItem(.separator())

        for cmd in FormatMenu.blockCommands where cmd.id != "format.table" {
            menu.addItem(marked(cmd.makeItem()))
        }
        menu.addItem(calloutRow())
        menu.addItem(FormatMenu.footnoteCommand.makeItem())
        return menu
    }

    /// A heading row rendered at the weight it applies, the way Notes previews
    /// Title / Heading / Subheading.
    private func headingRow(_ level: Int) -> NSMenuItem {
        let item = MenuCommand(id: "format.heading\(level)", submenu: "Heading",
                               title: "Heading \(level)",
                               action: #selector(EditorTextView.formatHeading(_:)),
                               tag: level).makeItem()
        // H1 18pt, H2 15.5pt, H3 13pt — a visible step down without overwhelming
        // the plain rows beneath.
        let size = [18.0, 15.5, 13.0][level - 1]
        item.attributedTitle = NSAttributedString(
            string: item.title,
            attributes: [.font: NSFont.systemFont(ofSize: size, weight: .semibold)])
        return item
    }

    /// The single callout row. The label is the syntax it writes, matching how
    /// the list rows show their own markers.
    private func calloutRow() -> NSMenuItem {
        MenuCommand(id: "format.callout.NOTE", submenu: "Alert / Callout",
                    title: "> [!NOTE]",
                    action: #selector(EditorTextView.formatCallout(_:)),
                    representedObject: "NOTE").makeItem()
    }

    /// Prefixes a row with the marker it inserts (`•`, `1.`, `▎`), so the menu
    /// previews its own effect.
    private func marked(_ item: NSMenuItem) -> NSMenuItem {
        let marker: String
        switch item.action {
        case #selector(EditorTextView.formatBulletedList(_:)): marker = "•  "
        case #selector(EditorTextView.formatNumberedList(_:)): marker = "1.  "
        case #selector(EditorTextView.formatBlockQuote(_:)):   marker = "▎ "
        default: return item
        }
        item.attributedTitle = NSAttributedString(
            string: marker + item.title,
            attributes: [.font: NSFont.menuFont(ofSize: 0)])
        return item
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
        ("function", "format.math"),
        ("textformat.subscript", "format.subscript"),
        ("textformat.superscript", "format.superscript"),
    ]

    /// Which inline style a row button reflects. Nil for commands that have no
    /// detectable on/off state at the caret.
    static func style(for commandID: String) -> ActiveInlineStyles? {
        switch commandID {
        case "format.bold":          return .bold
        case "format.italic":        return .italic
        case "format.underline":     return .underline
        case "format.strikethrough": return .strikethrough
        case "format.highlight":     return .highlight
        case "format.code":          return .code
        case "format.math":          return .math
        case "format.subscript":     return .subscript
        case "format.superscript":   return .superscript
        default:                     return nil
        }
    }

    /// The block style a popup row applies, so the row matching the caret's own
    /// block can be checkmarked.
    static func blockStyle(for item: NSMenuItem) -> ActiveBlockStyle? {
        switch item.action {
        case #selector(EditorTextView.formatHeading(_:)):     return .heading(level: item.tag)
        case #selector(EditorTextView.formatBulletedList(_:)): return .bulletedList
        case #selector(EditorTextView.formatNumberedList(_:)): return .numberedList
        case #selector(EditorTextView.formatBlockQuote(_:)):   return .blockQuote
        case #selector(EditorTextView.formatCodeBlock(_:)):    return .codeBlock
        case #selector(EditorTextView.formatMathBlock(_:)):    return .mathBlock
        case #selector(EditorTextView.formatCallout(_:)):      return .callout
        default:                                               return nil
        }
    }

    private func iconRowItem(_ row: [(String, String)]) -> NSMenuItem {
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 12, bottom: 4, right: 12)

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
            // The highlighter reads as its ink colour, matching the mark it makes.
            if id == "format.highlight" { button.contentTintColor = .systemYellow }
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

        let item = NSMenuItem()
        item.title = ""   // NSMenuItem defaults to "NSMenuItem", which VoiceOver reads out
        item.view = stack
        return item
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

// MARK: - Menu delegate

extension FormatToolbar: NSMenuDelegate {
    /// Rebuild the format popup on every open so a shortcut changed in Settings ▸
    /// Key Bindings shows through, and so the icon rows re-evaluate enablement.
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu.title == "Format" else { return }
        menu.removeAllItems()
        iconTargets.removeAll()
        let fresh = formatPopupMenu()
        for item in fresh.items {
            fresh.removeItem(item)
            menu.addItem(item)
        }
        refreshIconRows(in: menu)
        refreshBlockRows(in: menu)
    }

    /// Checkmarks the row matching the caret's own block, the way Notes ticks the
    /// current paragraph style.
    private func refreshBlockRows(in menu: NSMenu) {
        guard let editor = document?.editor else { return }
        let active = editor.activeBlockStyle()
        for item in menu.items {
            guard let style = Self.blockStyle(for: item) else { continue }
            item.state = style == active ? .on : .off
        }
    }

    /// Icon-row buttons are not validated items, so they have to ask the focused
    /// editor directly — for both their enabled state and whether the style they
    /// apply is already in effect at the caret.
    private func refreshIconRows(in menu: NSMenu) {
        let editor = document?.editor
        let active = editor?.activeInlineStyles() ?? []
        for item in menu.items {
            guard let stack = item.view as? NSStackView else { continue }
            for case let button as NSButton in stack.arrangedSubviews {
                guard let target = button.target as? FormatIconTarget else { continue }
                (button as? FormatIconButton)?.isActive =
                    Self.style(for: target.styleID).map(active.contains) ?? false
                button.isEnabled = editor?.isFormattingActionEnabled(
                    target.action, representedObject: nil) ?? false
                // An explicit contentTintColor (the highlighter's yellow) defeats
                // AppKit's automatic dimming, so fade the whole button instead.
                button.alphaValue = button.isEnabled ? 1.0 : 0.35
            }
        }
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

    init(action: Selector, styleID: String) {
        self.action = action
        self.styleID = styleID
        super.init()
    }

    @objc func fire(_ sender: NSButton) {
        sender.enclosingMenuItem?.menu?.cancelTracking()
        NSApp.sendAction(action, to: nil, from: sender)
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

    /// A disabled button must not look hoverable.
    override var isEnabled: Bool {
        didSet { if !isEnabled { isHovered = false } else { updateBackground() } }
    }

    private func updateBackground() {
        wantsLayer = true
        layer?.cornerRadius = 5
        let color: NSColor? =
            !isEnabled ? nil
            : isActive ? .controlAccentColor.withAlphaComponent(isHovered ? 0.32 : 0.22)
            : isHovered ? .labelColor.withAlphaComponent(0.10)
            : nil
        layer?.backgroundColor = color?.cgColor
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
        button.isEnabled = (NSApp.target(forAction: action) as? EditorTextView)?
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
