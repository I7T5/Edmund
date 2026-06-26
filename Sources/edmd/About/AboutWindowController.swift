import AppKit
import SwiftUI

final class AboutWindowController: NSWindowController {
    convenience init() {
        let hosting = NSHostingController(rootView: AboutView())
        hosting.sizingOptions = [.preferredContentSize]
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable]
        window.title = ""
        window.center()
        window.isReleasedWhenClosed = false
        self.init(window: window)
    }
}
