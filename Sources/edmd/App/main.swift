import AppKit
import EdmundCore
import Sparkle

// Entry point for the app the user knows as "Edmund" (CFBundleName). The
// executable target — and so this binary at Edmund.app/Contents/MacOS/edmd — is
// named `edmd`, an expansion of "Editor for Markdown". The backronym is the
// app's original working name; it survives only here and in Package.swift, never
// in anything user-facing.

// --- App Delegate -----------------------------------------------------------

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {

    var aboutWindowController: AboutWindowController?
    var settingsWindowController: SettingsWindowController?
    // startingUpdater: true kicks off the scheduled background check immediately;
    // the "Check for Updates…" menu item targets this controller directly.
    let updaterController = SPUStandardUpdaterController(
        startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)

    // MARK: - Typewriter Mode (persisted)

    static let typewriterModeKey = "EditorTypewriterMode"

    /// Whether typewriter scrolling is enabled. Defaults to on (the historical
    /// behavior) when nothing has been saved yet.
    static func typewriterModeEnabled(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: typewriterModeKey) as? Bool ?? true
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppSettings.applyLogging()
        Log.info("Edmund launched", category: .app)
        AppSettings.applyAppearance()
        setupMenuBar()

        // Opt-in (default off): upload any crash reports macOS wrote for us since
        // last launch. Fire-and-forget; never blocks startup.
        if AppSettings.sendCrashLogs {
            CrashReporter.uploadPendingReports(
                alreadySent: AppSettings.sentCrashReports,
                onSent: { AppSettings.sentCrashReports.insert($0) })
        }

        // Open file from command-line argument. When a file is given,
        // `applicationShouldOpenUntitledFile` suppresses the otherwise-automatic
        // blank document, so we don't end up with two windows.
        let args = CommandLine.arguments
        if args.count > 1 {
            let url = URL(fileURLWithPath: args[1])
            Log.info("Opening file from launch argument: \(url.path)", category: .document)
            NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, _ in }
        }

        #if DEBUG
        ReproScript.runIfRequested()
        #endif
    }

    // Auto-open a blank document on launch only when no file was passed on the
    // command line (otherwise the file arg + the blank doc make two windows).
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        CommandLine.arguments.count <= 1 && AppSettings.startupAction == .createNewDocument
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        AppSettings.reopenWindows
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    // Reopen a new untitled document when the app is activated with no windows.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            if AppSettings.startupAction == .createNewDocument {
                NSDocumentController.shared.newDocument(nil)
            }
        }
        return true
    }

    // MARK: - Settings

    @MainActor @objc func showAbout(_ sender: Any?) {
        if aboutWindowController == nil {
            aboutWindowController = AboutWindowController()
        }
        aboutWindowController?.showWindow(nil)
        aboutWindowController?.window?.makeKeyAndOrderFront(nil)
    }

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
        appMenu.addItem(withTitle: "About Edmund",
                        action: #selector(AppDelegate.showAbout(_:)),
                        keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Settings\u{2026}",
                        action: #selector(AppDelegate.showSettings(_:)),
                        keyEquivalent: ",")

        let updatesItem = appMenu.addItem(
            withTitle: "Check for Updates\u{2026}",
            action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)),
            keyEquivalent: "")
        updatesItem.target = updaterController

        appMenu.addItem(NSMenuItem.separator())

        appMenu.addItem(withTitle: "Quit Edmund",
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

        fileMenu.addItem(NSMenuItem.separator())

        fileMenu.addItem(withTitle: "Export as PDF\u{2026}",
                         action: #selector(Document.exportToPDF(_:)),
                         keyEquivalent: "")

        fileMenu.addItem(withTitle: "Print\u{2026}",
                         action: #selector(Document.printDocument(_:)),
                         keyEquivalent: "p")

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

        // Format menu — built from the declarative command registry.
        mainMenu.addItem(FormatMenu.build())

        // View menu
        let viewMenuItem = NSMenuItem()
        let viewMenu = NSMenu(title: "View")

        // Zoom (font size + max content width, scaled together). Target nil
        // routes through the responder chain to the key window's Document.
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

        // Routes through the responder chain to the key window's toolbar.
        viewMenu.addItem(withTitle: "Customize Toolbar…",
                         action: #selector(NSWindow.runToolbarCustomizationPalette(_:)),
                         keyEquivalent: "")

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
