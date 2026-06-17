// SettingsWindowController — the AppKit window + preference toolbar that hosts
// each SwiftUI pane in an NSHostingController and animates pane switches.

import AppKit
import SwiftUI

/// A CotEditor-style Settings window. The window chrome and the pane-switching
/// preference toolbar stay AppKit; each pane's content is a SwiftUI view hosted
/// in an `NSHostingController`, which owns all of the layout.
final class SettingsWindowController: NSWindowController, NSToolbarDelegate {
    private enum Pane {
        case general
        case appearance

        var title: String {
            switch self {
            case .general: return "General"
            case .appearance: return "Appearance"
            }
        }

        var identifier: NSToolbarItem.Identifier {
            switch self {
            case .general: return Self.generalID
            case .appearance: return Self.appearanceID
            }
        }

        static let generalID = NSToolbarItem.Identifier("settings.general")
        static let appearanceID = NSToolbarItem.Identifier("settings.appearance")
    }

    /// Owns the editor font / line-height state and the font-panel plumbing.
    /// Shared across pane rebuilds so the font panel keeps targeting it.
    private let fonts = FontSettings()

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 360),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.center()
        window.isReleasedWhenClosed = false

        self.init(window: window)
        setupWindow()
        showPane(.general, animated: false)
    }

    private func setupWindow() {
        guard let window else { return }
        window.titleVisibility = .visible
        window.titlebarSeparatorStyle = .line

        let toolbar = NSToolbar(identifier: "SettingsToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false
        toolbar.selectedItemIdentifier = Pane.generalID
        window.toolbar = toolbar
        window.toolbarStyle = .preference
    }

    // MARK: - Toolbar

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Pane.generalID, Pane.appearanceID]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar,
                 itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.target = self
        item.action = #selector(selectPane(_:))

        switch itemIdentifier {
        case Pane.generalID:
            item.label = "General"
            item.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: "General")
        case Pane.appearanceID:
            item.label = "Appearance"
            item.image = NSImage(systemSymbolName: "eyeglasses", accessibilityDescription: "Appearance")
        default:
            return nil
        }
        item.paletteLabel = item.label
        return item
    }

    @objc private func selectPane(_ sender: NSToolbarItem) {
        switch sender.itemIdentifier {
        case Pane.generalID: showPane(.general, animated: true)
        case Pane.appearanceID: showPane(.appearance, animated: true)
        default: break
        }
    }

    // MARK: - Panes

    private func showPane(_ pane: Pane, animated: Bool) {
        guard let window else { return }
        window.title = pane.title
        window.toolbar?.selectedItemIdentifier = pane.identifier

        let root: AnyView = switch pane {
        case .general: AnyView(GeneralSettingsView())
        case .appearance: AnyView(AppearanceSettingsView(fonts: fonts))
        }
        let hosting = NSHostingController(rootView: root)
        // `.preferredContentSize` makes the window reliably size itself to the
        // SwiftUI content (manually reading `fittingSize` before the view is in a
        // window yields zero — and a zero-width window).
        hosting.sizingOptions = [.preferredContentSize]

        let topY = window.frame.maxY
        let startFrame = window.frame

        // Swap in the new pane and let the window resize to it, then compute the
        // target frame with the top edge kept fixed. Screen updates are coalesced
        // so the intermediate (bottom-anchored) resize never flashes on screen.
        window.disableScreenUpdatesUntilFlush()
        window.contentViewController = hosting
        window.layoutIfNeeded()
        var endFrame = window.frame
        endFrame.origin.y = topY - endFrame.height

        if animated, window.isVisible {
            // Animate only the window frame (width is constant between panes), so
            // the new content simply reveals as the height changes — no fade, no
            // competing resize.
            window.setFrame(startFrame, display: false)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                window.animator().setFrame(endFrame, display: true)
            }
        } else {
            window.setFrame(endFrame, display: false)
        }
    }
}
