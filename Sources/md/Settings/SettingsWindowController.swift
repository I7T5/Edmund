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
        window.title = "Settings"
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

        addPane(GeneralSettingsView(), label: "General", symbol: "gearshape")
        addPane(AppearanceSettingsView(fonts: fonts), label: "Appearance", symbol: "eyeglasses")
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
            self?.view.isHidden = false
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
