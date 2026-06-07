import AppKit
import MarkdownEditorCore

// --- App Delegate -----------------------------------------------------------

class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {

    var settingsWindowController: SettingsWindowController?

    // MARK: - Typewriter Mode (persisted)

    static let typewriterModeKey = "EditorTypewriterMode"

    /// Whether typewriter scrolling is enabled. Defaults to on (the historical
    /// behavior) when nothing has been saved yet.
    static func typewriterModeEnabled(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: typewriterModeKey) as? Bool ?? true
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMenuBar()

        // Open file from command-line argument. When a file is given,
        // `applicationShouldOpenUntitledFile` suppresses the otherwise-automatic
        // blank document, so we don't end up with two windows.
        let args = CommandLine.arguments
        if args.count > 1 {
            let url = URL(fileURLWithPath: args[1])
            NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, _ in }
        }
    }

    // Auto-open a blank document on launch only when no file was passed on the
    // command line (otherwise the file arg + the blank doc make two windows).
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        CommandLine.arguments.count <= 1
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    // Reopen a new untitled document when the app is activated with no windows.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            NSDocumentController.shared.newDocument(nil)
        }
        return true
    }

    // MARK: - Settings

    @MainActor @objc func showSettings(_ sender: Any?) {
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController()
        }
        settingsWindowController?.showWindow(nil)
        settingsWindowController?.window?.makeKeyAndOrderFront(nil)
    }

    // MARK: - View

    /// Toggles typewriter scrolling, persists the choice, and applies it to every
    /// open document immediately.
    @MainActor @objc func toggleTypewriterMode(_ sender: Any?) {
        let newValue = !AppDelegate.typewriterModeEnabled()
        UserDefaults.standard.set(newValue, forKey: AppDelegate.typewriterModeKey)
        for case let doc as Document in NSDocumentController.shared.documents {
            doc.editor?.typewriterModeEnabled = newValue
        }
    }

    @MainActor func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(toggleTypewriterMode(_:)) {
            menuItem.state = AppDelegate.typewriterModeEnabled() ? .on : .off
        }
        return true
    }

    // MARK: - Open Document

    /// Manual Open panel — bypasses NSDocumentController's type validation
    /// which is broken without Info.plist.
    @MainActor @objc func openDocumentManually(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true

        let complete: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            NSDocumentController.shared.openDocument(
                withContentsOf: url, display: true
            ) { _, _, error in
                if let error = error {
                    NSAlert(error: error).runModal()
                }
            }
        }

        // Attach the panel to the front window as a sheet so it's always visible
        // — a free-floating panel can open off-screen or behind the window
        // (the app's windows can launch off-screen), which looks like a hang.
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            panel.beginSheetModal(for: window, completionHandler: complete)
        } else {
            panel.begin(completionHandler: complete)
        }
    }

    // MARK: - Menu Bar

    @MainActor private func setupMenuBar() {
        let mainMenu = NSMenu()

        // App menu (required for Cmd+Q)
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Settings\u{2026}",
                        action: #selector(AppDelegate.showSettings(_:)),
                        keyEquivalent: ",")

        appMenu.addItem(NSMenuItem.separator())

        appMenu.addItem(withTitle: "Quit md",
                        action: #selector(NSApplication.terminate(_:)),
                        keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        // File menu — NSDocument provides the standard actions
        let fileMenuItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")

        fileMenu.addItem(withTitle: "New",
                         action: #selector(NSDocumentController.newDocument(_:)),
                         keyEquivalent: "n")

        fileMenu.addItem(withTitle: "Open\u{2026}",
                         action: #selector(AppDelegate.openDocumentManually(_:)),
                         keyEquivalent: "o")

        // Recent documents submenu
        let recentMenuItem = NSMenuItem(title: "Open Recent", action: nil, keyEquivalent: "")
        let recentMenu = NSMenu(title: "Open Recent")
        recentMenu.addItem(withTitle: "Clear Menu",
                           action: #selector(NSDocumentController.clearRecentDocuments(_:)),
                           keyEquivalent: "")
        recentMenuItem.submenu = recentMenu
        fileMenu.addItem(recentMenuItem)

        fileMenu.addItem(NSMenuItem.separator())

        fileMenu.addItem(withTitle: "Save",
                         action: #selector(NSDocument.save(_:)),
                         keyEquivalent: "s")

        fileMenu.addItem(NSMenuItem.separator())

        fileMenu.addItem(withTitle: "Rename\u{2026}",
                         action: #selector(Document.rename(_:)),
                         keyEquivalent: "")

        fileMenu.addItem(withTitle: "Move To\u{2026}",
                         action: #selector(Document.move(_:)),
                         keyEquivalent: "")

        fileMenuItem.submenu = fileMenu
        mainMenu.addItem(fileMenuItem)

        // Edit menu (required for Cmd+C/V/X/A/Z)
        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")

        editMenu.addItem(withTitle: "Undo",
                         action: #selector(EditorTextView.undo(_:)),
                         keyEquivalent: "z")

        let redoItem = editMenu.addItem(withTitle: "Redo",
                                        action: #selector(EditorTextView.redo(_:)),
                                        keyEquivalent: "z")
        redoItem.keyEquivalentModifierMask = [.command, .shift]

        editMenu.addItem(NSMenuItem.separator())

        editMenu.addItem(withTitle: "Cut",
                         action: #selector(NSText.cut(_:)),
                         keyEquivalent: "x")

        editMenu.addItem(withTitle: "Copy",
                         action: #selector(NSText.copy(_:)),
                         keyEquivalent: "c")

        editMenu.addItem(withTitle: "Paste",
                         action: #selector(NSText.paste(_:)),
                         keyEquivalent: "v")

        editMenu.addItem(withTitle: "Select All",
                         action: #selector(NSText.selectAll(_:)),
                         keyEquivalent: "a")

        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        // View menu
        let viewMenuItem = NSMenuItem()
        let viewMenu = NSMenu(title: "View")

        let typewriterItem = viewMenu.addItem(
            withTitle: "Typewriter Mode",
            action: #selector(AppDelegate.toggleTypewriterMode(_:)),
            keyEquivalent: "")
        typewriterItem.state = AppDelegate.typewriterModeEnabled() ? .on : .off

        viewMenuItem.submenu = viewMenu
        mainMenu.addItem(viewMenuItem)

        NSApplication.shared.mainMenu = mainMenu
    }
}

// --- Launch -----------------------------------------------------------------
let app = NSApplication.shared

// Must be created before NSDocumentController.shared is first accessed.
let _ = DocumentController()

let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.activate(ignoringOtherApps: true)
app.run()
