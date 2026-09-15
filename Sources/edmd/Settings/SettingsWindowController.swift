// SettingsWindowController — the Settings window.
//
// Built on NSTabViewController (`.toolbar` style), which provides the native
// preference toolbar, pane selection, and per-pane window sizing. Each pane is a
// SwiftUI view hosted in an NSHostingController. Pane switching mirrors
// CotEditor: hide the content, animate the window resize, then reveal it.

import AppKit
import SwiftUI

final class SettingsWindowController: NSWindowController {
    convenience init() {
        let tabController = SettingsTabViewController()
        let window = NSWindow(contentViewController: tabController)
        window.styleMask = [.titled, .closable]
        // The tab controller titles itself after the selected pane while its
        // view loads (above, as the window takes it as content view controller),
        // so seed the window from that — assigning a literal here would paint
        // over the first pane's name until the user switched tabs.
        window.title = tabController.title ?? "Settings"
        window.toolbarStyle = .preference
        window.center()
        window.isReleasedWhenClosed = false
        self.init(window: window)
    }
}

/// Hosts the Settings panes as toolbar tabs and animates the window resize on
/// each switch.
final class SettingsTabViewController: NSTabViewController {
    /// Owns the editor font / line-height state and the font-panel plumbing.
    private let fonts = FontSettings()

    override func viewDidLoad() {
        super.viewDidLoad()
        tabStyle = .toolbar

        // General first and Advanced last are fixed; between them the look of
        // the thing comes before its behaviour, which is where CotEditor
        // (General, Window, Appearance, Edit) and Mail (General, Accounts,
        // Junk, Fonts & Colors, Viewing) both put it. Appearance precedes
        // Themes: it holds the broad choices, Themes is the authoring pane.
        addPane(GeneralSettingsView(), label: "General", symbol: "gearshape")
        addPane(AppearanceSettingsView(fonts: fonts), label: "Appearance",
                symbol: "eyeglasses")
        addPane(ThemesSettingsView(), label: "Themes", symbol: "paintbrush")
        addPane(EditSettingsView(), label: "Edit", symbol: "square.and.pencil")
        addPane(SyntaxSettingsView(), label: "Syntax", symbol: "chevron.left.forwardslash.chevron.right")
        addPane(KeyBindingsSettingsView(), label: "Key Bindings", symbol: "keyboard")
        addPane(ExtensionsSettingsView(), label: "Extensions", symbol: "puzzlepiece.extension")
        addPane(AdvancedSettingsView(), label: "Advanced", symbol: "gearshape.2")
    }

    private func addPane(_ view: some View, label: String, symbol: String) {
        let hosting = NSHostingController(rootView: view)
        // Report a definite size so the tab controller can size the window to it.
        hosting.sizingOptions = [.preferredContentSize]
        let item = NSTabViewItem(viewController: hosting)
        item.label = label
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        addTabViewItem(item)
    }

    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        guard let tabViewItem else { return }
        // The window title follows this controller's title, and names the
        // selected pane (as System Settings does). It has to be set from the
        // item's label: super resets the title to the pane's own — nil, since
        // the panes are untitled NSHostingControllers — which would show
        // "Untitled".
        title = tabViewItem.label
        switchPane(to: tabViewItem)
    }

    /// Resize the window to fit the newly selected pane, keeping the top-left
    /// fixed. The content is hidden during the resize so nothing stretches
    /// mid-animation, then revealed once the window is at its final size.
    private func switchPane(to tabViewItem: NSTabViewItem) {
        guard let window = view.window,
              let contentSize = tabViewItem.view?.frame.size else { return }

        let frame = window.frameRect(forContentSize: contentSize)

        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            window.setFrame(frame, display: true)
            return
        }

        view.isHidden = true
        NSAnimationContext.runAnimationGroup { context in
            context.allowsImplicitAnimation = true
            context.duration = window.animationResizeTime(frame)
            window.setFrame(frame, display: true)
        } completionHandler: { [weak self] in
            // AppKit runs this on the main thread but types it as a plain
            // `@Sendable` closure, so the isolation has to be asserted rather
            // than hopped to — a hop would land a frame later and flash the
            // pane back in after the resize had already finished.
            MainActor.assumeIsolated { self?.view.isHidden = false }
        }
    }
}

private extension NSWindow {
    /// The window frame for the given content size, keeping the top-left fixed.
    func frameRect(forContentSize contentSize: NSSize) -> NSRect {
        let frameSize = frameRect(forContentRect: NSRect(origin: .zero, size: contentSize)).size
        return NSRect(origin: frame.origin, size: frameSize)
            .offsetBy(dx: 0, dy: frame.height - frameSize.height)
    }
}
