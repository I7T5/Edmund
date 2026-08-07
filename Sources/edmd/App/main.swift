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
    let servicesProvider = ServicesProvider()
    // startingUpdater: true kicks off the scheduled background check immediately;
    // the "Check for Updates…" menu item targets this controller directly.
    // `-debug.disableUpdater YES` skips the start entirely: on dev builds the
    // failed check throws a *modal* "updater failed" alert at launch that
    // blocks the whole app (no document window until dismissed), which breaks
    // scripted/automated runs.
    let updaterController = SPUStandardUpdaterController(
        startingUpdater: !UserDefaults.standard.bool(forKey: "debug.disableUpdater"),
        updaterDelegate: nil, userDriverDelegate: nil)

    // MARK: - Typewriter Mode (persisted)

    static let typewriterModeKey = "EditorTypewriterMode"

    /// Whether typewriter scrolling is enabled. Defaults to on (the historical
    /// behavior) when nothing has been saved yet.
    static func typewriterModeEnabled(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: typewriterModeKey) as? Bool ?? true
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppSettings.applyLogging()
        AppSettings.applyAutosaving()
        Log.info("Edmund launched", category: .app)
        AppSettings.applyAppearance()
        AppSettings.applyCodeSyntax()
        AppSettings.applyExtensionStates()
        setupMenuBar()

        // Right-click ▸ Services entries (see Info.plist NSServices). Held
        // strongly — `NSApplication.servicesProvider` does not retain.
        NSApp.servicesProvider = servicesProvider

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

    // Declares that our restorable state is archived with secure coding — not a
    // switch for whether windows come back. Wiring it to the "Reopen windows"
    // preference only opted the app into legacy insecure archiving.
    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        AppSettings.quitWhenAllWindowsClosed
    }

    // Document windows stay restorable all session so a crash can hand back
    // unsaved work (Document.makeWindowControllers). On a clean quit, honor
    // "Reopen windows from last session" instead: drop the flag before AppKit
    // archives the window state, so the next launch has nothing to restore.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if !AppSettings.reopenWindows {
            for window in NSApp.windows { window.isRestorable = false }
        }
        return .terminateNow
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

    /// Toggles focus-mode dimming, persists the choice, and applies it to every
    /// open document immediately. The Settings checkbox binds the same key.
    @MainActor @objc func toggleFocusMode(_ sender: Any?) {
        UserDefaults.standard.set(!AppSettings.focusMode, forKey: AppSettings.Key.focusMode)
        AppSettings.applyEditSettingsToOpenDocuments()
    }

    @MainActor func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(toggleTypewriterMode(_:)) {
            menuItem.state = AppDelegate.typewriterModeEnabled() ? .on : .off
        }
        if menuItem.action == #selector(toggleFocusMode(_:)) {
            menuItem.state = AppSettings.focusMode ? .on : .off
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

    /// Edit ▸ Find. Edmund's own commands, so they are rebindable — the standard
    /// Edit items above them (Cut/Copy/Paste, Undo) keep their system shortcuts.
    @MainActor private static let findCommands: [MenuCommand] = [
        MenuCommand(id: "find.show", group: "Edit", submenu: "Find", title: "Find\u{2026}",
                    action: #selector(EditorTextView.showFindBar(_:)), shortcut: .cmd("f")),
        MenuCommand(id: "find.replace", group: "Edit", submenu: "Find", title: "Find and Replace\u{2026}",
                    action: #selector(EditorTextView.showFindReplaceBar(_:)), shortcut: .cmdOpt("f")),
        MenuCommand(id: "find.next", group: "Edit", submenu: "Find", title: "Find Next",
                    action: #selector(EditorTextView.findNext(_:)), shortcut: .cmd("g")),
        MenuCommand(id: "find.previous", group: "Edit", submenu: "Find", title: "Find Previous",
                    action: #selector(EditorTextView.findPrevious(_:)), shortcut: .cmdShift("g")),
    ]

    @MainActor private func setupMenuBar() {
        // Before any `makeItem()`, which resolves each command's override by id.
        KeyBindingStore.migrateRenamedIDs()

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

        // Recent documents submenu. AppKit fills this in by itself only for a
        // menu that came out of a nib marked systemMenu="recentDocuments" —
        // there is no API to say the same thing about a menu built in code, so
        // a hand-made one just sits there empty (the documents *are* recorded;
        // it's only the menu that never hears about them). Fill it on open
        // instead, from NSDocumentController's own list.
        let recentMenuItem = NSMenuItem(title: "Open Recent", action: nil, keyEquivalent: "")
        let recentMenu = NSMenu(title: "Open Recent")
        recentMenu.delegate = self
        recentMenuItem.submenu = recentMenu
        fileMenu.addItem(recentMenuItem)

        fileMenu.addItem(NSMenuItem.separator())

        fileMenu.addItem(withTitle: "Save",
                         action: #selector(NSDocument.save(_:)),
                         keyEquivalent: "s")

        fileMenu.addItem(NSMenuItem.separator())

        // Edmund's own File commands are rebindable (Settings ▸ Key Bindings);
        // the standard New/Open/Save/Print above keep their system shortcuts.
        fileMenu.addItem(MenuCommand(id: "file.rename", group: "File", title: "Rename\u{2026}",
                                     action: #selector(Document.rename(_:))).makeItem())

        fileMenu.addItem(MenuCommand(id: "file.moveTo", group: "File", title: "Move To\u{2026}",
                                     action: #selector(Document.move(_:))).makeItem())

        fileMenu.addItem(NSMenuItem.separator())

        fileMenu.addItem(MenuCommand(id: "file.exportPDF", group: "File", title: "Export as PDF\u{2026}",
                                     action: #selector(Document.exportToPDF(_:))).makeItem())

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

        editMenu.addItem(NSMenuItem.separator())

        // Typing behaviour rather than window furniture, so they sit here with
        // Hard Wrap Paragraphs instead of in View. Renamed off the `view.`
        // prefix to match; `KeyBindingStore.migrateRenamedIDs` carries any
        // shortcut the user had set across to the new ids.
        let typewriterItem = MenuCommand(id: "edit.typewriterScroll", group: "Edit",
                                         title: "Typewriter Scroll",
                                         action: #selector(AppDelegate.toggleTypewriterMode(_:))).makeItem()
        typewriterItem.state = AppDelegate.typewriterModeEnabled() ? .on : .off
        editMenu.addItem(typewriterItem)

        // Dims everything but the lines the selection touches. Same setting as
        // Settings ▸ Edit ▸ Editor, so the two always agree.
        let focusItem = MenuCommand(id: "edit.focusMode", group: "Edit", title: "Focus Mode",
                                    action: #selector(AppDelegate.toggleFocusMode(_:))).makeItem()
        focusItem.state = AppSettings.focusMode ? .on : .off
        editMenu.addItem(focusItem)

        editMenu.addItem(NSMenuItem.separator())

        // Reflows the selected paragraphs, or the whole document when nothing
        // is selected. The manual counterpart to Settings ▸ Edit ▸ Document,
        // which only wraps files that already arrived wrapped. First-responder
        // routing like the Find items, so it greys out in Reading mode.
        editMenu.addItem(withTitle: "Hard Wrap Paragraphs",
                         action: #selector(EditorTextView.hardWrapParagraphs(_:)),
                         keyEquivalent: "")

        editMenu.addItem(NSMenuItem.separator())

        // Find submenu — routes to first-responder actions on EditorTextView,
        // which forward to the document's FindController. Grays out in Reading
        // mode (the web view is first responder and implements none of these).
        let findMenuItem = NSMenuItem()
        let findMenu = NSMenu(title: "Find")
        for command in Self.findCommands { findMenu.addItem(command.makeItem()) }
        findMenuItem.submenu = findMenu
        findMenuItem.title = "Find"
        editMenu.addItem(findMenuItem)

        // The standard text submenus, same first-responder routing as Find.
        // NSTextView supplies the actions *and* the checkmark state for the
        // toggles (our validateMenuItem override falls through to super for
        // anything that isn't a formatting command).
        //
        // In Reading mode the editing commands gray out — measured: all of
        // Transformations, plus Show Spelling and Check Document Now. The two
        // spell-checking toggles and Start Speaking stay live, because the web
        // view answers those selectors itself; both are harmless there (they
        // act on the rendered view, not the source).
        //
        // Substitutions is deliberately absent: smart quotes/dashes, text
        // replacement and autocorrect are switched off in
        // `EditorTextView.commonInit()` on purpose — they rewrite typed Markdown
        // and the completion machinery can strand marked text, breaking the
        // storage == rawSource invariant. Same reason "Correct Spelling
        // Automatically" is left out of Spelling and Grammar below.
        let spellingMenu = NSMenu(title: "Spelling and Grammar")
        spellingMenu.addItem(withTitle: "Show Spelling and Grammar",
                             action: #selector(NSText.showGuessPanel(_:)),
                             keyEquivalent: ":")
        spellingMenu.addItem(withTitle: "Check Document Now",
                             action: #selector(NSText.checkSpelling(_:)),
                             keyEquivalent: ";")
        spellingMenu.addItem(.separator())
        spellingMenu.addItem(withTitle: "Check Spelling While Typing",
                             action: #selector(NSTextView.toggleContinuousSpellChecking(_:)),
                             keyEquivalent: "")
        spellingMenu.addItem(withTitle: "Check Grammar With Spelling",
                             action: #selector(NSTextView.toggleGrammarChecking(_:)),
                             keyEquivalent: "")
        let spellingItem = NSMenuItem()
        spellingItem.title = "Spelling and Grammar"
        spellingItem.submenu = spellingMenu
        editMenu.addItem(spellingItem)

        let transformMenu = NSMenu(title: "Transformations")
        transformMenu.addItem(withTitle: "Make Upper Case",
                              action: #selector(NSResponder.uppercaseWord(_:)), keyEquivalent: "")
        transformMenu.addItem(withTitle: "Make Lower Case",
                              action: #selector(NSResponder.lowercaseWord(_:)), keyEquivalent: "")
        transformMenu.addItem(withTitle: "Capitalize",
                              action: #selector(NSResponder.capitalizeWord(_:)), keyEquivalent: "")
        let transformItem = NSMenuItem()
        transformItem.title = "Transformations"
        transformItem.submenu = transformMenu
        editMenu.addItem(transformItem)

        let speechMenu = NSMenu(title: "Speech")
        speechMenu.addItem(withTitle: "Start Speaking",
                           action: #selector(NSTextView.startSpeaking(_:)), keyEquivalent: "")
        speechMenu.addItem(withTitle: "Stop Speaking",
                           action: #selector(NSTextView.stopSpeaking(_:)), keyEquivalent: "")
        let speechItem = NSMenuItem()
        speechItem.title = "Speech"
        speechItem.submenu = speechMenu
        editMenu.addItem(speechItem)

        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        // Format menu — built from the declarative command registry.
        mainMenu.addItem(FormatMenu.build())

        // Editor right-click Font submenu mirrors Format ▸ Font.
        EditorTextView.contextFontMenuProvider = { FormatMenu.fontMenu() }

        // View menu — built in its own file (ViewMenu.swift).
        mainMenu.addItem(ViewMenu.build())

        // Window menu — built in its own file (WindowMenu.swift). Assigning
        // the submenu to `windowsMenu` (not just adding the item) makes
        // AppKit auto-populate the open-window list and checkmark below the
        // static Minimize/Zoom/Bring All to Front items.
        let windowMenuItem = WindowMenu.build()
        mainMenu.addItem(windowMenuItem)
        NSApplication.shared.windowsMenu = windowMenuItem.submenu

        NSApplication.shared.mainMenu = mainMenu
    }
}

// MARK: - Open Recent

/// Rebuilds the Open Recent menu each time it opens (see the note where the
/// menu is created). The list itself is macOS's — every open goes through
/// `NSDocumentController.openDocument(withContentsOf:)`, which records it.
extension AppDelegate: NSMenuDelegate {

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        for url in NSDocumentController.shared.recentDocumentURLs {
            let item = menu.addItem(withTitle: url.lastPathComponent,
                                    action: #selector(openRecentDocument(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = url
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            icon.size = NSSize(width: 16, height: 16)
            item.image = icon
        }
        if !menu.items.isEmpty { menu.addItem(.separator()) }
        // nil target → the document controller picks it up off the responder
        // chain, same as every other standard document action here.
        menu.addItem(withTitle: "Clear Menu",
                     action: #selector(NSDocumentController.clearRecentDocuments(_:)),
                     keyEquivalent: "")
    }

    @MainActor @objc private func openRecentDocument(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, error in
            // A recent file can be gone or renamed; AppKit's own alert says so.
            if let error { NSAlert(error: error).runModal() }
        }
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
