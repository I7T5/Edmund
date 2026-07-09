import AppKit
import EdmundCore

// MARK: - View menu

@MainActor
enum ViewMenu {

    /// The top-level "View" menu item (with its submenu).
    static func build() -> NSMenuItem {
        let viewMenuItem = NSMenuItem()
        let viewMenu = NSMenu(title: "View")

        // Routes through the responder chain to the key window's toolbar.
        // AppKit auto-inserts "Show Tab Bar"/"Show All Tabs" above this at
        // runtime (window tabbing is on by default) — that position isn't
        // ours to control short of disabling tabbing outright.
        viewMenu.addItem(withTitle: "Customize Toolbar…",
                         action: #selector(NSWindow.runToolbarCustomizationPalette(_:)),
                         keyEquivalent: "")
        viewMenu.addItem(.separator())

        let typewriterItem = viewMenu.addItem(
            withTitle: "Typewriter Scroll",
            action: #selector(AppDelegate.toggleTypewriterMode(_:)),
            keyEquivalent: "")
        typewriterItem.state = AppDelegate.typewriterModeEnabled() ? .on : .off

        // View-mode toggle (Edit ↔ Read) + the Source-mode checkbox.
        viewMenu.addItem(.separator())
        viewMenu.addItem(FormatMenu.viewModeToggleItem())
        viewMenu.addItem(withTitle: "Source Mode",
                         action: #selector(Document.toggleSourceMode(_:)),
                         keyEquivalent: "")
        viewMenu.addItem(.separator())

        // Zoom (font size + max content width, scaled together). Target nil
        // routes through the responder chain to the key window's Document.
        // Kept last, directly above the separator AppKit inserts before its
        // automatic "Enter/Exit Full Screen" item at the menu's end.
        viewMenu.addItem(withTitle: "Actual Size",
                         action: #selector(Document.actualSize(_:)),
                         keyEquivalent: "0")
        viewMenu.addItem(withTitle: "Zoom In",
                         action: #selector(Document.zoomIn(_:)),
                         keyEquivalent: "=")
        viewMenu.addItem(withTitle: "Zoom Out",
                         action: #selector(Document.zoomOut(_:)),
                         keyEquivalent: "-")
        viewMenu.addItem(.separator())

        viewMenuItem.submenu = viewMenu
        return viewMenuItem
    }
}
