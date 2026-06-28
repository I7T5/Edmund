import AppKit
import UniformTypeIdentifiers
import EdmundCore

/// NSDocument subclass that provides standard macOS document lifecycle:
/// file open/save, dirty-dot indicator, click-to-rename in the titlebar,
/// recent documents, and more — all for free.
///
/// The actual editing is delegated entirely to `EditorTextView`.
class Document: NSDocument, HeadingNavigable {

    var editor: EditorTextView!
    private var statusBar: StatusBarView!
    private var viewModeButton: NSButton?
    private static let viewModeItemID = NSToolbarItem.Identifier("viewMode")

    /// Editor scroll view and its container, held so Read mode can swap the
    /// editor out for a `ReadModeWebView` (created lazily on first read).
    private var scrollView: NSScrollView!
    private var containerView: NSView!
    private var readView: ReadModeWebView?

    /// Content loaded from disk before the editor window exists.
    /// `nonisolated(unsafe)` because `read(from:ofType:)` may be called
    /// off the main actor, but the value is only consumed on main via `showWindows`.
    nonisolated(unsafe) var pendingContent: String?

    // MARK: - Type Registration
    //
    // Without an Info.plist (SPM executable), NSDocument's default readableTypes
    // and writableTypes are empty, which causes NSDocumentController to disable
    // Open/Save entirely. We override them here.

    override class var readableTypes: [String] {
        ["public.plain-text", "net.daringfireball.markdown"]
    }

    override class var writableTypes: [String] {
        ["net.daringfireball.markdown", "public.plain-text"]
    }

    override class var autosavesInPlace: Bool {
        AppSettings.autoSaveWithVersions
    }

    override class func isNativeType(_ name: String) -> Bool {
        return readableTypes.contains(name)
    }

    // A single writable type keeps the save panel from showing a file-format
    // popup. Everything we write is markdown, so there's nothing to choose.
    override func writableTypes(for saveOperation: NSDocument.SaveOperationType) -> [String] {
        ["net.daringfireball.markdown"]
    }

    // The `net.daringfireball.markdown` UTI prefers the ".markdown" extension;
    // force ".md" instead, which is what people actually expect.
    override func fileNameExtension(forType typeName: String,
                                    saveOperation: NSDocument.SaveOperationType) -> String? {
        "md"
    }

    // `fileNameExtension(forType:…)` alone isn't enough: for an untitled save
    // the panel still seeds its name field from the markdown UTI's preferred
    // extension (".markdown"). Force the default name to end in ".md" and let
    // the user type any other extension if they really want one.
    override func prepareSavePanel(_ savePanel: NSSavePanel) -> Bool {
        savePanel.allowedContentTypes = []
        savePanel.allowsOtherFileTypes = true
        let base = (savePanel.nameFieldStringValue as NSString).deletingPathExtension
        savePanel.nameFieldStringValue = (base.isEmpty ? "Untitled" : base) + ".md"
        return true
    }

    // MARK: - Window Setup

    override func makeWindowControllers() {
        // Default content size for first launch. Any saved size is applied as a
        // full window frame at the end of setup (below), once the toolbar is in
        // place — so the frame round-trips exactly and doesn't drift by the
        // title bar + toolbar height each time.
        let windowWidth: CGFloat = 800
        let windowHeight: CGFloat = 560

        let window = DocumentWindow(
            contentRect: NSRect(x: 0, y: 0, width: windowWidth, height: windowHeight),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = false
        window.isMovableByWindowBackground = true
        // Don't persist/restore document windows: macOS state restoration
        // otherwise reopens the last-edited file on the next launch, so a fresh
        // start (or File ▸ New) shows that document instead of a blank Untitled.
        window.isRestorable = AppSettings.reopenWindows
        window.minSize = NSSize(width: 320, height: 400)
        window.backgroundColor = NSColor.textBackgroundColor

        // Build the TextKit 2 text system chain (viewport-based layout).
        editor = EditorTextView.makeTextKit2(
            frame: NSRect(x: 0, y: 0, width: windowWidth, height: windowHeight),
            containerSize: NSSize(width: windowWidth, height: CGFloat.greatestFiniteMagnitude)
        )
        editor.minSize = NSSize(width: 0, height: 0)
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                height: CGFloat.greatestFiniteMagnitude)
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.textContainerInset = NSSize(width: 24, height: 18)
        // Centered reading column (see EditorTextView+ContentWidth); applies the
        // persisted fraction now and recomputes the inset on every resize.
        editor.contentWidthFraction = CGFloat(AppSettings.contentWidthFraction)
        editor.updateContentInset()
        editor.typewriterModeEnabled = AppDelegate.typewriterModeEnabled()
        editor.document = self

        // Toolbar holds the right-aligned view-mode toggle (and gives the
        // titlebar extra height for roomy traffic lights). Set it only after
        // `editor` exists — assigning the toolbar synchronously vends its items.
        let toolbar = NSToolbar(identifier: "MainToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = true
        toolbar.autosavesConfiguration = true   // persists layout per "MainToolbar"
        window.toolbar = toolbar
        window.toolbarStyle = .unified
        window.titlebarSeparatorStyle = .line

        // Wire the window's secondary-click interception now that the toolbar has
        // synchronously vended the view-mode button (see DocumentWindow).
        window.viewModeButton = viewModeButton
        window.makeViewModeMenu = { [weak self] in self?.viewModeMenu() ?? NSMenu() }

        let statusBarHeight: CGFloat = 22
        let contentBounds = window.contentView!.bounds

        // The text view fills the whole window; the status bar floats over its
        // bottom edge, revealed on hover.
        scrollView = NSScrollView(frame: contentBounds)
        scrollView.autoresizingMask = [.width, .height]
        scrollView.hasVerticalScroller = true
        scrollView.scrollerStyle = .overlay
        scrollView.drawsBackground = false
        scrollView.documentView = editor

        // Floating status bar: hidden by default, fades in when the pointer
        // enters its strip. Counts on the left, line ending on the right.
        statusBar = StatusBarView(frame: NSRect(
            x: 0, y: 0, width: contentBounds.width, height: statusBarHeight
        ))
        statusBar.autoresizingMask = [.width]

        containerView = NSView(frame: contentBounds)
        containerView.autoresizesSubviews = true
        containerView.addSubview(scrollView)
        containerView.addSubview(statusBar)   // overlay, on top of the text

        window.contentView = containerView

        NotificationCenter.default.addObserver(
            self, selector: #selector(editorDidChange(_:)),
            name: NSText.didChangeNotification, object: editor
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(editorSelectionDidChange(_:)),
            name: NSTextView.didChangeSelectionNotification, object: editor
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowDidResize(_:)),
            name: NSWindow.didResizeNotification, object: window
        )

        // Restore the last window's frame size (the toolbar is now installed, so
        // the frame is final). Applied as a frame, not a contentRect, so it
        // round-trips exactly with what windowDidResize saves. Then center.
        if let savedSize = AppSettings.lastWindowSize {
            window.setFrame(NSRect(origin: window.frame.origin, size: savedSize), display: false)
        }
        window.center()

        let wc = NSWindowController(window: window)
        addWindowController(wc)
        window.makeFirstResponder(editor)
        // Honor the persisted source-mode preference for the editing view.
        if AppSettings.sourceMode { setViewMode(.source) }
        updateStatusBar()
    }

    @objc private func windowDidResize(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        // Save the full frame size; it's restored verbatim via setFrame on the
        // next window, so the size round-trips exactly (no title-bar/toolbar drift).
        AppSettings.lastWindowSize = window.frame.size
    }

    @objc private func editorDidChange(_ notification: Notification) {
        updateStatusBar()
        // Keep an open Read view in sync with edits (it renders a snapshot).
        refreshReadView()
    }

    @objc private func editorSelectionDidChange(_ notification: Notification) {
        updateStatusBar()
    }

    private func updateStatusBar() {
        guard let editor = editor, let statusBar = statusBar else { return }
        let text = editor.rawSource
        let nsText = text as NSString
        let wordCount = text.split { $0.isWhitespace || $0.isNewline }.count
        let charCount = text.count

        // Cursor position: 0-based character location and 1-based line number.
        let cursorOffset = editor.selectedRange().location
        let location = min(cursorOffset, nsText.length)
        let upToCursor = nsText.substring(to: location)
        let line = upToCursor.isEmpty ? 1 : upToCursor.components(separatedBy: "\n").count

        // The buffer is always LF; show the file's remembered original ending.
        statusBar.setMetrics(words: wordCount, characters: charCount,
                             location: location, line: line,
                             lineEnding: editor.originalLineEnding.displayName)
    }

    // MARK: - Reading

    override nonisolated func read(from data: Data, ofType typeName: String) throws {
        guard let contents = String(data: data, encoding: .utf8) else {
            Log.error("Read failed: \(data.count) bytes not valid UTF-8", category: .io)
            throw NSError(domain: NSOSStatusErrorDomain, code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Could not read file as UTF-8"])
        }
        Log.info("Read \(data.count) bytes from disk", category: .io)
        pendingContent = contents
    }

    /// Called after makeWindowControllers when opening an existing file.
    override func showWindows() {
        super.showWindows()
        if let content = pendingContent {
            editor?.loadContent(content)
            pendingContent = nil
            warnIfInconsistentLineEndings(in: content)
        }
        updateStatusBar()
    }

    /// Warn (once, suppressibly) when an opened file mixed line-ending styles.
    /// The buffer has already been normalized to a single style for editing.
    private func warnIfInconsistentLineEndings(in content: String) {
        guard LineEnding.isInconsistent(in: content),
              !AppSettings.suppressInconsistentLineEndingWarning,
              let window = windowControllers.first?.window else { return }

        let alert = NSAlert()
        alert.messageText = "Inconsistent Line Endings"
        alert.informativeText = "This document mixes different line endings. "
            + "It will be saved using \(editor?.originalLineEnding.displayName ?? "LF") throughout."
        alert.addButton(withTitle: "OK")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Do not warn about inconsistent line endings"
        alert.beginSheetModal(for: window) { _ in
            if alert.suppressionButton?.state == .on {
                AppSettings.suppressInconsistentLineEndingWarning = true
            }
        }
    }

    /// Cross-file link following: scroll this document's editor to a heading
    /// once it's on screen (the content has already loaded in showWindows).
    func navigateToHeading(_ heading: String) {
        editor?.scrollToHeading(heading)
    }

    // MARK: - Rename & Move (manual — NSDocument's built-in versions
    //         are disabled without Info.plist / .app bundle)

    override func rename(_ sender: Any?) {
        guard let url = fileURL, let window = windowControllers.first?.window else { return }
        let panel = NSSavePanel()
        panel.directoryURL = url.deletingLastPathComponent()
        panel.nameFieldStringValue = url.lastPathComponent
        panel.prompt = "Rename"
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let newURL = panel.url else { return }
            do {
                try FileManager.default.moveItem(at: url, to: newURL)
                self.fileURL = newURL
            } catch {
                NSAlert(error: error).runModal()
            }
        }
    }

    override func move(_ sender: Any?) {
        guard let url = fileURL, let window = windowControllers.first?.window else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Move"
        panel.message = "Choose a new location for \"\(url.lastPathComponent)\""
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let destDir = panel.url else { return }
            let newURL = destDir.appendingPathComponent(url.lastPathComponent)
            do {
                try FileManager.default.moveItem(at: url, to: newURL)
                self.fileURL = newURL
            } catch {
                NSAlert(error: error).runModal()
            }
        }
    }

    // MARK: - View Mode (edit / reading / source)

    private func icon(for mode: EditorTextView.ViewMode) -> NSImage? {
        let name: String
        switch mode {
        case .edit:    name = "pencil"
        case .reading: name = "book"
        case .source:  name = "chevron.left.forwardslash.chevron.right"
        }
        return NSImage(systemSymbolName: name, accessibilityDescription: label(for: mode))
    }

    private func label(for mode: EditorTextView.ViewMode) -> String {
        switch mode {
        case .edit:    return "Edit"
        case .reading: return "Read"
        case .source:  return "Source"
        }
    }

    /// Shows the active mode's icon on the button and keeps the tooltip in sync.
    private func refreshViewModeButton() {
        guard let editor else { return }
        // The `</>` source glyph reads wider/larger than pencil and book at the
        // same point size, so render it a touch smaller to match visually.
        let pointSize: CGFloat = editor.viewMode == .source ? 11 : 13
        viewModeButton?.image = icon(for: editor.viewMode)?
            .withSymbolConfiguration(.init(pointSize: pointSize, weight: .regular))
        viewModeButton?.toolTip = "View mode: \(label(for: editor.viewMode))"
    }

    private func setViewMode(_ mode: EditorTextView.ViewMode) {
        editor.viewMode = mode
        applyViewMode(mode)
        refreshViewModeButton()
    }

    /// Swaps the on-screen view for the mode: Read mode shows the rendered-HTML
    /// `ReadModeWebView`; Edit and Source stay on the editor's scroll view.
    private func applyViewMode(_ mode: EditorTextView.ViewMode) {
        guard let containerView else { return }
        if mode == .reading {
            let read = readView ?? {
                let v = ReadModeWebView()
                v.frame = scrollView.frame
                v.autoresizingMask = [.width, .height]
                // Below the floating status bar so counts stay visible.
                containerView.addSubview(v, positioned: .below, relativeTo: statusBar)
                // Route internal navigation through the editor's link resolver
                // (which resolves against this document's directory and opens via
                // NSDocumentController) instead of navigating the webview.
                v.onOpenWikiLink = { [weak self] in self?.editor.followWikiLink($0) }
                v.onOpenInternalLink = { [weak self] in self?.editor.followLinkDestination($0) }
                readView = v
                return v
            }()
            read.render(markdown: editor.rawSource,
                        theme: editor.theme,
                        callouts: mergedCallouts,
                        baseURL: documentDirectory,
                        options: renderOptions)
            read.isHidden = false
            scrollView.isHidden = true
            editor.window?.makeFirstResponder(read)
        } else {
            readView?.isHidden = true
            scrollView.isHidden = false
            editor.window?.makeFirstResponder(editor)
        }
    }

    /// Re-renders an open Read view from the editor's current source + theme.
    /// No-op unless Read mode is the active, visible view — so settings/edit
    /// broadcasts stay cheap when the user is in Edit or Source mode.
    func refreshReadView() {
        guard let read = readView, !read.isHidden, editor?.viewMode == .reading else { return }
        read.render(markdown: editor.rawSource,
                    theme: editor.theme,
                    callouts: mergedCallouts,
                    baseURL: documentDirectory,
                    options: renderOptions)
    }

    /// The opened file's directory, used to resolve relative image paths for
    /// inlining (nil for an unsaved document).
    private var documentDirectory: URL? {
        fileURL?.deletingLastPathComponent()
    }

    /// Built-in callout styles merged with the editor's user overrides, so Read
    /// mode and the PDF match exactly what the editor draws.
    private var mergedCallouts: [String: CalloutStyle] {
        var m = Callout.defaultStyles
        for (k, v) in editor.calloutStyleOverrides { m[k] = v }
        return m
    }

    /// Read-mode/export render options derived from user settings.
    private var renderOptions: ReadRenderOptions {
        ReadRenderOptions(preserveBlankLines: AppSettings.renderBlankLinesAsBreaks)
    }

    // MARK: - Export / Print

    @objc func exportToPDF(_ sender: Any?) {
        let name = (displayName as NSString).deletingPathExtension
        MarkdownPrinter.exportPDF(markdown: editor.rawSource,
                                  theme: editor.theme,
                                  callouts: mergedCallouts,
                                  baseURL: documentDirectory,
                                  options: renderOptions,
                                  suggestedName: name.isEmpty ? "Untitled" : name,
                                  window: windowControllers.first?.window)
    }

    @objc override func printDocument(_ sender: Any?) {
        MarkdownPrinter.print(markdown: editor.rawSource,
                              theme: editor.theme,
                              callouts: mergedCallouts,
                              baseURL: documentDirectory,
                              options: renderOptions,
                              window: windowControllers.first?.window)
    }

    /// The editing-side view: Source when source mode is on, otherwise Edit.
    /// Read is the other half of the toggle.
    private var editingMode: EditorTextView.ViewMode {
        AppSettings.sourceMode ? .source : .edit
    }

    @objc private func selectEditMode(_ sender: Any?)    { setViewMode(editingMode) }
    @objc private func selectReadingMode(_ sender: Any?) { setViewMode(.reading) }

    /// The "Source mode" checkbox (button menu and View menu). Persists the
    /// setting and, if we're in the editing view, swaps it to the new editing
    /// mode right away.
    @objc func toggleSourceMode(_ sender: Any?) {
        AppSettings.sourceMode.toggle()
        if editor.viewMode != .reading { setViewMode(editingMode) }
    }

    /// Keeps the View-menu "Source Mode" checkmark in sync with the setting.
    override func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(toggleSourceMode(_:)) {
            item.state = AppSettings.sourceMode ? .on : .off
        }
        return super.validateMenuItem(item)
    }

    /// Toggle the editing view ↔ Read (the View-menu ⌘E item and the toolbar
    /// button). With source mode on the editing view is Source, so this flips
    /// Source ↔ Read; otherwise Edit ↔ Read.
    @objc func toggleViewMode(_ sender: Any?) {
        setViewMode(editor.viewMode == .reading ? editingMode : .reading)
    }

    /// One mode menu item: icon + title, checked when `on`.
    private func menuItem(_ title: String, _ image: NSImage?,
                          _ action: Selector, on: Bool) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.image = image
        item.state = on ? .on : .off
        return item
    }

    /// The right-click menu: Edit / Read selection, a divider, then the
    /// "Source mode" checkbox. Built fresh each time so state stays current.
    fileprivate func viewModeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false   // actions always fire on selection
        let inEditing = editor?.viewMode != .reading
        menu.addItem(menuItem("Edit", icon(for: .edit),
                              #selector(selectEditMode(_:)), on: inEditing))
        menu.addItem(menuItem("Read", icon(for: .reading),
                              #selector(selectReadingMode(_:)), on: !inEditing))
        menu.addItem(.separator())
        menu.addItem(menuItem("Source mode", icon(for: .source),
                              #selector(toggleSourceMode(_:)), on: AppSettings.sourceMode))
        return menu
    }

    // MARK: - Writing

    override func data(ofType typeName: String) throws -> Data {
        // The buffer is always LF; restore the file's original line ending on
        // write so opening, then saving, doesn't silently rewrite every line.
        let normalized = editor?.rawSource ?? ""
        let ending = editor?.originalLineEnding ?? .lf
        let text = ending == .lf
            ? normalized
            : normalized.replacingOccurrences(of: "\n", with: ending.string)
        guard let data = text.data(using: .utf8) else {
            Log.error("Save failed: could not encode \(text.count) chars as UTF-8", category: .io)
            throw NSError(domain: NSOSStatusErrorDomain, code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Could not encode text as UTF-8"])
        }
        Log.info("Saving \(data.count) bytes (\(ending.displayName))", category: .io)
        return data
    }
}

// MARK: - Toolbar (view-mode toggle)

extension Document: NSToolbarDelegate {
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, Self.viewModeItemID]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, .space, Self.viewModeItemID]
    }

    func toolbar(_ toolbar: NSToolbar,
                 itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard itemIdentifier == Self.viewModeItemID else { return nil }
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.label = "View Mode"
        item.visibilityPriority = .high

        // Left-click toggles the editing view ↔ Read. The right-click mode menu
        // is handled upstream in DocumentWindow.sendEvent — every view-level
        // approach (the view's `menu`, rightMouseDown, a gesture recognizer)
        // loses the secondary click to the toolbar's "Customize Toolbar…" menu.
        let button = NSButton(image: NSImage(), target: self,
                              action: #selector(toggleViewMode(_:)))
        button.bezelStyle = .texturedRounded
        button.imagePosition = .imageOnly
        viewModeButton = button
        item.view = button
        refreshViewModeButton()
        return item
    }
}

/// Document window that intercepts a secondary (right / control) click on the
/// view-mode toolbar button and shows the mode menu itself. `sendEvent` is the
/// single funnel all window events pass through *before* the toolbar/titlebar
/// can turn the click into its own "Customize Toolbar…" context menu, so this is
/// the one place the interception reliably wins.
final class DocumentWindow: NSWindow {
    weak var viewModeButton: NSView?
    var makeViewModeMenu: (() -> NSMenu)?

    override func sendEvent(_ event: NSEvent) {
        if isSecondaryClick(event), let button = viewModeButton,
           button.bounds.contains(button.convert(event.locationInWindow, from: nil)),
           let menu = makeViewModeMenu?() {
            menu.popUp(positioning: nil,
                       at: NSPoint(x: 0, y: button.bounds.maxY + 4), in: button)
            return
        }
        super.sendEvent(event)
    }

    private func isSecondaryClick(_ event: NSEvent) -> Bool {
        switch event.type {
        case .rightMouseDown: return true
        case .leftMouseDown:  return event.modifierFlags.contains(.control)
        default:              return false
        }
    }
}
