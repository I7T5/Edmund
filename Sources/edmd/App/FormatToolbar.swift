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
    /// ordinary menu rows (which get dividers, submenus, hover, keyboard nav and
    /// live shortcut display for free — the reason this is an `NSMenu` and not a
    /// hand-built popover).
    ///
    /// Checklist and Table are absent on purpose: they are their own toolbar
    /// items.
    func formatPopupMenu() -> NSMenu {
        let menu = NSMenu(title: "Format")
        menu.addItem(iconRowItem(Self.inlineRow1))
        menu.addItem(iconRowItem(Self.inlineRow2))
        menu.addItem(.separator())

        menu.addItem(FormatMenu.headingSubmenuItem())
        menu.addItem(FormatMenu.thematicBreakCommand.makeItem())
        for cmd in FormatMenu.listCommands where cmd.id != "format.checklist" {
            menu.addItem(cmd.makeItem())
        }
        menu.addItem(.separator())

        for cmd in FormatMenu.blockCommands where cmd.id != "format.table" {
            menu.addItem(cmd.makeItem())
        }
        menu.addItem(FormatMenu.calloutSubmenuItem())
        menu.addItem(FormatMenu.footnoteCommand.makeItem())
        return menu
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

    private func iconRowItem(_ row: [(String, String)]) -> NSMenuItem {
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 12, bottom: 4, right: 12)

        for (symbol, id) in row {
            guard let cmd = FormatMenu.fontCommands.first(where: { $0.id == id }) else { continue }
            let target = FormatIconTarget(action: cmd.action)
            iconTargets.append(target)

            let button = NSButton(image: Self.rowSymbol(symbol) ?? NSImage(),
                                  target: target, action: #selector(FormatIconTarget.fire(_:)))
            button.bezelStyle = .accessoryBar
            button.setButtonType(.momentaryPushIn)
            button.imagePosition = .imageOnly
            button.toolTip = cmd.title
            button.setAccessibilityLabel(cmd.title)
            // The highlighter reads as its ink colour, matching the mark it makes.
            if id == "format.highlight" { button.contentTintColor = .systemYellow }
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
    }

    /// Icon-row buttons are not validated items, so they have to ask the focused
    /// editor directly.
    private func refreshIconRows(in menu: NSMenu) {
        let editor = document?.editor
        for item in menu.items {
            guard let stack = item.view as? NSStackView else { continue }
            for case let button as NSButton in stack.arrangedSubviews {
                guard let target = button.target as? FormatIconTarget else { continue }
                button.isEnabled = editor?.isFormattingActionEnabled(
                    target.action, representedObject: nil) ?? false
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

    init(action: Selector) {
        self.action = action
        super.init()
    }

    @objc func fire(_ sender: NSButton) {
        sender.enclosingMenuItem?.menu?.cancelTracking()
        NSApp.sendAction(action, to: nil, from: sender)
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
