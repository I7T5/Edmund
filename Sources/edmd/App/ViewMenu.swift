import AppKit
import EdmundCore

// MARK: - View menu

@MainActor
enum ViewMenu {

    /// The top-level "View" menu item (with its submenu).
    static func build() -> NSMenuItem {
        let viewMenuItem = NSMenuItem()
        let viewMenu = NSMenu(title: "View")

        // Routes through the responder chain to the key window's Document, which
        // flips the persisted setting and retitles this item Show/Hide in
        // validateMenuItem — so it always agrees with Settings ▸ Edit ▸ Display.
        // (AppKit's own toggleToolbarShown(_:) would move the toolbar behind the
        // setting's back.) The title here is the first-launch default; the real
        // one is applied every time the menu opens.
        viewMenu.addItem(MenuCommand(id: "view.toggleToolbar", group: "View", title: "Hide Toolbar",
                                     action: #selector(Document.toggleToolbarShown(_:))).makeItem())

        // Full-screen auto-hide. Lives here rather than in Settings, next to
        // the switch it qualifies.
        viewMenu.addItem(MenuCommand(id: "view.autoHideToolbar", group: "View",
                                     title: autoHideToolbarTitle,
                                     action: #selector(Document.toggleAutoHideToolbar(_:))).makeItem())

        // Routes through the responder chain to the key window's toolbar.
        // AppKit auto-inserts "Show Tab Bar"/"Show All Tabs" above this at
        // runtime (window tabbing is on by default) — that position isn't
        // ours to control short of disabling tabbing outright.
        viewMenu.addItem(withTitle: "Customize Toolbar…",
                         action: #selector(NSWindow.runToolbarCustomizationPalette(_:)),
                         keyEquivalent: "")

        // The format bar across the top of the editor, kept below the toolbar
        // section with a divider on each side. Titled for the default state
        // (the bar starts hidden) the way Hide Toolbar above is —
        // Document.validateMenuItem flips it; no default shortcut.
        viewMenu.addItem(.separator())
        viewMenu.addItem(MenuCommand(id: "view.showFormatBar", group: "View",
                                     title: "Show Format Bar",
                                     action: #selector(Document.toggleFormatBar(_:))).makeItem())

        // View-mode toggle (Edit ↔ Read) + the Source-mode checkbox.
        viewMenu.addItem(.separator())
        viewMenu.addItem(FormatMenu.viewModeToggleItem())
        viewMenu.addItem(MenuCommand(id: "view.sourceMode", group: "View",
                                     title: "Show Source in Editor",
                                     action: #selector(Document.toggleSourceMode(_:))).makeItem())

        // Web Inspector (⌥⌘I). nil target → routes through the responder chain
        // to the key window's Document, so it works from Edit mode too: it
        // switches to Read mode and opens the inspector, and toggles the
        // inspector back off when it's already up.
        viewMenu.addItem(MenuCommand(id: "view.inspectReader", group: "View", title: "Inspect Reader",
                                     action: #selector(Document.toggleReaderInspector(_:)),
                                     shortcut: .cmdOpt("i")).makeItem())
        viewMenu.addItem(.separator())

        // Zoom (font size + max content width, scaled together). Target nil
        // routes through the responder chain to the key window's Document.
        // Kept last, directly above the separator AppKit inserts before its
        // automatic "Enter/Exit Full Screen" item at the menu's end.
        for cmd in zoomCommands { viewMenu.addItem(cmd.makeItem()) }
        viewMenu.addItem(.separator())

        viewMenuItem.submenu = viewMenu
        return viewMenuItem
    }

    /// Title case, like every other menu item. Only in the View menu — the
    /// toolbar's own context menu is AppKit's (Icon and Text / … / Customize
    /// Toolbar…) and Apple's apps put this setting in View, the way Safari
    /// carries "Always Show Toolbar in Full Screen".
    static let autoHideToolbarTitle = "Auto-Hide Toolbar"

    private static let zoomCommands: [MenuCommand] = [
        MenuCommand(id: "view.actualSize", group: "View", title: "Actual Size",
                    action: #selector(Document.actualSize(_:)), shortcut: .cmd("0")),
        MenuCommand(id: "view.zoomIn", group: "View", title: "Zoom In",
                    action: #selector(Document.zoomIn(_:)), shortcut: .cmd("=")),
        MenuCommand(id: "view.zoomOut", group: "View", title: "Zoom Out",
                    action: #selector(Document.zoomOut(_:)), shortcut: .cmd("-")),
    ]
}
