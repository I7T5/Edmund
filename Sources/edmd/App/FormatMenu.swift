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
// Groundwork for user-configurable shortcuts: every command carries a stable
// `id` and a default `Shortcut`. A later pass can resolve a per-`id` override
// from UserDefaults before building the item; nothing is persisted yet.

/// A key equivalent: the (lowercased) key plus its modifier flags.
struct Shortcut {
    let key: String
    let modifiers: NSEvent.ModifierFlags

    static func cmd(_ key: String) -> Shortcut { Shortcut(key: key, modifiers: [.command]) }
    static func cmdShift(_ key: String) -> Shortcut { Shortcut(key: key, modifiers: [.command, .shift]) }
    static func cmdOpt(_ key: String) -> Shortcut { Shortcut(key: key, modifiers: [.command, .option]) }
}

/// One actionable menu command.
struct MenuCommand {
    let id: String
    let title: String
    let action: Selector
    var shortcut: Shortcut? = nil
    var tag: Int = 0
    var representedObject: Any? = nil

    func makeItem() -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: shortcut?.key ?? "")
        item.keyEquivalentModifierMask = shortcut?.modifiers ?? []
        item.tag = tag
        item.representedObject = representedObject
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
        menu.addItem(.separator())

        for cmd in listCommands { menu.addItem(cmd.makeItem()) }
        menu.addItem(.separator())

        for cmd in linkCommands { menu.addItem(cmd.makeItem()) }
        menu.addItem(.separator())

        for cmd in blockCommands { menu.addItem(cmd.makeItem()) }
        menu.addItem(calloutSubmenuItem())
        menu.addItem(.separator())

        menu.addItem(fontSubmenuItem())

        formatItem.submenu = menu
        return formatItem
    }

    /// The "Cycle View Mode" item (⌘E) for the View menu — bracketed by
    /// dividers by the caller.
    static func viewModeCycleItem() -> NSMenuItem {
        MenuCommand(id: "view.cycleMode", title: "Cycle View Mode",
                    action: #selector(Document.cycleViewMode(_:)),
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
        MenuCommand(id: "format.footnote", title: "Footnote",
                    action: #selector(EditorTextView.formatFootnote(_:))),
    ]

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
        MenuCommand(id: "format.bold", title: "Bold",
                    action: #selector(EditorTextView.formatBold(_:)), shortcut: .cmd("b")),
        MenuCommand(id: "format.italic", title: "Italic",
                    action: #selector(EditorTextView.formatItalic(_:)), shortcut: .cmd("i")),
        MenuCommand(id: "format.underline", title: "Underline",
                    action: #selector(EditorTextView.formatUnderline(_:)), shortcut: .cmd("u")),
        MenuCommand(id: "format.strikethrough", title: "Strikethrough",
                    action: #selector(EditorTextView.formatStrikethrough(_:))),
        MenuCommand(id: "format.highlight", title: "Highlight",
                    action: #selector(EditorTextView.formatHighlight(_:))),
        MenuCommand(id: "format.code", title: "Code",
                    action: #selector(EditorTextView.formatCode(_:))),
        MenuCommand(id: "format.math", title: "Math",
                    action: #selector(EditorTextView.formatInlineMath(_:))),
        MenuCommand(id: "format.keyboard", title: "Keyboard",
                    action: #selector(EditorTextView.formatKeyboard(_:))),
        MenuCommand(id: "format.comment", title: "Comments",
                    action: #selector(EditorTextView.formatComment(_:))),
    ]

    /// GitHub alert types (uppercase in source: `> [!NOTE]`).
    private static let githubCalloutTypes = ["NOTE", "TIP", "IMPORTANT", "WARNING", "CAUTION"]

    /// Obsidian callout types (lowercase in source: `> [!note]`).
    private static let obsidianCalloutTypes = [
        "note", "abstract", "info", "todo", "tip", "success", "question",
        "warning", "failure", "danger", "bug", "example", "quote",
    ]

    // MARK: - Submenus

    private static func headingSubmenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Heading", action: nil, keyEquivalent: "")
        let menu = NSMenu(title: "Heading")
        for level in 1...6 {
            menu.addItem(MenuCommand(id: "format.heading\(level)", title: "Heading \(level)",
                                     action: #selector(EditorTextView.formatHeading(_:)),
                                     tag: level).makeItem())
        }
        item.submenu = menu
        return item
    }

    private static func calloutSubmenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Alert / Callout", action: nil, keyEquivalent: "")
        let menu = NSMenu(title: "Alert / Callout")
        for type in githubCalloutTypes {
            menu.addItem(MenuCommand(id: "format.callout.\(type)", title: type.capitalized,
                                     action: #selector(EditorTextView.formatCallout(_:)),
                                     representedObject: type).makeItem())
        }
        menu.addItem(.separator())
        for type in obsidianCalloutTypes {
            menu.addItem(MenuCommand(id: "format.callout.\(type)", title: type.capitalized,
                                     action: #selector(EditorTextView.formatCallout(_:)),
                                     representedObject: type).makeItem())
        }
        item.submenu = menu
        return item
    }

    private static func fontSubmenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Font", action: nil, keyEquivalent: "")
        let menu = NSMenu(title: "Font")
        for cmd in fontCommands { menu.addItem(cmd.makeItem()) }
        item.submenu = menu
        return item
    }
}
