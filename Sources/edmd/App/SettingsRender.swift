#if DEBUG
import AppKit
import SwiftUI
import EdmundCore

/// Offscreen render of a Settings pane or a theme detail to a PNG, for
/// checking layout work without a live `screencapture` (which has never
/// worked for these panes — see ARCHITECTURE §8). DEBUG builds only.
///
///   -debug.render <target> -debug.renderOut <path.png> [-debug.renderDark YES]
///
/// Targets:
///   pane:<Label>     a whole Settings pane through the real window, by its
///                    toolbar label — `pane:Appearance`, `pane:Themes`
///   editor:<name>    an editor theme's detail box — `editor:solarized-light`
///   syntax:<name>    a code theme's detail box — `syntax:tomorrow`
///
/// Renders in Aqua unless `-debug.renderDark YES`, writes the PNG at the
/// screen's scale, and exits. Pass `-debug.disableUpdater YES` alongside.
@MainActor
enum SettingsRender {
    static func runIfRequested() {
        let defaults = UserDefaults.standard
        guard let target = defaults.string(forKey: "debug.render"),
              let out = defaults.string(forKey: "debug.renderOut") else { return }
        let dark = defaults.bool(forKey: "debug.renderDark")

        let window: NSWindow
        if target.hasPrefix("pane:") {
            let label = String(target.dropFirst(5))
            let controller = SettingsWindowController()
            guard let tabs = controller.contentViewController as? NSTabViewController,
                  let index = tabs.tabViewItems.firstIndex(where: { $0.label == label }),
                  let paneWindow = controller.window else {
                fail("no pane labelled \(label)")
            }
            tabs.selectedTabViewItemIndex = index
            window = paneWindow
        } else if let detail = detailView(for: target) {
            let view = NSHostingController(rootView: detail).view
            view.frame = NSRect(x: 0, y: 0, width: 472, height: 620)
            view.layoutSubtreeIfNeeded()
            view.frame.size.height = max(view.fittingSize.height, 300)
            window = NSWindow(contentRect: view.frame, styleMask: [.titled],
                              backing: .buffered, defer: false)
            window.contentView = view
        } else {
            fail("unknown render target \(target)")
        }

        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.setFrameOrigin(NSPoint(x: 300, y: 300))
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.layoutIfNeeded()
        // Let SwiftUI settle: fonts, preferences, the tab resize animation.
        RunLoop.current.run(until: Date().addingTimeInterval(2.0))

        let id = CGWindowID(window.windowNumber)
        guard let image = CGWindowListCreateImage(
                .null, .optionIncludingWindow, id, [.boundsIgnoreFraming, .bestResolution]),
              let data = NSBitmapImageRep(cgImage: image)
                .representation(using: .png, properties: [:]) else {
            fail("could not capture window \(id)")
        }
        do {
            try data.write(to: URL(fileURLWithPath: out))
        } catch {
            fail("could not write \(out): \(error)")
        }
        print("wrote \(out)")
        exit(0)
    }

    /// The Themes pane owns its selection, so a detail is built directly —
    /// editable, with edits dropped, in a bordered box the width of the pane's.
    private static func detailView(for target: String) -> AnyView? {
        let store = ThemeStore.shared
        let detail: AnyView
        if target.hasPrefix("editor:") {
            let name = String(target.dropFirst(7))
            guard let theme = store.generalThemes().first(where: { $0.name == name }) else {
                fail("no editor theme named \(name)")
            }
            detail = AnyView(GeneralThemeDetail(theme: theme, syntaxThemes: store.syntaxThemes(),
                                                isEditable: true, onChange: { _ in },
                                                onNewSyntaxTheme: { _ in })
                .padding(16))
        } else if target.hasPrefix("syntax:") {
            let name = String(target.dropFirst(7))
            guard let theme = store.syntaxThemes().first(where: { $0.name == name }) else {
                fail("no code theme named \(name)")
            }
            detail = AnyView(SyntaxThemeDetail(theme: theme, isEditable: true, onChange: { _ in }))
        } else {
            return nil
        }
        return AnyView(detail.frame(width: 440).border(.separator).padding(16))
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("render: \(message)\n".utf8))
        exit(1)
    }
}
#endif
