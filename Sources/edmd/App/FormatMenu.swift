import AppKit
import EdmundCore

// MARK: - Format menu (declarative command registry)
//
// The Format menu and its shortcuts are described by a single table of
// `MenuCommand`s and built from it. Action methods live on `EditorTextView`
// (and `Document` for the view-mode cycle); items use a nil target so they
// route through the responder chain to the focused editor — exactly like the
// undo/redo items in `setupMenuBar`.
//
// User-configurable shortcuts: every command carries a stable `id`, a `group`
// (the menu it appears under) and a default `Shortcut`. `makeItem()` resolves a
// per-`id` override from `KeyBindingStore` and registers the built item in
// `KeyBindingCatalog`, which is what Settings ▸ Key Bindings lists and edits.

/// A key equivalent: the (lowercased) key plus its modifier flags.
struct Shortcut: Equatable {
    let key: String
    let modifiers: NSEvent.ModifierFlags

    static func cmd(_ key: String) -> Shortcut { Shortcut(key: key, modifiers: [.command]) }
    static func cmdShift(_ key: String) -> Shortcut { Shortcut(key: key, modifiers: [.command, .shift]) }
    static func cmdOpt(_ key: String) -> Shortcut { Shortcut(key: key, modifiers: [.command, .option]) }
}

/// One actionable menu command.
struct MenuCommand {
    let id: String
    /// The menu this command lives under, as Settings ▸ Key Bindings groups it.
    var group: String = "Format"
    /// The submenu it sits in, if any ("Font", "Heading", …). Settings lists the
    /// commands nested under this title, the way the menu bar shows them.
    var submenu: String? = nil
    let title: String
    let action: Selector
    /// The out-of-the-box shortcut. The user's override, if any, wins in `makeItem()`.
    var shortcut: Shortcut? = nil
    var tag: Int = 0
    var representedObject: Any? = nil

    @MainActor func makeItem() -> NSMenuItem {
        let effective = KeyBindingStore.effective(id: id, default: shortcut)
        let item = NSMenuItem(title: title, action: action, keyEquivalent: effective?.key ?? "")
        item.keyEquivalentModifierMask = effective?.modifiers ?? []
        item.tag = tag
        item.representedObject = representedObject
        KeyBindingCatalog.shared.register(id: id, group: group, submenu: submenu, title: title,
                                          defaultShortcut: shortcut, item: item)
        // nil target → responder chain (focused EditorTextView / Document).
        return item
    }
}

@MainActor
enum FormatMenu {

    /// The top-level "Format" menu item (with its submenu).
    static func build() -> NSMenuItem {
        let formatItem = NSMenuItem()
        let menu = NSMenu(title: "Format")

        menu.addItem(headingSubmenuItem())
        menu.addItem(thematicBreakCommand.makeItem())
        menu.addItem(.separator())

        for cmd in listCommands { menu.addItem(cmd.makeItem()) }
        menu.addItem(.separator())

        for cmd in linkCommands { menu.addItem(cmd.makeItem()) }
        menu.addItem(.separator())

        for cmd in blockCommands { menu.addItem(cmd.makeItem()) }
        menu.addItem(calloutSubmenuItem())
        menu.addItem(footnoteCommand.makeItem())
        menu.addItem(.separator())

        menu.addItem(fontSubmenuItem())

        formatItem.submenu = menu
        return formatItem
    }

    /// The "Toggle View Mode" item (⌘E) for the View menu — bracketed by
    /// dividers by the caller.
    static func viewModeToggleItem() -> NSMenuItem {
        MenuCommand(id: "view.toggleMode", group: "View", title: "Toggle View Mode",
                    action: #selector(Document.toggleViewMode(_:)),
                    shortcut: .cmd("e")).makeItem()
    }

    // MARK: - Groups

    private static let listCommands: [MenuCommand] = [
        MenuCommand(id: "format.bulletedList", title: "Bulleted List",
                    action: #selector(EditorTextView.formatBulletedList(_:)), shortcut: .cmdOpt("b")),
        MenuCommand(id: "format.numberedList", title: "Numbered List",
                    action: #selector(EditorTextView.formatNumberedList(_:))),
        MenuCommand(id: "format.checklist", title: "Checklist",
                    action: #selector(EditorTextView.formatChecklist(_:)), shortcut: .cmd("l")),
    ]

    private static let linkCommands: [MenuCommand] = [
        MenuCommand(id: "format.link", title: "Link",
                    action: #selector(EditorTextView.formatLink(_:)), shortcut: .cmd("k")),
        MenuCommand(id: "format.wikilink", title: "Wikilink",
                    action: #selector(EditorTextView.formatWikilink(_:))),
        MenuCommand(id: "format.image", title: "Image",
                    action: #selector(EditorTextView.formatImage(_:))),
    ]

    private static let thematicBreakCommand = MenuCommand(id: "format.thematicBreak", title: "Thematic Break",
                    action: #selector(EditorTextView.formatThematicBreak(_:)))

    private static let footnoteCommand = MenuCommand(id: "format.footnote", title: "Footnote",
                    action: #selector(EditorTextView.formatFootnote(_:)))

    private static let blockCommands: [MenuCommand] = [
        MenuCommand(id: "format.table", title: "Table",
                    action: #selector(EditorTextView.formatTable(_:))),
        MenuCommand(id: "format.codeBlock", title: "Code Block",
                    action: #selector(EditorTextView.formatCodeBlock(_:))),
        MenuCommand(id: "format.mathBlock", title: "Math Block",
                    action: #selector(EditorTextView.formatMathBlock(_:))),
        MenuCommand(id: "format.blockQuote", title: "Block Quote",
                    action: #selector(EditorTextView.formatBlockQuote(_:)), shortcut: .cmdShift("b")),
    ]

    private static let fontCommands: [MenuCommand] = [
        MenuCommand(id: "format.bold", submenu: "Font", title: "Bold",
                    action: #selector(EditorTextView.formatBold(_:)), shortcut: .cmd("b")),
        MenuCommand(id: "format.italic", submenu: "Font", title: "Italic",
                    action: #selector(EditorTextView.formatItalic(_:)), shortcut: .cmd("i")),
        MenuCommand(id: "format.underline", submenu: "Font", title: "Underline",
                    action: #selector(EditorTextView.formatUnderline(_:)), shortcut: .cmd("u")),
        MenuCommand(id: "format.strikethrough", submenu: "Font", title: "Strikethrough",
                    action: #selector(EditorTextView.formatStrikethrough(_:))),
        MenuCommand(id: "format.subscript", submenu: "Font", title: "Subscript",
                    action: #selector(EditorTextView.formatSubscript(_:))),
        MenuCommand(id: "format.superscript", submenu: "Font", title: "Superscript",
                    action: #selector(EditorTextView.formatSuperscript(_:))),
        MenuCommand(id: "format.highlight", submenu: "Font", title: "Highlight",
                    action: #selector(EditorTextView.formatHighlight(_:))),
        MenuCommand(id: "format.code", submenu: "Font", title: "Code",
                    action: #selector(EditorTextView.formatCode(_:))),
        MenuCommand(id: "format.math", submenu: "Font", title: "Math",
                    action: #selector(EditorTextView.formatInlineMath(_:))),
        MenuCommand(id: "format.keyboard", submenu: "Font", title: "Keyboard",
                    action: #selector(EditorTextView.formatKeyboard(_:))),
        MenuCommand(id: "format.comment", submenu: "Font", title: "Comments",
                    action: #selector(EditorTextView.formatComment(_:))),
    ]

    /// GitHub alert types (uppercase in source: `> [!NOTE]`).
    private static let githubCalloutTypes = ["NOTE", "TIP", "IMPORTANT", "WARNING", "CAUTION"]

    /// Obsidian-only callout types (lowercase). note/tip/warning are omitted
    /// since they duplicate NOTE/TIP/WARNING already in the GitHub group.
    private static let obsidianCalloutTypes = [
        "abstract", "info", "todo", "success", "question",
        "failure", "danger", "bug", "example", "quote",
    ]

    // MARK: - Submenus

    private static func headingSubmenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Heading", action: nil, keyEquivalent: "")
        item.submenu = headingMenu()
        return item
    }

    /// A fresh Heading submenu: Body (level 0, strips the `#` prefix), a
    /// separator, then Heading 1–6. Shared by the menu bar and the format bar's
    /// heading pulldown. Like `fontMenu()`, each call re-registers the ids in
    /// `KeyBindingCatalog` — already the behaviour for the context Font menu.
    static func headingMenu() -> NSMenu {
        let menu = NSMenu(title: "Heading")
        menu.addItem(MenuCommand(id: "format.heading0", submenu: "Heading",
                                 title: "Body",
                                 action: #selector(EditorTextView.formatHeading(_:)),
                                 tag: 0).makeItem())
        menu.addItem(.separator())
        for level in 1...6 {
            menu.addItem(MenuCommand(id: "format.heading\(level)", submenu: "Heading",
                                     title: "Heading \(level)",
                                     action: #selector(EditorTextView.formatHeading(_:)),
                                     tag: level).makeItem())
        }
        return menu
    }

    private static func calloutSubmenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Alert / Callout", action: nil, keyEquivalent: "")
        item.submenu = calloutMenu()
        return item
    }

    /// A fresh Alert / Callout submenu: the five GitHub alerts, a separator,
    /// then the Obsidian-only types. Shared by the menu bar and the format bar's
    /// callout pulldown.
    static func calloutMenu() -> NSMenu {
        let menu = NSMenu(title: "Alert / Callout")
        for type in githubCalloutTypes {
            menu.addItem(MenuCommand(id: "format.callout.\(type)", submenu: "Alert / Callout",
                                     title: type.capitalized,
                                     action: #selector(EditorTextView.formatCallout(_:)),
                                     representedObject: type).makeItem())
        }
        menu.addItem(.separator())
        for type in obsidianCalloutTypes {
            menu.addItem(MenuCommand(id: "format.callout.\(type)", submenu: "Alert / Callout",
                                     title: type.capitalized,
                                     action: #selector(EditorTextView.formatCallout(_:)),
                                     representedObject: type).makeItem())
        }
        return menu
    }

    private static func fontSubmenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Font", action: nil, keyEquivalent: "")
        item.submenu = fontMenu()
        return item
    }

    /// A fresh Font submenu built from `fontCommands` (Bold, Italic, …). Also
    /// used to replace the system Font submenu in the editor's right-click menu
    /// (see `EditorTextView.contextFontMenuProvider`).
    static func fontMenu() -> NSMenu {
        let menu = NSMenu(title: "Font")
        for cmd in fontCommands { menu.addItem(cmd.makeItem()) }
        return menu
    }
}
